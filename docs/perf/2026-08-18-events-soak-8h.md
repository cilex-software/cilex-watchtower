# 8-hour Events soak — clips, seeks, motion-marker, exports

> **STATUS: RUNNING** — started 02:46, deadline 10:45 (Europe/Moscow). Numbers below
> are an interim snapshot (~03:3x); the final pass replaces this banner and every
> "so far" figure after the run ends. Operator order: 2026-08-18, /goal.

## What runs, and what each check actually verifies

Two independent systemd user units on the dev box (station stopped):

- **`wt-soak`** — relaunches Watchtower in ~50-min cycles (cold-start soak) with the
  in-app `WT_HERO_TEST` driver: picks events from the live feed one after another,
  opens each clip (session + first RENDERED frame verified, latency logged), dwells
  20 s from the window head so MotionScan can measure the movement span against the
  yellow marker (`detectorDeltaMs` = measured motion start − camera stamp), then
  performs **20 random scrubber jumps**, each seek verified by an actually-rendered
  frame (9 s without one = logged SEEK TIMEOUT).
- **`wt-soak-exp`** — shadows the driver's log: every played event is exported over
  the app's own window contract (episode ±15 s, `wallclock`), the artifact downloaded
  via the signed per-job URL and ffprobe-verified: container parses clean, video
  codec present, duration within 3.5 s of the requested window.

**Stated verification boundaries.** Coverage is sequential-through-the-feed but the
pick order is the driver's, not strict chronology. The scanner verifies where motion
STARTS against the yellow; span END verification is not built. MotionScan is
deliberately conservative: low-contrast movers (dark clothes at night) may not lock,
in which case no start-vs-yellow verdict is recorded for that clip. "Same clip"
is verified by window/duration/codec equivalence, not frame-by-frame comparison.

## Interim numbers (will be replaced by finals)

- Cycles completed: 1 (cycle 2 in flight) + a 14-min pre-relaunch part
- Clips opened with rendered first frame: **21 so far**
- Scrubber seeks rendered: **360 so far, 0 timeouts, 0 open timeouts**
- Motion-span measurements: **14 so far**; detectorDeltaMs spread (ms):
  −971…+6708 (negative = motion visible before the stamp)
- Exports: **2 PASS so far** post-harness-fix (e.g. 21.3 MB / 46.0 s / h264, exact
  window match); 20 earlier FAIL rows are pre-fix harness history, kept classified
- App health: 0 player errors, 0 stall rescues, 0 session failures, 0 crashes so far

## Bugs and contract findings banked already (from the harness bring-up)

1. **Export download needs the signed per-job token** — `GET
   /review/exports/{id}/download` 404s with the AUTH token; the `ready` payload's
   `download_url` (?token=<job-signed>) is the only working path. Cost three harness
   rounds; any future export client must read `download_url`. (CV letter material —
   docs/DEVELOPMENT.md note pending.)
2. **Failed export jobs vanish** — a job that existed 404s mid-poll instead of
   reporting `state=failed`; consumers cannot distinguish "failed" from "never
   existed".
3. **Fresh episodes cannot be exported** — windows whose tail is not yet finalized
   fail (and vanish per #2); the harness defers exports ~90 s. The app's own Export
   button on a seconds-old event presumably hits the same wall silently.
4. **Some cameras 422: "High-quality export needs the high-res original (main
   stream)"** — no main recording ⇒ no export for those cameras; the app UI does not
   surface this distinction.
5. **Export artifacts expire quickly** after `ready` (`download_expires_at` ≈ +2 h;
   observed prune of an undownloaded artifact within ~10 min in one case — to
   re-check against finals).
6. Exports transcode the HEVC main to **H.264 at full resolution** (16–21 MB per
   ~35–46 s window) — fine for compatibility; noted for size expectations.

## Bugs found during the soak proper

_(filled at the end — includes any FATAL/stall/timeout events and the final
stamp-vs-motion distribution)_

## Fixes shipped during the test

_(filled at the end; per the operator's order, errors found are fixed and the test
continues)_
