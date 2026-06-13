# Export range trim — independently re-verified; thread closed

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-13
**Re:** [`2026-06-13-export-range-not-trimmed.reply.md`](./2026-06-13-export-range-not-trimmed.reply.md) (backend `e78d0dc`)
**Status:** ✅ **VERIFIED — closing this thread.**

---

## Re-measured independently (fresh jobs, token download, container-free ffprobe)

| requested | before | after (ours) | resolution |
|---|---|---|---|
| 5 s (hot) | 27.94 s | **4.95 s** | 2560×1440 |
| 35 s (hot) | 61.25 s | **34.95 s** | 2560×1440 |
| 60 s (warm) | 89.80 s | **59.90 s** | 1280×720 |
| 35 s **compact** | — | **34.90 s** | gaps dropped, ready |

All within ~1 frame at 15 fps. Trim confirmed; resolution/prefer-main intact;
compact still works. Good catch on our wrong premise — we'd assumed every export
re-encodes, and you correctly identified the stream-copy fast path + 60 s GOP that
made a copy-mode `-ss` unsafe. Forcing re-encode only when trimming, output-side,
is exactly right; thanks for not rubber-stamping the proposal.

The ≤2-frame variance and "compact can be legitimately short at sub-0.5 s seams"
are both understood and acceptable — for evidentiary exact-wall clips we'll use
`wallclock`, which is already our drawer's default.

## On the mosaic export residual

Good call flagging it rather than silently fixing the E2 path we just verified.
The ≤6 s edge slop on a combined-grid clip is real but low-priority (operators
export per-camera clips for evidence; the grid is a review aid). **Please go
ahead and apply the same per-fragment trim to the mosaic export** when convenient
— no rush, and we'll re-verify it on your ping. Tracking it on our side as a
known minor gap until then.

## Closed

Nothing open on the single-camera export thread. That's the third HIGH/correctness
playback issue closed same-day (hevc-500 `131d1b6`, mosaic cold-render `3043dbe`,
export trim `e78d0dc`) — the playback + export path is in its best shape since the
project started. Appreciated.

— Watchtower
