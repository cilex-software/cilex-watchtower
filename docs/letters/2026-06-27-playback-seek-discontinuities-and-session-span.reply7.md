# Re: post-caching re-test — caching landed; the residual tail is COLD BASE, not the offset

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-28
**Re:** your reply6 (offset caching live, `673296e`) — Qt re-test + the cold-first-seek question

## TL;DR

Caching works — **warm/repeat scrubs are now fast** (median ~0.3–0.7 s, 1 s seeks ~60–165 ms; was ~1.8 s).
Continuous direct seeks **land 99 % with zero re-opens needed**, so I made the watchdog a last-resort and
the **seek re-open rate → ~0** — the per-scrub re-open leak is gone, as you predicted. **The cold-first-seek
tail remains, and your diagnosis was the key:** it's the **cold BASE rendition** (S3 fetch, ~2–4 s on
backward/far seeks), **not** the offset step — so offset-prewarm won't move it; only broader base warming
will. That's a UX-niceness, not blocking — your call.

## 1. Post-caching Qt re-test (`WT_HERO_TEST`, continuous, on-screen)

**Latency — caching delivered on warm/repeat serves:**

| | post-cache | was (un-cached, reply5) |
|---|---|---|
| 1 s seeks | **~60–165 ms** | (slow) |
| most seeks (median) | **~0.3–0.7 s** | **~1.8 s** |
| cold tail (p90) | ~2.5 s | ~2.3 s |

**Pure-direct diagnostic (re-open DISABLED, 6 s timeout) — the clean truth:** direct seeks **land 99 %**
(1 % truly-stuck even at 6 s), **0 re-opens**. Continuous PTS removed the demuxer hang, so the watchdog was
never catching hangs — only catching *slow* seeks.

**Seek re-open rate:**

| config | re-open rate |
|---|---|
| un-cached (reply5) | ~18 % |
| post-cache, tight 2.8 / 4 s watchdog | 26–29 % (churning the cold tail) |
| **post-cache, 6 s last-resort watchdog** | **→ ~0 %** (only a genuine >6 s hang — ~never on continuous) |

So the **per-scrub re-open (and its ~8 MB/open Qt cost) → ~0** — the win, achieved by *trusting the direct
seek to land* instead of re-opening.

## 2. The cold-first-seek tail — YES it remains, and it's cold BASE (not the offset)

Your finding nailed it. The residual slow seeks (~2–4 s, variable) are **cold base renditions** — backward/
far seeks into regions the prewarm hasn't reached (it warms *ahead* of the playhead). Two consequences:

- **Offset-prewarm won't fix this tail.** Per your own measurement the offset remux is ~0.1 s once base is
  warm; the cost here is the BASE (S3 fetch + transcode). Pre-generating offset variants would shave ~0.1 s
  off an already-warm region, not touch the cold one.
- **Re-opening doesn't fix it either** (so we don't). A client re-open hits the *same* cold base — that's
  why the tight watchdog was counterproductive (re-opened cold-but-landing seeks for nothing). We now let the
  direct seek land in ~2–4 s.

The only lever that kills the tail is **warming base more broadly** — backward + a wider window around the
playhead, not just ahead. That's a bigger change than offset-prewarm, and it's UX-niceness on backward/far
seeks (not correctness, not the leak) — so **your call**. If you widen base prewarm we'll see it collapse
with no client change; if not, the client already degrades gracefully (lands in ~2–4 s, no re-open, no leak).

## 3. One honesty note on the leak

In our harness the seek re-opens were never the *dominant* RSS driver — the per-EVENT open (the Qt-internal
decode leak from our earlier letter) dominates and is unaffected by continuous. So the clean proof that
continuous removes the per-scrub leak is the **re-open rate → ~0** (each avoided re-open = ~8 MB not leaked
in a scrub-heavy session), not a big drop in the test's absolute RSS. The per-event Qt leak stays a separate
(Qt-upgrade) matter on our side.

## 4. Default flip (ask 2)

From our side: **GO to flip** — continuous is a clear win (freeze gone, warm scrubs fast, scrub re-opens
→ ~0). Flip whenever your hls.js browser sanity-check passes; we already opt in explicitly, so we have the
cached behaviour now regardless. 48 h cap still confirmed live.

## Over to you
1. **Cold-base tail:** your call whether to widen base prewarm (backward + wider window) — the only lever
   left, and it's UX-niceness, not blocking.
2. **Flip the default** after the hls.js check.

The Playback wall (`WT_SEEK_TEST`) gets the same wiring next on our side. Re-test logs:
`docs/perf/2026-06-28-continuous-postcache.*`.

— Watchtower client team
