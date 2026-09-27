# Update the booth's wall to a probed build. Only watchtower.exe changes: warden.py is
# already the current 1.4.10 (hash-identical to the repo), and nothing since 1.1.594
# changed Qt, GStreamer or packaging, so no windeployqt run is needed.
# Documented safe swap order (a running .exe is LOCKED on Windows):
#   1. stop the WATCHDOG first, else it races and starts a SECOND wall
#   2. stop Warden itself -- the process, not just its task
#   3. close the app
#   4. back up the live exe, copy the new one in
#   5. start Warden; it spawns the app
#   6. verify by PARENTAGE, never by process count
#   7. restore the watchdog and the geometry task
# RUN preflight.ps1 FIRST, and run THIS in the background: the Warden it starts inherits
# the caller's output pipe, so a foreground tool call waits until that Warden dies.
# Rollback = the same script with -ExeSrc pointing at the *.rollback copy it made.
# STRICTLY ASCII.
param(
    [string]$ExeSrc = 'C:\dev\cilex-watchtower\build-windows\watchtower.exe',
    [string]$BackupDir = ('C:\wt\backup-' + (Get-Date -Format 'yyyy-MM-dd'))
)
$ErrorActionPreference = 'Continue'
$install = Join-Path $env:LOCALAPPDATA 'Programs\Cilex Watchtower'
$exeDst  = Join-Path $install 'watchtower.exe'
$wpDst   = Join-Path $install 'warden\warden.py'
$exeSrc  = $ExeSrc
$bk      = $BackupDir

if (-not (Test-Path $exeSrc)) { throw "no build at $exeSrc" }
if (-not (Test-Path $bk)) { New-Item -ItemType Directory -Path $bk | Out-Null }

Write-Output "== 1. pause the watchdog"
& schtasks /change /tn "wt-warden-guard" /disable 2>&1 | Select-Object -Last 1
& schtasks /end    /tn "wt-warden-guard" 2>&1 | Select-Object -Last 1
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*wall-watchdog*' } |
  ForEach-Object { Write-Output "   watchdog pid=$($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Output "== 2. stop Warden (excluding this shell -- a CommandLine filter matches its own process)"
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'warden' } |
  ForEach-Object { Write-Output "   warden pid=$($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

Write-Output "== 3. close the app"
Get-Process watchtower -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Output "   app pid=$($_.Id)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

Write-Output "== 4. back up and swap"
$old = (Get-Item $exeDst).VersionInfo.FileVersion
Copy-Item $exeDst (Join-Path $bk "watchtower.exe.$old.rollback") -Force
Copy-Item $exeSrc $exeDst -Force
Write-Output ("   {0} -> {1}  ({2:N0} bytes)" -f $old, (Get-Item $exeDst).VersionInfo.FileVersion, (Get-Item $exeDst).Length)

Write-Output "== 5. start Warden"
# Exactly as C:\wt\wall-watchdog.ps1 starts it (same working dir, same two log files),
# so a Warden started by hand is indistinguishable from one the watchdog started.
$Py = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
$wp = Start-Process -FilePath $Py -ArgumentList @("`"$wpDst`"", 'run') -PassThru -WindowStyle Hidden `
        -WorkingDirectory (Split-Path $wpDst) `
        -RedirectStandardOutput (Join-Path $env:LOCALAPPDATA 'watchtower-warden\warden-stdout.log') `
        -RedirectStandardError  (Join-Path $env:LOCALAPPDATA 'watchtower-warden\warden-stderr.log')
Write-Output "   warden pid=$($wp.Id)"
Start-Sleep -Seconds 15

Write-Output "== 6. verify by PARENTAGE"
$apps = @(Get-CimInstance Win32_Process -Filter "Name='watchtower.exe'")
foreach ($a in $apps) {
  Write-Output ("   app pid={0} parent={1} supervised={2} version={3}" -f $a.ProcessId, $a.ParentProcessId,
    ($a.ParentProcessId -eq $wp.Id), (Get-Item $a.ExecutablePath).VersionInfo.FileVersion)
}
if ($apps.Count -ne 1 -or $apps[0].ParentProcessId -ne $wp.Id) {
  Write-Output "   !!! NOT exactly one supervised wall -- investigate before re-enabling the watchdog"
}

Write-Output "== 7. restore supervision"
& schtasks /change /tn "wt-warden-guard" /enable 2>&1 | Select-Object -Last 1
& schtasks /run    /tn "wt-warden-guard" 2>&1 | Select-Object -Last 1
& schtasks /run    /tn "wt-window-geometry" 2>&1 | Select-Object -Last 1
