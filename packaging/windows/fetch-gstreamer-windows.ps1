<#
.SYNOPSIS
  Download the GStreamer-for-Windows MSVC RUNTIME (the DLLs + plugins Watchtower bundles).

.DESCRIPTION
  Watchtower drives GStreamer directly (RtspVideoSource), so the GStreamer runtime is NOT handled
  by windeployqt and must be fetched + bundled separately. Ship ONLY the LGPL plugin subset we use
  (see packaging/windows/README.md) — never gst-plugins-ugly (GPL).

  SCAFFOLD: pin the version and VERIFY the URL against https://gstreamer.freedesktop.org/download/
  before relying on it — the exact filename/version may differ from the default below.

.EXAMPLE
  pwsh ./fetch-gstreamer-windows.ps1 -Version 1.24.12
#>
param(
    [string]$Version = "1.26.11",                 # verified downloadable 2026-07-04 (CI pins the same)
    [string]$Dest    = "$PSScriptRoot/_gstreamer"  # gitignored; see .gitignore
)
$ErrorActionPreference = "Stop"

$arch       = "x86_64"
$base       = "https://gstreamer.freedesktop.org/data/pkg/windows/$Version/msvc"
$runtimeMsi = "gstreamer-1.0-msvc-$arch-$Version.msi"
$url        = "$base/$runtimeMsi"

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$msi = Join-Path $Dest $runtimeMsi

Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $msi

# Administrative (extract-only) install so we can pick out DLLs without touching the system.
$extract = Join-Path $Dest "runtime"
Write-Host "Extracting to $extract"
Start-Process msiexec.exe -ArgumentList "/a `"$msi`" /qn TARGETDIR=`"$extract`"" -Wait

Write-Host ""
Write-Host "GStreamer runtime extracted under: $extract"
Write-Host "deploy.ps1 will copy ONLY the LGPL subset we use:"
Write-Host "  core/base/good (coreelements, playback, typefindfunctions, videoconvertscale, app, rtsp/rtp)"
Write-Host "  + d3d11 (DXVA hardware decode).  EXCLUDE gst-plugins-ugly (GPL) and unused codecs."
