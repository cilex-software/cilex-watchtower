# Motion-clip playlist discontinuities — FIXED; seek keyframe interval — root-caused, needs a storage call

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision (backend)
**Date:** 2026-06-14
**Re:** `2026-06-14-motion-clip-playlist-discontinuities.md` (BLOCKER) + `2026-06-14-playback-seek-keyframe-interval.md`
**Status:** **#1 ✅ FIXED + DEPLOYED + VERIFIED** (commit `3c0fb32`). **#2 root-caused — it's the camera's GOP, not a separate review encode; see the trade-off below.**

---

## #1 — Motion-clip playlist discontinuities — FIXED

Your diagnosis was exactly right, and it's the single-camera twin of the mosaic
fix (`0d71c0d`). Confirmed against `.106`'s actual renditions: recorded playback
**always remuxes** (stream-copy — "recorded playback never transcodes"), and
ffprobe shows every segment resets PTS to `1.400` independently (seg0 and seg1
both). The single-camera playlist was emitting `#EXT-X-DISCONTINUITY` only at
media-epoch boundaries — continuous cameras happened to get one per segment
(their segments differ in epoch), but a motion clip's segments share one epoch,
so none were emitted → `hlsdemux2` stalled at the seg→seg PTS jump-back.

Now it emits `#EXT-X-DISCONTINUITY` before **every** review segment (RFC 8216
§4.3.2.3). Verified live:
- `.106` motion clip: **13 discontinuities / 13 segments** (+1 for the leading gap).
- `.108` continuous: **5 / 5** — no regression.

Please re-run `playback-smoothness-test.sh` against the raw `playlist.m3u8`; it
should report 0 freezes. You can drop your client-side discontinuity injector.

## #2 — Seek keyframe interval — root cause, and why "review-only" isn't cheap

You're right about the cause, but the fix lands in a different place than the
letter assumed. There is **no separate review rendition to re-GOP**: the HEVC
review tier is a **stream-copy remux of the recorded main stream**, so its
keyframe interval *is the camera's*. ffprobe on the cameras confirms it:

```
.106 / .108 main: H.265, 15 fps, GovLength=50  → keyframe interval 3.33 s
```

So the only two ways to get ~2 s for review are:
1. **Shorten the camera's I-frame interval** (ISAPI `GovLength` 50 → 30 = 2.0 s).
   This is the cheap, correct fix — but it changes the **recorded** stream (and
   the live RTSP), not review-only, because recording is stream-copy. Cost:
   more I-frames → a modest recording-size increase (small in absolute terms at
   our ~250 kbps measured bitrates; live actually benefits — faster keyframe =
   faster live start). It also shortens GOP for **trimmed export** (your noted
   "same root cause") for free.
2. **Re-encode the review rendition** with a short GOP — defeats the cheap-remux
   design (iGPU/CPU on every reviewed segment) and we'd avoid it.

We're going with option 1, but it's a recording/storage trade-off, so it's
getting an explicit decision on our side (interval: 2.0 s vs 1.5 s) before we
push `GovLength` to the fleet over ISAPI. I'll confirm here once it's applied and
ffprobe shows ~2 s spacing. No client change needed.

## Optional — large cold segments

Agreed it's not blocking, and your proxy prefetch/caching is the right client-side
mitigation. A backend warm-cache is plausible later; not prioritising it now.

— Cilex Vision
