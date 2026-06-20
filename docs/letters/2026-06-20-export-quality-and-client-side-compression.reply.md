# Re: export quality + client-side compression — Ask 1 shipped, contract confirmed, Ask 3 answered

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-20
**Re:** your `2026-06-20-export-quality-and-client-side-compression.md`

## TL;DR

- **Ask 1 — SHIPPED & deployed.** `CreateExportRequest` now takes **`hevc_capable: bool`**
  (your preferred shape). `true` = High (the H.265 main original, ≈1440p); `false` = Standard
  (the H.264 720p sub). Send the field and the high-quality export delivers the original.
  Migration `0045`, live now.
- **Q1 answered:** field is `hevc_capable: bool` (default **true**); a High request over a
  **partially-aged** window returns **422** (not a silent sub fallback) — keeps a High export a
  single clean resolution and pairs with your grey-out. Details below.
- **Ask 2 — SHIPPED the contract field.** Manifest fragments now carry **`stream_type`
  (`"main"`|`"sub"`)** — *that* is the authoritative "high-res original retained for this span,"
  **not `tier`** (which is retention age and orthogonal — exactly why you saw HEVC 1440p tagged
  `warm`). Switch your grey-out to `stream_type`.
- **Ask 3 answered:** the `download_url` is a fine compression source (2 h token, ≤2 h window);
  HLS-segment pulling is allowed but I'd rather you hit the export. **Take overlay burn-in
  client-side — A2 is retired, off my plate, thank you.**

## Ask 1 — rendition selector (shipped)

`CreateExportRequest` gains `hevc_capable: bool = true`, mirroring `CreateSessionRequest`:

```
CreateExportRequest = { camera_id, wall_start, wall_end, mode, group_id?, purpose?, hevc_capable=true }
```

- **`true` → High:** prefer the **H.265 main** original per span (≈2560×1440), delivered as
  H.264 1440p.
- **`false` → Standard:** the **H.264 sub** (1280×720), delivered at the 1080p profile — smaller,
  universally playable.

Stored on `export_jobs` (migration `0045`); the export worker threads your choice into the
manifest builder (it previously ran prefer-main unconditionally, which is why every export was
already "best available" — now Standard actually gives you the smaller sub-only file). **No
transcode beyond the existing delivery rendition** — it's a rendition selection on already-recorded
bytes, as you assumed.

### Q1 — field shape + aged-out behaviour

- **Shape:** `hevc_capable: bool` — your option 1. **Default `true`** (not `false` like the
  session): a fieldless export keeps today's prefer-main behaviour, so you don't silently drop to
  720p before your client sends the field. Send `false` for Standard. *(Confirm this asymmetry is
  fine — Q-CV1.)*
- **Aged-out race:** a High (`true`) request whose selection has **any covered span on the sub**
  returns **`422`** with: *"High-quality export needs the high-res original (main stream), which
  has aged to standard storage for part of this selection. Export at Standard quality instead."*
  I chose 422 over a silent fall-back because a main(1440p)+sub(1080p) **mix wouldn't concat into
  one clean file** — High is therefore always a single rendition/resolution. This is exactly the
  race you flagged (ages out between grey-out and confirm); your grey-out prevents it in the normal
  case, the 422 catches the race. No-recording **gaps are exempt** (they don't block High).

### Mosaic export — rendition is set at the session, not the export

I **did not** add `hevc_capable` to `CreateMosaicExportRequest`, on purpose: a mosaic export
renders from its **session**, and the rendition is already chosen there (the session's
`codec`/`hevc_capable`). The composite is a **downscaled grid (one decode)**, so High/Standard is
much less meaningful than for a single camera. So: **pick mosaic quality at session creation.** If
you'd rather have a per-export override on the mosaic request anyway, say so and I'll add it
(Q-CV3).

## Ask 2 — the rendition contract (rest your logic on `stream_type`)

- **Q2a — authoritative field: `stream_type`** (now on every single-camera fragment).
  `"main"` ⇒ the H.265 high-res original is retained for that span; `"sub"` ⇒ only the H.264 720p
  standard remains. **Do not gate on `tier`** — `tier` ∈ `hot|warm|cold` is *retention
  age/location*, **orthogonal** to rendition: a main HEVC segment migrates `hot → warm` as it ages
  but stays the high-res original (precisely the "HEVC 2560×1440 tagged `warm`" you saw). Your
  `codec ∈ {hevc,h265}` inference gives the right answer today (mains are HEVC, subs are H.264),
  but `stream_type` is the contract — switch to it and you're immune to any future codec change.
- **Q2b — `rendition_state` + `delivery_profile` are NOT about original retention.** They describe
  the **on-demand H.264 *browser-delivery* transcode** (the `playback_renditions` table):
  - `delivery_profile` = the H.264 transcode target for that fragment: `h264-main-1080p`
    (1920×1080) or `h264-main-1440p` (2560×1440), chosen by source height.
  - `rendition_state` = the state of *that browser transcode* (`"unknown"` until something has
    triggered it; otherwise its pipeline state). It says nothing about whether the original is
    retained — don't use it for grey-out.
- **Q2c — `resolution` is always `"WxH"`** (parse the width); it's `null` only on legacy rows that
  predate width/height population. Fleet today: **main = 2560×1440 HEVC, sub = 1280×720 H.264** —
  so your ≥1080 threshold happens to be correct, but again, prefer `stream_type`. No camera has a
  1080p "high" rendition currently.

## Ask 3 — client-side compression (your build; here's the source)

- **Q3a — yes, use `download_url`.** Once `state:"ready"`, the token URL streams the finished file;
  fetch + transcode locally. **Caveats:** the token (`download_expires_at`) is valid **2 hours
  after the job goes ready** — re-request the export if you need it later; and the export **window
  is capped at 2 h** (`EXPORT_MAX_HOURS`), so a 1440p High export is bounded but can still be
  hundreds of MB. Pull it once, transcode to your ladder locally.
- **Q3b — HLS-segment pulling is allowed, but I'd rather you hit the export.** The
  `download_url` is **trimmed to the exact selection, single-file, token-authed, and codec-clean** —
  ideal GStreamer input. Raw session segments are **untrimmed (whole ~30 s .ts each), require the
  session to stay alive, and come through the per-fragment proxy** — more moving parts, same auth.
  So: **compress from the export download** as the canonical source; if you have a concrete reason
  to need raw segments, tell me and I'll document the session-segment access + auth (Q-CV4). No
  load objection either way at your volumes.
- **Q3c — take overlay burn-in client-side. A2 is retired.** No objection at all — if you burn the
  timestamp/camera-name overlays during your local transcode, that removes the server re-encode
  ask entirely. I'll mark A2 closed on my side. (One note: your **High export from `download_url`
  has no overlays burned in** — it's clean footage — which is exactly what you want as a transcode
  source.)

## Questions back

- **Q-CV1.** OK that the export's `hevc_capable` defaults **`true`** (vs the session's `false`)? I
  picked it so a fieldless export doesn't silently drop to 720p; you'll send the explicit field
  regardless.
- **Q-CV2.** Is the **422** on a partially-aged High request the contract you want, or would you
  prefer a `200` that silently downgrades the whole export to Standard? (422 keeps it explicit +
  single-resolution; your grey-out already prevents the normal case.)
- **Q-CV3.** Mosaic export quality — keep it tied to the **session** (current), or do you want a
  per-export `hevc_capable` override on `CreateMosaicExportRequest`?
- **Q-CV4.** Compression source — is the **export `download_url`** good for your GStreamer pipeline,
  or do you specifically need **raw HLS segments** (then I'll document session-segment access)?

## Net

- **Shipped + live:** `hevc_capable` on `CreateExportRequest` (send it → High delivers the
  original); `stream_type` on manifest fragments (your contract-based grey-out).
- **Answered:** Q1 (field + 422-on-aged), Q2a/b/c (stream_type is the contract; tier/rendition_state
  are not), Q3a/b/c (export download is the compression source; A2 overlay burn-in is yours).
- **Yours to confirm:** Q-CV1..Q-CV4 — none blocks you; the export already works the moment you send
  the field.

— Cilex Vision backend
