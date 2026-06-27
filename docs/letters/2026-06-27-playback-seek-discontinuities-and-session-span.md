# Playback seeks stall across HLS fragment discontinuities + the review-session span cap

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-27
**Re:** why far playback seeks froze the video, and the ~24–36 h ceiling on review-session span

## How to read this letter

One area (the `/review/sessions` HLS), two asks. We found and **client-side worked-around** a real
defect: seeking the playback player to any target outside the playout buffer **froze the video** (the
playhead moved but no frame ever rendered). We traced it to the session manifest being a chain of
per-fragment `EXT-X-DISCONTINUITY` segments, which Qt's FFmpeg HLS demuxer cannot seek across. We've
**shipped a workaround** (commit `fb9efa8`: far seeks re-open a short window at the target), so **nothing
below blocks us** — but the workaround costs UX (it re-centres the scrubber), and the root cause lives in
the manifest. Ask 1 is the root fix; Ask 2 is a related limit we hit while testing it. Neither is urgent.

## TL;DR

1. **The session HLS is a chain of discontinuous fragments, and seeking across them stalls the player.**
   Each ~30 s fragment carries its own `EXT-X-PROGRAM-DATE-TIME` + `EXT-X-DISCONTINUITY`. A seek to an
   un-buffered position (any jump beyond ~20–30 s) leaves the demuxer stuck — position updates, the
   player reports *Playing / BufferedMedia*, but **zero frames render** (confirmed to 45 s). Can the
   manifest present a **continuous timeline** for a contiguous recording span (drop the per-fragment
   discontinuity where the media is actually continuous), or is there a seek/manifest mode you'd
   recommend so a mid-session seek lands without re-opening?
2. **`POST /review/sessions` won't assemble a span beyond ~24–36 h.** A 24 h window returns the full set
   (2 879 fragments); 36 h / 48 h / 72 h / 240 h come back **empty** — even though footage clearly exists
   ≥ 4 days back (1 h windows starting 30 h / 48 h / 96 h ago all return fragments). Is the cap an
   intentional guard (fragment count? manifest size?), and **what is the supported maximum** — i.e. can
   we offer multi-day review, or should we design the client around a fixed ~24 h ceiling?

## Evidence

**Ask 1 — the freeze.** Driven with an instrumented seek harness (camera `.108`, HEVC 2560×1440 main),
timing each seek *command → actual frame update* off the video sink:

| jump | result |
|---|---|
| 1 s / 10 s (in-buffer) | render in ~30–100 ms |
| 30 s, 1 m, 5 m, 10 m, 20 m, … | **no frame in 45 s — frozen** |

Reproduced **on the real display and in a normal 1 h session** (not just our 24 h test session). The
FFmpeg HLS log shows the cause — a wall of `Skip ('#EXT-X-DISCONTINUITY')` / `#EXT-X-PROGRAM-DATE-TIME`
between every fragment. Continuous *playback* is fine (it walks the discontinuities); only *seeking*
across them stalls. Our client workaround re-opens a short ~30 min session starting just before the
target (the target then sits near the start of a fresh short HLS and renders) — exactly what the event
hero already does. It works, but it shrinks the scrubber to that window; a continuous manifest would let
us keep the full-session timeline and drop the workaround.

**Ask 2 — the span cap.** Same `POST /review/sessions {camera_id, wall_start, wall_end, hevc_capable}`:

| requested span | result |
|---|---|
| 1 h | 119 fragments |
| 24 h | 2 879 fragments (continuous) |
| 36 h / 48 h / 72 h / 240 h | **empty manifest** |

…while a 1 h window *starting* 96 h ago still returns 121 fragments. So footage retention is ≥ 4 days, but
a single session can't span it.

## What we need

1. Either a continuous-timeline manifest for contiguous spans, or your recommended way to make
   mid-session seeks land — so we can retire the re-open workaround and keep the full scrubber.
2. Confirmation of the intended maximum session span (and whether multi-day review is on the table).
