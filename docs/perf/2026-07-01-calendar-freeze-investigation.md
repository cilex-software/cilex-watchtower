# Playback calendar: "awfully slow" + ".201 click a past day → stops responding" — investigation (2026-07-01)

Context: operator unplugged all cameras but **.201** (an unlikely "many cameras suddenly
unplugged" edge case) and reported two issues on the **Playback** screen:
1. the footage **calendar is awfully slow**, and **playing historic records is awfully slow**;
2. on **.201**, clicking a **non-today** day on the calendar makes the app **stop responding**.

This documents the root-cause investigation. Reproduced, measured, and characterised both.

## TL;DR
- **"Stops responding" = a bounded GUI-thread stall while tearing down the *currently playing*
  playback session on a calendar day-switch.** Measured **~300 ms on a healthy backend, up to
  ~1 s when the backend is degraded** (segments starved). It is **bounded** (GStreamer/souphttpsrc
  cap it ≈1 s) — **not an unbounded hang** — and it recovers on its own.
- **It is NOT fixable from our side by teardown ordering or proxy-socket tricks** — both were
  implemented and measured **ineffective** (data below). The stall is internal to the QtMultimedia
  **GStreamer** backend's pipeline NULL-state transition.
- **"Awfully slow" = the backend itself is slow** under the unplugged-cameras condition. Measured
  live: **login 7.8 s, `/streams` 3.0 s** (session/coverage calls were fast, ~0.05–0.2 s). Historic
  playback is gated by how fast the backend serves segments; the client can't speed that up.
- `.201` records almost nothing — only **2 of the last 35 days have footage** (2026-06-24: 19.7 s;
  today: 151.5 s). Clicking any of the ~33 empty days is a valid "No footage" state; clicking while
  a session is playing triggers the teardown stall.

## How it was reproduced & measured
Added a dev harness + instrumentation (kept, behind env flags — consistent with the existing
`WT_*` test hooks):
- **`WT_CAL_STRESS`** (`qml/Main.qml`) — drives the calendar the way an operator does: rotates the
  roster, opens a day (plays if there's footage), scrubs it, then clicks the next day, sweeping the
  retention window. Emits `[CAL] …` action lines.
- **`[PBSTOP]`** (`qml/PlaybackScreen._teardownPlayer`, under `WT_TRACE`) — times the synchronous
  `player.stop(); player.source=""` teardown and whether a session was playing.
- **`WT_HLS_SLOW_MS=<ms>`** (`HlsProxy`) — TEST-ONLY degraded-backend emulator: holds every segment
  response that long (and bypasses the read-ahead cache) so the starvation is deterministic.
- `WT_SMOOTHTEST`'s 1 s heartbeat doubles as a **GUI-freeze detector**: a gap between heartbeats ==
  the GUI thread was blocked that long.

**Key measurement — teardown stall vs. session state and backend latency** (`[PBSTOP] took=`):

| backend | session playing? | `player.stop()` blocks |
|---|---|---|
| healthy (real) | no  | **0–1 ms** |
| healthy (real) | yes | **~300 ms** |
| degraded (`WT_HLS_SLOW_MS=20000`) | yes | **~1000 ms** (capped by GStreamer/souphttpsrc) |

The stall appears **only when a session is actively playing** at click time, and **caps ~1 s** even
under extreme (20 s/segment) starvation — souphttpsrc/GStreamer time out the streaming-thread join.
Heartbeat gaps under starvation topped out ~2–3 s (the 1 s stop + surrounding jank), never unbounded.

## What was tried to fix the stall — and why it was reverted
The stall is `player.stop()` joining the GStreamer streaming thread. Three angles were implemented
and measured; **all ineffective**, so all were reverted (kept the codebase honest):
1. **Proxy `abortInflight` (sever the dead session's in-flight reads before stop()).** The proxy runs
   on its own thread, so it can act while the GUI is in `stop()`. Result: only *sometimes* helped —
   `s->abort()` (RST) makes souphttpsrc treat it as a retriable error and **back off ~1 s before
   retrying**; the streaming thread the join waits on sleeps that backoff.
2. **Drain-by-session-id + a clean 503 (not RST) + `BlockingQueuedConnection` ordering.** Still
   ~1000 ms — completing/closing the socket does **not** reduce the pipeline NULL-transition cost.
3. **Teardown-order sweep** (`stop`, `source`-only, `stop`-only, `pause`+clear, clear+`stop`): **all
   ~1000 ms** under starvation. Confirms the cost is internal to the GStreamer teardown, not our
   call order.

Conclusion: there is **no clean client-side fix** for the teardown stall on the Qt 6.4 GStreamer
media backend. It is bounded and recovers; under a healthy backend it's a ~300 ms hitch.

## Mitigation options (decision pending)
- **A — accept it.** It's a bounded, self-recovering ~300 ms–1 s hitch that only bites in the
  degraded-backend edge case the operator deliberately created; do nothing client-side.
- **B — perceived-responsiveness mitigation.** Update the calendar/loading UI state *before* the
  blocking teardown (defer `stop()` one event-loop tick) so the click is acknowledged instantly,
  then the ~1 s hitch happens behind the already-updated screen. Doesn't remove the block, improves
  feel; small re-entrancy risk to handle.
- **C — backend letter.** The dominant "awfully slow" is backend latency under load (login 7.8 s
  measured). File a `docs/letters/` note so the backend degraded-mode behaviour is on record.

## Overnight validation
An extended calendar + historic-playback **soak** runs tonight against the **real degraded backend**
(cameras unplugged = the reported condition), rotating the roster, sweeping days, scrubbing footage,
under crash/hang supervision — to confirm the stall stays **bounded** (no unbounded hang), quantify
the teardown hitch and time-to-first-frame (mean/stdev), and catch any crash. Results:
`docs/perf/2026-07-01-calendar-soak-results.md` (pending).

## Tooling
`docs/perf/soak-tools/` — `guard_cal_supervisor.sh` (build/, system Qt 6.4.2, hang-aware),
`guard_sampler.py`, and the analyzer. Harness/instrumentation: `WT_CAL_STRESS` (Main.qml),
`[PBSTOP]`/`WT_TRACE` (PlaybackScreen.qml), `WT_HLS_SLOW_MS` (HlsProxy.cpp).
