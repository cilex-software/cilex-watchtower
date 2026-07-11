# Measured: first-segment latency at fresh session offsets (the seek pattern you asked for)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-11
**Re:** the "bounded later lever" from the continuous-timeline thread — you asked us to
come back "IF operators complain about backward/far cold seeks, with the seek pattern."
Here it is, measured.

## TL;DR

A 2-day, ~2,400-cycle soak of the frame-by-frame review flow (open day → click a
fragment → step frames) pinned the last remaining latency class in playback review:
**the first segment served at a never-before-served offset of a fresh session takes
~2-4 s** (serve-time remux starting cold at that offset). Everything client-side
around it is now near-optimal, so this floor is yours if you want to lift it. Not
urgent — the operator experience is already bounded (~1.7-3 s worst case after our
mitigations) — but it is the single biggest remaining number in the review flow.

## The seek pattern (concrete, reproducible)

Operator gesture: open a day for review, click a fragment deep in the timeline
(anywhere not yet played), immediately inspect frame-by-frame. Our client issues:

1. `POST /review/sessions` for the day (or a ~30 min bounded window on heavy days) —
   fast (60-600 ms), fragments listed fine.
2. Playback starts at the session head — first frame in ~0.7-1.3 s. Good.
3. Click at offset T (e.g. 3.4 h into a light-day full-session, or minute 16 of a
   30-min window): demuxer requests the segment at T → **~2-4 s of nothing** unless
   that offset was served before (your offset-caching makes repeats fast: we
   measured 15-173 ms direct-seek lands on previously-served regions — that fix
   works). Fresh offsets are always cold, and a review shift hits mostly fresh
   offsets.

Distribution from the soak (fragment-click gesture, fresh offsets only):
- bounded 30-min sessions (.67 days): total picture gap ~2.0 s (was 5.7 s before
  our client fixes below)
- full-day sessions, deep offsets (.201 Jul 8): ~4.2-5.5 s → now ~1.7-3 s with the
  pre-emptive re-open (below)
- stored segments verified clean (ffprobe) — this is pure serve-path latency, not
  data damage.

## What we already did client-side (so you don't re-litigate it)

- Adaptive freeze-watchdog: 2.5 s (instead of 6 s) when the seek target is >60 s
  past anything rendered this session.
- **Pre-emptive re-open**: a target >5 min past anything rendered skips the direct
  seek entirely and re-opens the session AT the target — because a fresh session's
  first segment (your remux starts there) beats waiting for a cold mid-session
  segment. That's the tell: **re-open-at-offset ≈ 1-2 s, mid-session-at-offset ≈
  2-4 s** — the fast path exists in your stack already; it's just only reachable by
  opening a new session.

## The ask (bounded, pick your shape)

Make the mid-session cold-offset path as fast as your session-open path — options
we'd be equally happy with:

1. **Prioritized remux-at-offset**: when a segment request arrives for an offset far
   from the current remux head, restart/branch the remux at that offset (what a new
   session effectively does) instead of serving in sequence.
2. **First-N-segments prewarm at session open** for the *target* offset only (we
   always tell you where we'll land: our re-opens start ~15 s before the target) —
   no fleet-wide prewarm, no memory-budget blowup; strictly bounded to the session
   being opened.
3. Or bless the current shape as intended: we keep the pre-emptive re-open (it
   works), and you close this as by-design. We'd just like the choice to be
   deliberate.

Context for sizing: two review clients churning day-jumps produced zero backend
distress over ~6 h (your box rode through fine, including your own mid-soak
query-api deploy). Full soak chronicle in our repo:
`docs/perf/2026-07-10-fsoak-filmstrip-soak.md`.

— Watchtower
