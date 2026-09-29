# guard3.ps1 - the wall's safety check for Labs, worker-0.3 onward: a station-side HOLD.
#
# Keeps Labs OFF on this computer while the guards' wall is unwell, and lets it run again
# once the wall has been healthy for a sustained stretch. Replaces guard2.ps1 (the
# 2026-09-28 overnight guard), which paused through control.json `paused` and killed the
# worker. Once cilex-vision's control plane governs (1.0.84 + worker-0.3), `paused` no
# longer governs; the one local switch that does is the HOLD (tools/labs/station.py
# write_hold / clear_hold). The worker drops the unit in hand within a second, claims
# nothing, and reports the hold's reason to the admin page. A restarted worker stays held.
#
# SILENT (operator rule 2026-09-28: nothing about Labs is shown to non-admins): no window,
# no toast, no tray; files only. Start it hidden.
#
# HARM sets the hold (by = "wall-guard"). It is judged by FAILURE signals only, never by
# what is on screen: a guard opening one camera parks the wall's 35 tiles, which is
# navigation, not harm (measured 2026-09-28; see guard2.ps1):
#   err > 0 for 3 samples; lit < livePipes for 3 samples;
#   swd rises, or recon rises >= 3 in 10 min, on a STEADY full wall (this sample and the two
#   before; returning from a single camera rebuilds 9-13 pipelines by itself);
#   gui_stall >= 2000 ms, or 3 stalls >= 1 s in 10 min -- LESS any forward step of the system
#   clock the System log recorded inside it (see ClockStepMs: apps before 1.1.749 timed stalls
#   on the wall clock, and Windows Time steps the booth's +3.8 s every night);
#   the wall app restarted or is not running;
#   full-wall displayed rate < 70% of BaseRate for 3 samples (full wall to full wall only).
# RELEASE (clear_hold): only a hold THIS guard set (by = "wall-guard", including one left
# from an earlier run), after ReleaseAfterSec (default 15 min) with no harm signal and no
# stall >= 1 s, and never while the guard is blind. A hold set by anyone else is never
# touched.
# Log keys: HOLD SET: / HOLD RELEASED: / GUARD BLIND / START ABORTED
# -TestDir <dir>: replay <dir>\fr.log; the hold is written to <dir>\control.json through the
#                 same station.py code; logs stay in <dir>.
# STRICTLY ASCII (the office profile is Cyrillic, so it is discovered at run time).
#
# RUN IT ON THE MACHINE IT GUARDS (2026-09-29). -Office watches wt-office-01 from the booth
# over C$; that was only how it could be started without anyone at the office, and it
# leaves the office unguarded whenever the booth reboots or the link drops. Local mode
# (no -Office) is the real deployment; the office passes -Labs/-Python/-GuardDir for its
# own copy of tools/labs.
# -StartWorker: the guard also starts the Labs worker when none is running (hidden, Idle,
# ffmpeg from -FfmpegDir on PATH) and restarts it if it dies, at most 3 times an hour. So
# the worker never runs without its guard: start the guard, never the worker alone.
param([switch]$Office, [string]$OfficeHost = '192.168.1.5',
      [double]$BaseRate = 0, [int]$BasePipes = 0,
      [int]$ReleaseAfterSec = 900, [string]$TestDir = '',
      [string]$Labs = 'C:\dev\cilex-watchtower\tools\labs',
      [string]$Python = 'python',
      [string]$GuardDir = 'C:\wt\labs-guard',
      [switch]$StartWorker, [string]$Api = 'http://192.168.1.4:8000', [string]$FfmpegDir = '')
$ErrorActionPreference = 'Continue'
$labs = $Labs
$BY   = 'wall-guard'
$tag  = if ($Office) { 'office' } else { 'local' }
if (-not (Test-Path -LiteralPath $GuardDir)) { New-Item -ItemType Directory -Path $GuardDir -Force | Out-Null }
$log  = Join-Path $GuardDir "guard-$tag.log"
$csv  = Join-Path $GuardDir "wall-$tag.csv"
function L($m) { ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Out-File -FilePath $log -Append -Encoding utf8 }
function Csv($row) { $row | Out-File -FilePath $csv -Append -Encoding ascii }

if ($Office) {
    $prof = Get-ChildItem -LiteralPath "\\$OfficeHost\C$\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'AppData\Local\Programs\Cilex Watchtower\watchtower.exe') } |
            Select-Object -First 1
    if (-not $prof) { L "START ABORTED: no Watchtower install found under \\$OfficeHost\C$\Users"; exit 1 }
    $roam = Join-Path $prof.FullName 'AppData\Roaming'
    $loc  = Join-Path $prof.FullName 'AppData\Local'
} else {
    $roam = $env:APPDATA
    $loc  = $env:LOCALAPPDATA
}
$fr = Join-Path $roam 'Cilex Vision\Watchtower\flightrec\watchtower.log'
$sd = Join-Path $loc  'watchtower-labs'
if ($TestDir) { $fr = "$TestDir\fr.log"; $sd = $TestDir; $log = "$TestDir\guard.log"; $csv = "$TestDir\wall.csv" }
$ctl = Join-Path $sd 'control.json'

# Only THIS desktop session counts: the office update's SAC probe runs a second
# watchtower.exe for 8 s in session 0, which is not a second wall.
$mySession = (Get-Process -Id $PID).SessionId
function App() { @(Get-CimInstance Win32_Process -Filter "Name='watchtower.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.SessionId -eq $mySession -and $_.ExecutablePath -notlike 'C:\wt\*' }) }
function Worker() { @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
                      Where-Object { $_.SessionId -eq $mySession -and $_.CommandLine -like '*run_worker.py*--loop*' }) }
$workerStarts = New-Object System.Collections.Generic.List[datetime]
$gaveUp = $false
if ($FfmpegDir) { $env:Path = "$FfmpegDir;$env:Path" }        # inherited by the worker it starts
function Start-Worker {
    $recent = @($workerStarts | Where-Object { ((Get-Date) - $_).TotalMinutes -lt 60 })
    if ($recent.Count -ge 3) {
        if (-not $script:gaveUp) { $script:gaveUp = $true; L "WORKER NOT RESTARTED: it was started 3 times in the last hour -- leaving it stopped" }
        return
    }
    $script:gaveUp = $false
    try {
        # Through cmd `start /low /b`: the hidden console, and its conhost.exe, then belong to
        # cmd -- not to the worker -- so a kill of the worker's children can never take the
        # console away. 2026-09-29 02:13 on wt-office-01: worker-0.3.2's Stop killed its own
        # conhost, and every ffmpeg after that died at start (0xC0000142), filing ~25 units
        # failed. /low starts it at Idle from the first instruction; its children inherit it.
        # The worker's log goes in the GUARD's folder, never beside the code: on the booth
        # -Labs is the git checkout, and a log there left the tree dirty, which made the
        # 1.1.707 build refuse to start (2026-09-29).
        $cmdline = '/c start "" /low /b "{0}" -u "{1}" --loop --api {2} >> "{3}" 2>&1' -f `
                   $Python, (Join-Path $labs 'run_worker.py'), $Api, (Join-Path $GuardDir 'worker.log')
        Start-Process -FilePath cmd.exe -ArgumentList $cmdline -WorkingDirectory $labs -WindowStyle Hidden -ErrorAction Stop
        $workerStarts.Add((Get-Date))
        Start-Sleep -Seconds 3
        $w = @(Worker)
        if ($w.Count) { L ("worker started by the guard: pid {0}, priority {1}, console owned by cmd" -f $w[0].ProcessId, (Get-Process -Id $w[0].ProcessId -ErrorAction SilentlyContinue).PriorityClass) }
        else { L "worker start: no worker process 3 s after launching it" }
    } catch {
        $workerStarts.Add((Get-Date))
        L "worker start FAILED: $($_.Exception.Message)"
    }
}
function ReadJson($p) {
    try {
        $fs = [IO.File]::Open($p, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        return ($t | ConvertFrom-Json)
    } catch { return $null }
}
function Hold() {
    # the hold as station._hold_of reads it: an object with a non-empty why, else none
    $d = ReadJson $ctl
    if ($d -and $d.hold -and $d.hold.why) { return $d.hold }
    return $null
}
function Station($code, $arg) {
    # station.py's own writer: atomic, keeps the rest of the file (camera_health included)
    $py = "import sys, json; sys.path.insert(0, sys.argv[1]); import station as S; print(json.dumps($code))"
    return @(& $Python -c $py $labs $sd $arg 2>&1 | ForEach-Object { "$_" })
}
function Set-Hold($why) {
    $why = ($why -replace '"', "'")
    if ($why.Length -gt 120) { $why = $why.Substring(0, 120) }
    $out = Station "S.write_hold(sys.argv[3], by='$BY', directory=sys.argv[2])" $why
    L "HOLD SET: $why"
    foreach ($o in $out) { L "  hold: $o" }
}
function Clear-Hold($why) {
    $out = Station "S.clear_hold(by='$BY', directory=sys.argv[2])" 'x'
    L "HOLD RELEASED: $why"
    foreach ($o in $out) { L "  release: $o" }
}
# Up to 1.1.748 the app's stall detector (src/main.cpp, runs only when WT_TRACE is set) measured
# on the WALL clock, so a forward step of the system clock read as a freeze of the same length;
# fe8fc6f (1.1.749) moved it to a monotonic clock, and this stays for walls not yet on it (and
# costs nothing after: a monotonic stall has no step inside it to subtract). Windows Time steps
# the booth's clock +3.75..+3.93 s every night between 00:03 and 00:34 (System log,
# Kernel-General event 1; 16 steps 09-15..09-30), and every gui_stall >= 2 s the booth logged
# 09-26..09-30 sits on one of them to the second; 2026-09-30 00:11:13 "gui_stall 3770 ms"
# (step +3.754 s) set a hold while the app's 2 s timer never missed a tick. So subtract every
# forward step whose event falls inside the stall ($end is the line's own time, which is when
# the stall ended). Returns 0 when there is none, AND when the log cannot be read: an
# unreadable log must never hide a real freeze.
function ClockStepMs([datetime]$end, [int]$ms) {
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 1;
                                                 StartTime = $end.AddMilliseconds(-$ms - 1000); EndTime = $end.AddSeconds(2) } -ErrorAction Stop)
    } catch { return 0 }
    $sum = 0.0
    foreach ($e in $ev) {
        try {
            $d = @{}; foreach ($x in ([xml]$e.ToXml()).Event.EventData.Data) { $d[$x.Name] = $x.'#text' }
            $s = ([datetime]::Parse($d['NewTime']) - [datetime]::Parse($d['OldTime'])).TotalMilliseconds
            if ($s -gt 0) { $sum += $s }
        } catch {}
    }
    return [int][Math]::Round($sum)
}

# ---------------------------------------------------------------------------------------
if ($BaseRate -le 0 -or $BasePipes -le 0) { L "START ABORTED: -BaseRate and -BasePipes (pre-worker full-wall values) are required"; exit 1 }
if (-not (Test-Path -LiteralPath $fr)) { L "START ABORTED: no flight recorder at $fr"; exit 1 }
$app0 = $null
if (-not $Office -and -not $TestDir) {
    $a0 = @(App)
    if ($a0.Count -ne 1) { L "START ABORTED: expected one wall app, found $($a0.Count)"; exit 1 }
    $app0 = $a0[0].ProcessId
}
if (-not (Test-Path -LiteralPath $csv)) { Csv 'time,up_s,live_pipes,shown_per_s,gui_stall_ms,lit,err,swd,recon_ran' }

$h0 = Hold
$mine = [bool]($h0 -and $h0.by -eq $BY)          # a hold from an earlier run of this guard is ours to release (start log only)
$lastHarm = Get-Date                             # the release clock starts when this guard starts watching
L ("guard3 started ({0} on {1}): baseline {2} frames/s, {3} pipelines; release after {4} s healthy; wall app {5}; starts the worker: {6}; hold now: {7}" -f `
   $tag, $env:COMPUTERNAME, $BaseRate, $BasePipes, $ReleaseAfterSec, $(if ($app0) { "pid $app0" } elseif ($TestDir) { 'test' } else { 'remote' }),
   $(if ($StartWorker -and -not $Office) { "yes (running now: $((@(Worker) | ForEach-Object { $_.ProcessId }) -join ',' ))" } else { 'no' }),
   $(if ($h0) { "by $($h0.by): $($h0.why)$(if ($mine) { ' (ours: will release when healthy)' } else { ' (not ours: never touched)' })" } else { 'none' }))

$lastHeldWhy = $null
function Harm($why) {
    $script:lastHarm = Get-Date
    $h = Hold
    if ($h) {
        # already held (ours or anyone's): never overwrite; say so once per distinct reason
        if ($why -ne $script:lastHeldWhy) { $script:lastHeldWhy = $why; L "harm while held by $($h.by): $why" }
        return
    }
    $script:lastHeldWhy = $why
    Set-Hold $why
}

$pos = (Get-Item -LiteralPath $fr).Length
if ($TestDir) { $pos = 0 }
$carry = ''
$stalls = New-Object System.Collections.Generic.List[datetime]
$recons = New-Object System.Collections.Generic.List[object]
$lowRate = 0; $errRun = 0; $darkRun = 0; $full1 = $false; $full2 = $false
$lastFrames = $null; $lastUp = $null; $lastSwd = $null; $lastRecon = $null
$lastRate = $null; $lastLp = $null; $lastLit = $null
$lastMemtel = Get-Date; $blind = $false
$lastSummary = Get-Date; $lastState = $null

while ($true) {
    Start-Sleep -Seconds 15
    $now = Get-Date

    # -- the wall app itself (booth: by process; both: by the recorder's start line below)
    if ($app0 -or (-not $Office -and -not $TestDir)) {
        $a = @(App)
        if ($a.Count -ne 1) { Harm ("wall app not running (found {0})" -f $a.Count) }
        elseif ($a[0].ProcessId -ne $app0) {
            Harm ("the wall app restarted (pid {0} -> {1})" -f $app0, $a[0].ProcessId)
            $app0 = $a[0].ProcessId
            $lastFrames = $null; $lastSwd = $null; $lastRecon = $null; $full1 = $false; $full2 = $false; $recons.Clear()
        }
    }

    # -- the worker: started (and restarted) by this guard when asked to, never without it
    if ($StartWorker -and -not $Office -and -not $TestDir -and @(Worker).Count -eq 0) { Start-Worker }
    $st = ReadJson (Join-Path $sd 'status.json')
    if ($st) {
        $sk = "$($st.pid)|$($st.state)|$($st.server_mode)|$($st.governed)"
        if ($sk -ne $lastState) { $lastState = $sk; L ("worker: pid {0} state {1}, governed {2}, server_mode {3}, note: {4}" -f $st.pid, $st.state, $st.governed, $st.server_mode, $st.note) }
    }

    # -- the wall, from its flight recorder
    try {
        $len = (Get-Item -LiteralPath $fr -ErrorAction Stop).Length
        if ($len -lt $pos) { $pos = 0; $carry = ''; $lastFrames = $null }      # rotated
        if ($len -gt $pos) {
            $fs = [IO.File]::Open($fr, 'Open', 'Read', 'ReadWrite')
            [void]$fs.Seek($pos, 'Begin')
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            $new = $sr.ReadToEnd()
            $pos = $fs.Position
            $sr.Close(); $fs.Close()
            $parts = @(($carry + $new) -split "`n")
            $carry = $parts[-1]
            # NOT $parts[0..($parts.Count - 2)]: with one part that is 0..-1, counted DOWN.
            $whole = if ($parts.Count -ge 2) { $parts[0..($parts.Count - 2)] } else { @() }
            foreach ($line in $whole) {
                $sm = [regex]::Match($line, '=== watchtower start v(\S+) pid=(\d+)')
                if ($sm.Success) {
                    Harm ("the wall app started again (v{0} pid {1})" -f $sm.Groups[1].Value, $sm.Groups[2].Value)
                    $lastFrames = $null; $lastSwd = $null; $lastRecon = $null; $full1 = $false; $full2 = $false; $recons.Clear()
                    continue
                }
                $m = [regex]::Match($line, '^(\S+) .*gui_stall (\d+) ms')
                if ($m.Success) {
                    $ms = [int]$m.Groups[2].Value
                    if ($ms -ge 1000) {
                        $ts = $m.Groups[1].Value; if ($ts.Length -gt 23) { $ts = $ts.Substring(0, 23) }
                        $end = [datetime]::MinValue
                        if ([datetime]::TryParseExact($ts, 'yyyy-MM-ddTHH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture,
                                                      [Globalization.DateTimeStyles]::None, [ref]$end)) {
                            $step = ClockStepMs $end $ms
                            if ($step -gt 0) {
                                $real = [Math]::Max(0, $ms - $step)
                                L ("gui_stall {0} ms at {1} is the system clock moving +{2} ms (Windows Time, System log Kernel-General 1), not a freeze: counted as {3} ms" -f `
                                   $ms, $ts.Substring(11, 8), $step, $real)
                                $ms = $real
                            }
                        }
                    }
                    if ($ms -gt 150) { Csv ("{0},,,,{1}" -f $now.ToString('s'), $ms) }
                    if ($ms -ge 1000) { $stalls.Add($now); $lastHarm = $now; L "gui_stall $ms ms" }
                    if ($ms -ge 2000) { Harm "the wall's screen froze for $ms ms" }
                }
                $mm = [regex]::Match($line, '^(\S+) .*\[MEMTEL\] up=(\d+)s.*?livePipes=(\d+) frames=(\d+).*? dec=(\d+) lit=(\d+) err=(\d+) swd=(\d+) recon=(\d+)/(\d+)')
                if ($mm.Success) {
                    $up  = [int]$mm.Groups[2].Value; $lp = [int]$mm.Groups[3].Value; $frm = [long]$mm.Groups[4].Value
                    $lit = [int]$mm.Groups[6].Value; $err = [int]$mm.Groups[7].Value
                    $swd = [long]$mm.Groups[8].Value; $recon = [long]$mm.Groups[9].Value
                    $lastLp = $lp; $lastLit = $lit; $lastMemtel = $now
                    if ($err -gt 0) { $errRun++ } else { $errRun = 0 }
                    if ($errRun -ge 3) { Harm "$err of $lp video streams in error for 90 s" }
                    if ($lit -lt $lp) { $darkRun++ } else { $darkRun = 0 }
                    if ($darkRun -ge 3) { Harm ("{0} of {1} tiles dark for 90 s" -f ($lp - $lit), $lp) }
                    $fullWall = ($lp -eq $BasePipes -and $lit -eq $lp)
                    $steady = ($fullWall -and $full1 -and $full2)
                    if ($lastSwd -ne $null -and $swd -ge $lastSwd -and $recon -ge $lastRecon) {
                        if ($steady) {
                            if ($swd -gt $lastSwd) { Harm ("{0} streams rebuilt by the watchdog on a steady wall" -f ($swd - $lastSwd)) }
                            if ($recon -gt $lastRecon) { $recons.Add([pscustomobject]@{ t = $now; n = ($recon - $lastRecon) }) }
                        } elseif ($swd -gt $lastSwd -or $recon -gt $lastRecon) {
                            L ("wall rebuilt after navigation: swd +{0}, recon +{1} (not counted: the wall was not steady)" -f ($swd - $lastSwd), ($recon - $lastRecon))
                        }
                    }
                    while ($recons.Count -and ($now - $recons[0].t).TotalMinutes -gt 10) { $recons.RemoveAt(0) }
                    $rsum = 0; foreach ($r in $recons) { $rsum += $r.n }
                    if ($rsum -ge 3) { Harm "$rsum stream reconnects in 10 min on a steady wall"; $recons.Clear() }
                    $lastSwd = $swd; $lastRecon = $recon
                    $rateText = ''
                    if ($lastFrames -ne $null -and $up -gt $lastUp) {
                        $rate = ($frm - $lastFrames) / ($up - $lastUp)
                        $lastRate = $rate; $rateText = $rate.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
                        if ($fullWall -and $full1) {
                            if ($rate -lt 0.7 * $BaseRate) { $lowRate++ } else { $lowRate = 0 }
                            if ($lowRate -ge 3) { Harm ("the wall shows {0:N0} frames/s, under 70% of its usual {1}, for 90 s" -f $rate, $BaseRate); $lowRate = 0 }
                        } else { $lowRate = 0 }
                    }
                    $full2 = $full1; $full1 = $fullWall
                    $ts = $mm.Groups[1].Value; if ($ts.Length -gt 19) { $ts = $ts.Substring(0, 19) }
                    Csv ("{0},{1},{2},{3},,{4},{5},{6},{7}" -f $ts, $up, $lp, $rateText, $lit, $err, $swd, $recon)
                    $lastFrames = $frm; $lastUp = $up
                }
            }
        }
    } catch {
        L "flight recorder read failed: $($_.Exception.Message)"
    }
    while ($stalls.Count -and ($now - $stalls[0]).TotalMinutes -gt 10) { $stalls.RemoveAt(0) }
    if ($stalls.Count -ge 3) { Harm "3 screen freezes of 1 s or more in 10 min"; $stalls.Clear() }

    # -- blind: a guard that parses nothing protects nothing, and must not release anything
    if (-not $blind -and ($now - $lastMemtel).TotalMinutes -ge 3) { $blind = $true; L "GUARD BLIND: no MEMTEL line parsed for 3 min" }
    if ($blind -and ($now - $lastMemtel).TotalMinutes -lt 1) { $blind = $false; $lastHarm = $now; L "guard sees MEMTEL again (release clock restarted)" }

    # -- release: only a hold that is OURS NOW (who set it is re-read every time: an admin
    #    may have replaced it), and only after a sustained healthy stretch, never blind
    $h = Hold
    if ($h -and $h.by -eq $BY -and -not $blind -and ($now - $lastHarm).TotalSeconds -ge $ReleaseAfterSec) {
        Clear-Hold ("the wall has been healthy for {0:N0} min" -f (($now - $lastHarm).TotalMinutes))
        $lastHeldWhy = $null
    }

    if (($now - $lastSummary).TotalMinutes -ge 30) {
        $lastSummary = $now
        L ("health: shown {0:N1}/s (usual full wall {1}), pipes {2} lit {3}; hold: {4}" -f $lastRate, $BaseRate, $lastLp, $lastLit,
           $(if ($h) { "$($h.by): $($h.why)" } else { 'none' }))
    }
}
