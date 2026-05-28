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
1. **Mid-playback codec switch unverified — BLOCKED.** h264 720p ↔ hevc 1440p across `#EXT-X-DISCONTINUITY` only happens on windows spanning the 3-day hot→warm boundary. Default zoom presets (15m/1h/24h) are all-HEVC and work. A **static gst pipeline broke at the switch**; QMediaPlayer's dynamic playbin *may* cope but needs the **synthesized multi-day mixed timeline the cilex agent offered** — ping them for it. (The 2026-05-26 15:06→18:23 window is a same-day codec switch from a pipeline cutover, but the real test wants the synthesized timeline.)
2. **Same-group camera switch in the playback aside** — not yet built.
3. ~~Full export drawer~~ **DONE (2026-05-27, uncommitted).** `qml/ExportDrawer.qml` — 440px drawer + centered confirm modal, wired from PlaybackScreen's "Export Clip". Verified by screenshot (drawer + modal render faithfully; gap detection, est-size, HH:MM:SS.mmm range all compute). Backend accepts only 4 fields ([[cilex-vision-playback-api]]); purpose/overlays/audio collected in-UI, marked "pending Cilex Vision support," only supported fields transmitted. Spec letter in `docs/letters/`. See [[handling-design-backend-gaps]].

**Latent contract issues (real but don't manifest with today's all-hot, all-"ready" ~3.3h footage):** revisit when warm/cold or multi-day footage exists.
- `PlaybackScreen.qml` keeps only `availability === "ready"` fragments (~lines 126 & 132); cilex says cold fragments report `"hydrating"` (cosmetic) and **still play** — they'd be wrongly dropped.
- `resolution` not plumbed (only `codec` + `tier` read); aside infers resolution from codec, which breaks on mixed timelines.
- Window builder uses `Date.now() - zoomMin*60000`, so default zooms won't land on prior-day/UTC test footage without seeking.
- Live edge (`clipped_to_finalized` + `live_gap_s`) parsed into `meta` but not enforced in seeking.
