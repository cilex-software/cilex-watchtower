# Is the keyframe interval FIXED or does the camera vary it with scene activity?
# If dynamic, keyframe-only decode yields an unpredictable frame count per segment,
# which matters more for the design than the average GOP does.
$ffDir = Join-Path $env:LOCALAPPDATA "Programs\Cilex Watchtower.v1144"
$ff    = Join-Path $ffDir "ffmpeg.exe"
$work  = "C:\wt\labs-bench"

foreach ($seg in @("hiwatch-04eecdcb20f9.ts","hiwatch-083bc1712c35.ts")) {
    $log = Join-Path $work "si.err"
    $p = Start-Process -FilePath $ff -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardError $log `
         -ArgumentList @("-hide_banner","-nostats","-threads","1","-i",$seg,"-an","-vf","showinfo","-f","null","-")
    $p.WaitForExit()

    # showinfo lines carry "n:<idx> ... type:<I|P|B>"
    $idx = @()
    $n = -1
    foreach ($line in (Get-Content $log)) {
        if ($line -match "n:\s*(\d+)\b") {
            $n = [int]$Matches[1]
            if ($line -match "type:I") { $idx += $n }
        }
    }
    if ($idx.Count -lt 2) { Write-Output "$seg : could not parse showinfo"; continue }
    $gaps = @()
    for ($i=1; $i -lt $idx.Count; $i++) { $gaps += ($idx[$i] - $idx[$i-1]) }
    $u = $gaps | Sort-Object -Unique
    Write-Output "=== $seg ==="
    Write-Output ("  I-frames: {0}   last frame index: {1}" -f $idx.Count, $n)
    Write-Output ("  gaps between I-frames: {0}" -f ($gaps -join ", "))
    Write-Output ("  distinct gap values: {0}   min {1}  max {2}" -f ($u -join "/"), $u[0], $u[-1])
    if ($u.Count -eq 1) { Write-Output "  => FIXED GOP of $($u[0])" } else { Write-Output "  => VARIABLE keyframe interval" }
    Write-Output ""
}
