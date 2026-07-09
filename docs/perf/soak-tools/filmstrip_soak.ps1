<#
.SYNOPSIS
  Filmstrip frame-loading soak (Windows) -- hammers the frame-by-frame filmstrip's harvest/load path
  overnight, the targeted regression net for the 2026-07-09 filmstrip fixes (0c2e79c F-reaches-mode,
  8f2a7d0 flicker/dark-edge/strip-vanishing-on-back-steps, 7b0fe89 pin-during-harvest/fresh-entry-
  reset/ready-guard).

.DESCRIPTION
  Each cycle launches watchtower with WT_FRAME_MODE=1 (auto-enter the filmstrip once footage renders ->
  warmup harvest + rolling prefetch fill the strip's decoded-frame thumbnails) AND WT_STEPTEST=<N>
  (the alternating 10-fwd/12-back stepper soak driving the harvest under concurrent stepping, hitting
  back-steps + window edges). The app self-quits on [STEPT] DONE, so every relaunch is a FRESH ENTRY
  (exercises fresh-entry reset). Per cycle we record the [STEPT] SUMMARY (wrongWay / fails / cache=Nf
  harvest fill) and flag anything off: a crash (exit before DONE), a wedge (no [STEPT]/heartbeat
  progress while alive -> procdump -ma), fails>0, wrongWay>0, or an anaemic harvest (cache far below
  the strip's needs => "frames not loading"). Aggregates across the night.

.NOTES
  ASCII-only (PS 5.1 + pwsh). WIN32 GUI -> QT_FORCE_STDERR_LOGGING routes [STEPT]/[WT-STEP]/[WT-MEM]
  to a redirected stderr. Artifacts land durable (NOT %TEMP%). procdump auto-detected.

.EXAMPLE
  powershell -File .\filmstrip_soak.ps1 -Dist C:\git\portable\2026-07-09-filmstrip2 -EndTime 07:00
  powershell -File .\filmstrip_soak.ps1 -Dist C:\git\portable\2026-07-09-filmstrip2 -DurationMinutes 6   # smoke
#>
param(
    [string]$Dist          = "C:\git\portable\2026-07-09-filmstrip2",
    [string]$BackendUrl    = "http://100.107.51.72:8000",
    [string]$Ip            = "192.168.1.201",         # DS-I402(D): fresh 07-08 HEVC 1440p footage
    [string]$Day           = "2026-07-08T18:00:00",
    [int]$Steps            = 100,                       # alternating steps per cycle (harvest under stepping)
    [int]$MinCacheFrames   = 8,                         # a healthy harvest fills the strip; below this = "frames not loading"
    [string]$EndTime       = "07:00",
    [int]$DurationMinutes  = 0,                         # >0 overrides EndTime (smoke)
    [string]$SoakDir       = "$env:USERPROFILE\watchtower-soak\filmstrip",
    [string]$ProcDump      = "",
    [int]$CycleHangSeconds = 120,                       # no [STEPT]/heartbeat this long while alive => wedge
    [int]$CycleCapSeconds  = 300,                       # hard cap per cycle
    [int]$PollSeconds      = 5
)
$ErrorActionPreference = "Stop"
$exe = Join-Path $Dist "watchtower.exe"
if (-not (Test-Path $exe)) { throw "watchtower.exe not found in '$Dist' -- pass -Dist <unzipped portable dir>." }

if (-not $ProcDump) {
    foreach ($c in @("C:\wt\procdump\procdump64.exe","C:\wt\procdump\procdump.exe","procdump64.exe","procdump.exe")) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { $ProcDump = $cmd.Source; break }
        if (Test-Path $c) { $ProcDump = (Resolve-Path $c).Path; break }
    }
}
$haveDump = [bool]$ProcDump -and (Test-Path $ProcDump)

New-Item -ItemType Directory -Force -Path $SoakDir | Out-Null
$SUP = Join-Path $SoakDir "supervisor.log"
$INC = Join-Path $SoakDir "incidents.log"
$CSV = Join-Path $SoakDir "cycles.csv"
if (-not (Test-Path $CSV)) { "cycle,result,steps,wrongWay,fails,cacheFrames,cacheMB,alive_s" | Out-File -FilePath $CSV -Encoding ascii }

$env:WT_CV_URL                    = $BackendUrl
$env:WT_CV_AUTOLOGIN              = "1"
$env:WT_FRAME_MODE                = "1"            # auto-enter the filmstrip (harvest + prefetch)
$env:WT_STEPTEST                  = "$Steps"       # drive the stepper through the strip
$env:WT_PLAYBACK_IP               = $Ip
$env:WT_PLAYBACK_DAY              = $Day
$env:WT_TRACE                     = "1"
$env:WT_SMOOTHTEST                = "999999"       # GUI heartbeat (wedge detector)
$env:QT_FORCE_STDERR_LOGGING      = "1"
$env:QT_ASSUME_STDERR_HAS_CONSOLE = "1"
$env:QT_MESSAGE_PATTERN           = "%{time hh:mm:ss.zzz} %{message}"

$START = Get-Date
if ($DurationMinutes -gt 0) { $END = $START.AddMinutes($DurationMinutes) }
else { $END = [datetime]::Today.Add([timespan]::Parse($EndTime)); if ($END -le $START) { $END = $END.AddDays(1) } }

function Write-Sup([string]$m) { $l = "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m; Add-Content -Path $SUP -Value $l; Write-Host $l }
Write-Sup ("FILMSTRIP SOAK START -- {0} (backend {1}) cam={2} day={3} steps={4}, until {5:ddd HH:mm}, procdump={6}" -f `
    $exe, $BackendUrl, $Ip, $Day, $Steps, $END, $(if ($haveDump) { $ProcDump } else { "NONE" }))
if (-not $haveDump) { Write-Sup "WARNING: procdump NOT found -- a wedge will be recorded but NOT dumped." }

$cycle = 0; $agg = @{ clean = 0; crash = 0; wedge = 0; fails = 0; wrongWay = 0; lowCache = 0; steps = 0 }
while ((Get-Date) -lt $END) {
    $cycle++
    $log = Join-Path $SoakDir ("cycle{0:D4}.err.log" -f $cycle)
    $out = Join-Path $SoakDir ("cycle{0:D4}.out.log" -f $cycle)
    $started = Get-Date
    $app = Start-Process $exe -WorkingDirectory $Dist -PassThru -RedirectStandardError $log -RedirectStandardOutput $out
    $capEnd = $started.AddSeconds($CycleCapSeconds); if ($capEnd -gt $END) { $capEnd = $END }
    $lastProgress = Get-Date; $seenCount = 0; $result = ""
    while ((Get-Date) -lt $capEnd) {
        Start-Sleep -Seconds $PollSeconds
        if ($app.HasExited) { break }
        $n = (Select-String -Path $log -Pattern '\[STEPT\]|WTSMOOTH t=' -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($n -gt $seenCount) { $seenCount = $n; $lastProgress = Get-Date }
        if (((Get-Date) - $lastProgress).TotalSeconds -ge $CycleHangSeconds) { $result = "wedge"; break }
    }
    $aliveS = [int]((Get-Date) - $started).TotalSeconds
    $lines = if (Test-Path $log) { Get-Content $log -ErrorAction SilentlyContinue } else { @() }
    $doneSeen = [bool]($lines | Select-String -Pattern '\[STEPT\] DONE' -Quiet)
    $sumLine  = ($lines | Select-String -Pattern '\[STEPT\] SUMMARY' | Select-Object -Last 1).Line
    $wrongWay = 0; $fails = 0; $steps = 0; $cf = -1; $cmb = 0.0
    if ($sumLine) {
        if ($sumLine -match 'steps=(\d+)')     { $steps = [int]$Matches[1] }
        if ($sumLine -match 'wrongWay=(\d+)')  { $wrongWay = [int]$Matches[1] }
        if ($sumLine -match 'fails=(\d+)')     { $fails = [int]$Matches[1] }
        if ($sumLine -match 'cache=(\d+)f/([\d.]+)MB') { $cf = [int]$Matches[1]; $cmb = [double]$Matches[2] }
    }
    $fatal = ($lines | Select-String -Pattern 'WT-FATAL|CRITICAL' | Measure-Object).Count

    if (-not $result) {
        if ($doneSeen) { $result = "clean" }
        elseif ($app.HasExited) { $result = "crash" }
        else { $result = "cap" }   # ran out the cap without DONE and without a hang stall (rare)
    }
    # procdump a live wedge BEFORE the kill
    $dumpPath = ""
    if ($result -eq "wedge" -and -not $app.HasExited -and $haveDump) {
        $dumpPath = Join-Path $SoakDir ("wedge_cycle{0:D4}.dmp" -f $cycle)
        Write-Sup ("WEDGE cycle #{0} -- procdump -ma {1}" -f $cycle, $app.Id)
        try { & $ProcDump -accepteula -ma $app.Id $dumpPath 2>&1 | Out-Null } catch { Write-Sup ("procdump failed: {0}" -f $_.Exception.Message) }
    }
    if (-not $app.HasExited) { try { $app.Kill() } catch { } }
    Get-Process -Name watchtower -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $app.Id } | Stop-Process -Force -ErrorAction SilentlyContinue

    $lowCache = ($result -eq "clean" -and $cf -ge 0 -and $cf -lt $MinCacheFrames)
    ("{0},{1},{2},{3},{4},{5},{6},{7}" -f $cycle, $result, $steps, $wrongWay, $fails, $cf, $cmb, $aliveS) | Out-File -FilePath $CSV -Append -Encoding ascii
    switch ($result) { "clean" { $agg.clean++ } "crash" { $agg.crash++ } "wedge" { $agg.wedge++ } default { } }
    $agg.fails += $fails; $agg.wrongWay += $wrongWay; $agg.steps += $steps; if ($lowCache) { $agg.lowCache++ }

    if ($result -ne "clean" -or $fails -gt 0 -or $wrongWay -gt 0 -or $lowCache -or $fatal -gt 0) {
        $blk = @()
        $blk += ("###### cycle #{0} result={1} (alive {2}s) wrongWay={3} fails={4} cache={5}f fatal={6} {7}" -f `
            $cycle, $result, $aliveS, $wrongWay, $fails, $cf, $fatal, $(if ($lowCache) { "LOW-HARVEST" } else { "" }))
        $blk += ($lines | Select-String -Pattern '\[STEPT\]|WT-FATAL|CRITICAL|\[WT-STEP\].*(fail|FAIL)' | Select-Object -Last 12 | ForEach-Object { "   $_" })
        if ($dumpPath) { $blk += "   procdump: $dumpPath" }
        ($blk -join "`r`n") | Out-File -FilePath $INC -Append -Encoding ascii
    }
    Write-Sup ("cycle #{0}: {1} steps={2} wrongWay={3} fails={4} cache={5}f/{6}MB alive={7}s{8}" -f `
        $cycle, $result, $steps, $wrongWay, $fails, $cf, $cmb, $aliveS, $(if ($lowCache) { " LOW-HARVEST" } else { "" }))
    Start-Sleep -Seconds 2
}

Get-Process -Name watchtower -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Sup ("DONE -- cycles={0} clean={1} crash={2} wedge={3} | totalSteps={4} fails={5} wrongWay={6} lowHarvest={7}" -f `
    $cycle, $agg.clean, $agg.crash, $agg.wedge, $agg.steps, $agg.fails, $agg.wrongWay, $agg.lowCache)
Write-Output "FILMSTRIP_SOAK_COMPLETE"
