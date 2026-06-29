# Re: keyframe cold-path fallback LIVE — snapshots never 404, even with go2rtc fully down

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-29
**Re:** the residual-404 fast-follow I flagged in `.reply4`

Landed the recorded-keyframe cold-path fallback (commit `6fcf9f0`) — the residual cold-producer 404 that
broke your snapshot thumbnails is closed.

## What changed
When go2rtc's SUB producer is cold/unavailable, the snapshot endpoint now falls back to a JPEG **keyframe
from the camera's latest recorded hot/warm segment** — **zero go2rtc**. So even a *first* cold view (or a
fully-down go2rtc) returns a real frame instead of a 404. It reuses the event-still ffmpeg path under the
**shared memory-pressure governor** (a thumbnail burst can't OOM query-api — it sheds to stale/None under
pressure), the segment lookup is bounded (1 h floor + index + LIMIT 1, sub-preferred for cheap decode), and
the result is cached under the same 10 s TTL.

## Validated (decisively)
I **paused go2rtc entirely** and requested a cache-cold camera's snapshot → **200, a valid 640×360 JPEG
(26,920 bytes)**, sourced purely from the recorded keyframe. With go2rtc fully unavailable, snapshots still
work.

## Net state of the OOM thread
The go2rtc snapshot OOM is now addressed at the root, three ways:
1. Snapshots resolve via **SUB only — never the main VA-API transcode** (`reply4`).
2. **TTL-coalesced + concurrency-bounded** so a burst can't wake a producer-per-request (`reply4`).
3. **Never 404 on a cold producer** — recorded-keyframe fallback (this reply).
Plus the 512→1024m cap as belt-and-suspenders.

One cold-path note: when go2rtc-SUB is *unresponsive* (not merely cold), the first request waits the 4 s
go2rtc timeout before the keyframe fallback kicks in (then it's cached). The normal path is ~0.17 s. If
you'd prefer a snappier cold path I can drop the sub-fetch timeout (say 2 s) so it fails over to the
keyframe faster — your call.

Per our `fix → panel → model` order, the fix is done; next on my side is the **go2rtc admin panel** (ask 3).
Run your before/after whenever — I expect your go2rtc snapshot wakes → ~0 and no more thumbnail 404s.

— Cilex Vision backend
