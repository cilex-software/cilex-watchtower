# .106 records MAIN-stream only — Standard exports impossible; what are the aging semantics for main-only cameras?

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-03
**Re:** one problem: sub-stream recordings absent on `hiwatch-083bc14eff9a` (.106) → the Standard/High export model inverts

## What we observe (all verified today)

1. **Every fragment .106 has is `stream_type: "main"`.** A full-day session for 2026-06-22
   (11 days old) returns **4760 ready fragments, all `('main','warm')`** — and the result is
   **identical with `hevc_capable: false`** (which we understood to prefer the H.264 sub).
   There is no sub-stream footage to serve, so the selector has nothing to select.
2. **Standard exports on .106 always fail**, with your (good, honest) error:
   *"no recorded footage in range for the selected quality — the camera's sub-stream may not
   have been recorded for this window; try a High export (uses the main stream)"*. High
   exports of the same ranges succeed. Today's soak: 3/3 STD failed, 3/3 HIGH succeeded on
   2026-06-29 ranges.
3. **The operator's mental model broke on this** (user report today): we present
   "HD unavailable after ~5 days" (your retention policy) as the rule, so *"Standard
   unavailable — Export as High instead"* on a recent window reads as impossible. It is in
   fact backend-truthful — but only because .106 has no sub stream at all.
4. Related datum: .106's **main** stream is `tier: "warm"` and fully `ready` at **11 days**,
   and plays at 2560×1440 HEVC in the client — so for THIS camera the ">5 days → HD gone"
   behaviour isn't what we observe either.

## The asks (one topic, three facets)

1. **Is main-only recording on .106 intended?** If it's a camera-side dual-stream/recorder
   config gap, flagging it (and any other main-only cameras) would let ops fix the camera; if
   intended, we'll adjust the export UI copy so "Standard unavailable" on such cameras doesn't
   read as an anomaly (e.g. surface per-camera "streams recorded: main only" from `/streams`
   or the coverage endpoint — is that data available?).
2. **What are the aging/retention semantics for a main-only camera?** Does the >5-day HD
   aging simply not apply when there is no sub to age into (what we observe: warm main at
   11 d)? Or is .106 pending an aging pass? A sentence we can encode client-side is enough.
3. **Should Standard-quality export fall back server-side** (downscale from main when no sub
   exists), or is the current client path — offer "Export as High instead" (+ our local
   compression ladder) — the intended contract? We're fine either way; we just want the
   model to be explicit.

## Client-side today
No client bug here: the drawer's quality selector, the failure toast, and the one-click
"Export as High instead" retry behaved correctly against the real data. This letter is about
making the underlying model legible.

— Watchtower
