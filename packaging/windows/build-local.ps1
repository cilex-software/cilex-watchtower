# ============================================================
# Cilex Watchtower — LOCAL Windows build + publish (no GitHub Actions)
#
# The Windows twin of the team repo's build-and-push-local.sh idea: when CI
# minutes are unavailable (Actions billing) or you simply prefer local builds,
# run THIS on any Windows 10/11 machine (a plain VM is fine — no GPU needed
# for building) and publish the artifacts to the same rolling GitHub release
# CI uses. Release assets are free — no Actions billing anywhere in this path.
#
#   pwsh packaging\windows\build-local.ps1                 # build only
#   pwsh packaging\windows\build-local.ps1 -Publish        # + gh release upload
#
# Faithful mirror of .github/workflows/windows.yml (keep the two in sync):
# same Qt/GStreamer versions, same preset (RelWithDebInfo -> watchtower.pdb),
# same deploy.ps1, same PyInstaller warden.exe, same NSIS installer.
#
# ---- one-time machine setup (admin) ----------------------------------------
#   winget install Microsoft.VisualStudio.2022.BuildTools --override `
#       "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet"
#   winget install Kitware.CMake Ninja-build.Ninja NSIS.NSIS Python.Python.3.12 Git.Git GitHub.cli
#   pip install aqtinstall
#   aqt install-qt windows desktop 6.12.0 win64_msvc2022_64 -m qtmultimedia qtshadertools -O C:\Qt
#   # GStreamer 1.26.11 MSVC runtime + devel MSIs -> install to C:\gstreamer (from
#   # gstreamer.freedesktop.org; versions MUST match windows.yml's GST_VERSION)
#   gh auth login          # for -Publish
# -----------------------------------------------------------------------------
param(
    [switch]$Publish,
    [string]$QtRoot  = "C:\Qt\6.12.0\msvc2022_64",
    [string]$GstRoot = "C:\gstreamer\1.0\msvc_x86_64",
    [string]$Tag     = "windows-latest"
)
$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $repo

# Pristine-tree guard (same safety property as the team script): artifacts must
# describe a COMMIT, never a dirty working tree.
$dirty = git status --porcelain
if ($dirty) { throw "working tree is dirty - commit or stash first (artifacts must map to a sha)" }
$sha = (git rev-parse --short HEAD).Trim()

# MSVC env (vcvars) if not already in a developer shell.
if (-not $env:VCToolsInstallDir) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw "MSVC Build Tools not found - see one-time setup above" }
    Import-Module (Join-Path $vs "Common7\Tools\Microsoft.VisualStudio.DevShell.dll")
    Enter-VsDevShell -VsInstallPath $vs -Arch amd64 -SkipAutomaticLocation
}

$env:QT_ROOT_DIR = $QtRoot
$env:GSTREAMER_ROOT = $GstRoot
$env:PKG_CONFIG_PATH = Join-Path $GstRoot "lib\pkgconfig"

Write-Host "==> Configure + build ($sha, RelWithDebInfo)"
cmake --preset windows
cmake --build build-windows

Write-Host "==> Deploy runtime (windeployqt + GStreamer subset)"
pwsh packaging/windows/deploy.ps1 `
    -ExePath (Resolve-Path build-windows/watchtower.exe).Path `
    -QmlDir (Resolve-Path qml).Path `
    -GstRuntime $env:GSTREAMER_ROOT

Write-Host "==> warden.exe (CW-16)"
pwsh packaging/windows/build-warden.ps1 -Dist build-windows/dist

Write-Host "==> Stage watchtower.pdb (CW-17 - a dump without its PDB is garbage)"
$pdb = Get-ChildItem build-windows -Filter watchtower.pdb -Recurse | Select-Object -First 1
if (-not $pdb) { throw "watchtower.pdb not found - RelWithDebInfo regressed?" }
Copy-Item $pdb.FullName watchtower.pdb -Force

Write-Host "==> Installer (NSIS)"
Push-Location packaging/windows
makensis installer.nsi
Pop-Location

Compress-Archive -Path build-windows/dist/* -DestinationPath watchtower-windows-portable.zip -Force
Compress-Archive -Path watchtower.pdb -DestinationPath watchtower-pdb.zip -Force
$installer = Get-ChildItem packaging/windows/CilexWatchtower-*-setup.exe | Select-Object -First 1

Write-Host ""
Write-Host "==> Built from ${sha}:"
Write-Host "    $($installer.FullName)"
Write-Host "    watchtower-windows-portable.zip  (incl. warden\warden.exe)"
Write-Host "    watchtower-pdb.zip"

if ($Publish) {
    # Same shape as CI's rolling release: delete + recreate the tag with all
    # three assets. gh only needs `repo` scope; zero Actions involvement.
    Write-Host "==> Publishing to release '$Tag'"
    gh release delete $Tag --yes --cleanup-tag 2>$null
    gh release create $Tag $installer.FullName watchtower-windows-portable.zip watchtower-pdb.zip `
        --prerelease --target (git rev-parse HEAD) `
        --title "Windows local build ($sha)" `
        --notes "Built locally by packaging/windows/build-local.ps1 from $sha (Actions-free path)."
    Write-Host "==> Published. Verify: gh release view $Tag"
}
