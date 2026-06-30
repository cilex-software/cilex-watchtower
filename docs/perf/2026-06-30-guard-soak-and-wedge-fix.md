# Extended Live-screen guard soak (#1) + the playback-wall GUI-wedge fix

## Soak #1 — 2026-06-30 01:31 → 12:00 (10.5 h, guard-usage emulation via WT_GUARD_SOAK)
**Result: no crash, no OOM, no leak — but a critical GUI wedge that invalidated most of the run.**

- **0 crashes / 0 kills**, `MEMGUARD=0` (RSS-shed valve never needed), `G_IS_OBJECT=0`.
- **RSS flat ~450 MB** (mean 452 ± 21, max 485), trend **+2.2 MB/h ≈ noise** → leak fixes hold.
- **GUI WEDGED at ~22 min** on the **playback-wall → Live** transition: all GUI timers stopped (MEMTEL +
  `[GUARD]` froze), `livePipes=0` (live wall never rebuilt), but the **process stayed alive** (RSS pinned
  456 MB, CPU 2–7 %). The supervisor's process-liveness check couldn't see it → no relaunch → 9.6 h frozen.
- Real per-action data (the one cycle before the freeze): playback-wall heaviest (RSS 468, max **485 MB**,
  the composited mosaic); Live CPU peak **115 %** (9 VA-API decodes); events-triage lightest (298 MB).
- The setup also caught + fixed a **snapshot-401** bug (cached snapshot_url needs auth; raw QML Images sent no
  cookie → blank tiles) by routing snapshots through the auth'd cvframe provider.

## Root cause of the wedge — a GUI-thread deadlock
The `HlsProxy` (local 127.0.0.1 HLS proxy the mosaic player streams through) ran on the **GUI thread**, with a
GUI-thread `QNetworkAccessManager`. On the wall↔Live transition:
1. `player.stop()` runs on the GUI thread and blocks, joining the QtMultimedia demuxer thread.
2. The demuxer is blocked reading a mosaic segment from the proxy.
3. The proxy can't serve it — it's on the GUI thread, which is stuck in `stop()`.
→ deadlock. (The corrupt mosaic stream — "Packet corrupt" — makes a read more likely to be in flight.) It can
hit on wall **enter or exit**; both touch the mosaic player + the GUI-thread proxy.

## Fix — move the proxy off the GUI thread
- `HlsProxy` creates its `QTcpServer` + its **own** `QNetworkAccessManager` in an `init()` slot that runs on a
  dedicated `QThread` (`PlaybackClient` does `moveToThread` + a `BlockingQueuedConnection` `init`). The proxy
  now serves the player's segment reads independently of the GUI thread → `player.stop()` can't deadlock.
- Cross-thread auth: `AuthController::token()` getter → pushed to the proxy-thread NAM via a queued
  `setAuthToken` (on login + re-login). No cross-thread cookie-jar sharing. Port read via a `std::atomic`.
- `~PlaybackClient` quits + joins the proxy thread.

**Verified (WT_GUARD_SOAK, 4 s Live dwell, 9 min):** wall→Live cleared **twice** without wedging; MEMTEL
**19 ticks** (baseline froze at 8); `[GUARD]` **18 steps**; mosaic plays with **0 auth/mosaic errors**; live
pipelines rebuilt. Both Qt builds clean.

## Supervisor v2 — hang-aware
The v1 supervisor only checked process liveness, so it missed the wedge. v2 watches the MEMTEL/`[GUARD]`
heartbeat: if it stalls ≥120 s while the process is alive ⇒ GUI wedge → record the cause + the `[GUARD]`
actions that led to it, then kill + relaunch. So a re-run genuinely "re-opens and continues" through any hang.

## Re-run
Launched with the fix + supervisor v2 (`docs/perf/soak-tools/`). Watch the RSS trend across repeated wall
opens — soak #1 only opened the wall once (then wedged), so the re-run is the first real test of many
wall enter/exit cycles.
