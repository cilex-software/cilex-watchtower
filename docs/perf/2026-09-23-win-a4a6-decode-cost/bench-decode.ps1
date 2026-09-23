# Full-decode vs keyframe-only decode cost, per 30s -sub segment.
# Measures CPU TIME (user+kernel) as well as wall, because the fleet budget is in CPU-seconds
# and on a 12-thread box those two differ by up to 12x.
# Software decode only. No -hwaccel: the shared iGPU wedges at ~16 concurrent VA-API contexts.
$ffDir = Join-Path $env:LOCALAPPDATA "Programs\Cilex Watchtower.v1144"
$ff    = Join-Path $ffDir "ffmpeg.exe"
$env:PATH = "$ffDir;" + $env:PATH
$dir = $PSScriptRoot
$N = 7

function Measure-Run($segPath, $extra, $tag) {
    $log = Join-Path $dir "run.err"
    $a = @("-hide_banner", "-nostats") + $extra + @("-i", "`"$segPath`"", "-an", "-f", "null", "-")
    # NB: Process.StartTime/ExitTime give nonsense for an exited child here -- use a Stopwatch.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $ff -ArgumentList $a -NoNewWindow -PassThru `
                       -RedirectStandardError $log
    $p.WaitForExit()
    $sw.Stop()
    [pscustomobject]@{ tag = $tag; cpu = $p.TotalProcessorTime.TotalSeconds; wall = $sw.Elapsed.TotalSeconds }
}

# frame counts first (one run each, -nostats off so we can read frame=)
function Count-Frames($segPath, $extra) {
    $a = @("-hide_banner") + $extra + @("-i", "`"$segPath`"", "-an", "-f", "null", "-")
    $log = Join-Path $dir "count.err"
    $p = Start-Process -FilePath $ff -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardError $log
    $p.WaitForExit()
    $line = Select-String -Path $log -Pattern "frame=" | Select-Object -Last 1
    if ($line -and $line.Line -match "frame=\s*(\d+)") { return [int]$Matches[1] }
    return -1
}

$segs = Get-ChildItem $dir -Filter "*.ts"
foreach ($s in $segs) {
    Write-Output "================ $($s.Name)  ($($s.Length) bytes) ================"
    $allF = Count-Frames $s.FullName @()
    $keyF = Count-Frames $s.FullName @("-skip_frame", "nokey")
    Write-Output ("frames total = {0}   keyframes = {1}   => GOP ~ {2:N1} frames, keyframe period ~ {3:N2} s at 15 fps" -f `
                  $allF, $keyF, ($allF / [math]::Max($keyF,1)), (($allF / [math]::Max($keyF,1)) / 15.0))

    foreach ($mode in @(
        @{ tag = "full   -threads 1"; extra = @("-threads","1") },
        @{ tag = "full   -threads auto"; extra = @() },
        @{ tag = "keyonly -threads 1"; extra = @("-threads","1","-skip_frame","nokey") },
        @{ tag = "keyonly -threads auto"; extra = @("-skip_frame","nokey") }
    )) {
        $runs = @()
        for ($i = 0; $i -lt $N; $i++) { $runs += Measure-Run $s.FullName $mode.extra $mode.tag }
        $cpus  = ($runs | ForEach-Object { $_.cpu })  | Sort-Object
        $walls = ($runs | ForEach-Object { $_.wall }) | Sort-Object
        $medC = $cpus[[int]($N/2)]; $medW = $walls[[int]($N/2)]
        Write-Output ("  {0,-22}  CPU med {1,6:N3} s  (min {2,6:N3} max {3,6:N3})   wall med {4,6:N3} s   n={5}" -f `
                      $mode.tag, $medC, $cpus[0], $cpus[-1], $medW, $N)
    }
}
