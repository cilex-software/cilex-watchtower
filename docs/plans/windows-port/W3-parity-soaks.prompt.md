# Prompt W3 — Parity validation: the Linux soak discipline, on Windows

## Status
OPEN. Depends on W2 (runtime green on the GPU box). Mostly unattended machine time
(~1 week elapsed). **Qt 6.12 msvc2022_64 MANDATORY.**

## Context
All the QA drivers are env-gated QML — they run on Windows unmodified:
`WT_NIGHT_SOAK` (+`WT_SOAK_FIX_CAM/DAY`, `WT_GRAB_STORM`), `WT_SEEK_SPAM`, `WT_GUARD_SOAK`,
`WT_CAL_STRESS`, `WT_SMOOTHTEST`, `WT_HLS_SLOW_MS`/`WT_HLS_SLOW_EVERY`. What does NOT
port: the bash supervisors (`docs/perf/soak-tools/*.sh`) and the fifo-gdb wedge catcher —
Linux/ptrace-specific. Windows equivalents:
- **Supervisor → PowerShell** (`docs/perf/soak-tools/night_soak_supervisor.ps1`): same
  design — launch app, poll `[NTIME]`/`[WT-MEM]` heartbeat count in the log every 15 s,
  stall ≥150 s while process alive ⇒ wedge; record incident block; relaunch. Keep the
  export-sidecar **mtime guard** (never touch files older than supervisor start — the
  `fa07dee` invariant) when stat+deleting soak exports.
- **Stack capture → procdump** (Sysinternals): on wedge, `procdump -ma <pid>` BEFORE the
  kill (the Windows analog of the gdb thread-apply-all-bt that cracked HANG #1); analyze
  dumps with WinDbg `!analyze` / `~*k` offline. Ship `procdump.exe` alongside the soak
  tools or document the download (license: Sysinternals EULA — do not commit the binary).

## Task
1. Port the night-soak supervisor to PowerShell (above); smoke it with a 30 min run.
2. **Overnight soak on Win10 AND Win11** (one night each, GPU box): the standard
   `WT_NIGHT_SOAK` flow. Pass bar = the Linux bar: 0 crashes, 0 wedges (heartbeat gap
   >150 s), RSS bounded (plateau, no ratchet), exports correct per policy, 0 `[SEEKBAR]`
   violations.
3. **GC-fix parity check** (the 2026-07-03 HANG #1 class): during a heavy-day churn slice,
   confirm `marshal=` stays ~1 ms and the `WT_SMOOTHTEST` heartbeat never gaps >2 s. The
   fix is source-level and should hold; this proves it on the 6.12 Windows QML engine.
4. **Click-spam parity** (`WT_SEEK_SPAM=1`, healthy backend): after-burst recovery in the
   same band as Linux (p90 <1 s, no 15 s timeouts, coalesce lines present).
5. Results → `docs/perf/2026-…-windows-soak-results.md` (house format: totals, RSS
   envelope, findings ranked, artifacts kept OUTSIDE any temp dir that a reboot clears).

## Verify
Both overnight soaks green + the two parity checks green, documented. Any wedge caught
MUST have a procdump — a hang without a dump is a failed capture, rerun.

## Gotchas
- PowerShell `Get-Content -Wait` for tailing; `Select-String -Quiet` for the heartbeat
  count; avoid the bash `pgrep -f` self-match class of bugs — track PIDs explicitly.
- Windows Defender may tax the export-sidecar's rapid file stat/delete loop — if soak
  export timing skews, add an exclusion for the soak dir (document it).
- Screen/power settings: disable sleep + display-off for the soak nights (or test BOTH
  configurations deliberately — display-off is a real operator condition).
- Auto-commit + push (docs + the .ps1 tooling) when verified.
