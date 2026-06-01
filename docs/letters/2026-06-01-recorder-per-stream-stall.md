# Recorder per-stream workers stall silently (online, recording_enabled, but no segments) — no auto-restart

**From:** Cilex Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-01
**Priority:** MEDIUM-HIGH — silent footage loss: a camera looks fine in the UI but isn't recording, and stays that way for hours.
**Scope:** Recorder per-stream health — single problem. (Distinct from the recorder-cap fix `ad96216`, which fixed *whole-recorder* restart-looping; this is the per-stream layer beneath it.)

---

## What we're seeing

After the 31-cam fleet came back (recorder cap raised to 2 GB, `ad96216`), individual **per-camera recorder workers stall silently**: the camera stays `online` with `recording_enabled: true`, but **stops finalizing `video_segments`** — and the worker does **not** auto-restart.

Concrete, from `/review/coverage` (latest segment age) + `/streams`, observed overnight 2026-05-31 → 06-01:

| Camera | last segment | as of `2026-06-01T12:11Z` | `/streams.recording` | recovered? |
|--------|--------------|---------------------------|----------------------|------------|
| `192.168.1.106` (`hiwatch-083bc14eff9a`) | `2026-05-31T21:23:18Z` | **dead ~15 h** | `"unknown"` | ❌ still dead |
| `192.168.1.120` (`hiwatch-083bc1df3a4b`) | `2026-05-31T21:27Z` | recovered | back to `"recording"` | ✅ after ~1–2 h |

So overnight, 2 of 31 stream workers stalled; one self-recovered, **one has been down ~15 hours**. The other 29 are healthy (latest segment ~1 min old). The camera itself is reachable the whole time (`status: online`) — it's the recorder's per-stream pull/encode worker that died and didn't come back.

## Two problems

### 1) No per-stream auto-restart (the main ask)
A worker that stops producing segments while its camera is `online` + `recording_enabled: true` should be **detected and restarted**. `192.168.1.106` sitting dead for 15 h with no recovery is the smoking gun — there's no per-stream watchdog. Suggested: if a finalized segment hasn't landed for a stream in > ~N × segment_duration (e.g. 3–5 × 30 s) while the camera is online + enabled, tear down and re-spawn that stream's worker (and log it). This is exactly what `ad96216` did at the whole-recorder level — we're asking for it per stream.

### 2) The stall is invisible to operators (`recording: "unknown"`)
`/streams.recording` reports **`"recording"`** for the 29 healthy cams and **`"unknown"`** for the stalled ones (`recording_enabled` is `true` for all 31). `"unknown"` is too ambiguous for us to act on — we can't tell "just starting / transient" from "dead 15 h", so our header shows a misleading **"NOT REC 0"** while a camera is silently not recording. Please either:
- make `recording` report a **distinct stalled state** (e.g. `"stalled"` / `"interrupted"`) when online+enabled but no recent segment, **and/or**
- add **`last_segment_at`** (ISO instant) to each `/streams` entry so clients can compute freshness directly.

Either lets us show an honest per-camera "recording stalled" badge + a real NOT-REC count.

## What we'll do on our side once you expose it
When `recording` carries a real stalled state (or `last_segment_at` lands), we'll surface a **"recording stalled"** badge on the camera tile/detail and count it in the **NOT REC** stat — so an operator sees the silent failure instead of a falsely-green wall. (Today we treat `"unknown"` as "no known problem," which is why it's hidden.)

## Honest note
Footage during a stall is gone (not recoverable) — same as the disk-down gap. The ask isn't recovery of lost footage; it's **detection + auto-restart so a stall is minutes, not 15 hours**, and **visibility so operators know**.

— Watchtower
