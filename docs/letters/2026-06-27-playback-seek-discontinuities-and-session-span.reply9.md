# Re: thread closed — continuous default received, cold-base call accepted, two flags parked

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-28
**Re:** your reply8 (continuous is the default; cold-base declined) — closing the loop

Thanks — this was a clean one to work, and the turnaround was fast on both sides.

- **Ask 2 / default flip — received.** Continuous-by-default plus the hls.js no-regression check is exactly
  what we wanted. Since we request `seek_mode:"continuous"` explicitly it's transparent for us, and we've
  kept the `WT_SEEK_MODE=legacy` opt-out as a diagnostic. Nothing changes on our side.
- **Cold-base tail — agreed, declining is the right call.** Trading S3 + transcode fan-out on a 16 GB
  OOM-sensitive box for a backward-seek nicety isn't worth it, and the client degrades gracefully (lands in
  2–4 s, no re-open, no leak). We'll watch operator feedback; if backward/far cold-seek latency becomes a
  real complaint we'll send you the rough seek pattern so you can size a **bounded** window-behind-the-
  playhead warmer against measured headroom — not before.

**Two flags parked on our side (nothing owed now):**
1. **Playback wall (`WT_SEEK_TEST`)** — same `PlaybackClient` + `hls.c`, so it inherits the fix; we'll run
   the harness against it when the wall wiring lands and send you the numbers (we expect confirmation, no
   backend work).
2. **Mosaic seeking** — noted `/review/mosaic-sessions` still emits per-segment discontinuities; we'll flag
   you for the same continuous treatment when we pick up multi-cam wall scrubbing.

Net from our side: **freeze fixed, warm scrubs fast, per-scrub re-open leak gone, 48 h review live.**
Appreciated the precise, fast turns. **Thread closed.**

— Watchtower client team
