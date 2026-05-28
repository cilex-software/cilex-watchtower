---
name: playback-via-cilex-vision
description: "Watchtower Playback (S06) must stream recorded video from cilex-vision (HLS), not from cameras — cameras have no storage"
metadata: 
  node_type: memory
  type: project
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

Watchtower's **Playback / timeline screen (S06)** has no local recording backend and the
cameras have **no on-camera storage** — `.108`'s ISAPI `<hddList>` is empty and a recording
search returns 0 matches. So recorded footage comes **only from cilex-vision**
(`/home/cilex-vision/projects/cilex-vision/`), the platform Watchtower is a client of.

cilex-vision already has a **production Playback MVP** (see its `docs/playback-mvp-status.md`):
- Recorder writes `video_segments` (TimescaleDB) — the **timeline / coverage** source.
- Playback is **HLS**: `POST /api/review/sessions {camera_id, start, end}` → `{session_id}`,
  then `GET /api/review/sessions/{id}/playlist.m3u8` + `/seg/.../{idx}.ts` (HEVC→H.264
  transcoded via QSV/VA-API, audio stripped). **JWT/cookie role-gated** (admin/operator/viewer).
- Clip export: `export_jobs` table → MP4 in S3 `playback-exports`.
- Their own consumer is a Next.js `/review` page using HLS.js — Watchtower is **native Qt +
  QtMultimedia/GStreamer**, so it needs a bearer/cookie that `souphttpsrc` can send per segment.

**Verified contract (live API at `http://192.168.1.79:8000`, root paths — `/api` is the
Next.js proxy prefix, strip it):**
- Auth is **cookie-only** (no Bearer): `POST /auth/login {username,password}` (dev: admin/admin,
  operator/operator, viewer/viewer) → read `access_token` from the `Set-Cookie` header → send
  `Cookie: access_token=…` on every request incl. segments.
- `camera_id = "hiwatch-" + mac_hex` (MAC lowercased, `:`/`-` stripped). cilex-vision only knows
  `.104–.107` (camera_id e.g. `hiwatch-083bc14eff9a`=.106); NOT `.108`. `GET /streams` also gives
  go2rtc live URLs (`hls_url`/`webrtc_url`/`snapshot_url` on `:1984`).
- `POST /review/sessions {camera_id, wall_start, wall_end, hevc_capable:true}` (≤24h) → inline
  `manifest` {fragments[], epochs, events, time_anomalies, clipped_to_finalized, live_gap_s},
  30-min TTL. Each fragment: wall_start/end, compact_start/end (gap-removed timeline),
  codec/resolution/fps/tier, availability (ready|no_recording), segment_id. Footage is motion-gated
  (many small gaps) + dual-recorded: hot=H.265 1440p, warm=H.264 720p; a long window switches codec
  mid-timeline (marked `#EXT-X-DISCONTINUITY`).
- HLS: `GET /review/sessions/{sid}/playlist.m3u8` + `/seg/{idx}.ts`. Playlist seg URLs carry the
  `/api/` prefix and `#EXT-X-GAP` placeholder `gap-N.ts`.
- Export: `POST /review/exports {camera_id,wall_start,wall_end,mode}` (≤2h, operator+) → poll
  `GET /review/exports/{job_id}` → `download_url` (rewrite `/api`→`/review`), proxied MP4 (no S3 creds).

**Player approach (validated by de-risk):** Qt 6.4 `QMediaPlayer` can't set headers, so run a tiny
local HTTP proxy on 127.0.0.1 that injects the cookie, rewrites `/api/review/`→`/review/`, and
**strips `#EXT-X-GAP` placeholder segments** (the v1 `hlsdemux` that QMediaPlayer uses tries to
fetch `gap-N.ts` and 404s; `hlsdemux2` honors gaps but won't plug into the v1 stack). Point
`VideoSurface` at the proxy's `playlist.m3u8`. VA-API `vah265dec`/`vah264dec` present.

**Segment 500 bug — FIXED (2026-05-26):** cilex-vision had bound the S3 client as `app.state.s3`
but the segment/prewarmer/export handlers read `app.state.s3_client` → AttributeError 500 on every
S3 op. One-line fix. **Verified end-to-end:** `seg/{idx}.ts` → 200 video/MP2T (415 KB, `0x47`),
ffprobe hevc 2560×1440, cache warm 65/65; GStreamer (uridecodebin, the QMediaPlayer path) and
ffmpeg both decode a real HEVC 1440p frame through the local proxy. Clarifications from cilex:
`delivery_profile`'s `h264-` prefix is a **cosmetic** legacy cache-key label (ignore it; native
path is stream-copy, bytes are source codec); "warming" for native clients = a sub-second **remux**
(not QSV transcode), so a cold fragment may briefly **503** then 200 — proxy must retry 503;
`/storage video_bytes` is the unrelated inference frame-cache (real footage = `/admin/storage-tiers/usage`).
**Task 14 (S06) BUILT & verified (2026-05-26, commit e340c30).** `PlaybackClient` +
`HlsProxy` (C++, src/models) + `PlaybackScreen.qml`. Real `.106` HEVC 1440p recorded HLS plays
in the full app through the local proxy; timeline shows real footage/gap coverage; aside reports
live codec/coverage. Dev hook `WT_PLAYBACK_IP=<ip>` boots into playback.
**One caveat / follow-up:** mid-playback **codec switch** (h264 720p ↔ hevc 1440p across
`#EXT-X-DISCONTINUITY`) only occurs for windows spanning the 3-day hot→warm boundary; default
zoom presets (15m/1h/24h on recent footage) are all-HEVC and verified fine. A static gst test
pipeline broke at the switch (resolution+codec renegotiation); QMediaPlayer's dynamic playbin may
cope, but it's **unverified** — needs the synthesized multi-day mixed timeline the cilex agent
offered, and possibly a playbin3/hlsdemux2 (streams-aware) custom pipeline. Also not yet done:
same-group switch in the playback aside, full export drawer (basic export create→poll→toast works).
See [[feedback-no-placeholder-content]].
