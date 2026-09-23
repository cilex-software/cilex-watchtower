# Decompose decode cost into: demux/parse floor, per-I-frame, per-P-frame.
# This makes the answer independent of the GOP disagreement between this box and CV:
# whatever their segments' GOP is, they can compute the cost from these three terms.
$ffDir = Join-Path $env:LOCALAPPDATA "Programs\Cilex Watchtower.v1144"
$ff    = Join-Path $ffDir "ffmpeg.exe"
$work  = "C:\wt\labs-bench"
$N = 5

function Med($a) { $s = $a | Sort-Object; return $s[[int]($a.Count/2)] }
function Run-Cpu($extra) {
    $vals = @()
    for ($i=0; $i -lt $N; $i++) {
        $log = Join-Path $work "d.err"
        $p = Start-Process -FilePath $ff -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardError $log `
             -ArgumentList (@("-hide_banner","-nostats","-fflags","+discardcorrupt","-threads","1") + $extra + @("-i","concat20.ts","-an","-f","null","-"))
        $p.WaitForExit()
        $vals += $p.TotalProcessorTime.TotalSeconds
    }
    return (Med $vals)
}

$all  = Run-Cpu @("-skip_frame","all")     # demux + parse, decode nothing
$key  = Run-Cpu @("-skip_frame","nokey")   # + I frames only
$full = Run-Cpu @()                        # + everything

# 20 segments; frame census measured earlier: 8890 frames total, 31+30 keyframes per pair x10
$nFrames = 8890
$nKey    = (31 + 30) * 10
$nP      = $nFrames - $nKey

Write-Output "=== 20-segment stream (10 min of -sub), single-threaded, software ==="
Write-Output ("  frames = {0}   I = {1}   P/B = {2}" -f $nFrames, $nKey, $nP)
Write-Output ""
Write-Output ("  skip_frame all   (parse only) : {0,7:N3} CPU-s" -f $all)
Write-Output ("  skip_frame nokey (parse + I)  : {0,7:N3} CPU-s" -f $key)
Write-Output ("  full decode      (everything) : {0,7:N3} CPU-s" -f $full)
Write-Output ""
$iCost = ($key - $all) / $nKey
$pCost = ($full - $key) / $nP
Write-Output ("  => parse floor      {0,8:N4} CPU-s per 30s segment" -f ($all/20))
Write-Output ("  => per I-frame      {0,8:N4} CPU-s  ({1:N2} ms)" -f $iCost, ($iCost*1000))
Write-Output ("  => per P/B-frame    {0,8:N4} CPU-s  ({1:N2} ms)" -f $pCost, ($pCost*1000))
Write-Output ("  => I-frame costs {0:N1}x a P-frame" -f ($iCost/[math]::Max($pCost,1e-9)))
Write-Output ""
Write-Output "=== cost of a 30s segment at various GOPs, derived ==="
Write-Output ("  {0,-8} {1,10} {2,14} {3,12} {4,10}" -f "GOP","keyframes","keyonly CPU-s","full CPU-s","ratio")
foreach ($gop in @(15, 30, 50, 60)) {
    $f = 450.0
    $k = [math]::Round($f / $gop)
    $parse = $all/20
    $ko = $parse + ($k * $iCost)
    $fu  = $parse + ($k * $iCost) + (($f - $k) * $pCost)
    Write-Output ("  {0,-8} {1,10} {2,12:N3} {3,12:N3} {4,9:N2}x" -f $gop, $k, $ko, $fu, ($fu/$ko))
}
