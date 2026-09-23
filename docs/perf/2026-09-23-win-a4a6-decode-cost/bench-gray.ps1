# Verify the counter-intuitive result: is format=gray really more expensive than
# format=bgr24? And what does taking the NATIVE yuv420p frame cost (the zero-conversion
# route to luma, which is what MOG2 actually wants)?
$ffDir = Join-Path $env:LOCALAPPDATA "Programs\Cilex Watchtower.v1144"
$ff    = Join-Path $ffDir "ffmpeg.exe"
$work  = "C:\wt\labs-bench"
$N = 9
function Stat($a) { $s = $a | Sort-Object; return [pscustomobject]@{ med=$s[[int]($a.Count/2)]; min=$s[0]; max=$s[-1] } }
function Cpu($extra) {
    $v = @()
    for ($i=0; $i -lt $N; $i++) {
        $p = Start-Process -FilePath $ff -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardError (Join-Path $work "g.err") `
             -ArgumentList (@("-hide_banner","-nostats","-threads","1","-fflags","+discardcorrupt","-i","concat20.ts","-an") + $extra)
        $p.WaitForExit(); $v += $p.TotalProcessorTime.TotalSeconds
    }
    return (Stat $v)
}
Write-Output "=== n=$N each, 8890 frames of 1280x720, single-threaded ==="
foreach ($r in @(
  @{ t="decode only (no conversion)";            a=@("-f","null","-") },
  @{ t="vf format=gray  -> null";                a=@("-vf","format=gray","-f","null","-") },
  @{ t="vf format=bgr24 -> null";                a=@("-vf","format=bgr24","-f","null","-") },
  @{ t="NATIVE yuv420p -> rawvideo (zero conv)"; a=@("-pix_fmt","yuv420p","-f","rawvideo","NUL") },
  @{ t="bgr24 -> rawvideo";                      a=@("-pix_fmt","bgr24","-f","rawvideo","NUL") }
)) {
    $s = Cpu $r.a
    Write-Output ("  {0,-38} med {1,6:N3}  min {2,6:N3}  max {3,6:N3}  => {4,6:N1} CPU-s/cam-h" -f `
                  $r.t, $s.med, $s.min, $s.max, ($s.med*6))
}
