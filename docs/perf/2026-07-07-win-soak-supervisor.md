# W3 night-soak supervisor — ported to PowerShell + validated (2026-07-07)

W3 (parity soaks) step 1: the Linux soak discipline, on Windows. The QA drivers are all
env-gated QML and run unchanged (`WT_NIGHT_SOAK`, `WT_SEEK_SPAM`, `WT_GUARD_SOAK`,
`WT_SMOOTHTEST`, `WT_CAL_STRESS`, `WT_HLS_SLOW_*`). What does **not** port is the bash
supervisor + the fifo-gdb wedge catcher (ptrace-specific). Ported to
`docs/perf/soak-tools/night_soak_supervisor.ps1`.

## Design (kept identical to `night_soak_supervisor.sh`)

Launch app → poll the app log every 15 s for the `[NTIME]`/`[WT-MEM]` heartbeat → if the count
does not advance for **≥150 s while the process is alive** it is a GUI wedge → record an incident
block (cause, last actions, last `[WT-MEM]`, host mem, dump path) → kill → relaunch, until the end
time. A sidecar sizes + deletes soak exports so disk doesn't fill, guarded by an **mtime rule**:
it never touches a clip whose `LastWriteTime` predates supervisor start (the `fa07dee` invariant —
never delete the operator's own exports).

## Windows-specific changes

| Linux | Windows |
|---|---|
| `qInfo()` to stdout on a console app | **`QT_FORCE_STDERR_LOGGING=1`** — a WIN32 GUI app writes nothing to stdout; route `[WT-*]`/`[NTIME]` to a redirected stderr (per-run `app_run<N>.log`) |
| `gdb -p <pid> -batch -ex 'thread apply all bt'` on a live wedge | **`procdump -accepteula -ma <pid> <dump>`** BEFORE the kill; analyze offline in WinDbg (`!analyze -v`, `~*k`) |
| Wayland/`DISPLAY`/`LD_LIBRARY_PATH`/`MALLOC_ARENA_MAX`/`WT_PTRACE_ANY` | dropped (not applicable) |
| `pgrep -f` / `kill -0` | explicit PID from `Start-Process -PassThru`; `$app.HasExited`; stray sweep by name excluding the tracked pid |
| `python3 guard_sampler.py` | native `Get-Process` sample (`WorkingSet64`, `TotalProcessorTime`) → `samples.csv` |
| `$HOME/watchtower-soak` | `%USERPROFILE%\watchtower-soak` (durable — **NOT `%TEMP%`**, which a reboot clears: the 2026-07-03 night lost the first HANG #1 record that way) |

The script is **ASCII-only** so it parses under both Windows PowerShell 5.1 and pwsh (same lesson
as the w2-bringup harness).

`procdump.exe` is under the Sysinternals EULA — **not committed**; the supervisor auto-detects it
(`C:\wt\procdump\` or PATH) or takes `-ProcDump <path>`. Download:
`https://download.sysinternals.com/files/Procdump.zip`.

## Validation (this box: Win10 19045, GTX 1070, over Tailscale)

- **2-min mechanics smoke** (`-DurationMinutes 2 -HangSeconds 45`): clean end-time stop, `crashes=0
  hangs=0`, **72 heartbeats detected** with no false wedge — confirms `Select-String` reads the
  live `Start-Process`-redirected log (the key porting risk). `samples=12` (RSS 211→538 MB as it
  loaded). **`exports_sized=2`** — the night-soak driver made exports and the sidecar sized +
  deleted them under the mtime guard.
- **procdump capture**: the exact supervisor command wrote a **1.1 GB full dump** of the live
  process. (Budget disk: a `-ma` dump of the running client is ~1 GB each; wedges should be rare.)
- **30-min smoke** against the CI-built dist (`-DurationMinutes 30`): clean end-time stop, **1
  launch, 0 crashes, 0 hangs**, single pid throughout; 120 samples, RSS bounded 275-800 MB (ended
  631, no ratchet); HW decode held (0 software). The export matrix ran end-to-end through the app:
  **STD exports OK** (~12-14 s/clip), while HIGH exports on aged footage were correctly refused by
  the app's own "main-stream aged to standard storage" policy (expected, not a defect). Compress/
  burn (the libopenh264 path) was NOT exercised by the soak matrix -- still to validate through the UI.

## How to run the overnight soaks (remaining W3 work — unattended)

```powershell
# Win10 and Win11, one night each, on the GPU box:
powershell -File docs\perf\soak-tools\night_soak_supervisor.ps1 -Dist C:\wt\portable-ci -EndTime 07:00
```
Prereqs / gotchas:
- Disable sleep + display-off for the soak night (or deliberately test display-off — a real
  operator condition).
- If export sidecar timing skews, add a Defender exclusion for the export dir (document it).
- A wedge without a procdump is a **failed capture** — rerun.

Pass bar = the Linux bar: 0 crashes, 0 wedges (>150 s heartbeat gap), RSS bounded (plateau, no
ratchet), exports correct per policy, 0 `[SEEKBAR]` violations. Plus the two parity checks:
GC-fix (`marshal≈1 ms`, `WT_SMOOTHTEST` heartbeat never gaps >2 s) and click-spam
(`WT_SEEK_SPAM=1`, p90 <1 s recovery, coalesce lines present). Results →
`docs/perf/2026-…-windows-soak-results.md`.
