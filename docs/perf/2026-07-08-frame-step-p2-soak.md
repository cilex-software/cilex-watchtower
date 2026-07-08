# P2 frame-step: decoded-frame cache + alternating soak — results

**Date:** 2026-07-08 · **Plan:** `docs/plans/2026-07-08-frame-step-plan.md` §P2 · Precedes: P0 spike + P1 (`docs/perf/2026-07-08-frame-step-spike.md`).

## What P2 added

- **`FrameCache` (C++):** bounded decoded-frame cache — the industry answer (mpv `reverse_queue` / US7190883 LRU) to the P1-measured pathology (seeks into the recently-stepped zone render its head frame; only sequential decode enters it). Captures **only during step operations** (never at play rate): the expensive walk already displays every frame it decodes, so one walk fills the cache for free. JPEG-88 storage (~0.4 MB/frame at 1440p vs 14.7 MB raw), PTS-keyed, caps 96 frames / 56 MB, evicts the end farthest from the stepping locus. Repaint reconstructs a `QVideoFrame` (PTS restamped, so `FrameClock` stays truthful) via `QVideoSink::setVideoFrame`.
- **Cache-first stepping in `FrameStepper`:** backward = cache repaint (instant) → direct PTS seek → anchored overseek + walk (which refills the cache). Forward re-traces cached ground instantly while `diverged`, re-converging exactly at the frame the player is parked on, then resumes real flushes seamlessly.
- **Divergence handling:** cache repaints show frames the player isn't parked on — `diverged` tracks it; the playhead follows the stepper's cursor; **resume-for-play** parks the player ~300 ms behind the shown frame before playing (a seek into the hot zone is unreliable — landing shortly behind is deterministic); every real transport op (scrubber/far seek, ±10 s jumps, speed change, session load) **invalidates** cache + divergence + any in-flight step.
- **Window-edge / disc-boundary fallbacks:** a back-step whose target clamps at the loaded window's start, or whose jump crosses a kept `#EXT-X-DISCONTINUITY`, routes into `seekToWall` (the far/re-open machinery) instead of failing silently.
- **Soak harness:** `WT_STEPTEST=<N>` now alternates 10-forward/12-backward blocks — the net 2-frame backward drift per cycle pushes below the cache bottom so every path (cache, direct, walk-refill, edge) is exercised.

## Results

| Run | Steps | wrongWay | fails | paths | back lat | fwd lat | cache |
|---|---|---|---|---|---|---|---|
| `.106` HEVC 2560×1440 | **200** | **0** | 1 — sanctioned: window-edge at step 154 → `seekToWall` fallback fired correctly, soak continued | cache 150 · flush 46 · walk 3 | **p50 0 ms · p95 0 ms** | p50 100 · p95 199 ms | 18–24 f / 6.7–9.0 MB |
| `.201` H.264 1280×720 | **60** | **0** | **0** | cache 41 · flush 18 · walk 1 | **p50 0 ms · p95 0 ms** | p50 133 · p95 183 ms | 18 f / 3.7 MB |

- **Hot back-step: ~3400 ms (P1) → ~0 ms** — ≥95 % of backward steps are sub-millisecond cache repaints; walk refills (~1.4 s, down from 3.4 s thanks to the anchored overseek + short drift) fire only when stepping below the cached window — 4 walks in 137 back-steps total.
- **Direction correctness: 0 wrong-way steps in 260** across both codecs and all paths (PTS-asserted per step).
- Memory bounded: cache ≤ 9 MB observed (cap 56 MB); process RSS 462–478 MB, normal.
- Qt 6.12 / VA-API / Wayland; both cameras real recorded footage via the live backend.

## Honest notes

- The **first** backward step after plain play→pause still pays a walk fill (~1.4–3 s: frames displayed at play rate are deliberately not captured — GPU-readback+JPEG at 20 fps would jank playback). Every subsequent step in that neighbourhood is instant. Mitigations if it ever matters: capture-on-pause of the last GOP via a second offscreen decoder (heavy), or accepting ~1 low-rate capture/s during playback (cheap, partial) — deferred.
- The plan's "session survives 5 min of paused stepping" acceptance is **pending a manual pass** (the machinery that would recover an expired session — `seekToWall` unseekable-player recovery — is in place and untouched).
- Step UX polish (freeze-frame overlay hiding the walk's visible fast-forward flashes; ms readout) lands in P3.

**Next:** P3 (fractional speeds, Shift+arrows, ms readout, walk-visual polish) → P4 (events hero reuse).
