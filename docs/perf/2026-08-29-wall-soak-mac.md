# 16-camera playback-wall soak — Mac client, 6 h vs the pilot (2026-08-29 03:45–09:45)

Operator order executed with a Mac-written implementation of the ordered
tool (the canonical `tools/wall-soak.py` landed from the Ubuntu box the same
night, `8a249e5`, colliding in flight — the box tool is canonical for future
runs; the EXACT script behind this run is preserved as
`tools/wall-soak-mac.py`). The twin's run is separate and NOT summarized
here.
The grid is DERIVED from `/recording/segments`: every camera on a wall
provably had continuous footage (gap ≤ 3.0 s) across its 90 s window, so a
dark cell is a defect, never an armed-but-silent camera. Writes were mosaic
create/prewarm/delete only. One session in flight; every session disposed.

## Headline numbers (all measured; raw JSONL in `scratchpad/wall-soak/`)

| metric | value |
|---|---|
| cycles / full-16 walls | **136 / 136** — every session returned 16 cells |
| distinct windows exercised | 115 (evening/night strips; see boundary) |
| create → 200 | med **376 ms**, p95 1,773 ms, max 5,696 ms |
| prewarm → segment served | med **4,689 ms**, p95 8,823 ms, max 10,890 ms |
| cold GET before prewarm | **503 on 136/136 (100 %)**, med 104 ms — the known `ready` ≠ servable gap, now with an exact rate |
| 503 AFTER prewarm-poll | **0** |
| 0-byte segments | **1** (cycle 129 — root-caused below) |
| backend-unavailable events | **0** (no 0/502/504, no restart artifacts) |
| leaked sessions | **0** (136 disposes OK + all investigation sessions) |

## The defect that matters — CORRECTED same day: the ARMED-CAMERA class blanks walls, not one camera

> **Correction (operator's challenge, same morning):** 44b2d is an ARMED
> camera; its "12 s hole" is a normal inter-episode gap, and my claim that it
> "passed 100+ cycles" was false — it was placed exactly once, and failed.
> Generalization probe: a second armed camera, different window, also 0-byte.
> Armed placements 2/2 fail; continuous-only walls 135/135 clean. The soak's
> continuity bar admits armed cameras so rarely that a CLASS defect looked
> like a 1-in-136 fluke; 67 armed cameras are in the fleet. Details + the
> withdrawn lines: the letter's CORRECTION & ESCALATION section.

Cycle 129 (window `04:31:55Z`+90 s) served fragment 0 as **HTTP 200 with a
0-byte body** after an honored prewarm; fragment 1 of the same session was a
healthy 1.3 MB. Investigated live, one variable at a time:

1. Reproduced with the same window+cams — deterministic (200/0-byte again).
2. Window+60 s and camera-swap probes ALSO 0-byte → not that exact window
   edge, not the first-suspected camera.
3. Different-window controls concurrently CLEAN (soak cycles 130–132 and a
   05:00Z probe, 592 KB) → not a server-state latch. My mid-investigation
   "regression switched on" model was WRONG and is corrected here: the
   failure is **data-locked**, not time-locked.
4. Binary search over the 16 cameras at the poisoned window → culprit
   **`hiwatch-04eecdd44b2d`**: culprit + known-good pair → 0 bytes;
   control pair without it → 598 KB.
5. The culprit's `/recording/segments` rows inside the window look healthy
   (contiguous ~4 s, 186–826 KB) — but there is a **12 s recording hole at
   04:31:00–04:31:11**, 44 s before the window. Whether that discontinuity
   (or content corruption) breaks the compositor is CV's half; the client
   evidence ends at the named camera + timestamps.

Consequences, stated as the wall sees them: **one bad tile silently blanks a
16-camera composite fragment** — no error, no 5xx, manifest still says
`ready` — and a guard gets a skipped/black slice of wall with nothing to
distinguish it from working playback. Letter filed:
`docs/letters/2026-08-29-mosaic-zero-byte-fragment.md` (asks: per-tile fault
isolation, 0-byte must never ship as 200/ready, and the 44b2d source
question).

## Server warts found by the tool on the way in (second letter)

- `/recording/segments` defaults to `limit=100` **silently** and its `total`
  field mirrors the returned page size, not the true count — a consumer that
  trusts either gets silently truncated inventory (my first planner pass saw
  4 candidate windows instead of 49 exactly this way). `limit` caps at 1000;
  offset paginates. Letter:
  `docs/letters/2026-08-29-segments-pagination-warts.md`, which also files
  the cold-503 100 % rate as a datum for the existing `ready` ≠ servable
  contract-gap thread.

## Boundaries, stated plainly

- Night run (03:45–09:45): server under night load; the 49 candidate windows
  all came from evening/night strips — daytime hours (12:16–20:12Z lookback
  segment) produced ZERO ≥16-continuous windows at gap-tol 3.0 s, which is
  itself a datum about daytime recording churn, recorded not interpreted.
- Segment fetches verified fragment 0 (+ fragment 1 during investigation)
  per session, not every fragment of every wall.
- The Ubuntu twin's results are its own report; nothing here is filled from
  it.

## Tool corrections owned during the night

- First planner pass trusted the endpoint's default page size → 100-segment
  cap → 4 phantom-clustered windows. Fixed with pagination before the run;
  the plan went to 49 windows/53–56 cameras.
- A local/UTC mix-up briefly read as a "3-hour segment lag" — disproven
  minutes later by `date -u`; no lag existed. Same error class as the box
  agent's own 08-22 correction; owned here so the pattern is visible.
