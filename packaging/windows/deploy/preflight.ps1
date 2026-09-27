# preflight.ps1 - may THIS build go near the guard's wall? Run BEFORE any swap.
#
# Replaces probe-sac.ps1, which on 2026-09-28 said "ALLOWED (running after 6 s)" for a
# 1.1.671 that crash-looped the wall: it asked for the offscreen platform, which this
# install does not ship, so the probe sat on a Qt error dialog (on the guard's screen)
# and "still running" meant "stuck", not "healthy". This one:
#   1. hardlinks the fresh exe into C:\wt\pb2 (full runtime; qoffscreen.dll added there,
#      in the STAGING copy only, never the live install);
#   2. runs it HEADLESS under C:\wt\dbg\catch_abort.py for 40 s: SAC refusal shows as a
#      CreateProcess failure, a crash as a second-chance exception with a symbolised stack;
#   3. restores HKCU cilex:// to the live install (the app re-registers it at start, so
#      a staging run would otherwise leave guard links opening the staging exe).
# PASS only if the build is still alive at 40 s with no second-chance exception.
# STRICTLY ASCII.
param([string]$Fresh = 'C:\dev\cilex-watchtower\build-windows\watchtower.exe', [int]$Seconds = 40)
$dst = 'C:\wt\pb2\watchtower.exe'
$key = 'HKCU:\Software\Classes\cilex\shell\open\command'
$live = '"' + (Join-Path $env:LOCALAPPDATA 'Programs\Cilex Watchtower\watchtower.exe') + '" "%1"'
if (-not (Test-Path $Fresh)) { "NO BUILD at $Fresh"; exit 2 }
if (-not (Test-Path 'C:\wt\pb2\platforms\qoffscreen.dll')) { "pb2 lacks qoffscreen.dll -- would show a Qt dialog; aborting"; exit 2 }
"fresh: {0}  sha256 {1}" -f (Get-Item $Fresh).VersionInfo.FileVersion, (Get-FileHash $Fresh).Hash.Substring(0, 16)
Remove-Item $dst -Force -ErrorAction SilentlyContinue
New-Item -ItemType HardLink -Path $dst -Target $Fresh | Out-Null
$out = & python (Join-Path $PSScriptRoot 'catch_abort.py') offscreen $Seconds 2>&1 | ForEach-Object { "$_" }
Set-ItemProperty -Path $key -Name '(default)' -Value $live
$alive  = [bool]($out | Where-Object { $_ -like 'TIMEOUT: still alive*' })
$second = @($out | Where-Object { $_ -match '^== (EXCEPTION|C\+\+ exception).*SECOND chance' })
$cpfail = @($out | Where-Object { $_ -like 'CreateProcess failed*' })
$out | Where-Object { $_ -match '^\[ODS' -and $_ -match 'watchtower start|\[STREAMS\]|\[WALL\]|FATAL|fatal' } | Select-Object -First 8
if ($second.Count) { $out | Select-Object -Last 30 }
"cilex:// restored to: " + (Get-ItemProperty -Path $key).'(default)'
if ($cpfail.Count) { "VERDICT: BLOCKED at CreateProcess: $($cpfail[0])"; exit 1 }
if ($alive -and -not $second.Count) { "VERDICT: PASS -- alive after $Seconds s, no second-chance exception"; exit 0 }
"VERDICT: FAIL -- died or faulted (see above)"; exit 1
