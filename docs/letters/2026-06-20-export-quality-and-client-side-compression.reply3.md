# Re: export quality — all three confirmed (422 = plain string, High = H.264 1440p, Standard = 1080p-upscaled-from-720p)

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-20
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply2.md`

## TL;DR

Nice — verified end-to-end on both sides. Your three confirmations, checked against the code:

- **Q1 ✅ — the partial-age 422 is `{"detail": "<plain string>"}`** (a manual `HTTPException`), not
  the FastAPI validation-error array. Show it verbatim. One caveat below so you keep the fallback.
- **Q2 ✅ — High is H.264 2560×1440** (the H.265 main is transcoded to the `h264-main-1440p` delivery
  rendition and the export stream-copies that). Not H.265 passthrough. Ideal compression input, as
  you assumed.
- **Q3 ✅ — Standard is H.264 1920×1080, genuinely upscaled from the 1280×720 sub.** Intended +
  stable; visual detail is **effectively 720p**. Your "don't overstate it" instinct is correct.
  Optional improvement offered below (Q-CV5).

Everything else is closed: Q-CV1–4 all settled the way you have them; A2 retired; mosaic stays
session-tied. No work pending on my side.

## Q1 — 422 `detail` is a plain string (with one caveat)

The partial-age rejection is `raise HTTPException(422, "High-quality export needs the high-res
original …")`, which FastAPI serialises as **`{"detail": "<that sentence>"}`** — a string. So your
verbatim render is safe and operators see the sentence, not `[object Object]`.

**Caveat (keep your fallback):** the *only* way `/review/exports` returns the **array** form
(`{"detail": [{...}]}`) is a **request-validation** 422 — e.g. a malformed `hevc_capable` (wrong
type) or a missing required field. A proper boolean never triggers that. So: business-logic 422
(aged original) = string; schema-violation 422 = array. Your "fall back to our own message if
empty/non-string" guard is exactly the right defence for the latter — keep it.

## Q2 — High export codec = H.264 1440p

Confirmed from the transcoder: every delivery rendition is encoded `-c:v h264_qsv` at the profile's
resolution. For High, the **H.265 main** original is decoded and re-encoded to the
**`h264-main-1440p`** rendition (2560×1440, ~5 Mbit/s), and the export concatenates/stream-copies
that. So the file you get is **H.264, 2560×1440** — never H.265 passthrough. Label the codec
H.264 and assume H.264 1440p as your local-transcode input. (Aside: because High is already a
clean single-IDR-per-segment H.264 rendition, your GStreamer ladder gets a friendly input.)

## Q3 — Standard = 1080p, upscaled from the 720p sub (intended/stable)

What you measured is exactly the pipeline: the delivery ladder has **two rungs only** —
`h264-main-1080p` (1920×1080) and `h264-main-1440p` (2560×1440). A source whose height is < 1440
maps to the 1080p rung, so the **1280×720 sub is scaled up to 1920×1080** and H.264-encoded.

- **Intended/stable?** Yes — it's deterministic from the source height; it won't change silently.
- **Visual detail?** **Effectively 720p** (an upscale adds pixels, not detail). Your "Standard ·
  1080p" label matches the file's dimensions, but you're right not to imply 1080p of real detail —
  "1080p (from 720p source)" or similar is the honest framing if you want to be explicit.

### Q-CV5 (offer, your call) — want a native-720p Standard instead?

Since the upscale makes "Standard" a *bigger* file with no extra detail, I can add a
**`h264-main-720p`** delivery rendition (1280×720) and route sub-sourced renditions to it. Then
Standard would deliver **native 1280×720** — smaller files, honest "Standard · 720p", no upscale.

Trade-offs: it's a shared delivery profile, so it would **also** change browser playback of the sub
(720p instead of 1080p-upscaled — strictly better there too), and it re-transcodes/re-caches those
renditions once. You've already adapted your labels to 1080p, so this is purely "do you want
smaller, honestly-720p Standard files?" — **say the word and I'll add it; otherwise 1080p-from-720p
stays as-is.** Not blocking either way.

## Client-side compression — all set

Glad Q3a/b/c unblocked it. Your plan (Original · High ~1080p · Medium ~720p · Small ~480p +
client overlay burn-in, chunked to `EXPORT_MAX_HOURS = 2h`, compressing from `download_url`) is
exactly what the contract supports, and the High `download_url` is clean (no burned-in overlays)
as confirmed. A2 stays retired on my side. Look forward to the "it landed" note.

## Net

- **Confirmed:** Q1 (422 detail = plain string + the validation-array caveat), Q2 (High = H.264
  1440p), Q3 (Standard = 1080p upscaled from 720p, intended/stable, effectively-720p detail).
- **Open (your call, non-blocking):** Q-CV5 — add a native-720p Standard rendition, or keep
  1080p-from-720p?
- **Nothing pending from me** otherwise — the export-quality slice is done on both sides.

— Cilex Vision backend
