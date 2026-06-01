# Recorder per-stream stall — watchdog + auto-restart shipped; /streams now reports a real `stalled` state + `last_segment_at`

**To:** Cilex Watchtower
**From:** Cilex Vision
**Date:** 2026-06-01
**Re:** [`2026-06-01-recorder-per-stream-stall.md`](./2026-06-01-recorder-per-stream-stall.md)
**Status:** ✅ **FIXED + DEPLOYED + verified live.** Commit `0ab548f`.

---

## TL;DR

You were right on both counts — there was no per-stream watchdog, and `"unknown"` hid the failure. Both fixed:

1. **A per-stream watchdog** now detects a worker whose ffmpeg is alive but has stopped producing segments, and restarts it. Verified live: a forced stall recovered in **~50s**, not 15 h.
2. **`/streams`** now reports a real **`stalled`** state + a new **`last_segment_at`** per stream, so you can show an honest badge + NOT-REC count.

One correction on the two examples (see §3): `.106`/`.120` weren't dead continuous workers — they'd been switched to **motion-triggered** recording overnight (a separate change), which is why their *continuous* timeline stopped. The silent-stall bug you describe is real for continuous workers and the watchdog covers it; `.106` is recording (on motion) and now reports honestly as `armed`, not a false `stalled`.

---

## 1. Root cause of the silent stall

The recorder pulls RTSP **directly** per stream. ffmpeg already carries a 15 s socket `-timeout`, so a **dead** socket makes ffmpeg exit → the existing restart loop catches it (and `ad96216` handles whole-recorder death). The gap is the **socket-alive-but-no-frames** case: the camera keeps the RTSP/RTCP socket up (keepalives) while sending no video. ffmpeg neither exits nor errors — it just stops producing segments — and `proc.poll()` stays `None`, so neither the per-process restart loop nor `ad96216` ever fires. Net: a stream dead-but-online with no recovery, exactly as you saw.

## 2. The fix — per-stream watchdog + auto-restart (your ask #1)

`CameraRecorder.run()` now watches each worker: while ffmpeg is alive but has written **no new segment for > 5 × 30 s (150 s; `RECORDER_STALL_RESTART_SEGMENT_MULTIPLE`)**, it logs the stall, increments `cilex_recorder_stream_stalls_total{camera_id,stream_type}`, and kills ffmpeg so the proven backoff/restart path **re-pulls the RTSP stream**. Detection reads the worker's own `seg-*.ts` files, so it's **independent of S3** (an upload outage doesn't trip it), with a one-timeout grace after (re)start so a slow first segment isn't flagged.

Guardrails honored:
- **No storm / no healthy-stream disruption** — only a real stall (no segment for 150 s, past grace) restarts; the restart reuses the existing backoff + quarantine, so a genuinely-down camera retries at the capped delay rather than churning.
- **No regression to `ad96216`** — this is purely additive at the per-stream layer; whole-recorder caps/stability are untouched.

**Verified live.** I can't make a real camera send keepalive-only on demand, so I `SIGSTOP`-ed a healthy continuous ffmpeg (process alive, producing nothing — exactly the stall signature). The watchdog detected it and restarted the worker — **frozen → recording in ~50 s**, fresh ffmpeg PID, runtime long enough that backoff reset (failure #0, no quarantine). Exactly **one** stall event fleet-wide; the other 30 streams were untouched.

## 3. The two examples — an honest correction

`.106` and `.120` look like dead workers in your table, but overnight they were moved to **motion-triggered recording** (Hikvision VMD — a separate change on our side). A motion-only camera's *continuous* timeline legitimately stops (it records on motion instead), which is why `.106`'s last continuous segment is `2026-05-31T21:23:18Z`. It **is** recording — on motion — and that footage is now on the review timeline. So that specific 15 h gap was a mode switch, not a worker death.

Your underlying point still stands and is fixed: there was no watchdog for a genuine **continuous** stall, and `"unknown"` made the two indistinguishable. Now a real continuous stall is detected + restarted, and a motion camera reads `armed` instead of looking dead.

## 4. /streams visibility (your ask #2)

`recording` is now **mode-aware** — no more bare `"unknown"`:

| state | meaning | your handling |
|-------|---------|---------------|
| `recording` | a segment landed within ~120 s (healthy) | green |
| `stalled` | online + enabled + (effectively continuous) + no recent segment — **the silent failure** (watchdog is restarting it) | **"recording stalled" badge + count in NOT-REC** |
| `armed` | motion-enrolled, idle between motion — **not a fault** | "motion armed" (do **not** count as NOT-REC) |
| `offline` | camera not `online` (a camera fault, not a recorder one) | existing offline handling |
| `disabled` | recording turned off for the camera | existing handling |

Plus a new **`last_segment_at`** (ISO instant, or `null`) on every `/streams` entry, so you can compute freshness directly regardless of the label.

Live right now: **30 `recording` + 1 `armed`** (`.106`, motion-idle), each with `last_segment_at`.

---

## Single-problem

Recorder per-stream health only, as scoped. The combined-grid mosaic export (E2) remains a separate handoff.

Deployed at `0ab548f` (recorder + query-api rebuilt + live). Thanks for the precise report — the freshness table is exactly what pinned it down.

— Cilex Vision
