# Amortised decode cost through ONE long-lived decoder. Run entirely from an ASCII-only
# directory: ffmpeg's concat demuxer could not read a list file containing the Cyrillic
# profile path under any PS 5.1 encoding.
$ffDir = Join-Path $env:LOCALAPPDATA "Programs\Cilex Watchtower.v1144"
$ff    = Join-Path $ffDir "ffmpeg.exe"
$env:PATH = "$ffDir;" + $env:PATH
$work = "C:\wt\labs-bench"
if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work | Out-Null }
Copy-Item (Join-Path $PSScriptRoot "*.ts") $work -Force
Get-ChildItem $work -Filter "*.ts" | Select-Object Name, Length | Format-Table -AutoSize

function Run-Timed($a) {
    $log = Join-Path $work "t.err"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $ff -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardError $log -WorkingDirectory $work
    $p.WaitForExit()
    $sw.Stop()
    [pscustomobject]@{ cpu=$p.TotalProcessorTime.TotalSeconds; wall=$sw.Elapsed.TotalSeconds; code=$p.ExitCode; log=$log }
}

# 20 segments = 10 minutes of one camera's -sub
$lines = @()
1..10 | ForEach-Object { $lines += "file 'hiwatch-04eecdcb20f9.ts'"; $lines += "file 'hiwatch-083bc1712c35.ts'" }
Set-Content -Path (Join-Path $work "concat.txt") -Value $lines -Encoding ascii
$r = Run-Timed @("-hide_banner","-loglevel","error","-f","concat","-safe","0","-i","concat.txt","-c","copy","-an","-f","mpegts","concat20.ts")
if ($r.code -ne 0) { Get-Content $r.log | Select-Object -First 5 }
$big = Join-Path $work "concat20.ts"
Write-Output ("concat20.ts = {0:N0} bytes  (exit {1})" -f (Get-Item $big).Length, $r.code)

# how many frames are actually in it?
$r = Run-Timed @("-hide_banner","-fflags","+discardcorrupt","-i","concat20.ts","-an","-f","null","-")
$fl = Select-String -Path $r.log -Pattern "frame=" | Select-Object -Last 1
Write-Output "total frames in concat20: $($fl.Line)"

Write-Output ""
Write-Output "=== marginal cost per 30s segment, ONE decoder, software only ==="
foreach ($mode in @(
    @{ tag="full    -threads 1";    extra=@("-threads","1") },
    @{ tag="full    -threads auto"; extra=@() },
    @{ tag="keyonly -threads 1";    extra=@("-threads","1","-skip_frame","nokey") }
)) {
    $cs=@(); $ws=@()
    for ($i=0; $i -lt 5; $i++) {
        $x = Run-Timed (@("-hide_banner","-nostats","-fflags","+discardcorrupt") + $mode.extra + @("-i","concat20.ts","-an","-f","null","-"))
        $cs += $x.cpu; $ws += $x.wall
    }
    $cs = $cs | Sort-Object; $ws = $ws | Sort-Object
    Write-Output ("  {0,-22} 20 segs CPU med {1,7:N3}s wall med {2,7:N3}s  ->  PER SEGMENT CPU {3,6:N3}s  wall {4,6:N3}s   (CPU min {5:N3} max {6:N3})" -f `
                  $mode.tag, $cs[2], $ws[2], ($cs[2]/20), ($ws[2]/20), $cs[0], $cs[-1])
}
