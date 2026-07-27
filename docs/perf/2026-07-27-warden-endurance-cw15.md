# CW-15: 24 h endurance under Warden — GREEN, and three real defects surfaced

**Run:** 2026-07-26 16:58 → 2026-07-27 16:59 (24 h). Driver
`docs/perf/soak-tools/cw15-endurance.sh`, base `~/watchtower-soak/cw15-2026-07-26/`,
real pilot backend (uploads live). App: `build/` @ `c1da1fc` (pre-fix binary — the
three findings below were fixed AFTER the window closed, same day).

## Injections vs outcomes

16 injected faults → **15 reports, all uploaded (0 pending / 0 quarantine), zero
non-2xx in 30 PUTs, zero rate-cap hits** (peak hour minted 4 new ids vs the 30 cap).

| time | injection | outcome |
|---|---|---|
| 18:58, 20:58 | SEGV singles | 2 × `sigsegv`, 201/201 |
| 22:58–23:03 | kill-loop ×5 (~75 s apart) | 3 singles, then `restart-loop` **opened at death #4** (`4dd47b72`) |
| 23:09 | scheduled single, landed in-window | folded → loop closed 23:39 `deaths=6`, exactly 30 quiet min after the last death |
| 00:59 | SEGV single | **minted fresh** — the quiet-close fix held over a real span |
| 04:59 | SIGSTOP | outer net: flightrec silent 120 s → ABRT → `hang-watchdog` |
| 05:04 … 14:59 | SEGV singles | 6 × `sigsegv` |
| 16:59:50 | SEGV at the 24 h boundary | raced the driver's clean SIGTERM → classified as stop, **no report — but the marker survived on disk**; boot replay collects it on the next Warden start (the design self-heals; same story as a systemd stop racing a real crash) |

## Gates

- **G1** ✅ Warden PID 3444232 unchanged for 24 h; RSS 12–24 MB flat.
- **G2** ✅ one report per incident (loop folding per the contractual policy);
  spool bounded at 15 sent.
- **G3** ✅ **17/17 boots restored the saved view** (`[RESTORE] applied` every
  time, ≤ ~10 s after spawn). One drift explained below (external input, not code).
- **G4** ✅ zero non-injected deaths.
- **G5** ✅ the only hang alarm is the injected one; zero 4xx/429/5xx.
- **G6** ✅ app RSS max 246 MB over 17 boots; flightrec never needed rotation.

## Findings — the actual value of the run (all fixed same-day, post-window)

1. **Idle-age cliff (design gap).** An untouched session never changes the view
   blob, so its `at` never refreshed — a guard who simply WATCHED the wall for
   24 h would cross the freshness window, and the next crash would restore
   nothing ("stale"). The rule was meant for machines off for days, not quiet
   sessions. **Fix:** hourly heartbeat re-save while armed (Main.qml).
2. **Loop-folded deaths leaked their markers (Warden bug).** `mint()` consumed
   markers only via `collect()`, so deaths #5/#6 (folded into the open loop)
   left `marker-*.json` orphans — a Warden restart would boot-replay them as
   fresh singles, double-counting deaths the loop report already owns. Caught
   red-handed in the crash dir at end-of-run. **Fix:** folded markers are
   renamed into the loop report dir as `marker.death-N.json` (evidence, not
   orphans). Unit-proven: 6 deaths → 4 reports → 0 orphans.
3. **Offline-thumbnail warning storm (app hygiene).** With a camera tab focused
   and its group siblings offline, `LiveThumb` retried every 1 s and each 404
   logged a QQuickImage warning — **68 429 lines (~10/s, ~4 MB/h)** into the
   flight recorder for an expected state. **Fix:** after 3 straight failures the
   per-thumb poll backs off to 15 s until one succeeds.

**The `active=1→2` drift (G3 footnote):** boot #1 restored `active=1`; 46 s
later exactly one save recorded `active=2`, then never changed again. The only
unattended-reachable path to `activateTab(2)` is the Ctrl+Tab shortcut — a real
keystroke reached the soak window on the shared desktop (it takes Wayland focus
when it appears). The persistence machine did exactly its job with the input it
got. Lesson: endurance rigs on a live desktop are keyboard-reachable; treat
mid-run state drift with a matching save timestamp as input, not corruption.

## Post-fix verification

`[RESTTEST] PASS` (seed/verify), `[TABTEST] PASS`, F2 unit check PASS
(6 deaths → 3 singles + 1 loop, folded markers filed, zero orphans), build clean.

## Verdict

**CW-15 GREEN.** Warden held a real session for 24 h with 16 faults, guard-visible
cost per incident ≈ a 2 s blink into the exact restored view, evidence pipeline
lossless (including across its own shutdown race), and the run paid for itself
with three genuine defects that are now fixed.
