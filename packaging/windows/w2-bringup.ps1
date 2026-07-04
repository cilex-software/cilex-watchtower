<#
.SYNOPSIS
  W2 runtime bring-up harness for Cilex Watchtower on Windows (docs/plans/windows-port/W2).
  Launches the deployed watchtower.exe against the cilex-vision backend, captures the trace,
  screenshots the window, and reports pass/fail for the automatable W2 checks. The interactive
  gates (watch the wall / scrub playback / export) are in W2-RUNBOOK.md — this covers the parts
  a script can judge: does it launch, does the LIVE wall hardware-decode, is RSS sane, any crash.

.NOTES
  A WIN32 GUI app doesn't write qInfo() to stdout — QT_FORCE_STDERR_LOGGING makes the [WT-*]
  trace reach a redirectable stderr. Run from the unzipped watchtower-portable dir, or pass -Dist.

.EXAMPLE
  pwsh ./w2-bringup.ps1 -Dist C:\wt\watchtower-portable
  pwsh ./w2-bringup.ps1 -Dist C:\wt\watchtower-portable -HwOnly -Seconds 60
#>
param(
    [string]$Dist       = ".",
    [string]$BackendUrl = "http://192.168.1.79:8000",
    [int]$Seconds       = 45,
    [switch]$HwOnly,                       # WT_HW_ONLY=1 — refuse software video decoders (patent/perf gate)
    [string]$OutDir     = "w2-out"
)
$ErrorActionPreference = "Stop"
$exe = Join-Path $Dist "watchtower.exe"
if (-not (Test-Path $exe)) { throw "watchtower.exe not found in '$Dist' — pass -Dist <unzipped portable dir>." }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$trace = Join-Path $OutDir "trace.log"
$shot  = Join-Path $OutDir "render.png"

# --- environment: autologin to the wall, full trace to stderr, screenshot-then-continue ---
$env:WT_CV_URL                     = $BackendUrl
$env:WT_CV_AUTOLOGIN               = "1"
$env:WT_TRACE                      = "1"
$env:QT_FORCE_STDERR_LOGGING       = "1"     # GUI app -> force qInfo/qWarning to stderr
$env:QT_ASSUME_STDERR_HAS_CONSOLE  = "1"
$env:WT_SCREENSHOT                 = (Resolve-Path $OutDir).Path + "\render.png"
$env:WT_SCREENSHOT_MS              = "6000"  # grab ~6 s in, after the wall paints
if ($HwOnly) { $env:WT_HW_ONLY = "1" } else { Remove-Item Env:\WT_HW_ONLY -ErrorAction SilentlyContinue }

Write-Host "== launching $exe (backend $BackendUrl, ${Seconds}s, HwOnly=$($HwOnly.IsPresent)) =="
# WT_SCREENSHOT makes the app quit after the grab; to also capture LIVE decode we relaunch
# without it for the decode window. Two short runs: (1) render proof, (2) decode/RSS capture.
$p1 = Start-Process $exe -PassThru -RedirectStandardError (Join-Path $OutDir "render.stderr.log") -RedirectStandardOutput (Join-Path $OutDir "render.stdout.log")
Start-Sleep -Seconds 12
if (-not $p1.HasExited) { $p1.Kill() }
Copy-Item (Join-Path $OutDir "render.stderr.log") $trace -Force

Remove-Item Env:\WT_SCREENSHOT -ErrorAction SilentlyContinue     # 2nd run: keep running, capture decode
Write-Host "== decode/RSS capture run (${Seconds}s) =="
$p2 = Start-Process $exe -PassThru -RedirectStandardError (Join-Path $OutDir "run.stderr.log") -RedirectStandardOutput (Join-Path $OutDir "run.stdout.log")
Start-Sleep -Seconds $Seconds
if (-not $p2.HasExited) { $p2.Kill() }
Add-Content $trace (Get-Content (Join-Path $OutDir "run.stderr.log") -ErrorAction SilentlyContinue)

# --- analyze ---
$log = Get-Content $trace -ErrorAction SilentlyContinue
function Count($re) { ($log | Select-String -Pattern $re).Count }

$decHw   = Count '\[WT-DEC\].*\(hardware\)'
$decSw   = Count '\[WT-DEC\].*SOFTWARE'
$memN    = Count '\[WT-MEM\]'
$fatal   = Count '\[WT-FATAL\]'
$rss     = ($log | Select-String -Pattern 'rss=(\d+)MB' | ForEach-Object { [int]$_.Matches[0].Groups[1].Value })
$rssMax  = if ($rss) { ($rss | Measure-Object -Maximum).Maximum } else { 0 }
$streams = Count 'live_pipelines=[1-9]'
$rendered = Test-Path $shot

Write-Host ""
Write-Host "================ W2 automated checks ================"
Write-Host ("  [{0}] window rendered (screenshot)        : {1}" -f $(if ($rendered) {"PASS"} else {"FAIL"}), $(if ($rendered) {$shot} else {"no render.png — check render.stderr.log"}))
Write-Host ("  [{0}] launched without crash              : {1}" -f $(if ($fatal -eq 0) {"PASS"} else {"FAIL"}), "[WT-FATAL] count=$fatal")
Write-Host ("  [{0}] LIVE wall hardware-decodes (d3d11)  : {1}" -f $(if ($decHw -gt 0 -and $decSw -eq 0) {"PASS"} elseif ($decHw -gt 0) {"WARN"} else {"FAIL"}), "hardware=$decHw software=$decSw")
Write-Host ("  [{0}] live pipelines built                : {1}" -f $(if ($streams -gt 0) {"PASS"} else {"FAIL"}), "samples with live_pipelines>=1: $streams")
Write-Host ("  [{0}] RSS telemetry present + bounded      : {1}" -f $(if ($memN -gt 0 -and $rssMax -lt 3000) {"PASS"} elseif ($memN -gt 0) {"WARN"} else {"FAIL"}), "[WT-MEM] n=$memN maxRSS=${rssMax}MB")
Write-Host "====================================================="
Write-Host ""
Write-Host "== decoder lines =="; $log | Select-String -Pattern '\[WT-DEC\]' | Select-Object -First 12 | ForEach-Object { Write-Host "   $_" }
Write-Host ""
Write-Host "== ffmpeg encoders available (the libx264/W2 export note) =="
$ff = Join-Path $Dist "ffmpeg.exe"
if (Test-Path $ff) { & $ff -hide_banner -encoders 2>&1 | Select-String '264' | ForEach-Object { Write-Host "   $_" } }
else { Write-Host "   ffmpeg.exe not bundled next to the exe (export compress/burn will fail)" }
Write-Host ""
Write-Host "Full trace: $trace   Screenshot: $shot"
Write-Host "Interactive gates (playback scrub, export STD/HIGH, sleep/resume) -> W2-RUNBOOK.md"
