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
    [string]$Tag     = "windows-latest",
    [ValidateSet('Yes','No')][string]$UpdateSource='Yes',
    [ValidateSet('Ask','Yes','No')][string]$Rebuild='Ask'
)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Import-Module (Join-Path $PSScriptRoot 'BuildState.psm1')
function Publish-CilexWindowsBuild($Installer,$Portable,$Symbols,[string]$Commit,[string]$Version){
    gh release delete $Tag --yes --cleanup-tag 2>$null
    gh release create $Tag $Installer $Portable $Symbols --prerelease --target $Commit `
        --title "Windows local build $Version" `
        --notes "Built locally by packaging/windows/build-local.ps1 from committed source (Actions-free path)."
    if($LASTEXITCODE -ne 0){throw 'Release publication failed.'}
    Write-Host "==> Published. Verify: gh release view $Tag"
}
$plan=Start-CilexBuild -Repository $repo -BuildProfile 'windows-local' -Update $UpdateSource -Rebuild $Rebuild -Settings @{QtRoot=$QtRoot;GstRoot=$GstRoot;Configuration='RelWithDebInfo'}
if(-not $plan.build){
    if($Publish){
        Set-Location $repo
        $paths=@{};foreach($row in $plan.existing.outputs){$paths[$row.role]=$row.path}
        Publish-CilexWindowsBuild $paths.installer $paths.archive $paths.symbols $plan.existing.commit $plan.version
    }
    [IO.File]::Delete($plan.PlanPath);return
}
Set-Location $plan.source

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

Write-Host "==> Configure + build (version $($plan.version), RelWithDebInfo)"
cmake --preset windows
if($LASTEXITCODE -ne 0){throw 'CMake configure failed.'}
cmake --build build-windows
if($LASTEXITCODE -ne 0){throw 'Compilation failed.'}

Write-Host "==> Deploy runtime (windeployqt + GStreamer subset)"
pwsh packaging/windows/deploy.ps1 `
    -ExePath (Resolve-Path build-windows/watchtower.exe).Path `
    -QmlDir (Resolve-Path qml).Path `
    -GstRuntime $env:GSTREAMER_ROOT
if($LASTEXITCODE -ne 0){throw 'Runtime packaging failed.'}

Write-Host "==> warden.exe (CW-16)"
pwsh packaging/windows/build-warden.ps1 -Dist build-windows/dist -UpdateSource No -Rebuild $Rebuild
if($LASTEXITCODE -ne 0){throw 'Warden build failed.'}

Write-Host "==> Stage watchtower.pdb (CW-17 - a dump without its PDB is garbage)"
$pdb = Get-ChildItem build-windows -Filter watchtower.pdb -Recurse | Select-Object -First 1
if (-not $pdb) { throw "watchtower.pdb not found - RelWithDebInfo regressed?" }
Copy-Item $pdb.FullName watchtower.pdb -Force

Write-Host "==> Installer (NSIS)"
Push-Location packaging/windows
makensis installer.nsi
if($LASTEXITCODE -ne 0){throw 'Installer build failed.'}
Pop-Location

Compress-Archive -Path build-windows/dist/* -DestinationPath watchtower-windows-portable.zip -Force
Compress-Archive -Path watchtower.pdb -DestinationPath watchtower-pdb.zip -Force
$installer = Get-Item -LiteralPath (Join-Path 'packaging/windows' ('CilexWatchtower-'+$plan.version+'-setup.exe'))
Complete-CilexBuild -Plan $plan -Outputs @{binary=(Join-Path $plan.source 'build-windows/dist/watchtower.exe');installer=$installer.FullName;archive=(Join-Path $plan.source 'watchtower-windows-portable.zip');symbols=(Join-Path $plan.source 'watchtower-pdb.zip')}

Write-Host ""
Write-Host "==> Built version $($plan.version):"
Write-Host "    $($installer.FullName)"
Write-Host "    $([IO.Path]::GetFullPath('watchtower-windows-portable.zip'))"
Write-Host "    $([IO.Path]::GetFullPath('watchtower-pdb.zip'))"

if ($Publish) {
    # Same shape as CI's rolling release: delete + recreate the tag with all
    # three assets. gh only needs `repo` scope; zero Actions involvement.
    Write-Host "==> Publishing to release '$Tag'"
    Publish-CilexWindowsBuild $installer.FullName ([IO.Path]::GetFullPath('watchtower-windows-portable.zip')) ([IO.Path]::GetFullPath('watchtower-pdb.zip')) $plan.commit $plan.version
}
