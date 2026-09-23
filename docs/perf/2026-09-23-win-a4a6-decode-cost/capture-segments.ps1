# Capture real -sub segments by STREAM COPY (no decode, no transcode, no writes to CV).
# Matches what the recorder's warm tier stores, which is what an analyser would fetch.
# NOTE: no literal non-ASCII paths in here -- PS 5.1 reads a BOM-less .ps1 as ANSI.
$ffDir = Join-Path $env:LOCALAPPDATA "Programs\Cilex Watchtower.v1144"
$ff    = Join-Path $ffDir "ffmpeg.exe"
if (-not (Test-Path $ff)) { throw "ffmpeg not found at $ff" }
$env:PATH = "$ffDir;" + $env:PATH
$out = $PSScriptRoot

$cams = @("hiwatch-04eecdcb20f9", "hiwatch-083bc1712c35")
$procs = @()
foreach ($c in $cams) {
    $dst = Join-Path $out "$c.ts"
    if (Test-Path $dst) { Remove-Item $dst -Force }
    $a = @(
        "-hide_banner", "-loglevel", "warning",
        "-rtsp_transport", "tcp",
        "-fflags", "+discardcorrupt",
        "-i", "rtsp://192.168.1.4:8554/$c-sub",
        "-t", "30", "-c", "copy", "-an",
        "-f", "mpegts", "`"$dst`""
    )
    $procs += Start-Process -FilePath $ff -ArgumentList $a -NoNewWindow -PassThru
}
foreach ($p in $procs) { $p.WaitForExit() }
Get-ChildItem $out -Filter "*.ts" | Select-Object Name, Length
