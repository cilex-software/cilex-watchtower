# Export quality choice (high vs standard) + client-side compression

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-20
**Re:** letting an operator pick the export rendition, and what we need to compress clips client-side

## How to read this letter

One problem, two asks. We've **shipped the operator-facing UI already** (a High/Standard
quality choice in the export drawer, with the high option greyed + explained when the
original has aged out) — it's built entirely from data you already give us in the session
manifest, so **nothing below blocks us from showing the choice**. What we need from you is to
make the choice *take effect on the actual exported file*. Ask 1 is small and unblocks the
high-quality export today; Ask 2 is a contract confirmation; Ask 3 is forward-looking
(client-side compression — our work, but it leans on one thing from you). None of this is
urgent; it's the next slice of the export feature.

## TL;DR

1. **`POST /review/exports` has no rendition selector.** Please add one — `hevc_capable: bool`
   (mirroring `CreateSessionRequest`), or a `quality: "high"|"standard"` / `stream:
   "main"|"sub"` enum — so the operator's choice picks which rendition gets stream-copied.
   Same for `CreateMosaicExportRequest`.
2. **Confirm the per-fragment rendition contract** we now read (`codec`, `resolution`, `tier`,
   `rendition_state`, `availability`, `delivery_profile`): which of these authoritatively
   means *"the high-res original is still retained for this span"* vs *"only the standard sub
   remains"*? We currently infer "high = `codec` hevc or `resolution` ≥ 1080p". Want to rest it
   on your contract, not our inference.
3. **Client-side compression is ours to build** (local GStreamer transcode → a small ladder of
   output sizes). The one thing we need from you: a dependable way to fetch the **original
   quality** source to compress (see Ask 3). Bonus: if we transcode locally we can also burn in
   the timestamp/camera-name overlays client-side — which would retire the A2 server re-encode
   ask. Flagging so we don't both build overlay burn-in.

## Background — what we built, and why the choice is real

Operators export a clip from the playback timeline selection. They now choose **High quality**
(the full-resolution HEVC ~1440p original / main stream) or **Standard quality** (the H.264
720p sub). This maps onto your **dual-recording / tiering** model: the high-res original is
kept a limited window; the 720p sub is kept the full retention. So:

- The high-res original genuinely **ages out** — exactly the "if hot video isn't available,
  grey it out" behaviour the product wanted.
- We decide availability **per selection** from the session manifest: a fragment is "high" if
  `codec ∈ {hevc,h265}` or `resolution` is ≥1080p; "standard" otherwise. If **any** covered
  span of the selection has aged to the sub, we grey out **High quality** and the operator
  gets a tooltip: *"The high-quality original (1440p) is kept for a limited time, and this
  footage has aged into standard-quality storage (720p)."* (Or, for a selection that straddles
  the boundary, a "part of this selection has aged…" variant.)

That part is **done and verified** offscreen against both a high-available and an aged
selection. The gap is delivery.

## Ask 1 — a rendition selector on the export request (the actual blocker)

Confirmed from your live OpenAPI today:

```
CreateExportRequest        = { camera_id, wall_start, wall_end, mode, group_id?, purpose? }
CreateSessionRequest       = { camera_id, wall_start, wall_end, hevc_capable=false }
CreateMosaicExportRequest  = { wall_start, wall_end, mode, group_id?, purpose? }
```

The **session** lets us pick the rendition (`hevc_capable`); the **export** does not. So an
export currently delivers whatever single rendition the backend resolves internally — the
operator can't ask for the high-res original. Please add the selector to **`CreateExportRequest`**
(and `CreateMosaicExportRequest`). Our preference, in order:

1. `hevc_capable: bool` — symmetric with the session you already have; least surprising.
2. `quality: "high" | "standard"` — most human; you map it to main/sub internally.
3. `stream: "main" | "sub"` — most explicit if that's how storage is keyed.

Since exports are stream-copy (no transcode), this should be a rendition selection on the
already-recorded bytes, not new encode work. **The moment this lands we send one field and the
high-quality export works** — our client plumbing already carries the choice to the call site
(we just don't send an unknown field today, to avoid a 422 against the working export).

**Q1.** Which field shape do you want, and does the export honour the same main/sub availability
as the session (i.e., if `hevc_capable=true` but the original has aged out for part of the
window, do you 422, or silently fall back to the sub)? We grey the option out client-side, but
want to handle the race where it ages out between selection and confirm.

## Ask 2 — confirm the per-fragment rendition contract

The manifest fragments now carry a rich set we'd like to consume against a documented contract
rather than infer:

```
codec, resolution, tier, fps, media_epoch, availability, rendition_state, delivery_profile, …
```

We currently treat **hevc / ≥1080p ⇒ high-res original present**. Questions:

- **Q2a.** Is there a single authoritative field for "the high-res original is retained for this
  fragment" — e.g. `tier: "hot"` vs `"warm"`, or `rendition_state`? (We saw HEVC 2560×1440
  fragments tagged `tier: "warm"`, so tier ≠ codec — which is why we're asking.)
- **Q2b.** What does `rendition_state` enumerate, and `delivery_profile`? If one of them already
  means "original available," we'll switch our grey-out logic to it.
- **Q2c.** Is `resolution` always `"WxH"` (we parse the width)? Any cameras where the "high"
  rendition is 1080p rather than 1440p (so our ≥1080 threshold is right)?

## Ask 3 — client-side compression (our build; one dependency on you)

Next we want the operator to pick an **output size** independent of the stored rendition — a
sensible ladder, e.g. *Original · High (≈1080p) · Medium (≈720p) · Small (≈480p)* — produced
**entirely client-side** (local GStreamer/VA-API transcode of the exported clip; no server
encode load). This is our work. Two things from you:

- **Q3a.** Once Ask 1 lands, can we reliably fetch the **original-quality** export as a normal
  file (the `download_url` you already return) to transcode locally? Any size/expiry caveats on
  a 1440p original we should know (the `download_expires_at` you mentioned)?
- **Q3b.** Any objection to us pulling the **HLS segments** of the high-res session directly for
  local muxing/transcoding instead of round-tripping a server export (auth, rate, or load
  concerns)? Either source works for us; we'll pick whichever you'd rather we hit.
- **Q3c (heads-up, not a blocker).** If we transcode locally we can **burn in the
  timestamp/camera-name overlays** at the same time — which would **retire the A2 server
  re-encode ask** for single-camera export. Shout if you'd rather keep overlays server-side;
  otherwise we'll take overlay burn-in off your plate.

## Net

- **Shipped, no dependency:** the High/Standard choice + grey-out + tooltip (manifest-derived).
- **Blocked on you (small):** Ask 1 — a rendition field on `CreateExportRequest` — to make the
  high-quality export actually deliver the original. One field; we're wired for it.
- **Confirmations:** Ask 2 (rendition contract) so our availability logic is contract-based.
- **Forward-looking, mostly ours:** Ask 3 — client-side compression ladder; we need a reliable
  original-quality source (Q3a/Q3b), and we'll likely take overlay burn-in client-side (Q3c).

Other open backend items (shared ack B1, typed manifest schema C1, denormalized event
names C2, audio path A5, the go2rtc on-demand transcode cap value) are tracked separately in
`watchtower-to-cilex-vision-api-requests.md` and the 06-19 status round-up — not repeating them
here; this letter is just the export-quality/compression slice.

— Watchtower
