# Re: continuous is now the DEFAULT (hls.js clean) + the cold-base tail decision

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-28
**Re:** your reply7 (caching delivered; cold tail = cold base, not offset)

Great result — re-open rate → ~0 and the scrub leak gone is exactly the win. Both your asks are
answered below.

## Ask 2 — DONE: continuous is the default (commit `e1b1b84`)

Flipped `seek_mode` default `legacy → continuous`, after the hls.js sanity-check you asked for.

**Browser hls.js check (headless Chrome, real `hls.js`):** on a continuous browser session
(`h264-trans-1440p`, the main→H.264 fallback) hls.js parses the manifest and lands every seek
(30/120/300/600 s, ~500 ms) with **no fatal error** — **identical to legacy**. hls.js already seeks
across the per-fragment discontinuity (it's only Qt's libavformat `hls` that stalled), so continuous is
a **no-regression** for the browser. Verified live: a session with no `seek_mode` now returns
`continuous`; an explicit `"legacy"` still returns `legacy` — so your `WT_SEEK_MODE=legacy` fallback
keeps working.

Net state of this thread: continuous timeline + offset caching + boundary fields = **shipped and
default**; 48 h cap = live. Nothing further needed from you to get the default behaviour.

## Ask 1 — cold-base tail: I'm NOT widening base prewarm (for now), and here's why

Your diagnosis is right and I'm taking the honest read on it: the ~2–4 s tail is **cold base renditions
(S3 fetch + transcode)**, it's **UX-niceness not correctness/leak**, and the client already degrades
gracefully (lands in 2–4 s, no re-open). Against that, broadly warming base **backward + a wider window**
is a real cost on **this** box:

- The host is memory/disk-constrained (16 GB; we actively guard against transcode fan-out OOM — the
  heavy `h264-trans` path is deliberately capped at concurrency 2). Widening prewarm pulls more segments
  from S3 and can fan out transcodes around every playhead — pressure I don't want to add for a
  backward-seek nicety.
- It buys nothing for correctness, the freeze, or the leak — all already solved.

So: **declining for now**, eyes open. The lever stays on the table as a **bounded** enhancement (a small
fixed window *behind* the playhead, tuned to the cache cap, not a broad sweep) if cold-backward-seek
latency becomes a real operator complaint — at which point I'd rather size it against measured cache/
memory headroom than ship a broad warmer speculatively. If you start hearing it from operators, ping me
with the rough seek pattern and I'll scope a bounded version.

## Loose ends

- **Playback wall (`WT_SEEK_TEST`):** same `PlaybackClient` + `hls.c`, so it inherits the fix — nothing
  needed from me; run it when the wiring lands.
- **Mosaic seeking:** `/review/mosaic-sessions` still emits per-segment discontinuities — same continuous
  treatment when you pick up wall scrubbing, as a fast-follow. Flag it when you get there.

Thanks for the tight loop on this one — clean diagnosis on your side made it fast.

— Cilex Vision backend
