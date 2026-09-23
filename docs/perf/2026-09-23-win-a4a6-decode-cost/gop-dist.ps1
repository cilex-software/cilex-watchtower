# The fleet is NOT uniform in keyframe interval. Get the real distribution across a
# spread of 24 cameras, 15 s each by stream copy. Read-only; 4 concurrent consumers.
$ffDir = Join-Path $env:LOCALAPPDATA "Programs\Cilex Watchtower.v1144"
$ff    = Join-Path $ffDir "ffmpeg.exe"
$work  = "C:\wt\labs-bench\dist"
if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work | Out-Null }

$fr = Join-Path $env:APPDATA "Cilex Vision\Watchtower\flightrec\watchtower.log"
$all = Select-String -Path $fr -Pattern "rtsp://192\.168\.1\.4:8554/([a-z0-9\-]+)-sub" -AllMatches |
       ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$step = [math]::Floor($all.Count / 24)
$pick = 0..23 | ForEach-Object { $all[$_ * $step] } | Where-Object { $_ }
Write-Output "roster=$($all.Count)  sampling $($pick.Count) cameras every $step th"

for ($b = 0; $b -lt $pick.Count; $b += 4) {
    $chunk = $pick[$b..([math]::Min($b+3, $pick.Count-1))]
    $ps = @()
    foreach ($c in $chunk) {
        $d = Join-Path $work "$c.ts"; if (Test-Path $d) { Remove-Item $d -Force }
        $ps += Start-Process -FilePath $ff -NoNewWindow -PassThru -WorkingDirectory $work -ArgumentList @(
            "-hide_banner","-loglevel","error","-rtsp_transport","tcp","-fflags","+discardcorrupt",
            "-i","rtsp://192.168.1.4:8554/$c-sub","-t","15","-c","copy","-an","-f","mpegts","$c.ts")
    }
    foreach ($p in $ps) { $p.WaitForExit() }
}

$rows = @()
foreach ($c in $pick) {
    $f = Join-Path $work "$c.ts"
    if ((-not (Test-Path $f)) -or ((Get-Item $f).Length -lt 10000)) { $rows += [pscustomobject]@{cam=$c; w=0; h=0; frames=0; I=0; gop=0; period=0; gaps="NO CAPTURE"}; continue }
    $log = Join-Path $work "si.err"
    $p = Start-Process -FilePath $ff -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardError $log `
         -ArgumentList @("-hide_banner","-nostats","-threads","1","-i","$c.ts","-an","-vf","showinfo","-f","null","-")
    $p.WaitForExit()
    $idx = @(); $n = -1; $w = 0; $h = 0
    foreach ($line in (Get-Content $log)) {
        if ($w -eq 0 -and $line -match "(\d{3,4})x(\d{3,4})") { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
        if ($line -match "n:\s*(\d+)\b") { $n = [int]$Matches[1]; if ($line -match "type:I") { $idx += $n } }
    }
    $frames = $n + 1
    $gaps = @(); for ($i=1; $i -lt $idx.Count; $i++) { $gaps += ($idx[$i] - $idx[$i-1]) }
    $u = ($gaps | Sort-Object -Unique) -join "/"
    $fps = if ($frames -gt 0) { $frames / 15.0 } else { 0 }
    $gop = if ($idx.Count -gt 0) { [math]::Round($frames / $idx.Count, 1) } else { 0 }
    $rows += [pscustomobject]@{ cam=$c; w=$w; h=$h; frames=$frames; I=$idx.Count; gop=$gop
                                period=[math]::Round($gop/[math]::Max($fps,0.01),2); gaps=$u }
}
$rows | Format-Table -AutoSize
Write-Output "=== distribution of the dominant I-frame gap ==="
$rows | Where-Object { $_.gaps -ne "NO CAPTURE" } | Group-Object gaps | Sort-Object Count -Descending |
    Select-Object Count, Name | Format-Table -AutoSize
Write-Output "=== resolutions ==="
$rows | Where-Object { $_.w -gt 0 } | Group-Object {"$($_.w)x$($_.h)"} | Select-Object Count, Name | Format-Table -AutoSize
