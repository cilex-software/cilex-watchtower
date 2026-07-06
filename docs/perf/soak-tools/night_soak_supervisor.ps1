<#
.SYNOPSIS
  Overnight NIGHT-SOAK supervisor for Cilex Watchtower on Windows (W3 parity soak).
  Windows/PowerShell port of night_soak_supervisor.sh.

.DESCRIPTION
  Drives WT_NIGHT_SOAK (historic-playback timing + export matrix + seek-land + Esc/cancel) with
  WT_SMOOTHTEST as a continuous GUI heartbeat, samples RSS/CPU, and on any crash or GUI wedge
  records the cause + the actions leading up to it (with a procdump full dump on a live wedge),
  then relaunches. A sidecar stat's + deletes exported clips (logging their sizes) so disk does
  not fill -- with an mtime guard so it NEVER touches a clip older than supervisor start (the
  fa07dee invariant: never delete the operator's pre-existing exports).

  Wedge capture uses procdump (Sysinternals) -- the Windows analog of the Linux gdb
  'thread apply all bt' that cracked HANG #1. Analyze dumps offline with WinDbg (!analyze -v, ~*k).

.NOTES
  ASCII-only so it parses under Windows PowerShell 5.1 AND pwsh. A WIN32 GUI app does not write
  qInfo() to stdout, so QT_FORCE_STDERR_LOGGING routes the [WT-*]/[NTIME] trace to a redirectable
  stderr. Keep artifacts OUT of %TEMP% (a reboot clears it -- the 2026-07-03 night lost the first
  HANG #1 record that way). procdump.exe is under the Sysinternals EULA -- do NOT commit it; the
  supervisor auto-detects it (see -ProcDump) or documents the download.

.EXAMPLE
  powershell -File .\night_soak_supervisor.ps1 -Dist C:\wt\portable-ci -EndTime 07:00
  powershell -File .\night_soak_supervisor.ps1 -Dist C:\wt\portable-ci -DurationMinutes 30   # smoke
#>
param(
    [string]$Dist          = "C:\wt\portable-ci",
    [string]$BackendUrl    = "http://100.107.51.72:8000",
    [string]$EndTime       = "07:00",                       # local HH:mm; today if future, else tomorrow
    [int]$DurationMinutes  = 0,                             # >0 overrides EndTime (smoke tests)
    [string]$SoakDir       = "$env:USERPROFILE\watchtower-soak\night_soak",
    [string]$ExportDir     = "$env:USERPROFILE\Videos\Watchtower",
    [string]$ProcDump      = "",                            # auto-detected if empty
    [int]$HangSeconds      = 150,                           # no [NTIME]/[WT-MEM] this long while alive => wedge
    [int]$PollSeconds      = 15
)
$ErrorActionPreference = "Stop"

$exe = Join-Path $Dist "watchtower.exe"
if (-not (Test-Path $exe)) { throw "watchtower.exe not found in '$Dist' -- pass -Dist <unzipped portable dir>." }

# --- procdump auto-detect (Sysinternals EULA; not committed to the repo) ---
if (-not $ProcDump) {
    foreach ($c in @("C:\wt\procdump\procdump64.exe","C:\wt\procdump\procdump.exe","procdump64.exe","procdump.exe")) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { $ProcDump = $cmd.Source; break }
        if (Test-Path $c)  { $ProcDump = (Resolve-Path $c).Path; break }
    }
}
$haveDump = [bool]$ProcDump -and (Test-Path $ProcDump)

# --- durable output dir (NOT %TEMP%) ---
New-Item -ItemType Directory -Force -Path $SoakDir | Out-Null
$INC     = Join-Path $SoakDir "incidents.log"
$SUP     = Join-Path $SoakDir "supervisor.log"
$XSZ     = Join-Path $SoakDir "export_sizes.log"
$SAMPLES = Join-Path $SoakDir "samples.csv"
if (-not (Test-Path $SAMPLES)) { "time,pid,rss_mb,cpu_s" | Out-File -FilePath $SAMPLES -Encoding ascii }

# --- soak environment (Windows) ---
$env:WT_CV_URL                    = $BackendUrl
$env:WT_CV_AUTOLOGIN              = "1"
$env:WT_NIGHT_SOAK                = "1"
$env:WT_TRACE                     = "1"
$env:WT_SMOOTHTEST                = "999999"     # continuous GUI heartbeat; never self-quits
$env:QT_FORCE_STDERR_LOGGING      = "1"          # WIN32 GUI -> [WT-*]/[NTIME] to stderr
$env:QT_ASSUME_STDERR_HAS_CONSOLE = "1"

# --- time window ---
$START = Get-Date
if ($DurationMinutes -gt 0) {
    $END = $START.AddMinutes($DurationMinutes)
} else {
    $END = [datetime]::Today.Add([timespan]::Parse($EndTime))
    if ($END -le $START) { $END = $END.AddDays(1) }
}

function Write-Sup([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $msg
    Add-Content -Path $SUP -Value $line
    Write-Host $line
}

Write-Sup ("NIGHT SOAK START -- {0} (backend {1}), until {2:ddd HH:mm}, hang={3}s, procdump={4}" -f `
    $exe, $BackendUrl, $END, $HangSeconds, $(if ($haveDump) { $ProcDump } else { "NONE" }))
if (-not $haveDump) {
    Write-Sup "WARNING: procdump NOT found -- a GUI wedge will be recorded but NOT dumped (a hang without a dump is a failed capture). Set -ProcDump or install to C:\wt\procdump\."
}

# --- export sidecar sweep (mtime guard: only clips created AT/AFTER supervisor start) ---
function Invoke-ExportSweep {
    Get-ChildItem -Path $ExportDir -Filter *.mp4 -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LastWriteTime -lt $START) { return }                                   # SAFETY: never the operator's pre-existing clips
        if (((Get-Date) - $_.LastWriteTime).TotalSeconds -lt 3) { return }            # not still being written
        $sz = $_.Length
        ("{0} size={1} bytes={2} file={3}" -f (Get-Date -Format 'HH:mm:ss'), $sz, ("{0:N1}MB" -f ($sz/1MB)), $_.Name) |
            Out-File -FilePath $XSZ -Append -Encoding ascii
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# --- RSS/CPU sample of the tracked process ---
function Add-Sample($proc) {
    if (-not $proc -or $proc.HasExited) { return }
    try {
        $proc.Refresh()
        $rss = [int]($proc.WorkingSet64 / 1MB)
        $cpu = [int]$proc.TotalProcessorTime.TotalSeconds
        ("{0},{1},{2},{3}" -f (Get-Date -Format 'HH:mm:ss'), $proc.Id, $rss, $cpu) |
            Out-File -FilePath $SAMPLES -Append -Encoding ascii
    } catch { }
}

$run = 0
while ((Get-Date) -lt $END) {
    $run++
    $started = Get-Date
    $reason  = ""
    $runLog  = Join-Path $SoakDir ("app_run{0}.log" -f $run)
    $runOut  = Join-Path $SoakDir ("app_run{0}.out.log" -f $run)
    Write-Sup ("launch #{0} -> {1}" -f $run, (Split-Path -Leaf $runLog))
    $app = Start-Process $exe -WorkingDirectory $Dist -PassThru `
              -RedirectStandardError $runLog -RedirectStandardOutput $runOut
    $lastHb = 0
    $stall  = 0
    while ((Get-Date) -lt $END) {
        Start-Sleep -Seconds $PollSeconds
        Invoke-ExportSweep
        if ($app.HasExited) { $reason = "crash"; break }
        Add-Sample $app
        $hb = (Select-String -Path $runLog -Pattern 'NTIME|WT-MEM' -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($hb -gt $lastHb) { $lastHb = $hb; $stall = 0 } else { $stall += $PollSeconds }
        if ($stall -ge $HangSeconds) { $reason = "hang"; break }
    }

    if (-not $reason) {                                   # end reached, app healthy -> clean stop
        if (-not $app.HasExited) { try { $app.Kill() } catch { } }
        Write-Sup ("end time reached -- clean stop (run #{0})" -f $run)
        break
    }

    $aliveS = [int]((Get-Date) - $started).TotalSeconds
    $tag    = if ($reason -eq "hang") { "HANG/GUI-WEDGE" } else { "CRASH/KILL" }

    # --- procdump BEFORE the kill on a live wedge (the datum HANG #1 died without a stack) ---
    $dumpPath = ""
    if ($reason -eq "hang" -and -not $app.HasExited -and $haveDump) {
        $dumpPath = Join-Path $SoakDir ("wedge_run{0}_{1}.dmp" -f $run, (Get-Date -Format 'HHmmss'))
        Write-Sup ("GUI wedge -- procdump -ma {0} -> {1}" -f $app.Id, (Split-Path -Leaf $dumpPath))
        try { & $ProcDump -accepteula -ma $app.Id $dumpPath 2>&1 | Out-Null }
        catch { Write-Sup ("procdump failed: {0}" -f $_.Exception.Message) }
    }

    # --- incident block (mirrors the .sh record) ---
    $log = if (Test-Path $runLog) { Get-Content $runLog -ErrorAction SilentlyContinue } else { @() }
    $hostMem = try {
        $os = Get-CimInstance Win32_OperatingSystem
        "{0} MB free of {1} MB" -f [int]($os.FreePhysicalMemory/1024), [int]($os.TotalVisibleMemorySize/1024)
    } catch { "n/a" }
    $block = @()
    $block += ""
    $block += ("########## {0}  run #{1}  {2}  (alive {3}s, stall {4}s) ##########" -f $tag, $run, (Get-Date), $aliveS, $stall)
    if ($reason -eq "hang") { $block += ("-- cause: heartbeat stalled {0}s while process ALIVE => GUI wedge" -f $stall) }
    $block += "-- fatal/critical lines:"
    $block += ($log | Select-String -Pattern 'WT-FATAL|CRITICAL|assert|Terminated' | Select-Object -Last 20 | ForEach-Object { "   $_" })
    $block += "-- last actions:"
    $block += ($log | Select-String -Pattern '\[NTIME\]|\[NSEEK\]|\[XSOAK\]|\[XRESULT\]' | Select-Object -Last 10 | ForEach-Object { "   $_" })
    $block += "-- last [WT-MEM]:"
    $block += ($log | Select-String -Pattern 'WT-MEM' | Select-Object -Last 1 | ForEach-Object { "   $_" })
    $block += "-- last 6 log lines:"
    $block += ($log | Select-Object -Last 6 | ForEach-Object { "   $_" })
    $block += ("-- host: {0}" -f $hostMem)
    if ($dumpPath)              { $block += ("-- procdump: {0}" -f $dumpPath) }
    elseif ($reason -eq "hang") { $block += "-- procdump: NONE (capture failed -- rerun; a hang without a dump is a failed capture)" }
    ($block -join "`r`n") | Out-File -FilePath $INC -Append -Encoding ascii

    # --- kill the tracked pid + sweep any stray watchtower, then relaunch ---
    if (-not $app.HasExited) { try { $app.Kill() } catch { } }
    Get-Process -Name watchtower -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $app.Id } | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Sup ("{0} run #{1} (alive {2}s) -- recorded; relaunching" -f $tag, $run, $aliveS)
    Start-Sleep -Seconds 3
}

# --- teardown + summary ---
Get-Process -Name watchtower -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$crashes = if (Test-Path $INC)     { (Select-String -Path $INC -Pattern 'CRASH/KILL').Count }     else { 0 }
$hangs   = if (Test-Path $INC)     { (Select-String -Path $INC -Pattern 'HANG/GUI-WEDGE').Count } else { 0 }
$nsamp   = if (Test-Path $SAMPLES) { (Get-Content $SAMPLES).Count - 1 } else { 0 }
$nexp    = if (Test-Path $XSZ)     { (Get-Content $XSZ).Count }         else { 0 }
Write-Sup ("DONE -- {0} launch(es), crashes={1}, hangs={2}, samples={3}, exports_sized={4}" -f $run, $crashes, $hangs, $nsamp, $nexp)
Write-Output "NIGHT_SOAK_COMPLETE"
