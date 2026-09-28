# start-labs.ps1 - start Labs on THIS computer the safe way: the wall guard first, and the
# guard starts the Labs worker (and restarts it if it dies, at most 3 times an hour).
# Hidden; files only (C:\wt-labs\guard\). Nothing appears on screen (operator rule: Labs is
# never shown to anyone who is not an admin). Safe to run twice: a second guard is refused.
# STRICTLY ASCII: the profile path is Cyrillic, so it comes from the environment.
$py = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
$ff = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.2-full_build\bin'
$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
             Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*guard3.ps1*' })
if ($running.Count) { "The wall guard is already running here (pid $($running[0].ProcessId)). Nothing to do."; exit 0 }
foreach ($need in $py, $ff, 'C:\wt-labs\guard3.ps1', 'C:\wt-labs\run_worker.py') {
    if (-not (Test-Path -LiteralPath $need)) { "MISSING: $need -- not starting."; exit 1 }
}
$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\wt-labs\guard3.ps1',
       '-BaseRate', '12.3', '-BasePipes', '1', '-Labs', 'C:\wt-labs', '-Python', "`"$py`"",
       '-GuardDir', 'C:\wt-labs\guard', '-StartWorker', '-FfmpegDir', "`"$ff`"")
$p = Start-Process powershell.exe -ArgumentList $a -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 5
if ($p.HasExited) { "The guard stopped at once -- see C:\wt-labs\guard\guard-local.log" }
else { "Wall guard started (pid $($p.Id)). It starts the Labs worker whenever none is running." }
