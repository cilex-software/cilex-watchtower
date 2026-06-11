---
name: multicam-review-architecture
description: "Synchronized multi-camera wall playback — client-side N-way HLS sync is infeasible; chose server-composited mosaic (backend E1). Don't re-attempt the client-side approach."
metadata: 
  node_type: memory
  type: project
  originSessionId: 723dcf87-ec16-436b-ad39-2bbc85996b7c
---

**Synchronized wall playback** (rewind the whole camera wall to one instant, all
tiles play in lock-step) was scoped 2026-05-31. A P0 spike measured the obvious
client-side approach — open N `/review/sessions`, play each via `QMediaPlayer`+HLS,
slave all to one master clock — on both offscreen **and** the real Intel iGPU:

- Sync **logic works**: N=2 holds a stable **~350 ms** drift.
- It does **NOT scale**: N=4 drifts to **~4 s within ~13 s** (tiles stall in
  lock-step — decode/feed can't sustain realtime); N=8 → "Invalid playlist"; N=16 → 1 plays.
- Qt `QNetworkAccessManager` caps HTTP at **~6 connections/host** — one shared
  proxy starved many players. Per-session proxies (each its own authenticated NAM)
  cleared that wall, but **per-stream decode/feed throughput** is the hard ceiling
  (~2–3 streams). **16-way client-side is impossible on this hardware.**

**Decision (user, 2026-05-31): server-composited mosaic.** Ask the backend for ONE
synchronized, composited grid HLS stream (client decodes one stream → scales to 16,
perfect sync). Spec'd as **E1–E5** in `docs/letters/2026-05-31-multicam-synchronized-review.md`
(E1 mosaic, E2 combined export, E3 scrub poster frames + thumbnail-hybrid fallback,
E4 coverage union, E5 latent confirms). Client work (P1–P5) is **blocked on E1**.

The spike code (SharedPlaybackClock, openSessionsFor, per-session proxies,
WallPlaybackSpike.qml) was **throwaway and reverted** — not in the repo. When E1
ships, build the mosaic client fresh: one stream rendered across the grid via the
backend's `cells[]` mapping, `SharedPlaybackClock` driving the single stream's
transport. **Do not re-attempt client-side N-way sync.**

**Status 2026-06-01:** the **mosaic client IS built** (`qml/WallPlayback.qml` +
`PlaybackClient::openMosaicSession`/`mosaicPlaylistUrl`; entry = LiveMonitor "Go back
in time", reactive — no gate) and **E1 now WORKS at the 16-cam wall ✅.** It was briefly
blocked: CV's first deploy (`965b091`) composited 2×2 but the 16-cam wall never produced
a frame (thread/PID exhaustion → `503 rendering⇄error` loop, + 0-byte boundary segments).
CV fixed both (`51c7b4d`: `pids_limit` 256→1024, `-threads 1`/input, render semaphore,
seek-3s-early); re-verified end-to-end on the real iGPU — 16-cam 4×4 composites + plays,
populated cells synced, empties black-filled, cold render ~1s. Full arc:
`docs/letters/2026-05-31-disk-healthy-path-to-live.{reply2,reply3,reply4}.md`. The
server-mosaic decision is **validated and live for operators**. Client shipped a
render watchdog (honest-fail a stuck composite) + a `WT_WALL_DAY` dev hook. See
[[session-recovery]].

**Status 2026-06-12 — cold-render perf SOLVED (backend `3043dbe`).** The 2026-06-11
seek-latency analysis found wall cold opens ~44-54s and cold seeks ~25-35s: NOT
ffmpeg (~3.2s/seg) but 16 *sequential unbounded* per-cell hypertable lookups
(~1.9s each) — same disease as the hevc_capable 500 (`131d1b6`). Backend shipped
render *chase* (cold seg/N jumps the render head), batched bounded resolves,
parallel deduped downloads, 2 frame-threads/decoder, fps-before-scale (~3.7×
realtime), 48s render-ahead (`MOSAIC_RENDER_AHEAD=8`), create-time seeding.
Verified client-side: create 0.19s, cold head ~6s, far seek ~3s, adjacent-next
pre-rendered; **cold open-the-wall → moving grid ≈7.4s** (operator click ≈5-8s).
Watchdog re-tightened 75s→25s. Letters: `2026-06-11-mosaic-cold-render-latency.*`;
perf doc `docs/perf/2026-06-11-playback-seek-latency.md` (addendum 2).

Related: [[session-recovery]] · [[s06-playback-gaps]] · [[playback-via-cilex-vision]]
