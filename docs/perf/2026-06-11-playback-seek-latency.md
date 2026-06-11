# Playback seek latency — measured analysis (2026-06-11)

**Question:** how long from moving the scrubber (±10 min / ±1 h / ±1 day) until
playback actually resumes — single camera and the 16-cam wall — and what causes
the slowness?

**Method.** A scripted bench drove the real screens (`PlaybackScreen`,
`WallPlayback`) through open → ±10 m → ±1 h → ±6 h → day-switch sequences while a
new `WT_HLS_LOG=1` hook in `HlsProxy` logged every upstream request (attempt,
status, elapsed). "Resumed" = the playhead advancing again, cross-checked against
`mediaStatus` transitions and segment arrivals (the raw `QMediaPlayer.position`
property keeps advancing during a stalled wall seek, so position alone
over-reports — wall numbers below come from media-status + segment-arrival truth).
Footage that day: warm tier, H.264 1280×720@15, ~30 s/~460 KB segments, all
"ready". Backend on LAN.

## Results — single camera (day session, 2 880 segments)

| action | time to playing | breakdown |
|---|---|---|
| open a day (healthy path) | **2.7–6.1 s** | session POST 2.5–5.6 s (2 MB manifest) + playlist/segment/preroll ~0.3 s |
| open a day (production path, `hevc_capable:true`) | **~32 s → HTTP 500** | backend bug — every open fails; see letter `2026-06-11-session-hevc-capable-500.md` |
| seek ±10 min | **~50–290 ms** | fetches exactly the landing segment (+1–2 read-ahead), 35–160 ms each |
| seek ±1 h | **~50–190 ms** | same |
| seek +6 h | **~50 ms** | same |
| ±1 day (= day-switch; sessions cap at 24 h so it's a new session) | **~3.4 s** | session POST again + preroll |

Within-session scrubbing is excellent. The two real single-camera problems are
the `hevc_capable` 500 (dominant, breaks every open) and the 2–6 s session-create
cost (manifest size scales with window).

## Results — 16-cam wall (server-composited mosaic, 6 s segments)

| action | time to playing | breakdown |
|---|---|---|
| open a day | **44–54 s** | session create ~6 s + compositor cold-render of the head (~38–47 s) |
| seek into an already-rendered region | **0.2–0.5 s** | segments served in 50–130 ms |
| seek into a cold region (+10 min, +1 h) | **~25–34 s** | the backend renders the landed-on segment on demand at ~0.36× realtime |
| sustained playback right after a cold seek | stall-play-stall | next segments are also cold (~16 s per 6 s segment) until the renderer catches up |

The compositor is the entire wall story: ~6 s of mosaic takes ~16 s to render
(measured per-segment: head 15.3 s, far seek 34.5 s, adjacent next 16.9 s, raw
curl). While rendering it correctly answers `503 + Retry-After: 1`.

## Causes (ranked)

1. **Backend: `hevc_capable:true` → 500 after ~32 s** on `POST /review/sessions` —
   every single-camera open. Client workaround shipped (`false` + letter).
2. **Backend: mosaic cold render ~0.36× realtime, on demand** — all wall
   open/seek slowness. Letter with numbers + asks (prewarm at seek target,
   ≥1.5× realtime, render-ahead horizon): `2026-06-11-mosaic-cold-render-latency.md`.
3. **Client (fixed): wall watchdog declared failure at 18 s** while cold opens
   take ~50 s — operator saw an error banner, then video started behind it. Now
   self-clearing with a 75 s budget.
4. **Client (limit, documented): GStreamer souphttpsrc aborts any HTTP request at
   ~15 s** — the proxy must answer each request chain under that, so a cold wall
   seek is paced by the player's outer fragment-retry loop (works, survives
   multi-cycle waits; a >15 s proxy hold was tried and measured worse).
5. **Qt 6.4 `stop()` wart (fixed): re-prerolls the old media at position 0**,
   re-downloading its first segments during every session switch. Now fully
   unloaded (`source = ""`) before opening the next session.
6. **30 s segments**: seeks snap to segment boundaries (Qt seeks are FLUSH,
   non-ACCURATE) — landing up to ~30 s before the requested instant. Latency is
   fine today (segments are small), but accuracy suffers (matters for the
   event "−15 s lead-in" jump) and each seek downloads up to 30 s of footage for
   potentially 2 s of viewing. 4–6 s segments would tighten both. Backend-owned.
7. **Per-segment `#EXT-X-DISCONTINUITY` (75 % of boundaries)** — each recorder
   chunk is an independent remux with restarted timestamps. Harmless at
   720p15/H.264 measured today, but it forces a decoder reconfigure per segment;
   a risk multiplier once HEVC 1440p returns. Backend-owned.

## Verified end-to-end after fixes

Re-ran both benches: single-cam all steps pass (open 3.0 s, seeks ≤ 192 ms,
day-switch 3.4 s); wall opens with the loading state held (no false error) and
cold seeks complete through the player's retry loop. An earlier "day-switch
wedges the player" hypothesis was disproven — it was a bench artifact (stale
target window); playback resumes fine in every run.

## Proposals

Client-side (done in this change-set): watchdog fix, full unload on session
switch, `WT_HLS_LOG` diagnostics, `hevc_capable` workaround, boot-hook retry.

Client-side (possible next):
- **Optimistic scrub preview**: on scrub, show the nearest already-buffered frame
  + a "seeking…" chip instead of freezing the last frame — perceived latency win,
  no protocol change.
- **Debounce rapid scrubs** (only issue the final position after ~150 ms of rest)
  — avoids piling flush-seeks; cheap.
- **Qt 6.8 LTS upgrade** for QtMultimedia — newer hlsdemux2 + many seek/state
  fixes; removes the souphttpsrc 15 s + stop()-preroll warts. Medium effort,
  needs a test pass.

Backend-side (letters filed): fix `hevc_capable` 500; mosaic prewarm-at-seek +
faster-than-realtime render + render-ahead; consider 4–6 s segments and a shared
timestamp base (no per-segment discontinuity); slim the session-create response
(2 MB/day manifest → paginate or compact encoding) to cut the 2–6 s open cost.
