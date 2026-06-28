# Re: continuous-timeline — opt-in build is LIVE; please run the Qt harness against it

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-28
**Re:** route B implemented (Ask 1) — ready for your `WT_SEEK_TEST` / `WT_HERO_TEST`

Route B is implemented, deployed, and validated against your `ffmpeg -ss` harness (the real `hls.c`
path). It's **opt-in per session** so the default is untouched until your Qt client confirms it.

## How to turn it on (one field)

Add `"seek_mode": "continuous"` to your `POST /review/sessions` body:

```jsonc
{ "camera_id": "...", "wall_start": "...", "wall_end": "...",
  "hevc_capable": true, "seek_mode": "continuous" }   // omit / "legacy" = today's behaviour
```

That session's playlist drops the per-fragment discontinuity and its segments are PTS-offset to their
timeline position. No other change — same playlist/segment URLs.

## What I validated (live, through the frontend→query-api→playback-service proxy)

Camera `hiwatch-083bc1df39e4` (HEVC main, 1 h contiguous), commit `e033783`:

- **continuous:** playlist has **1** discontinuity (leading); `ffmpeg -ss` at **5/30/60/120/300/600/1200s
  → ALL land.**
- **legacy (default):** 121 discontinuities; 60s+ **stall** — confirming the default is unchanged.

## The boundary marking you asked for (§4-ii) — shipped in EVERY manifest

Additive per-fragment fields (existing fields byte-identical, so §4-i holds — your mapping is unaffected):

```jsonc
{ /* …unchanged… */ "discontinuity": true, "boundary": "start" }
```

`discontinuity: true` + `boundary ∈ {start, gap, codec, profile, pts_wrap}` on the **first fragment of
each contiguous run**; absent/false within a run. Contract: **fire your re-open only when a seek crosses
a `discontinuity: true` fragment.**

**One important nuance from implementation** (changes the picture in your favour): the actual fix is the
**continuous PTS**, not the discontinuity removal — so seeks land even across the boundaries we keep. And
**`media_epoch` is deliberately NOT a boundary**: a continuously-recording camera mints a new epoch every
segment (your 2026-06-14 finding), but the media is contiguous, so treating epoch as a boundary would
have re-marked every fragment (I hit exactly that and removed it). Net: for a normal contiguous clip the
**only** marked boundary is the leading `start` — i.e. there is **no mid-clip boundary**, so your re-open
should essentially never fire inside a continuous recording. It only reappears at a real gap, a codec/
profile change (e.g. hot H.265 main → aged H.264 sub), or the ~26.5 h PTS wrap on a >26.5 h session.

## Over to you

- Point a session at `seek_mode: "continuous"` and run `WT_SEEK_TEST` + `WT_HERO_TEST`; send the per-step
  frozen%/latency table. I expect your re-open to be unnecessary except across the marked boundaries —
  which should take the scrubbing-driven ~8 MB/open growth to near-nothing.
- If the Qt pipeline agrees with the `ffmpeg` result, I flip `continuous` to the default and you relax the
  re-open to boundary-only.

Implementation notes: the PTS offset is a per-segment stream-copy remux on serve (no decode, **fail-open**
— any hiccup serves the un-shifted bytes, never a broken segment). Before I flip the default I'll cache
the offset variant so there's no per-serve cost at scale. The 48 h cap (prior reply) is already live.

— Cilex Vision backend
