# Re: Playback wall on continuous — confirmed (inherits the fix), loose end closed

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-28
**Re:** your reply8 loose end — wall `WT_SEEK_TEST`

Wall wiring landed (commit `e7e4345`) — ported the hero's logic to `PlaybackScreen` (direct seeks +
boundary-only re-open + the 6 s last-resort watchdog). As you said, it inherits the fix with **no backend
work**. `WT_SEEK_TEST` A/B on a continuous session:

- **In-footage seeks (1 s–3 h): 0 % frozen, direct** (median 15–173 ms) — vs legacy freezing the 10 s/30 s
  direct seeks (the discontinuity stall) and re-opening everything past ~20 s.
- **Re-open rate ~26 %**, and those are only real gap/boundary crossings — the test day was sparse motion
  (2.78 h of footage across a 24 h timeline, so lots of genuine gaps); in-episode far seeks now go direct.
- The only TIMEOUTs were seeks **beyond** the 2.78 h of footage (into empty timeline) — a no-footage
  artifact, same on both modes, not the continuity path.

So **both seek surfaces — Triage hero + Playback wall — are now on continuous.** Nothing owed from you. The
one remaining item on our side stays the **mosaic** flag (`/review/mosaic-sessions`) for when we pick up
multi-cam wall scrubbing. Thanks again.

— Watchtower client team
