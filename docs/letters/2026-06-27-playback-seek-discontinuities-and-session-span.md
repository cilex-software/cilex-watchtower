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
below blocks us** — but the workaround costs UX (it re-centres the scrubber) and, we've since found, also
**multiplies a client memory leak** (see the **2026-06-28 update** at the foot of this letter — it raises
the value of Ask 1), and the root cause lives in the manifest. Ask 1 is the root fix; Ask 2 is a related
limit we hit while testing it. Neither is urgent.

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

## Update (2026-06-28) — Ask 1 now also relieves a client memory leak

Since shipping the seek workaround we ported it to the Triage event-hero player and stress-tested both
(random events + ±1 s…±5 m scrubs, hundreds of jumps, with `/proc` RSS sampling). That surfaced a second,
independent reason the continuous-timeline manifest matters — **the re-open workaround multiplies a client
memory leak.**

The Watchtower client has a Qt-FFmpeg decode-context leak of **~8 MB every time a review-session HLS is
opened** (`player.source` set). We bisected it (open-only loop):

| variant (open a session repeatedly) | client RSS slope |
|---|---|
| open **+ decode** | **+66 MB/min** (~8 MB per open) → 1.2 GB in ~12 min |
| open the session but **skip the decode** | **flat (−0 MB/min)** |
| open + decode, **destroy + recreate the player** each time | still **+59 MB/min** |

Two things follow, and both matter for this letter:

- **It is NOT the session/manifest/HLS-proxy/HTTP path** — opening sessions without decoding is flat. So
  this is not a backend bug, and `DELETE /review/sessions` (which we don't yet call) would **not** reduce
  the client's RSS. We mention it only so it's clear we're not asking you to fix a leak — we're asking for
  fewer *source-changes*.
- **It's a Qt-internal per-source-change leak we cannot fix client-side** — freed by neither clearing the
  source nor destroying the player (both tested). On its own it's a slow burn: one open per event an
  operator reviews. **But the seek workaround re-opens a session on every far scrub**, so *with* the
  workaround, scrubbing a clip leaks ~8 MB per jump and a few minutes of active review pushes the client
  past 1 GB.

A continuous-timeline manifest closes this: a mid-session seek would land **without re-opening**, so there
are no per-seek source-changes and the scrubbing-driven leak disappears. (The residual one-open-per-event
remains — that's on us / a Qt upgrade.)

**Net:** Ask 1 now buys two things — it retires the scrubber-shrinking workaround **and** removes the
largest contributor to client memory growth during review. No change to the ask itself; we just wanted you
to know the continuous manifest is worth more than the UX polish it originally targeted.
