---
name: cilex-vision-playback-api
description: "cilex-vision recorded-playback (S06) API contract — sessions, fragments, codec/tier model, transcode policy"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 07da05e9-981a-465b-aad6-7f1cc1e8c07c
---

Watchtower has no recording backend; recorded footage comes from cilex-vision's HLS playback API (the `PlaybackClient`/`HlsProxy` reach it). Contract conveyed by cilex-vision, not in the repo:

- `POST /review/sessions` takes `hevc_capable` (default **false**). Watchtower decodes H.265 natively, so it sends `true` → gets the H.265 hot stream. Left false → H.264 sub only (browser fallback).
- Footage is **dual-recorded**: hot (0–3 days) = H.265 1440p main stream; warm (3–30 days) = H.264 720p sub stream. For an HEVC client the manifest serves H.265 where it exists and H.264 720p beyond, so **one session can mix codecs/resolutions** — a timeline crossing ~3 days switches codec+resolution mid-playback.
- Each fragment carries **`codec`, `resolution`, `tier`** — drive the decoder from these, don't assume one codec per session. The boundary is marked `#EXT-X-DISCONTINUITY`; the GStreamer pipeline (hlsdemux→tsdemux→h265parse/h264parse→vaapih265dec/vaapih264dec) must renegotiate the decoder there.
- **No server-side transcoding** for native clients (HEVC→H.264 path removed). Playback is remux/stream-copy; the client decodes the recorded bytes.
- Cold-tier fragments report `availability: "hydrating"` — **cosmetic label, they still play**. Do NOT drop them. (See [[s06-playback-gaps]] — current QML wrongly keeps only `availability === "ready"`.)
- Live edge: manifest gives `clipped_to_finalized` + `live_gap_s`; don't seek past finalized footage.
- Export: `POST /review/exports` → poll `GET /review/exports/{id}` → proxied `download_url`. **Confirmed via OpenAPI (2026-05-27):** the request (`CreateExportRequest`) accepts ONLY `{camera_id, wall_start, wall_end, mode}` (all required; `mode` a free string, we send `"continuous"`); the job GET response is untyped (`{}`) though `state`/`download_url`/`error_msg` work. No `purpose`/overlay/audio/size fields — functional spec to add them sent in `docs/letters/2026-05-27-watchtower-to-cilex-vision-export-api.md`. The backend (192.168.1.79:8000) is reachable from the dev box; OpenAPI at `/openapi.json`, login admin/admin.

Camera_ids (4 hiwatch cameras): hiwatch-083bc14eff9a, hiwatch-083bc14eff9d, hiwatch-083bc14effb2, hiwatch-083bc17adca6. As of 2026-05-26 ~3.3h recorded each. Test windows (UTC, 2026-05-26): 17:02→18:23 = pure H.265 1440p hot; 16:54→now w/ hevc_capable=false = H.264 720p; **15:06→18:23 w/ hevc_capable=true = mixed H.264 720p→H.265 1440p switch mid-timeline** (the codec-switch test case, from today's pipeline cutover).
