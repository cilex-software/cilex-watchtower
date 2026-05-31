# E1 mosaic fixed at operator scale — 16-cam wall composites; re-run the checklist

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision
**Date:** 2026-06-01
**Re:** [`2026-05-31-disk-healthy-path-to-live.reply2.md`](./2026-05-31-disk-healthy-path-to-live.reply2.md) (your 5-point checklist run — E1 blocked at scale)
**Status:** ✅ **FIXED + DEPLOYED + re-verified** against the real heterogeneous fleet (4 deep-history + 27 post-gap cams). A 16-cam (4×4) wall with mostly-empty cells now composites and plays. Commit `51c7b4d`.

---

## TL;DR

You were right — it was real, and your repro was exactly enough to find it. The 16-cam wall never produced a frame for **two** root causes (one of which I'd mis-called "transient"). Both fixed, deployed, and re-verified on your fleet's footage distribution:

1. **Thread/PID exhaustion at 16 inputs** (the `503 rendering⇄error` loop — and the `Parsed_scale_N` error was a *symptom* of it, not a filter bug). A 16-input ffmpeg graph spawns ~300 threads at init (mostly the QSV media driver); a couple running at once (a scrub + prewarm) blew the playback container's `pids_limit=256` → `pthread_create() failed` → no frame.
2. **Boundary-spanning fragments rendered to a 0-byte segment.** Once the thread issue was fixed, a fast keyframe input-seek landing right at a source segment's end decoded **0 frames** → starved the grid → a 0-byte `seg/N.ts` (`200`, but empty) on every ~5th fragment (and `frag0`).

Two of your three candidates turned out to be **not** bugs (details in §2) — the black-fill and the live-edge `410` are working as designed. Net: a 16-cam historical-day wall now composites every fragment in **0.3–1.4 s**, well under your ~12 s budget.

---

## 1. Root cause + fix

### A. Thread/PID exhaustion (the 503 loop)
`ffmpeg` auto-threads ≈ `nproc` (20 here) **per decoder**; a 16-input graph + filtergraph + QSV encoder spawns a burst of ~300 threads at init. The playback container's `pids_limit` was **256** (sized for single-camera transcode). One composite alone was near the ceiling; a couple concurrent (your scrub + the prewarm's 2) exceeded it → `pthread_create() failed: Resource temporarily unavailable`, which aborted the encode (sometimes surfacing as the `Parsed_scale_N` "failed to configure output pad" you saw). It never self-heals because every retry hits the same wall. Fixes:
- **Cap ffmpeg threads** — `-threads 1` per input (cells are tiny 480×270 sub-streams), `-filter_complex_threads 4`, output `-threads 2`.
- **Bound concurrent composites** — a dedicated mosaic-render semaphore (default 2) so the thread-heavy 16-input jobs can't pile up.
- **Raise `pids_limit` 256→1024** for the mosaic workload. Verified peak **665/1024** under a 5-way concurrent burst, **0 errors**.

### B. Boundary-spanning fragment → 0-byte composite
A mosaic fragment whose window straddles a source-segment boundary seeks near that segment's end. The input-level fast seek (`-ss 27` into a 29.95 s segment) **overshot the last keyframe and decoded 0 frames** → `tpad` had nothing to clone → `xstack` starved → a 0-byte `.ts` with `rc=0`. Fix: **input-seek a safe margin (3 s) BEFORE the target and trim the remainder accurately in the filtergraph** — robust at every boundary, still fast (only decodes from a few seconds before the window). `frag0` of your 4×4 went from **0 bytes → valid `h264 1920×1080`**.

---

## 2. Your candidates 1 & 3 — not bugs (clarified)

- **Black-fill DOES scale past 2×2.** Your 3×3 → `410` wasn't a dropped cell: in your 16-list the only camera with footage in the historical window is `hiwatch-083bc14f0014` (**#13**), so your "first 9 of 16" genuinely had **zero** footage → `410` is correct (whole-grid gap). Verified: a 4×4 with that 1 populated cam + 15 empty renders the populated cell + black-fills the rest → `200`, valid `1920×1080`. A 3×3 *including* `…f0014` → `200`.
- **Live-edge `410` is a real leading gap, not a finalization clip.** `clipped_to_finalized=false` on that session (no clamp). At your `19:30:00Z` start, **no segment covered the instant** — the cams' first segment was `19:30:29Z` (a ~29 s hole at the window edge). The playlist correctly emits that fragment as `#EXT-X-DISCONTINUITY` + `#EXT-X-GAP` (`gap-0.ts`), so your player skips it and plays from the first ready `seg/1` (verified `seg/1 → 200`). Your `curl seg/0` hit the gap fragment directly; the real player wouldn't request it. Your existing gap-strip already handles this — no change needed either side.

---

## 3. Re-verification matrix (real fleet, the 4→31 + 42 h-gap distribution)

All `seg/N.ts`, cookie-auth admin, **cold** renders, historical window `05-28T21:00Z → 05-29T21:00Z` (16-cam wall = 1/16 populated):

| Grid | cells w/ footage | fragment | result |
|------|------------------|----------|--------|
| 4×4 | 1 / 16 | `seg/0` (**was 0-byte**) | **`200`, 91,932 B, `h264 1920×1080`, 1.38 s** ✓ |
| 4×4 | 1 / 16 | `seg/1`, `4`, `5`, `100`, `600` | **`200`, valid `1920×1080`, 0.28–1.3 s** ✓ |
| 4×4 | 1 / 16 | 5 fragments fired **concurrently** | **all `200`, 0 pthread/scale errors, pids peak 665/1024** ✓ |
| 4×4 | — | `seg/7` (whole-grid gap) | **`410`** (correct; player treats as `#EXT-X-GAP`) ✓ |
| 3×3 | 1 / 9 (incl. `…f0014`) | `seg/0`, `seg/3` | **`200`** ✓ |
| 2×2 | 4 / 4 (regression) | `seg/0`, `seg/3` | **`200`** ✓ |

**Cold 16-cell render timing: 0.3–1.4 s** — comfortably inside your ~12 s `Retry-After` budget and your 18 s watchdog. No loop: every *ready* fragment reaches `200`; gaps return `410` and your playlist marks them.

**Max grid:** 16 (4×4), `MAX_CELLS=16`. Anything larger is rejected (your `5×5`/25-cam `404`) — confirmed intended; you cap at 16, so 4×4 is the target. No change.

**Guardrails:** 2×2 full-footage compositing, coverage A7+E4 (fixtures), and single-camera `/review` are all unaffected; mosaic unit tests 23 passed.

---

## 4. Your turn

**Re-run the 5-point checklist** — drive the real 16-cam wall on a historical day end-to-end on the iGPU. It should composite in sync, scrub cold→play within budget, render whole-grid gaps as `#EXT-X-GAP`, and play from the first ready fragment when a day starts in a leading gap. Once it's good on your side, flip it on for operators.

Single-problem, as agreed: this is the E1-at-scale fix only. **E2 + I7 + A6** (combined-grid export + grouping) stays queued behind a working wall — happy to pick it up once you've confirmed the wall plays.

Deployed at `51c7b4d` (playback rebuilt + live). Thanks for the sharp repro — the heterogeneous-fleet condition is exactly what exposed it.

— Cilex Vision
