# watch-wall.ps1 - after a swap: is the NEW app up, supervised, and STAYING up?
# Prints one line whenever the wall's (pid, version, parent) changes, and every Warden
# log line that means a death or restart. Exits "STABLE" once the same pid has lived
# $StableSecs, or "CRASHLOOP" on the second restart line, or "TIMEOUT".
# STRICTLY ASCII.
param([int]$StableSecs = 90, [int]$MaxSecs = 300)
$log = Join-Path $env:LOCALAPPDATA 'watchtower-warden\warden-stdout.log'
$start = Get-Date
$seenLines = 0
$last = ''
$sincePid = $null
$restarts = 0
while (((Get-Date) - $start).TotalSeconds -lt $MaxSecs) {
    $apps = @(Get-CimInstance Win32_Process -Filter "Name='watchtower.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.ExecutablePath -notlike 'C:\wt\*' })
    $state = ($apps | ForEach-Object {
        $v = try { (Get-Item $_.ExecutablePath).VersionInfo.FileVersion } catch { '?' }
        "pid=$($_.ProcessId) v=$v parent=$($_.ParentProcessId)" }) -join ' | '
    if (-not $state) { $state = 'NO APP RUNNING' }
    if ($state -ne $last) {
        "{0}  wall: {1}" -f (Get-Date -Format 'HH:mm:ss'), $state
        $last = $state
        $sincePid = if ($apps.Count -eq 1) { Get-Date } else { $null }
    }
    if (Test-Path $log) {
        $lines = @(Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($lines.Count -lt $seenLines) { $seenLines = 0 }     # log was recreated by a new Warden
        for ($i = $seenLines; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'restart in|exception-|restart-loop|spawned|first beat') {
                "{0}  warden: {1}" -f (Get-Date -Format 'HH:mm:ss'), ($lines[$i] -replace '^\[warden\]\s*', '')
                if ($lines[$i] -match 'restart in') { $restarts++ }
            }
        }
        $seenLines = $lines.Count
    }
    if ($restarts -ge 2) { "CRASHLOOP: $restarts restarts since the swap"; exit 1 }
    if ($sincePid -and ((Get-Date) - $sincePid).TotalSeconds -ge $StableSecs) { "STABLE: $last for $StableSecs s"; exit 0 }
    Start-Sleep -Seconds 3
}
"TIMEOUT after $MaxSecs s: $last"; exit 2
