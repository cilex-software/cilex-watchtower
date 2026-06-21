# Re: native-720p — label flipped + verified live from our side (1280×720). One cache nuance (Q-W3)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-21
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply5.md`

## TL;DR

- **Label flipped — shipped.** The export drawer now reads **"Standard · 720p"** (was "1080p"),
  and the no-upscale compression ladder for a Standard source now correctly offers only
  **Original + 480p** (1080p/720p grey out as upscales). Verified in-app.
- **We ran our own end-to-end measurement** (so you don't need to run one): a **fresh-window
  Standard export now reports `resolution: 1280x720`** and the session manifest shows every sub
  fragment at `delivery_profile: h264-main-720p` / `1280x720`. **Q-W1 confirmed live, Q-W2 confirmed
  (contract transparent).** Thank you — native 720p is in.
- **One nuance to confirm (Q-W3, non-blocking):** a Standard export re-requested over a window you'd
  **already rendered pre-deploy** comes back **byte-identical at 1920×1080** (served from cache) —
  so "a fresh request always uses the new rung / no stale serving" doesn't quite hold for
  previously-rendered windows. Looks like the rendered-fragment cache is keyed by
  `(segment, hevc_capable)`, not by `delivery_profile`. Detail + question below.
- **Bitrate cap:** leave the 2 Mbit/s 720p cap as-is — we re-compress locally and the sub never
  binds it. Thanks for the offer.

## Shipped on us — the label flip

Three pre-export labels in the export drawer flipped from the 1080p assumption to 720p, and the one
constant that drives the compression ladder (`sourceHeight` for a Standard source: `1080 → 720`):

- Standard quality button: **"720p · smaller file"** (was "1080p").
- The "exporting standard (…)" fallback line in the confirm modal: **"(720p)"**.
- `sourceHeight = 720` for Standard → the ladder's "size ≥ source = upscale → unavailable" rule now
  greys **1080p and 720p**, leaving **Original + 480p** — exactly the honest behaviour you called
  out. Our local size estimate also drops to the 720p tier.

One design note on where the number comes from, since you suggested keying off the job's
`resolution`: the **drawer label is a pre-export descriptor** (there's no job yet at drawer time), so
that one is the hardcoded "720p" rung descriptor. The **post-export view (Clips & Snapshots) already
reads the job's live `resolution` field**, so a completed export always shows its *real* delivered
resolution — including the cache case below, where it honestly reads `1920x1080`.

## Our end-to-end measurement (answering your offer)

Driven against the live backend (`POST /review/sessions` + `POST /review/exports`, `hevc_capable:false`):

| What | Source | `delivery_profile` | `resolution` | `output_bytes` |
|---|---|---|---|---|
| Playback manifest (fresh sub footage, cam `…f0014`) | sub, `tier=warm` | **`h264-main-720p`** | **`1280x720`** | — (23/23 ready frags) |
| **Standard export, fresh window** (cam `…f0014`, `10:35:01–09Z`, never rendered) | sub | — | **`1280x720`** | 765,273 (~747 KB / 8 s) |
| Standard export, **re-requested old window** (cam `…ff9a`, `06-18T12:56:50Z`) | sub (cached) | — | `1920x1080` | 8,848 |
| High export (existing) | main | — | `2560x1440` | — (unchanged) |

So: **fresh Standard = native 1280×720** (Q-W1 ✓), **playback sub = native 720p** (the
`h264-main-720p` rung is live), **High unchanged** and the **request contract is transparent** —
`hevc_capable:false` still selects the sub, `stream_type` is still `main`/`sub`, our grey-out is
unaffected (Q-W2 ✓). No need for you to run a number; ours is above.

## Q-W3 — previously-rendered windows still serve the old 1080p rung (cache)

Worth a quick confirm because it's the one place your reply5 and our measurement diverge.

Before I found a fresh window, I re-exported a window **you'd already rendered pre-deploy** — cam
`…ff9a`, window `2026-06-18T12:56:50–56Z`, a brand-new job today, `hevc_capable:false`. It came back
`resolution: 1920x1080`, `output_bytes: 8848` — **byte-for-byte identical** to the pre-deploy job
over that same window. Only when I exported a **never-rendered** window did I get the new
`h264-main-720p` / 1280×720.

That reads like the rendered-fragment (or export) cache is keyed by **`(segment, hevc_capable)`**,
**not** by `delivery_profile` — so a segment already rendered at the old 1080p-upscale rung keeps
serving 1080p for any re-request until retention orphans it; only segments never rendered as a sub
hit the new rung. That's a slightly different statement than *"a fresh request always uses the new
rung … no stale serving."*

**Question:** is that intended — i.e. "uses the new rung" means **new windows**, and pre-deploy
1080p renditions simply age out over the retention window (no force-invalidate, and it doesn't
matter because new footage is the common case)? **Non-blocking for us either way** — fresh exports
(the normal path) are correctly 720p, and our Clips view shows the real delivered resolution
regardless. We're only flagging it because (a) "no stale serving" doesn't strictly hold for
re-exports of old windows, and (b) if you *intended* re-requests to regenerate at the new rung,
folding `delivery_profile` into the cache key would be the fix. If it's working as designed, just
say so and we'll close it.

## Your two offers

- **Measured number** — covered ourselves (table above); no need to run one on your side. If you'd
  like a like-for-like on the *same* camera/window as your earlier two-export table for an
  apples-to-apples size delta, happy to compare, but note the only honest native-720p figure is from
  a fresh (uncached) window, per Q-W3.
- **2 Mbit/s cap on the 720p rung** — **leave it.** The sub is ~0.1 Mbit/s so the cap never binds,
  and we always have the option to re-compress locally. No change wanted. Thanks for offering.

## One small heads-up (no action)

You noted the `resolution` field reports the *delivery rung*, so any sub ≤ 720p reports `1280x720`.
Our fleet's subs are all 1280×720, so it's exact for us — just flagging that if a sub-720 camera is
ever onboarded, its Standard export would over-report as `1280x720`. Fine today; parking it.

## Net

- **Shipped on us:** label flip → "Standard · 720p" + no-upscale ladder (Original + 480p for a
  Standard source).
- **Verified live from our side:** native-720p Standard export (`1280x720`) and native-720p playback
  (`h264-main-720p`). **Q-W1 ✓, Q-W2 ✓.**
- **Open (non-blocking):** **Q-W3** — confirm the cache-key behaviour for re-requests of
  previously-rendered windows.
- **Closed on both sides:** export quality (High/Standard native renditions), client-side
  compression, overlay burn-in. A2 retired.

— Watchtower
