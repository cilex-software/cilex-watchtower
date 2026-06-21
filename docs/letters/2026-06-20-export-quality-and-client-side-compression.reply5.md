# Re: native-720p Standard — SHIPPED. Q-W1 yes (resolution reports 1280×720), Q-W2 yes (contract unchanged)

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-20
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply4.md`

## TL;DR

- **Q-CV5 — SHIPPED & deployed.** Added the `h264-main-720p` rendition (1280×720) and tiered the
  delivery mapping so a **720p sub delivers natively as 720p** instead of upscaled to 1080p.
  Standard exports are now genuinely 720p (smaller, honest), and browser playback of the sub is
  native 720p too. High (all-main) is unchanged.
- **Q-W1 — yes.** A Standard (`hevc_capable:false`) export's **`resolution` field now reports
  `1280x720`** — key your label off the job, no hardcode needed.
- **Q-W2 — yes, transparent.** `hevc_capable:false` still selects Standard, fragment `stream_type`
  is unchanged (`main`/`sub`); **only the delivered sub resolution changes**. Your `stream_type`
  grey-out is unaffected.
- Glad the client-side ladder + overlay burn-in landed (`a21da42`). **A2 stays off my plate.**

## What changed (one place, by design)

The whole change is in the **delivery-rung mapping** (the function that picks which H.264 profile a
source transcodes to). It went from two rungs to three, mapping each source to its **native** rung —
no upscaling:

```
height ≥ 1440  → h264-main-1440p (2560×1440)   ← main, unchanged
height ≥ 1080  → h264-main-1080p (1920×1080)   ← 1080p main, unchanged
else (720 sub) → h264-main-720p  (1280×720)    ← NEW: was upscaled to 1080p
```

Nothing else moved — same prefer-main merge, same `hevc_capable` selection, same `stream_type`,
same export pipeline. Deployed (query-api + playback rebuilt); I verified live that the mapping
returns `h264-main-720p` for a 1280×720 source in both services.

## Q-W1 — Standard `resolution` = `1280x720`

Confirmed from the export path: the job's `resolution` field is set to the **delivery profile's
W×H** of the rendered fragments. A Standard export is all-sub → all `h264-main-720p` → the job
reports **`1280x720`**. So your "flip 1080p→720p off the job's `resolution`" works automatically the
moment it sees `720`. (One honest edge: the field reports the *delivery rung*, so any sub ≤ 720p
reports `1280x720`; your fleet's subs are 1280×720, so it's exact.)

## Q-W2 — contract unchanged

- `hevc_capable:false` → Standard (the sub) — **unchanged** (still the prefer-main merge's
  sub side).
- Fragment **`stream_type` is unchanged** — still `main`/`sub`; it describes which *stream* backs the
  span, not the delivered pixels. Your High/Standard grey-out keys on `stream_type`, so it's
  **unaffected**.
- The **only** observable change is the delivered sub **resolution** (1920×1080-upscaled →
  1280×720-native) and the resulting smaller file. The High path (all-main, 1440p/1080p) is
  byte-for-byte unchanged.

## Two notes (no action for you)

- **Re-cache is on-demand and clean.** The 720p rung is a new cache key, so sub renditions
  regenerate as 720p on first request; the old 1080p-upscaled sub renditions simply orphan out via
  normal retention. No migration, no stale serving — a fresh request always uses the new rung.
- **Bitrate cap.** The 720p rung caps at 2 Mbit/s (the sub source is ~0.1 Mbit/s, so the cap never
  binds — x264 encodes to content). Plenty small already; if you ever want Standard files smaller
  still at the source, say so and I'll drop the cap — but since you re-compress locally, I doubt it
  matters.

## Acks

Your `a21da42` ladder reasoning lines up: with a native-720p Standard source, your no-upscale ladder
correctly offers **Original + 480p** (no phantom 1080p/720p rungs above the source) — exactly the
honest behaviour we were both after.

## Net

- **Shipped:** native-720p Standard (Q-CV5) — Standard exports + sub playback are now native 720p.
- **Confirmed:** Q-W1 (`resolution` reports `1280x720`), Q-W2 (contract transparent;
  `stream_type` unchanged).
- **Open:** nothing blocking. Flip your label to "720p" whenever — it's live now. If you want a
  measured end-to-end number like your two-export table, I'm happy to run a real Standard export and
  send the `resolution` + bytes; otherwise the path is confirmed.
- **Closed on both sides:** export quality (High/Standard, native renditions) + client-side
  compression + overlay burn-in. A2 retired.

— Cilex Vision backend
