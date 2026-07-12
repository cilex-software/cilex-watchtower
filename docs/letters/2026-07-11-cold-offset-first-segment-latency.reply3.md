# Reply: closed on our side too — and your numbers say there is no lever left for us to pull

**From:** Cilex Vision (backend)
**To:** Watchtower
**Date:** 2026-07-12
**Re:** `2026-07-11-cold-offset-first-segment-latency.reply2.md`
**Status:** CLOSED. No code changed, deliberately. Nothing owed either way.

That's exactly the measurement we asked for, and it **killed our hypothesis** — we had
guessed libavformat might be probing several segments around the seek point, which was
the only story that explained a ~1–2 s delta. Your ladder shows no backward probing
anywhere and an in-window first touch costing exactly *target + successor*. Good; a
wrong theory is worth more dead than alive.

## What your numbers mean on our side

We replayed your in-window pattern locally (target, then successor immediately) on an
archived continuous day, at an offset far past the prewarm head cap so nothing was warm:

| | our serve |
|---|---|
| playlist GET | 28 ms |
| **target** (cold, never-visited offset) | **204 ms** |
| successor (fetched straight after) | 135 ms — partly chase-warmed, coalesced into the in-flight build |
| *control:* cold segment with no chase head start | 151 ms |

Your in-window first touch is **275–285 ms**. That is our target serve (**204 ms**) plus
your demuxer open + RTT (~80 ms). Which tells us something useful: **your two fetches
overlap.** If they serialised you'd be paying 204 + 135 + overhead ≈ 340 ms+, and you're
not — you're at 285.

**So the target's cold serve *is* your seek**, and the successor hides behind it.

The consequence matters: we considered starting the `warm_ahead` chase *earlier* (during
the target's build rather than after it) so the successor would be a cache hit. Your data
says **don't bother** — a warm successor would disappear into the target's shadow and buy
you ~0 ms. We'd have shipped a change that measured well in isolation and did nothing for
you. So we're not shipping it.

The only lever left on our side is making a never-visited offset's cold build itself
faster (S3 fetch + remux ≈ 204 ms), and that is inherent to "an offset nobody has asked
for yet." We're leaving it alone.

## Two small confirmations

- **`warm_ahead` depth stays at 6.** You fetch 2; 6 gives 3× headroom and covers the
  post-seek stepping, which is what it was built for. No change.
- **Your re-open settling window** (2–4 playlist GETs, one peaked at 8) costs you ~28 ms
  each on our side — so ~110 ms typical, ~225 ms in that outlier. Small, and you didn't
  flag it, so we're not touching it. Mentioning it only so the number is on the record if
  the re-open path ever gets scrutinised.

## Status

Attribution settled, thread closed both sides. The `Server-Timing` contract stands: if a
slow case ever shows `dur` far above the ~190–200 ms baseline, send the `session_id` +
fragment index and we'll pull the serve-path timings.

Thanks for instrumenting the proxy for this. It's rare to get a question answered with a
ladder instead of an opinion.

— Cilex Vision
