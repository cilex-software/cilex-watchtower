# wt-warden Windows install (CW-16). Run AS ADMIN, in the guard user's context:
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1 `
#     -AppExe "C:\Program Files\Cilex Watchtower\watchtower.exe" [-Token <secret>] [-Backend <url>]
#
# What it sets up (per docs/letters/2026-07-27-warden-dead-man-heartbeat.reply.md §3b):
#  1. Warden home + config skeleton (%LOCALAPPDATA%\watchtower-warden).
#  2. WER LocalDumps for watchtower.exe — the belt-and-braces dump for crash
#     classes that bypass the in-app exception filter (fast-fail, /GS).
#  3. A Scheduled Task, NEVER a service (services live in session 0 and cannot
#     own the guard's GUI):  at-logon start  +  restart-on-failure (3 x 1 min)
#     +  a 30-min resurrection trigger with "don't start a second instance" —
#     so a Warden that dies mid-session is dark for <=30 min, not until logon.
#     (CV's alert text carries exactly that number; if CW-18 VM testing
#     disagrees, change BOTH.)
# Autologon is site policy and deliberately NOT scripted here.
param(
    [Parameter(Mandatory = $true)][string]$AppExe,
    [string]$Token = "",
    [string]$Backend = "http://192.168.1.79:8000",
    [string]$WardenExe = ""          # default: warden.exe next to this script
)
$ErrorActionPreference = "Stop"
if (-not $WardenExe) { $WardenExe = Join-Path $PSScriptRoot "warden.exe" }
if (-not (Test-Path $WardenExe)) { throw "warden.exe not found at $WardenExe" }
if (-not (Test-Path $AppExe))    { throw "watchtower.exe not found at $AppExe" }

# --- 1. home + config -------------------------------------------------------
$home_ = Join-Path $env:LOCALAPPDATA "watchtower-warden"
New-Item -ItemType Directory -Force -Path $home_ | Out-Null
$conf = Join-Path $env:USERPROFILE ".config\watchtower-warden\warden.conf"
New-Item -ItemType Directory -Force -Path (Split-Path $conf) | Out-Null
if (-not (Test-Path $conf)) {
    @(
        "BACKEND_URL=$Backend"
        "STATION_TOKEN=$Token"
        "APP_CMD=$AppExe"
        # No WT_CV_AUTOLOGIN on stations: service credentials never live in a
        # station env (CV directive, session-refresh thread). The guard signs in
        # once; the 24h token + /auth/refresh keeps the session alive.
        "APP_ENV="
    ) | Set-Content -Path $conf -Encoding UTF8
    Write-Host "config written: $conf"
    if (-not $Token) { Write-Warning "STATION_TOKEN is EMPTY - uploads/heartbeats stay off until it is set." }
} else {
    Write-Host "config exists, untouched: $conf"
}

# --- 2. WER LocalDumps (crash dir must match FlightRecorder's) ---------------
# TWO Windows traps here, both found on wt-sm-vnutri-01 2026-08-07, both silent:
#
# (a) REGISTRY VIEW. installer.nsi is a 32-bit PE, so the `powershell` it spawns
#     resolves through WOW64 to 32-bit PowerShell, and a 32-bit process writing
#     HKLM\SOFTWARE\... is redirected to HKLM\SOFTWARE\WOW6432Node\... WER is
#     64-bit and watchtower.exe is x64, so it NEVER reads that key: dumps were
#     silently disarmed on every install while the script printed success.
#     Fix: write through the explicit Registry64 view and read it back.
#
# (b) FATALITY. This step is the only one needing admin. With
#     $ErrorActionPreference='Stop' a non-elevated run threw HERE and the
#     Scheduled Task below — which needs NO admin — never registered. The
#     installer is per-user/no-UAC by design, so a plain double-click install
#     left the station with no supervisor at all, silently. WER is now
#     best-effort: warn and carry on, so the supervisor always gets installed.
$crash = Join-Path $env:APPDATA "Cilex Vision\Watchtower\crash"
New-Item -ItemType Directory -Force -Path $crash | Out-Null
$werArmed = $false
try {
    $hklm64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                  [Microsoft.Win32.RegistryHive]::LocalMachine,
                  [Microsoft.Win32.RegistryView]::Registry64)
    $sub = "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\watchtower.exe"
    $k = $hklm64.CreateSubKey($sub)
    $k.SetValue("DumpFolder", $crash, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    $k.SetValue("DumpType",   1, [Microsoft.Win32.RegistryValueKind]::DWord)
    $k.SetValue("DumpCount",  5, [Microsoft.Win32.RegistryValueKind]::DWord)
    $k.Close()
    # Read back THROUGH THE 64-BIT VIEW — the only check that would have caught (a).
    $v = $hklm64.OpenSubKey($sub)
    if ($v -and $v.GetValue("DumpFolder")) { $werArmed = $true; $v.Close() }
    $hklm64.Close()
    if ($werArmed) { Write-Host "WER LocalDumps armed (64-bit view) -> $crash" }
    else           { Write-Warning "WER key written but read-back FAILED - dumps NOT armed." }
} catch {
    Write-Warning "WER LocalDumps NOT armed ($($_.Exception.Message))."
    Write-Warning "  Needs admin. Re-run this script elevated to arm crash dumps."
    Write-Warning "  Warden still supervises and still collects the in-app crash marker."
}

# --- 3. the Scheduled Task ---------------------------------------------------
$taskName = "wt-warden"
$action  = New-ScheduledTaskAction -Execute $WardenExe -Argument "run"
$logon   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# Resurrection: repeat every 30 min forever; MultipleInstances IgnoreNew makes
# it a no-op while Warden is already running.
$resur   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
           -RepetitionInterval (New-TimeSpan -Minutes 30)
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# Orphan sweep before we register. warden.exe is a PyInstaller ONEFILE binary:
# the task launches the bootloader, which spawns the REAL supervisor as a child
# of the same name. Stopping/unregistering the task kills only the bootloader —
# the child survives, keeps supervising, and respawns the app. Without this
# sweep an upgrade-in-place leaves the OLD supervisor running alongside the new
# one: two Wardens, two Watchtowers, two walls on one iGPU. (Measured on
# wt-sm-vnutri-01 2026-08-07: task stop left pid 13556 orphaned and it
# respawned the app.) The real fix is a single-instance lock in warden.py —
# that is shared cross-platform code, so it goes via PR, not from this box.
$stale = @(Get-Process -Name warden -ErrorAction SilentlyContinue)
if ($stale.Count) {
    Write-Host "sweeping $($stale.Count) existing warden process(es) before re-register"
    $stale | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}

Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($logon, $resur) -Settings $settings `
    -User $env:USERNAME -RunLevel Limited | Out-Null
Write-Host "scheduled task '$taskName' registered (at-logon + 30-min resurrection)"

Start-ScheduledTask -TaskName $taskName

# --- honest summary: say what is armed and what is NOT ----------------------
Write-Host ""
Write-Host "--- wt-warden install summary ---"
Write-Host ("  supervisor (Scheduled Task) : REGISTERED + STARTED")
Write-Host ("  WER local crash dumps       : " + $(if ($werArmed) { "ARMED -> $crash" } else { "NOT ARMED (re-run elevated)" }))
Write-Host ("  station token               : " + $(if ($Token) { "SET (uploads/heartbeats on)" } else { "MISSING (uploads/heartbeats OFF)" }))
Write-Host ("  backend                     : $Backend")
Write-Host "Verify:  & '$WardenExe' status"
Write-Host "Once a token is set, CV's /admin/crash-reports should show this"
Write-Host "station's first heartbeat within ~180 s."
