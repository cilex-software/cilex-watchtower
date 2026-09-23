# Why is my full-decode figure 9.3x lower than the Linux box's for the same stream?
# Hypothesis: their number includes frame DELIVERY (YUV->BGR convert + copy into numpy),
# mine is decoder-only (-f null with wrapped_avframe does no conversion).
# MOG2 only needs LUMA, so if conversion dominates, Y-plane-only is nearly free.
$ffDir = Join-Path $env:LOCALAPPDATA "Programs\Cilex Watchtower.v1144"
$ff    = Join-Path $ffDir "ffmpeg.exe"
$work  = "C:\wt\labs-bench"
$N = 5
function Med($a) { $s = $a | Sort-Object; return $s[[int]($a.Count/2)] }
function Cpu($extra) {
    $v = @()
    for ($i=0; $i -lt $N; $i++) {
        $p = Start-Process -FilePath $ff -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardError (Join-Path $work "c.err") `
             -ArgumentList (@("-hide_banner","-nostats","-threads","1","-fflags","+discardcorrupt","-i","concat20.ts","-an") + $extra)
        $p.WaitForExit(); $v += $p.TotalProcessorTime.TotalSeconds
    }
    return (Med $v)
}
# 20 segments = 10 min = 1/6 camera-hour. x6 -> CPU-s per camera-hour.
$scale = 6.0
Write-Output "=== 1280x720 h264 -sub, 8890 frames (10 min), single-threaded, software ==="
Write-Output ""
$rows = @(
  @{ tag="decode only, no conversion";        a=@("-f","null","-") },
  @{ tag="+ convert to gray (Y plane)";       a=@("-vf","format=gray","-f","null","-") },
  @{ tag="+ convert to bgr24 (OpenCV input)"; a=@("-vf","format=bgr24","-f","null","-") },
  @{ tag="+ bgr24 AND write out raw bytes";   a=@("-vf","format=bgr24","-f","rawvideo","NUL") },
  @{ tag="+ gray AND write out raw bytes";    a=@("-vf","format=gray","-f","rawvideo","NUL") }
)
$base = $null
foreach ($r in $rows) {
    $c = Cpu $r.a
    if ($null -eq $base) { $base = $c }
    Write-Output ("  {0,-34} {1,7:N3} CPU-s / 10min   =  {2,7:N1} CPU-s per camera-hour   ({3,5:N2}x decode-only)" -f `
                  $r.tag, $c, ($c*$scale), ($c/$base))
}
Write-Output ""
Write-Output "  Linux box reported for this same stream: 167 CPU-s/cam-h full, 31 keyframe."
