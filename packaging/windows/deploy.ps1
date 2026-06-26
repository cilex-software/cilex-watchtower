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
    [string]$GstRuntime = "$PSScriptRoot/_gstreamer/runtime"
)
$ErrorActionPreference = "Stop"
$dist = Split-Path -Parent $ExePath

# 1) Qt runtime. --compiler-runtime ships the VC++ Redistributable DLLs; OMIT it if you build with
#    the Hybrid CRT (static_compiler_runtime, Qt 6.12+) — see README.md.
Write-Host "== windeployqt =="
& windeployqt --release --qmldir "$QmlDir" --compiler-runtime "$ExePath"

# 2) GStreamer runtime (LGPL subset only — see README.md / DEVELOPMENT.md for the licence rationale).
Write-Host "== GStreamer bundle =="
if (Test-Path $GstRuntime) {
    # TODO (needs a Windows build to finalise the exact DLL list): copy ONLY the LGPL pieces:
    #   $GstRuntime\bin\*.dll                 -> $dist
    #       core:    gstreamer-1.0, gstbase-1.0, gstapp-1.0, gstvideo-1.0, gstrtp-1.0, gstrtsp-1.0
    #       glib:    glib-2.0, gobject-2.0, gmodule-2.0, gio-2.0, ffi, intl, z, ...
    #   $GstRuntime\lib\gstreamer-1.0\        -> $dist\lib\gstreamer-1.0   (plugins, LGPL ONLY:)
    #       libgstcoreelements, libgstplayback, libgsttypefindfunctions, libgstvideoconvertscale,
    #       libgstapp, libgstrtp, libgstrtsp, libgstrtpmanager, libgstd3d11  (DXVA HW decode)
    #       -- do NOT ship libgstx264 / gst-plugins-ugly (GPL) or codecs you don't use.
    #   At runtime set GST_PLUGIN_PATH=<dist>\lib\gstreamer-1.0 (or rely on the relative default).
    Write-Warning "TODO: implement the LGPL-subset copy from $GstRuntime (see comments above)."
}
else {
    Write-Warning "GStreamer runtime not found at $GstRuntime - run fetch-gstreamer-windows.ps1 first."
}

Write-Host ""
Write-Host "Dist assembled at: $dist"
Write-Host "Verify hardware decode:  set WT_TRACE=1 & set WT_HW_ONLY=1 & run -> expect [WT-DEC] ... d3d11...(hardware)"
