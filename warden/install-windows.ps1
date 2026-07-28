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
        "APP_ENV=WT_CV_AUTOLOGIN=1"
    ) | Set-Content -Path $conf -Encoding UTF8
    Write-Host "config written: $conf"
    if (-not $Token) { Write-Warning "STATION_TOKEN is EMPTY - uploads/heartbeats stay off until it is set." }
} else {
    Write-Host "config exists, untouched: $conf"
}

# --- 2. WER LocalDumps (crash dir must match FlightRecorder's) ---------------
$crash = Join-Path $env:APPDATA "Cilex Vision\Watchtower\crash"
New-Item -ItemType Directory -Force -Path $crash | Out-Null
$wer = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\watchtower.exe"
New-Item -Path $wer -Force | Out-Null
Set-ItemProperty -Path $wer -Name DumpFolder -Value $crash -Type ExpandString
Set-ItemProperty -Path $wer -Name DumpType   -Value 1 -Type DWord   # minidump
Set-ItemProperty -Path $wer -Name DumpCount  -Value 5 -Type DWord
Write-Host "WER LocalDumps armed -> $crash"

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
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($logon, $resur) -Settings $settings `
    -User $env:USERNAME -RunLevel Limited | Out-Null
Write-Host "scheduled task '$taskName' registered (at-logon + 30-min resurrection)"

Start-ScheduledTask -TaskName $taskName
Write-Host "started. Verify:  & '$WardenExe' status   (and CV's /admin/crash-reports"
Write-Host "should show this station's first heartbeat within ~180 s once a token is set)"
