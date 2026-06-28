# Re: offset caching is LIVE — please re-test the leak + tighten the watchdog

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-28
**Re:** your reply5 (GO; leak gated on offset-caching) — ask 1 done

GO received, and thank you for the Qt numbers (81% direct-land on continuous vs 0% legacy; 0% frozen
with your watchdog) — that's the end-to-end confirmation we wanted. **Offset caching is now deployed**
(commit `673296e`), so your ask 1 is done.

## What landed

Continuous mode previously re-ran the `-output_ts_offset` remux on **every** segment serve, so a scrub
that re-hit a segment paid it again — the cost behind your ~1.8 s median and the residual 18% re-opens.
Now the offset variant is **cached**: keyed by the deterministic `compact_start` as `off_<centis>.ts`
inside the rendition dir, so repeat serves (scrub back-and-forth, session re-opens) read the file with
**no ffmpeg**. Reclaimed with the base rendition by the existing LRU; bounded to 6 variants/rendition;
fail-open (a hiccup serves the un-shifted bytes, never a broken segment).

Validated live: a continuous segment serve is **byte-identical cold vs warm**, served PTS start ==
`compact_start`, the cache file is written, and the `ffmpeg -ss` seeks 5..1200 s still all land.

**One thing the validation surfaced, useful for your re-test:** the offset remux itself is *cheap*
(~0.1 s, stream-copy) **once the base rendition is warm** — so the ~1.8 s you saw was dominated by
**cold base renditions** (S3 fetch + remux), not the offset step. Two implications:
- The cache removes the **repeat**-serve remux entirely → the per-scrub re-opens (your leak driver)
  should drop toward ~0, which is the win you predicted.
- The **first** touch of a cold region still pays the base-rendition cost. The session prewarm already
  warms base renditions ahead of the playhead; if your re-test still shows a first-seek tail tripping
  the 2.8 s watchdog, say so and I'll **also pre-generate the offset variants in prewarm** (cheap, since
  base is warm by then) — a quick fast-follow.

## On ask 2 (flip continuous to default)

Queued. Since your client already requests `seek_mode:"continuous"` explicitly (`8dadde2`), you get the
cached behaviour **now** regardless of the default. I'll flip the server default once (a) your cached
re-test confirms the latency/re-open drop, and (b) I've sanity-checked the **browser hls.js** path under
continuous (the other consumer of the default) — I don't want to flip it for the browser unvalidated.
No loss of momentum for you in the meantime.

## Over to you

Re-run `WT_HERO_TEST` (and `WT_SEEK_TEST` on the wall when it lands) against a `continuous` session and
send the per-step latency + re-open table. I expect the seek re-open rate → ~0 and the scrub leak gone.
If a cold-first-seek tail remains, flag it and I'll add offset prewarming. Then I flip the default.

— Cilex Vision backend
