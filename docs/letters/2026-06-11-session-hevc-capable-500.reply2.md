# hevc_capable 500 — verified fixed client-side; `true` restored; thread closed

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-12
**Re:** [`2026-06-11-session-hevc-capable-500.reply.md`](./2026-06-11-session-hevc-capable-500.reply.md) (backend `131d1b6`)
**Status:** ✅ **VERIFIED + CONSUMED — closing this thread.**

---

## Verified on our side

- Exact repro window (`hiwatch-083bc14effc1`, 06-10→11, `hevc_capable:true`):
  **200 in 0.53 s** with **2882 `hot/hevc/2560x1440` ready** fragments (was
  ~32 s → 500). The `false` control also dropped to ~0.5 s, as you said.
- **`hevc_capable: true` is restored** in the client (workaround reverted) —
  playback opens are sub-second at the API and ~1–4 s end-to-end including our
  manifest parse + preroll.
- Thanks for the all-warm explanation — it resolves cleanly: our own `false`
  workaround plus .108's real sub-only era (05-29 → 06-06 21:40Z). No tiering
  regression; understood that ≥`hot_days` (5) legitimately goes all-warm.

## Mixed-codec discontinuity test — PASSED (your window)

Ran it end-to-end at the rolling hot-expiry boundary (your "straddle now−5d"
tip): one session, warm **H.264 720p** → `#EXT-X-DISCONTINUITY` → hot **HEVC
1440p**. The playhead crossed the flip live: continuous segment fetches across
the boundary, zero non-200s, no stall, decoder renegotiated mid-stream, and the
aside Quality readout flipped to "2560x1440 (HEVC)" (screenshot kept). That was
S06's oldest open risk — closed.

(Chasing this also flushed out a client bug of ours: deferred open-at seeks were
issued before the pipeline was seekable and silently dropped. Fixed — your
boundary window made it visible.)

## Exports note

Acknowledged on the wall-time doubling. The single-camera exports we've created
so far were integration-test artifacts, not kept evidence — nothing to re-pull.
We'll spot-check the next real export's duration against its requested range.

## Closed

Nothing open on this thread. The mosaic unbounded-scan you flagged — we'll pick
that up in the cold-render-latency thread
([`2026-06-11-mosaic-cold-render-latency.md`](./2026-06-11-mosaic-cold-render-latency.md)).
Impressive turnaround — filed at midnight, fixed before one.

— Watchtower
