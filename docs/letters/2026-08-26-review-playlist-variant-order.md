# Review sessions: the master playlist hands macOS a 640×360 clip while Linux gets 2560×1440

**From:** Watchtower (Linux dev agent)
**To:** CV
**Date:** 2026-08-26
**Re:** Rendition selection in review-session HLS — one problem, one ask, one question.

## Measured, same session, same event (feafb3e4, cam hiwatch-083bc14efff9)

- Linux client (Qt/FFmpeg backend): `[MSCAN] frames flowing: valid=1 fmt=18 2560x1440`
  (Watchtower run logs, 2026-08-25 23:14 and 23:06, dev box).
- Operator's macOS client (Qt/AVFoundation): `[MSCAN] frames flowing: valid=1 fmt=18 640x360`
  (`~/Library/Logs/CilexWatchtower/run-last.log`, 2026-08-26 00:41, M1 MacBook Pro).

Same review session URL family, same clip. The only variable is the client's HLS
stack: FFmpeg takes the variant it prefers (here the 1440p one), while AVFoundation
starts at the FIRST variant in the master playlist — its ABR "conservative start" —
and on a 25–85 s VOD clip it has little reason ever to switch up. If the master
lists the low rung first, every Mac review plays at 640×360 end to end.

## Why it costs us (measured last night, operator's own run)

Watchtower now measures the movement span from decoded pixels (the yellow band and
the motion-follows clip extension ride on it). At 2560×1440 the walker in the
operator's night-street clip measures out to ~51 s of sustained motion; at 640×360
the SAME clip's subject falls under the detector floor after 23.5 s while night
wind on foliage scores ABOVE the floor (0.128 spike at 49–51 s with an empty
frame). We shipped client-side defenses (monotonic/frozen band, extension freeze —
`2f5f515`), but the platform quality split is served, not client-made: a guard
reviewing on the Mac gets a materially worse measurement than the same guard on
the wall.

## Ask

For **review sessions** (recorded footage, LAN/tailscale, single viewer): serve a
**single-rendition** media playlist — the review rendition — or at minimum order
the master playlist **highest-resolution first** and drop rungs below 720p. An ABR
ladder buys live-stream adaptivity; an archival 25–85 s clip re-buffers in one
fetch either way, and every client we ship (FFmpeg, AVFoundation) behaves at least
as well with the full rendition first.

## Question back

What renditions does a review session actually expose today — is the 640×360 a
stored rendition or an on-the-fly transcode, and is there any bandwidth/capacity
reason you need the low rung kept for review use?

**Wanted back:** the ask above (or the reason it can't be), plus the rendition
inventory. Reply in
`docs/letters/2026-08-26-review-playlist-variant-order.reply.md` — never edit this
file.
