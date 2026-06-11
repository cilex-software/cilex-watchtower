---
name: s06-playback-gaps
description: S06 Playback open follow-ups (3 tracked) + latent contract issues not yet manifesting
metadata: 
  node_type: memory
  type: project
  originSessionId: 07da05e9-981a-465b-aad6-7f1cc1e8c07c
---

S06 Playback landed in commit e340c30 (single-quality H.265 hot playback verified). See [[build-roadmap]] for phase context, [[cilex-vision-playback-api]] for the contract.

**Tracked follow-ups explicitly left undone in S06:**
1. ~~Mid-playback codec switch~~ **VERIFIED END-TO-END (2026-06-12) — CLOSED.** One session spanning the rolling hot-expiry edge (now−5d): warm **H.264 720p** → `#EXT-X-DISCONTINUITY` → hot **HEVC 1440p**; playhead crossed live, continuous segment fetches, zero non-200s, no stall; aside flipped to "2560x1440 (HEVC)" (screenshot). Test recipe: `WT_PLAYBACK_DAY` now also takes a **local instant** (`YYYY-MM-DDTHH:MM:SS` → opens the day + seeks there −15s); pick an instant ~1 min before now−5d. Found+fixed in the process: **deferred open-at seeks were issued before `seekable` and silently dropped** (event "−15s jump" landed at day start; now applied on `onSeekableChanged`). Context: the hevc_capable 500 letter thread (backend `131d1b6` fixed an unbounded TimescaleDB query; day-session opens now ~0.5s; hot tier was never gone — [[cilex-vision-playback-api]]).
2. **Same-group camera switch in the playback aside** — not yet built.
3. ~~Full export drawer~~ **DONE (2026-05-27, uncommitted).** `qml/ExportDrawer.qml` — 440px drawer + centered confirm modal, wired from PlaybackScreen's "Export Clip". Verified by screenshot (drawer + modal render faithfully; gap detection, est-size, HH:MM:SS.mmm range all compute). Backend accepts only 4 fields ([[cilex-vision-playback-api]]); purpose/overlays/audio collected in-UI, marked "pending Cilex Vision support," only supported fields transmitted. Spec letter in `docs/letters/`. See [[handling-design-backend-gaps]].

**Latent contract issues (real but don't manifest with today's all-hot, all-"ready" ~3.3h footage):** revisit when warm/cold or multi-day footage exists.
- `PlaybackScreen.qml` keeps only `availability === "ready"` fragments (~lines 126 & 132); cilex says cold fragments report `"hydrating"` (cosmetic) and **still play** — they'd be wrongly dropped.
- ~~`resolution` not plumbed~~ **FIXED** — the aside reads `f.resolution` at the playhead (codec-inference fallback only for null rows); verified correct (05-29 shows "1280×720 (H.264)").
- Window builder uses `Date.now() - zoomMin*60000`, so default zooms won't land on prior-day/UTC test footage without seeking.
- Live edge (`clipped_to_finalized` + `live_gap_s`) parsed into `meta` but not enforced in seeking.
