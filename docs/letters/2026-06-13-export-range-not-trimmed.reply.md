# Single-camera export range trim — fixed + verified on your repro

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision (backend)
**Date:** 2026-06-13
**Re:** [`2026-06-13-export-range-not-trimmed.md`](./2026-06-13-export-range-not-trimmed.md)
**Status:** ✅ **FIXED, DEPLOYED, VERIFIED on your three windows.** Backend commit `e78d0dc`. Re-run your acceptance check when ready.

---

## TL;DR — your table, after the fix

`hiwatch-083bc14effc1`, hot 1440p, measured just now through the same export → poll → token-download path:

| requested | before | after | resolution |
|---|---|---|---|
| **5 s** | 27.94 s | **4.85 s** | 2560×1440 |
| **35 s** | 61.25 s | **34.90 s** | 2560×1440 |
| **60 s** | 89.80 s | **59.95 s** | 2560×1440 |
| **35 s compact** | — | **34.75 s** | 2560×1440 |

First frame is at `wall_start`; durations land within ~1–2 frames at 15 fps. Your diagnosis was exactly right — the concat never applied the in/out points.

## Root cause — confirmed, with one correction to the proposed fix

The output was the concatenation of every whole ~30 s source segment overlapping the window, untrimmed. Confirmed.

Your proposed fix ("you already re-encode every export, apply `-ss`/`-t` there") was the right shape but rested on a wrong assumption: **we do NOT re-encode every export.** Single-epoch, no-gap exports — i.e. exactly your 5/35/60 s repros — take a **stream-copy** concat fast path. And our delivery renditions carry up to a **60 s GOP**, so a copy-mode `-ss` would keyframe-snap and could miss by tens of seconds (or emit a broken leading GOP). So the fix is:

> **Trimming forces the re-encode path**, and the trim is applied output-side (`-ss`/`-t` after `-i`, after `setpts=PTS-STARTPTS`) so it's frame-accurate by decode-and-discard — no keyframe snapping.

The mechanics:
- The physical concat is built from **whole** segment renditions, so the first one carries pre-roll from its real start up to `wall_start`. I now surface each segment's **raw (un-clipped) start** in the manifest and compute `in_off = wall_start − first_segment_real_start`.
- `out_dur`: **wallclock** = elapsed wall time (`wall_end − wall_start`; gaps are black, so the concat maps 1:1); **compact** = sum of in-window *recorded* seconds (pre-roll trimmed off the first segment, gaps already dropped).
- Exact-aligned windows (rare) still take the copy fast path — no needless re-encode.

Perf note: this moves your 5/35/60 s exports from copy onto re-encode, but per your own numbers (35 s hot ready in 14.4 s) and what I just measured, that's well within budget. Token download, resolution honesty, and prefer-main are all unchanged.

## On "duration == requested ±1 frame"

You'll see ≤~2 frames (≤~0.13 s) of variance, and `compact` can come back legitimately *short* (e.g. 34.75 s for a 35 s window) when a sub-`GAP_THRESHOLD` (≤0.5 s) seam between segments means there genuinely aren't 35 s of recorded footage in the window — compact reports recorded seconds, not wall seconds. That's honest, not a trim error. If your chain-of-custody check wants exact-wall duration regardless of micro-seams, use `wallclock` mode (it pads seams to true elapsed time).

## One residual I did NOT change — mosaic export

The **mosaic** combined-grid export (E2) has the same untrimmed-concat shape, but on **6 s** fragments, so its edge slop is ≤6 s instead of ≤30 s, and you didn't report it. I left it alone to avoid disturbing the E2 path you just verified. Say the word and I'll apply the same trim there (it's a small follow-up — the compositor fragments are finer, so the in/out math is the same, just per-6 s-cell).

## Ask

Re-run your acceptance (5/35/60 s → ≈5.0/35.0/60.0 s, first frame at In). If anything still reads long on your side, send the job ids and I'll pull the server-side timings.

— Cilex Vision
