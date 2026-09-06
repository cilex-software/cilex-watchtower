<#
.SYNOPSIS
  Assemble a self-contained Windows dist folder next to the built watchtower.exe.

.DESCRIPTION
  Two stages:
    1) windeployqt  -> Qt DLLs + QML modules + Qt plugins (+ optionally the C++ runtime).
    2) GStreamer    -> the LGPL plugin subset we use (windeployqt does NOT handle GStreamer,
                       because Watchtower links/drives it directly via RtspVideoSource).
  Invoked by the CMake `deploy-windows` target, or run directly after a Windows build.

.EXAMPLE
  pwsh ./deploy.ps1 -ExePath ..\..\build-windows\watchtower.exe -QmlDir ..\..\qml
#>
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$QmlDir,
    # Clean output dir for the shippable dist — deliberately NOT the CMake binary dir, so
    # build junk (.obj / CMakeCache / build.ninja) never lands in the zip or installer.
    [string]$DistDir = (Join-Path (Split-Path -Parent $ExePath) "dist"),
    [string]$GstRuntime = "$PSScriptRoot/_gstreamer/runtime",
    # BtbN's LGPL shared FFmpeg build (genuinely LGPL — no x264/GPL). ClipTranscoder runs
    # `ffmpeg` via QProcess and Windows resolves the app dir first, so ffmpeg.exe beside the
    # exe is picked up. Best-effort in W1 (export is a W2 runtime gate); W4 formalises licences.
    # PINNED to an immutable dated release, not "latest" (audit 2026-09-03, Medium 12):
    # "latest" is a moving tag, so the shipped ffmpeg.exe + DLLs changed under every
    # build with no record of what went out. The hash was computed from the archive
    # itself on 2026-09-06 (sha256sum, 70,835,256 bytes), not copied from a release page.
    [string]$FfmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-09-05-13-10/ffmpeg-n8.1.2-50-g1a748fe2cd-win64-lgpl-shared-8.1.zip",
    [string]$FfmpegSha256 = "8702705c110c706f32522f3b451368df677510a094fbc56d370cd35d24822edf"
)
$ErrorActionPreference = "Stop"

# Fresh dist dir with just the exe; everything else is deployed in next to it.
if (Test-Path $DistDir) { Remove-Item -Recurse -Force $DistDir }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Copy-Item $ExePath -Destination $DistDir -Force
$dist = (Resolve-Path $DistDir).Path
$distExe = Join-Path $dist (Split-Path -Leaf $ExePath)

# 1) Qt runtime. --compiler-runtime ships the VC++ Redistributable DLLs; OMIT it if you build with
#    the Hybrid CRT (static_compiler_runtime, Qt 6.12+) — see README.md.
Write-Host "== windeployqt =="
& windeployqt --release --qmldir "$QmlDir" --compiler-runtime "$distExe"

# 2) GStreamer runtime — LGPL subset ONLY (README.md / DEVELOPMENT.md for the rationale). The
#    live pipeline is rtspsrc ! decodebin(d3d11 HW) ! ... ! appsink; ship its closure, never
#    gst-plugins-ugly (GPL). Copies are best-effort (names drift across GStreamer versions and
#    the full runtime dependency closure is validated on real hardware in W2) — a missing
#    optional DLL logs a warning rather than failing packaging.
Write-Host "== GStreamer bundle (LGPL subset) =="
$gstBin = Join-Path $GstRuntime "bin"
$gstPluginSrc = Join-Path $GstRuntime "lib/gstreamer-1.0"
if (Test-Path $gstBin) {
    # Core + GLib DLLs the pipeline links (LGPL). Copy by glob prefix so patch-version
    # suffixes in the filenames (e.g. gstreamer-1.0-0.dll) are matched.
    $dllPrefixes = @(
        'gstreamer-1.0','gstbase-1.0','gstapp-1.0','gstvideo-1.0','gstrtp-1.0','gstrtsp-1.0',
        'gstsdp-1.0','gstnet-1.0','gstpbutils-1.0','gstaudio-1.0','gsttag-1.0','gstcodecparsers-1.0',
        # d3d11/DXVA hardware-decode closure: gstd3d11.dll links these; without them it fails to
        # load and the live wall gets no hardware decoder (W2, verified on GTX 1070 2026-07-06).
        'gstcodecs-1.0','gstd3d11-1.0','gstdxva-1.0','gstd3dshader-1.0',
        'glib-2.0','gobject-2.0','gmodule-2.0','gio-2.0','gthread-2.0',
        'ffi','intl','z-1','orc-0.4','graphene-1.0','libwinpthread','pcre2-8'
    )
    foreach ($p in $dllPrefixes) {
        Get-ChildItem -Path $gstBin -Filter "$p*.dll" -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName -Destination $dist -Force }
    }
    # LGPL plugin subset -> <dist>\lib\gstreamer-1.0 (GStreamer's default relative plugin path).
    $pluginDst = Join-Path $dist "lib/gstreamer-1.0"
    New-Item -ItemType Directory -Force -Path $pluginDst | Out-Null
    $plugins = @(
        'coreelements','playback','typefindfunctions','videoconvertscale','videoparsersbad',
        # rtspclientsink dropped: the viewer uses rtspsrc (receive), never rtspclientsink (send);
        # its DLL failed to load in W2 (missing deps) and it is unused. See W2 findings 2026-07-06.
        'app','rtp','rtsp','rtpmanager','udp','tcp','autodetect','d3d11'
    )
    foreach ($pl in $plugins) {
        # Windows/MSVC GStreamer plugins are gst<name>.dll (no 'lib' prefix — that's Linux);
        # try both so the copy is correct regardless of the build's convention.
        $copied = $false
        foreach ($name in @("gst$pl.dll", "libgst$pl.dll")) {
            $src = Join-Path $gstPluginSrc $name
            if (Test-Path $src) { Copy-Item $src -Destination $pluginDst -Force; $copied = $true; break }
        }
        if (-not $copied) { Write-Warning "  plugin gst$pl.dll not found (ok if unused on this GStreamer version)" }
    }
    Write-Host "  GStreamer subset copied to $dist (+ lib\gstreamer-1.0)"
}
else {
    Write-Warning "GStreamer bin not found at $gstBin - live wall will not run until W2 fixes the bundle."
}

# 3) ffmpeg.exe (LGPL) beside the exe for ClipTranscoder. Best-effort: a fetch hiccup must not
#    fail the whole build (export is verified in W2, licences finalised in W4).
Write-Host "== ffmpeg.exe (LGPL) =="
try {
    $tmp = Join-Path $env:TEMP "ffmpeg-lgpl.zip"
    Invoke-WebRequest -Uri $FfmpegUrl -OutFile $tmp
    # Verify before extracting. A mismatch is a hard stop, not a warning: a tampered
    # or substituted archive must never reach the guard-station installer.
    $got = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $FfmpegSha256.ToLowerInvariant()) {
        throw "ffmpeg archive SHA-256 mismatch: expected $FfmpegSha256, got $got — refusing to bundle"
    }
    Write-Host "  ffmpeg archive SHA-256 verified"
    $ex = Join-Path $env:TEMP "ffmpeg-lgpl"
    if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
    Expand-Archive -Path $tmp -DestinationPath $ex -Force
    $exe = Get-ChildItem -Path $ex -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    if ($exe) {
        Copy-Item $exe.FullName -Destination $dist -Force
        # its shared LGPL DLLs, if this is a -shared build
        Get-ChildItem -Path $exe.Directory -Filter "*.dll" -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName -Destination $dist -Force }
        Write-Host "  ffmpeg.exe bundled"
    } else { Write-Warning "  ffmpeg.exe not found in archive" }
}
catch { Write-Warning "  ffmpeg fetch failed ($($_.Exception.Message)) - export post-processing needs it (W2/W4)" }

# 4) Licence notices — the LGPL inventory + source offers (W4). Shipped verbatim from
#    packaging/windows/licenses/ so the dist carries Qt/GStreamer/FFmpeg LGPL texts +
#    THIRD-PARTY-NOTICES.txt + SOURCES.md (the written offer). CI drift-checks that the
#    shipped GStreamer plugins all appear in NOTICE-GStreamer.txt.
$licSrc = Join-Path $PSScriptRoot "licenses"
$licDst = Join-Path $dist "licenses"
New-Item -ItemType Directory -Force -Path $licDst | Out-Null
if (Test-Path $licSrc) {
    Copy-Item (Join-Path $licSrc "*") -Destination $licDst -Recurse -Force
    Write-Host "  licenses copied: $((Get-ChildItem $licDst -File).Count) files"
} else {
    Write-Warning "  packaging/windows/licenses/ missing — dist ships without notices (W4 regression)"
}

Write-Host ""
Write-Host "Dist assembled at: $dist"
Write-Host "Verify hardware decode:  set WT_TRACE=1 & set WT_HW_ONLY=1 & run -> expect [WT-DEC] ... d3d11...(hardware)"
