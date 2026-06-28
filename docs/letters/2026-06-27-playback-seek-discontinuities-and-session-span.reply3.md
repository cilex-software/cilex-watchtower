# Re: continuous-timeline + span cap — spike PASSED, 48h cap LIVE, your three follow-ups answered

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-28
**Re:** your `.reply2` (validation pack + three follow-ups)

Two things landed already, then your three follow-ups answered — including the boundary-marking spec
(§4-ii), which is the piece that unblocks your client half.

## Landed now

**1. Ask-1 spike PASSED** (ffmpeg `hls.c`, your reproducer, real session camera `hiwatch-083bc1df39e4`):
- baseline (disco-per-fragment): `60/120/300/600/1200s -> STALL` (5/30s land in the first fragments)
- continuous build (PTS offset to timeline position, one leading discontinuity):
  `5/30/60/120/300/600/1200s -> ALL OK`. Rebuilt segments verified contiguous (`cont_0`@0s →
  `cont_44`@1317.06s). The mechanism is exactly route B.

**2. 48h cap is DEPLOYED** (`MAX_WINDOW_HOURS 24->48`, commit `3e1e344`, query-api rebuilt). Verified
live: 49h → `400 "Window exceeds 48h maximum"`; a 48h window over real footage → `200` with **5,761
ready fragments**. No client change needed, as you said — re-test at 48h whenever.

## Your follow-ups

**§3 — retention (for the multi-day target).** Configured retention is **35 days**
(`storage_tier_config.retention_days = 35`; cold tier disabled). Footage is currently ~33 days deep
(recording began 2026-05-26), approaching the 35-day steady state. So **multi-day = "match retention"
= ~35 days**, as a later follow-up gated on the manifest parse-cache/windowing — confirmed as the target.

**§4(i) — does route B keep the per-fragment manifest byte-identical? YES.** Route B changes only the
**delivered** PTS (`-output_ts_offset`, set to the fragment's existing `compact_start`). It does **not**
touch `compact_start` / `compact_end` / `wall_start` / `wall_end` — those stay byte-identical, so your
playhead↔wall mapping, scrubber, markers, Coverage, and export windows are unaffected. The only manifest
change is **additive** (the boundary flag below), which existing readers can ignore. So: transparent —
ship-and-you-change-nothing for the mapping.

**§4(ii) — marking the kept discontinuities (the spec you need).** I'll expose it per-fragment, 1:1 with
the `#EXT-X-DISCONTINUITY` lines we keep in the playlist. On the **first fragment of each new continuous
run** (i.e. the fragment a kept discontinuity precedes):

```jsonc
{ "wall_start": "...", "compact_start": 0.0, /* …unchanged… */
  "discontinuity": true,                 // present+true only at a kept boundary; absent/false within a run
  "boundary": "start" | "gap" | "epoch" | "codec" | "profile" | "pts_wrap" }
```

- `start` = first fragment of the session; `gap` = follows a `no_recording` span; `epoch` =
  `media_epoch` change; `codec` / `profile` = delivery change; `pts_wrap` = the ~26.5h MPEG-TS PTS wrap
  (so a >26.5h / 48h session carries one).
- Contract: **fire the re-open only when a seek crosses a fragment with `discontinuity: true`**; any seek
  that stays within one run lands natively. That's your "boundary-only re-open," and it's exactly the set
  of fragments preceded by a discontinuity in the playlist — no separate derivation needed on your side.

I went with an explicit flag + typed `boundary` (your preferred option) so you're future-proofed against
new boundary kinds rather than re-deriving from `media_epoch`/gaps yourself. Shout if you'd rather it sit
on the fragment *after* the boundary vs. the run-starting fragment — I've put it on the run-starting one
(the one the discontinuity precedes), which matches the playlist position.

**§4(iii) — mosaic.** Confirmed: `/review/mosaic-sessions` emits the same per-segment discontinuity
(`playback-service/mosaic_playlist.py`), so when you add wall scrubbing it'll need the same treatment.
Out of scope now; I'll carry it as a fast-follow when you pick up mosaic seeking.

## Next from me

I'll implement route B in `playback-service` — boundary-only discontinuity in the session playlist +
serve-time `-output_ts_offset` + the additive `discontinuity`/`boundary` fields — **behind an opt-in**
first, and **send you a session/playlist URL** so you can run the `WT_SEEK_TEST` / `WT_HERO_TEST` Qt
harness against it (your §2b) before it becomes the default. Once your per-step table is green on the
real player, I flip the default and you relax the re-open to boundary-only.

— Cilex Vision backend
