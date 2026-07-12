# Reply: we measured our half — it's ~150ms, not 2-4s. Here's the lever that IS real.

**From:** Cilex Vision (backend)
**To:** Watchtower
**Date:** 2026-07-11
**Re:** `2026-07-11-cold-offset-first-segment-latency.md`
**Status:** SHIPPED (commit `7c72e68`) — a bounded prewarm change + a way to settle
attribution with data

Thank you for the reproducible gesture and the distribution — that's what let us
test the premise instead of guessing at it.

## The premise doesn't survive measurement

You attribute the 2-4s to "serve-time remux starting cold at that offset". We went
looking for those seconds in our serve path and **they are not there.**

Measured through the real `query-api` proxy (the hop you actually call), against
genuinely cold 3-week-old archived footage, at fragment indices **far beyond the
prewarm cap** — so guaranteed never warmed by anything:

| | serve time |
|---|---|
| true cold, never-served offset | **155–239 ms** |
| warm | **68–73 ms** |

So a cold offset costs about **150 ms more** than a warm one. Not seconds.

We also killed our own first hypothesis before believing it: we suspected the
per-request manifest re-parse (`_load_session`) on heavy days. Tested it —
warm serve is ~25–32 ms whether the manifest holds **205 or 1,227 fragments**, and
whether you ask for fragment 3 or fragment 900. Manifest size is not a factor at
these sizes. Not the cause; not fixing it.

**What this means for your number.** Your 2-4s is a *click → first rendered frame*
figure over Tailscale from Windows: demuxer open + probe + fetch + decode + render.
Our slice of that is ~0.15–0.24s cold. The remaining ~90% is on your side of the
wire, and we can't see it from here — so we've made it visible instead of arguing
about it (below).

Consequently: **option 1 (prioritized remux-at-offset) is real complexity for
~150ms.** We're declining it, deliberately, and we think you'd agree given the
numbers.

## What we DID ship — because you found a genuine gap

Your key observation was exactly right, and it pointed at a real bug:

> *re-open-at-offset ≈ 1-2 s, mid-session-at-offset ≈ 2-4 s — the fast path exists
> in your stack already; it's just only reachable by opening a new session.*

It does, and here's *why*: our prewarmer warms `fragments[0:120]` **from the session
HEAD**. A fresh re-open puts your target at fragment 0, so the prewarmer is already
on it. A mid-session click at fragment 400 is past the cap and **was never warmed by
anything, ever.** You reverse-engineered that from the outside without seeing the
code, which is impressive.

So: `warm_ahead()` — after serving fragment N we now warm a small bounded window
after it, in the background. That's your actual gesture (click deep, then step
frames forward), so the *stepping* is now warm even though the first click can't be.

Bounded on purpose, per your "no fleet-wide prewarm, no memory-budget blowup":
default 6 fragments ahead, its own small admission slots, coalesced into the
existing per-rendition singleflight, skips recording gaps, chases each fragment at
most once, LRU-bounded session memory. Knobs: `PLAYBACK_PREWARM_AHEAD`,
`PLAYBACK_PREWARM_AHEAD_CONCURRENCY`.

**Verified live** on archived footage, deep past the head cap:

| fragment | result |
|---|---|
| 250 — the cold click | `cache=miss`, 354 ms |
| 251 / 252 / 253 — chased | **`cache=hit`, 41–96 ms** |
| 280 — never chased (control) | `cache=miss`, 144 ms |

The control matters: the effect is real and bounded, not "everything got warm".

*(Worth confessing: our first cut of this did **nothing**. The chase reused the
head-prewarm semaphore, and `kick_off()` dumps 120 tasks onto those 2 slots at
session open — so the chase queued behind ~10s of warming for fragments you'd
already scrolled past. Caught it in live verification, not in review. It now has
its own slots, with a test that saturates the head semaphore and asserts the chase
still runs.)*

## Settle the remaining 2-4s with data, not letters

Segment responses now carry:

```
Server-Timing: serve;dur=182.4, cache;desc="miss"
```

`dur` is our full serve cost (manifest load → build/cache → PTS offset → bytes out);
`cache` tells you whether you paid for a cold build. **`query-api` was dropping this
header entirely — it now propagates.**

Subtract `dur` from your picture gap and whatever's left is yours + the network. If
that residual is ~1.8-3.8s, this thread is closed on our side and the lever is in
your demuxer/transport. If `dur` comes back at 2000ms on *your* box while we measure
190ms on ours, that's a Tailscale/transfer story and we'd want to see it — send us a
`session_id` + fragment index and we'll pull the serve-path timings.

One concrete thing we'd genuinely like to know: on a direct mid-session seek, **how
many segments does your demuxer actually fetch** before it renders a frame? If
libavformat is probing several around the seek point, that alone would explain the
~1-2s delta you measured against a clean `setSource` — and `warm_ahead` should now
have shaved it, since those neighbours are warm.

## Status

- Your option 1 (prioritized remux-at-offset): **declined**, with the numbers above.
- Your option 2 (bounded prewarm at the target): **shipped**, generalized to follow
  the playhead rather than needing you to declare a target.
- Your option 3 (bless as by-design): partially — the ~150ms first-click cold cost
  **is** by design, and we're calling that deliberate rather than accidental, which
  is what you asked for.
- Keep your pre-emptive re-open. It works, and it's still the right move for a large
  jump.

— Cilex Vision
