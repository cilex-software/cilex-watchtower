# P0 #1 — Live-wall OOM: localize & fix the GStreamer live-pipeline leak

## Context (what crashed, what's established)
On 2026-06-29 the operator client OOM-crashed on the **Live wall**. Crash-log signature:
```
[MEMTEL] up=29s rss=2302MB playSec=0 opens=0 active=0
[MEMTEL] up=59s rss=6789MB playSec=0 opens=0 active=0
GLib-GObject-CRITICAL: g_object_unref: assertion 'G_IS_OBJECT (object)' failed
[MEMTEL] up=89s rss=8229MB playSec=0 opens=0 active=0
[WT-FATAL] killed by signal 15 (Terminated); RSS=8605 MB   (= OOM/earlyoom)
```
Established:
- **Not the playback path.** `playSec=0, opens=0` throughout → the QtMultimedia/FFmpeg hero/wall MediaPlayer
  (whose per-open growth was already fixed and proven to plateau) is idle. The growth is the **Live wall's
  GStreamer decode pipelines** (`RtspVideoSource`), which `[MEMTEL]` now also tracks via `livePipes`.
- **Not a regression from the recent memory work** — the live path (`RtspVideoSource`/`CameraTile`/
  `LiveMonitor`/`VideoSurface`) was untouched; only `main.cpp` got the process-wide `mallopt`/telemetry.
  (Re-confirm, but treat as pre-existing.)
- The wall runs up to `maxLiveDecodes` (default **9**, env `WT_MAX_DECODES`) live VA-API decodes of go2rtc
  **sub** streams (`rtspSubUrl`); tiles beyond the cap show polled `LiveThumb` snapshots (no pipeline). 9
  decodes ≈ the ~2.3 GB at 29 s; the climb to 8.6 GB over ~60 s is the leak.
- The `GLib-GObject-CRITICAL: g_object_unref … G_IS_OBJECT failed` is the prime lead: a **failed unref during
  pipeline teardown → that pipeline's graph is never reclaimed.** Under go2rtc instability (stalls/drops/503s
  → the `VideoSurface` stall-watchdog forces `reconnect()` → rebuild), repeated churn accumulates leaked
  pipelines → unbounded RSS → earlyoom.
- The reconnect *rate* is already bounded: per-tile backoff `_backoffMs=[2,5,10,20,30]s` + a
  ReconnectCoordinator (fleet stagger) + a teardown worker-thread semaphore `kMaxConcurrentTeardowns=8`. So
  the leak is **per-teardown**, not a rate storm.
- `RtspVideoSource` already keeps P0-trace counters `livePipelineCount()`/`totalFramesDelivered()`
  (`g_livePipelines`/`g_totalFrames`), surfaced in `[MEMTEL]` as `livePipes`/`frames`.

## ⚠ Safety (the box is OOM-sensitive — do NOT re-OOM it)
16 GB host **shared with the cilex-vision backend** (which OOM-loops). earlyoom (`-m 10,5`) SIGTERMs the
largest unprotected victim at MemAvailable < ~1.6 GB; Watchtower is a candidate. Therefore:
- **Never run the full cap-9 wall unbounded.** Test at `WT_MAX_DECODES=2` or `3`, short, watched.
- Watch RSS live (`[MEMTEL]` 30 s, or `/tmp/sampler.py <pid> <csv> <sec>`) and **hard-kill if RSS approaches
  ~5–6 GB** — well below the OOM line, leaving the backend headroom.
- Use the controlled churn repro below (low cap). **Do not** restart/pause go2rtc to induce instability — it
  hits the backend and other consumers.

## Goal
Under sustained reconnect/teardown churn, **RSS plateaus and `livePipes` stays ≤ `maxLiveDecodes`** (no
ratchet), with **zero `GLib-GObject-CRITICAL` on teardown**. Prove it with a bounded soak + before/after.

## Plan
1. **Controlled, safe reproducer (deterministic churn).** The crash's churn was go2rtc-driven, but the
   *mechanism* (per-teardown leak) reproduces via teardown↔rebuild churn. Add a `WT_WALL_CHURN` test driver
   (mirror the `WT_HERO_OPENONLY` harness pattern in `EvTriage.qml`) in `LiveMonitor.qml`/`CameraTile.qml`
   that, while set, repeatedly forces the visible tiles' pipelines to tear down + rebuild — call the live
   item's `reconnect()` (the exact crash path) on a timer — logging `livePipes` each cycle. Run at
   `WT_MAX_DECODES=2–3`. If each teardown leaks, `livePipes` ratchets past the cap and RSS climbs — the crash
   mechanism, bounded + safe. **Baseline first:** low cap, no churn → confirm `livePipes` = cap and RSS flat.
2. **Localize the leaked allocation.** Run the reproducer under the LD_PRELOAD malloc-site tracer
   (`docs/perf/leak-tools/malloctrace.cpp` — cracked the playback leak; dumps live ≥N-byte allocs by
   backtrace + `mallinfo2` on SIGUSR1). The `G_IS_OBJECT` CRITICAL points to CPU-side GStreamer/GObject (not
   GPU dmabuf); force software decode (`LIBVA_DRIVER_NAME=bogus`) if VA-API confounds the tracer. Identify
   the leaking site (expect `gst_*` / the teardown path / a `RtspVideoSource` lambda capture).
3. **Pin the `g_object_unref` failure.** `RtspVideoSource::teardown()` (~`src/models/RtspVideoSource.cpp:225–
   267`) hands the pipeline to a detached worker (`set_state(NULL)` + `gst_object_unref`), unrefs the bus +
   sink, clears appsink callbacks. The `G_IS_OBJECT` assertion = unref on an already-freed/invalid object — a
   double-unref or a race among the worker thread, the bus watch (`onBus`), the appsink callback, and
   `reconnect()`/`~RtspVideoSource`. Find which object is over-unref'd or used-after-free (likely the bus, the
   sink element, or the pipeline when teardown races a rebuild). A failed unref leaves a dangling ref → the
   graph never frees → the leak.
4. **Fix** so every pipeline (+ its bus/elements/appsink) is released **exactly once**, even under
   teardown↔rebuild↔destruct races. Candidate directions (choose by evidence): guard against double-teardown;
   remove the bus watch + detach the appsink *before* the worker unref; serialize teardown-vs-rebuild per
   source; review the worker-thread lambda captures / ownership (`QPointer`). Keep the existing
   semaphore/backoff/coordinator intact.
5. **Verify** (bounded, safe): re-run `WT_WALL_CHURN` at low cap for a sustained period → `livePipes` ≤ cap
   (no ratchet), RSS plateaus, zero `GLib-GObject-CRITICAL`. Then one guarded higher-cap confirmation if safe
   (watched, killed before ~5–6 GB). Record before/after RSS slope + `livePipes` trend.

## Deliverables
- The fix (commit); both Qt builds clean (`build68` + system `build`); `WT_WALL_CHURN` repro committed (gated,
  inert by default).
- A deep-dive doc under `docs/perf/` (cause / the unref race / before-after `livePipes`+RSS), in the style of
  the playback-leak deep-dive.
- Update the session-recovery memory with the result; auto-commit + push per the working agreement.
- **Honest fallback:** if the root teardown fix is large/risky, ship the safe interim — e.g. a conservative
  default `maxLiveDecodes` gated on go2rtc health, or a process/subsystem reset at an RSS threshold using the
  `livePipes` signal — and document the remaining work plainly.

## Files / tools
- `src/models/RtspVideoSource.{cpp,h}` — teardown ~225–267, `reconnect()` ~190, build ~340–400, `onBus` ~520.
- `qml/VideoSurface.qml` (stall watchdog + `_backoffMs` reconnect), `qml/CameraTile.qml`
  (`liveDecodeAllowed`/`snapshotMode`/cap), `qml/LiveMonitor.qml` (`maxLiveDecodes`, tile lifecycle).
- `docs/perf/leak-tools/malloctrace.cpp` (LD_PRELOAD tracer), `/tmp/sampler.py` (RSS), `[MEMTEL]`
  (`livePipes`/`frames`), `WT_MAX_DECODES`.
- **Acceptance:** live wall under sustained churn → RSS plateaus, `livePipes` ≤ cap, no GObject-CRITICAL, no
  OOM; both builds clean.
