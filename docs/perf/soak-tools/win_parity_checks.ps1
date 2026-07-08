<#
.SYNOPSIS
  W3 parity checks (Windows): the click-spam recovery band + the GC-fix (2026-07-03 HANG #1) heartbeat,
  the Windows analog of the Linux click-spam + smoothtest discipline. Two modes, one analyzer.

.DESCRIPTION
  -Mode spam  (step 4, click-spam parity): boot-loads a KNOWN heavy day, drives WT_SEEK_SPAM=1 --
      40 bursts of 12 chaotic far-seek clicks -- and measures last-click -> next-frame recovery
      ([SPAM] recovered after_ms=), coalescing ([PB] far-coalesce), and [SEEKBAR] violations.
      Pass band = Linux: recovery p90 < 1 s, no 15 s RECOVER-TIMEOUT, coalesce present, 0 [SEEKBAR].

  -Mode churn (step 3, GC-fix parity): drives WT_NIGHT_SOAK PINNED to the heavy day with
      WT_SOAK_NOEXPORT (pure open/seek churn -- the exact marshalling hot path the 2026-07-03 GC
      wedge blew up, and the harness the Linux fix was validated under). This is the FAIR heartbeat
      measurement: normal heavy-day churn, NOT the pathological click-spam.

  Both modes run WT_SMOOTHTEST as a 1 s GUI heartbeat and enable WT_TRACE for [PBTIME] marshal=.
  Every log line is timestamped via QT_MESSAGE_PATTERN so heartbeat GAPS are measured in wall-clock
  (a stalled event loop does not advance wall time between ticks -- the in-app sec counter can't see
  its own stall). GC-storm signature = a single open freezing >= 250 ms while it marshals the
  fragment payload (pre-fix Linux max was 1149 ms; post-fix "~1 ms flat"). marshal= also absorbs
  event-loop SCHEDULING delay under churn, so the typical value on Windows runs hotter than Linux --
  the decisive gate is NO storm-range spike AND the heartbeat never gaps > 2 s.

.NOTES
  ASCII-only (Windows PowerShell 5.1 AND pwsh). WIN32 GUI app -> QT_FORCE_STDERR_LOGGING routes the
  trace to a redirected stderr. Artifacts land durable (NOT %TEMP%).

.EXAMPLE
  powershell -File .\win_parity_checks.ps1 -Mode spam  -Ip 192.168.1.106 -Day 2026-06-22
  powershell -File .\win_parity_checks.ps1 -Mode churn -Ip 192.168.1.106 -Day 2026-06-22 -ChurnMinutes 8
#>
param(
    [ValidateSet("spam","churn")]
    [string]$Mode        = "spam",
    [string]$Dist        = "C:\wt\portable-ci",
    [string]$BackendUrl  = "http://100.107.51.72:8000",
    [string]$Ip          = "192.168.1.106",     # heavy main-stream camera
    [string]$Day         = "2026-06-22",        # its heaviest day (~5.2 h, 4760 frags)
    [int]$SmoothSeconds  = 900,                 # heartbeat window; outlasts the run in either mode
    [int]$ChurnMinutes   = 8,                   # churn mode: how long to churn before stopping
    [int]$MaxMinutes     = 12,                  # spam mode: hard cap if [SPAM] DONE never arrives
    [string]$OutDir      = "$env:USERPROFILE\watchtower-soak\parity",
    [int]$PollSeconds    = 5
)
$ErrorActionPreference = "Stop"

$exe = Join-Path $Dist "watchtower.exe"
if (-not (Test-Path $exe)) { throw "watchtower.exe not found in '$Dist' -- pass -Dist <unzipped portable dir>." }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'MMdd_HHmmss'
$log   = Join-Path $OutDir ("parity_{0}_{1}.err.log" -f $Mode, $stamp)
$out   = Join-Path $OutDir ("parity_{0}_{1}.out.log" -f $Mode, $stamp)
$sum   = Join-Path $OutDir ("parity_{0}_{1}.summary.txt" -f $Mode, $stamp)

# --- common environment: heartbeat + trace + timestamped lines ---
$env:WT_CV_URL                    = $BackendUrl
$env:WT_CV_AUTOLOGIN              = "1"
$env:WT_TRACE                     = "1"                    # enables [PBTIME] ... marshal= (_pbTime)
$env:WT_SMOOTHTEST                = "$SmoothSeconds"
$env:QT_FORCE_STDERR_LOGGING      = "1"
$env:QT_ASSUME_STDERR_HAS_CONSOLE = "1"
$env:QT_MESSAGE_PATTERN           = "%{time yyyy-MM-dd hh:mm:ss.zzz} %{message}"
# clear any mode-specific vars from a prior invocation in this shell
Remove-Item Env:WT_SEEK_SPAM,Env:WT_NIGHT_SOAK,Env:WT_SOAK_NOEXPORT,Env:WT_SOAK_FIX_CAM,Env:WT_SOAK_FIX_DAY,Env:WT_PLAYBACK_IP,Env:WT_PLAYBACK_DAY -ErrorAction SilentlyContinue

if ($Mode -eq "spam") {
    $env:WT_SEEK_SPAM   = "1"
    $env:WT_PLAYBACK_IP = $Ip
    $env:WT_PLAYBACK_DAY = $Day
} else {  # churn: WT_NIGHT_SOAK pinned to the heavy day, pure open/seek (no export/drawer)
    $env:WT_NIGHT_SOAK    = "1"
    $env:WT_SOAK_NOEXPORT = "1"
    $env:WT_SOAK_FIX_CAM  = $Ip
    $env:WT_SOAK_FIX_DAY  = $Day
}

Write-Host ("[parity/{0}] {1}  cam={2} day={3} backend={4}" -f $Mode, $exe, $Ip, $Day, $BackendUrl)
Write-Host ("[parity/{0}] log -> {1}" -f $Mode, $log)

$start = Get-Date
$hardEnd = if ($Mode -eq "spam") { $start.AddMinutes($MaxMinutes) } else { $start.AddMinutes($ChurnMinutes) }
$app = Start-Process $exe -WorkingDirectory $Dist -PassThru -RedirectStandardError $log -RedirectStandardOutput $out
Write-Host ("[parity/{0}] pid={1} launched..." -f $Mode, $app.Id)

$reason = if ($Mode -eq "spam") { "cap" } else { "duration" }
while ((Get-Date) -lt $hardEnd) {
    Start-Sleep -Seconds $PollSeconds
    if ($app.HasExited) { $reason = "exited"; break }
    if ($Mode -eq "spam" -and (Test-Path $log) -and (Select-String -Path $log -Pattern '\[SPAM\] DONE' -Quiet)) { $reason = "spam-done"; break }
    if ($Mode -eq "spam") {
        $d = (Select-String -Path $log -Pattern '\[SPAM\] recovered' -ErrorAction SilentlyContinue | Measure-Object).Count
        $t = (Select-String -Path $log -Pattern '\[SPAM\] RECOVER-TIMEOUT' -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host ("[parity/spam] +{0:mm\:ss}  recovered={1} timeouts={2}" -f ((Get-Date)-$start), $d, $t)
    } else {
        $o = (Select-String -Path $log -Pattern 'action=open-begin' -ErrorAction SilentlyContinue | Measure-Object).Count
        $s = (Select-String -Path $log -Pattern 'action=seek-begin' -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host ("[parity/churn] +{0:mm\:ss}  opens={1} seeks={2}" -f ((Get-Date)-$start), $o, $s)
    }
}
if (-not $app.HasExited) { try { $app.Kill() } catch { } }
Start-Sleep -Seconds 2
Get-Process -Name watchtower -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host ("[parity/{0}] run ended ({1}); analyzing {2}" -f $Mode, $reason, (Split-Path -Leaf $log))

# ============================ ANALYSIS ============================
$lines = if (Test-Path $log) { Get-Content $log } else { @() }
function Get-Pct([double[]]$vals, [double]$p) {
    if (-not $vals -or $vals.Count -eq 0) { return $null }
    $s = $vals | Sort-Object
    $idx = [int][math]::Ceiling(($p/100.0) * $s.Count) - 1
    if ($idx -lt 0) { $idx = 0 }; if ($idx -ge $s.Count) { $idx = $s.Count - 1 }
    return $s[$idx]
}
function TsOf([string]$line) {
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})') {
        try { return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $null) } catch { return $null }
    }
    return $null
}

# ---- click-spam recovery (spam mode) ----
$rec = @(); foreach ($l in $lines) { if ($l -match '\[SPAM\] recovered burst=\d+ after_ms=(\d+)') { $rec += [double]$Matches[1] } }
$timeouts = ($lines | Select-String -Pattern '\[SPAM\] RECOVER-TIMEOUT' | Measure-Object).Count
$coalesce = ($lines | Select-String -Pattern '\[PB\] far-coalesce'      | Measure-Object).Count
$seekbar  = ($lines | Select-String -Pattern '\[SEEKBAR\]'              | Measure-Object).Count
$doneBursts = 0; foreach ($l in $lines) { if ($l -match '\[SPAM\] DONE bursts=(\d+)') { $doneBursts = [int]$Matches[1] } }

# ---- backend round-trip (network) ----
$http = @(); foreach ($l in $lines) { if ($l -match 'session_http ms=(\d+) code=\d+') { $http += [double]$Matches[1] } }

# ---- GC-fix: marshal= (storm signature) ----
$marsh = @(); foreach ($l in $lines) { if ($l -match 'marshal=(\d+)ms') { $marsh += [double]$Matches[1] } }
$stormMs = 250
$mStorm  = if ($marsh.Count) { ($marsh | Where-Object { $_ -ge $stormMs } | Measure-Object).Count } else { 0 }

# ---- GC-fix: GUI heartbeat gaps (wall-clock between consecutive WTSMOOTH t= ticks) ----
$hbTimes = @(); foreach ($l in $lines) { if ($l -match 'WTSMOOTH t=\d+s') { $t = TsOf $l; if ($t) { $hbTimes += $t } } }
$maxGapMs = 0.0; $gapCount2s = 0
for ($i = 1; $i -lt $hbTimes.Count; $i++) {
    $g = ($hbTimes[$i] - $hbTimes[$i-1]).TotalMilliseconds
    if ($g -gt $maxGapMs) { $maxGapMs = $g }
    if ($g -gt 2000) { $gapCount2s++ }
}
$vidStalls = ($lines | Select-String -Pattern 'WTSMOOTH STALL' | Measure-Object).Count
$fatal     = ($lines | Select-String -Pattern 'WT-FATAL|CRITICAL' | Measure-Object).Count

# ---- verdicts ----
$recP50=Get-Pct $rec 50; $recP90=Get-Pct $rec 90; $recMax=if($rec.Count){($rec|Measure-Object -Maximum).Maximum}else{$null}
$hP50=Get-Pct $http 50; $hP90=Get-Pct $http 90; $hMax=if($http.Count){($http|Measure-Object -Maximum).Maximum}else{$null}
$mMed=Get-Pct $marsh 50; $mP90=Get-Pct $marsh 90; $mMax=if($marsh.Count){($marsh|Measure-Object -Maximum).Maximum}else{$null}
$passSpam = ($rec.Count -gt 0) -and ($recP90 -ne $null -and $recP90 -lt 1000) -and ($timeouts -eq 0) -and ($coalesce -gt 0) -and ($seekbar -eq 0)
$passGc   = ($marsh.Count -gt 0) -and ($mStorm -eq 0) -and ($mMax -ne $null -and $mMax -lt $stormMs) -and ($gapCount2s -eq 0) -and ($fatal -eq 0)

$r = New-Object System.Collections.Generic.List[string]
$r.Add("=================== W3 PARITY CHECK ({0}) ===================" -f $Mode.ToUpper())
$r.Add(("host   : {0}  build {1}" -f $env:COMPUTERNAME, (Get-Item $exe).VersionInfo.FileVersion))
$r.Add(("target : cam {0}  day {1}  backend {2}" -f $Ip, $Day, $BackendUrl))
$r.Add(("run    : start {0}  end {1}  log {2}" -f $start.ToString('MM-dd HH:mm:ss'), $reason, (Split-Path -Leaf $log)))
$r.Add(("net    : session_http (Tailscale RTT) p50/p90/max = {0}/{1}/{2} ms" -f $hP50,$hP90,$hMax))
$r.Add("")
if ($Mode -eq "spam") {
    $r.Add("-- CLICK-SPAM PARITY (step 4) ----------------------------------")
    $r.Add(("bursts completed       : {0}" -f $doneBursts))
    $r.Add(("recovery p50/p90/max ms: {0} / {1} / {2}" -f $recP50,$recP90,$recMax))
    $r.Add(("RECOVER-TIMEOUT (15s)  : {0}" -f $timeouts))
    $r.Add(("[PB] far-coalesce lines: {0}" -f $coalesce))
    $r.Add(("[SEEKBAR] violations   : {0}" -f $seekbar))
    $r.Add(("VERDICT click-spam     : {0}   (p90<1s bar is network-sensitive; see net line)" -f $(if($passSpam){"PASS"}else{"REVIEW"})))
}
$r.Add("")
$r.Add("-- GC-FIX / HEARTBEAT (step 3; authoritative in churn mode) -----")
$r.Add(("marshal samples        : {0}" -f $marsh.Count))
$r.Add(("marshal med/p90/max ms : {0} / {1} / {2}   (pre-fix Linux max 1149 ms = GC storm)" -f $mMed,$mP90,$mMax))
$r.Add(("marshal storm-spikes   : {0}   (opens >= {1} ms; MUST be 0)" -f $mStorm,$stormMs))
$r.Add(("GUI heartbeat ticks    : {0}" -f $hbTimes.Count))
$r.Add(("max heartbeat gap ms   : {0}   (gaps >2s: {1})" -f [int]$maxGapMs,$gapCount2s))
$r.Add(("video-dead-time STALLs : {0}   (expected during churn; not a GUI wedge)" -f $vidStalls))
$r.Add(("WT-FATAL/CRITICAL      : {0}" -f $fatal))
$r.Add(("VERDICT GC-fix         : {0}" -f $(if($passGc){"PASS"}else{"REVIEW"})))
$r.Add("================================================================")
$r | ForEach-Object { Write-Host $_ }
$r | Out-File -FilePath $sum -Encoding ascii
Write-Host ("[parity/{0}] summary -> {1}" -f $Mode, $sum)
$ok = if ($Mode -eq "spam") { $passSpam } else { $passGc }
Write-Output $(if ($ok) { "PARITY_PASS" } else { "PARITY_REVIEW" })
