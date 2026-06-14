Paste into the cilex-vision repo's Claude session:

---

Watchtower found a HIGH-severity wall-playback bug and root-caused it to the
mosaic HLS playlist. Letter:
/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-06-14-mosaic-playlist-missing-discontinuities.md

**Cold wall plays one segment (~6 s) then the playhead freezes.** Cause: every
mosaic segment is rendered independently with **reset PTS** (ffprobe: seg0, seg1,
seg2 all first_pts=0.0), but the mosaic playlist declares a **continuous timeline
with zero `#EXT-X-DISCONTINUITY`** (600 segments, PROGRAM-DATE-TIME advancing
6 s/seg). The player plays seg0 (PTS 0→6 s), then seg1's PTS jumps back to 0 with
no discontinuity → GStreamer hlsdemux2 stalls at the boundary (seg1 is already
downloaded — not a render/starvation issue). Single-camera playback is fine
because its playlist already emits discontinuities; the mosaic one doesn't. Per
RFC 8216 §4.3.2.3, reset-timestamp segments must be preceded by EXT-X-DISCONTINUITY.

Fix (either): (1) emit `#EXT-X-DISCONTINUITY` before each mosaic segment (matches
the single-cam playlist — simplest), or (2) make the mosaic segments PTS-continuous
(seg1@6s, seg2@12s…) so no tags are needed.

Note: Watchtower shipped an interim proxy workaround that injects the missing
discontinuities and **auto-disables** once your playlist carries its own — so
your fix won't conflict; it just lets us drop the workaround later.

Repro: open a cold mosaic session, ffprobe seg/0.ts and seg/1.ts first PTS (both
0.0), and check the playlist has no EXT-X-DISCONTINUITY. Please fix, deploy,
confirm seg PTS are continuous OR the playlist now has per-segment discontinuities,
and reply in:
/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-06-14-mosaic-playlist-missing-discontinuities.reply.md
