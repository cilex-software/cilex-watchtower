# Mosaic compositor: cold render dominates wall playback (measured numbers)

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-11
**Severity:** HIGH for the wall-playback UX — seeks into un-rendered regions take ~30–55 s.

---

## What we measured (16-cam day session, 2026-06-10, 4×4, 6 s segments)

Raw, against `/review/mosaic-sessions` + `seg/N.ts` (curl, then confirmed end-to-end
through the client):

| case | result |
|---|---|
| first segment at playlist head (cold) | **200 after ~15.3 s** (curl); **~46 s** to first frames end-to-end in the client on a separate session |
| far seek: seg/300 (30 min in, cold) | **200 after ~34.5 s** |
| the segment right after it (seg/301) | another **~17 s** |
| segment in an already-rendered region | **50–130 ms** ✓ |

So the compositor renders **~6 s of mosaic in ~16 s ≈ 0.36× realtime**, on demand,
at the requested position. Operator-visible consequences, measured in the client:

- **Open the wall on a day → ~54 s** until the grid starts moving (6.7 s session
  create + cold render of the head).
- **Scrub +10 min or +1 h → ~33 s** until playback resumes (the landed-on segment
  must be rendered first). Scrubbing back into a rendered region resumes in ~0.3 s.
- **After a cold seek, playback can't sustain**: the next segment is also cold and
  takes ~16 s per 6 s of content, so the wall plays-stalls-plays until the renderer
  catches up.
- While a segment renders, the server answers `503 + Retry-After: 1` (correct);
  but past our proxy's old ~12 s retry budget the 503 bounced up into GStreamer,
  which re-fetched the playlist and re-requested in a loop — sometimes erroring the
  whole wall (the "Compositing…" dead-end we reported from the field earlier).

## What we changed client-side (shipped)

- The wall's render watchdog no longer declares failure at 18 s (it used to show
  an error banner and then frames would arrive at ~50 s *behind* it); it now polls,
  stands down as soon as frames flow, and only fails honestly after 75 s.
- We also tried stretching our proxy's per-request 503-retry budget to ~60 s so a
  cold seek would be one clean wait — measurably worse: GStreamer's HTTP layer
  (souphttpsrc) aborts any request at ~15 s, so long holds just add timeouts and
  socket churn. The proxy stays just under that (~13 s per chain) and the player's
  own fragment-retry loop paces the wait. Noting it so you know the 15 s ceiling
  exists on our side per request.

Client-side this is now as good as it gets: **the remaining 25–55 s is entirely
render time on your side.**

## Asks (pick what fits your architecture — numbers above are the budget)

1. **Prewarm on seek** (biggest win): when `seg/N` is requested and cold, start
   the render *at N* and keep rendering forward from there (cancel/deprioritize
   the old position). If the renderer already does this, it needs to be faster —
   see (2). Today seg/300 cold = 34 s, which reads as "the renderer had to get
   there" rather than "started there".
2. **Faster-than-realtime rendering** for the active window — target ≥ 1.5×
   realtime sustained (e.g. parallel per-cell decode, ultrafast encoder preset,
   lower mosaic fps — 12–15 fps is fine for a review grid; cells are 480×270).
3. **Render-ahead horizon**: keep N segments rendered ahead of the last-requested
   position so steady playback never starves once it starts.
4. **Session-create prewarm head start**: kick off rendering at `wall_start`
   immediately on `POST /mosaic-sessions` (don't wait for the first segment GET) —
   the client always plays from the head right after opening.

With (1)+(2), open-the-wall lands ~10 s and scrubs land ~10–15 s; with (3) steady
playback holds. We can re-measure on request — the client now logs per-request
timings (`WT_HLS_LOG=1`).

— Watchtower
