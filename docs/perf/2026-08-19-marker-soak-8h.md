# 8-hour marker soak — does the yellow line begin and end with motion? (2026-08-19, 01:09–09:08)

Operator order: verify the movement span against visible motion on every clip,
name every video where it fails, log stats, fix the placement algorithm, fix
anything else found. Method: the operator's visual check (snapshot at yellow
start; find the mover mid-window and at ¾; watch it leave near the yellow end)
machine-translated — MotionScan measures the FIRST and LAST sustained pixel
motion across each fully-played window (2× playback), and every fully-scanned
clip emits a [MKT] verdict: startDeltaMs / endDeltaMs vs the camera-stamped span.

## Volume

10 app cycles (cold starts), **677 clips opened**, **311 fully scanned to a
verdict** (a verdict requires honest head-AND-tail scan coverage), 2,793
render-verified seeks (30 timeouts, 1.1 % — higher than the previous soak's
0.34 %; conditions differ: 2× playback + full-window dwells), 0 crashes,
3 stall rescues (all recovered), 18 "Invalid data" open-error lines (the known
B2 class).

## The verdict distributions (measured motion − camera stamp)

**START** (148 locks): median **−0.9 s**; 55 % honest within ±2 s;
21 % motion visible BEFORE the yellow (late stamps, worst −4.8 s);
24 % yellow starts before any visible motion (early stamps, worst +14.8 s).
Same double-tailed jitter the 476-sample soak measured; CV threads stand.

**END** (183 locks): **only 4 % honest.** On **83 % of clips, visible motion
ends more than 2 s before the yellow does — median overhang 12.2 s, p10 34.8 s.**
The camera's `motion_ended` fires long after visible motion stops (detector
hold/hysteresis), so the stamped duration systematically overstates the action.
This is the soak's headline: the END of the yellow was broken fleet-wide all
along; the start was merely jittery.

**Lock rate**: 48 % of scanned clips produced at least one measured edge
(163/311 nolock — genuinely still scenes, low-contrast movers, or motion
outside the padded window). The adaptive noise-floor gate (shipped last night)
is what got dark-scene locks at all; the nolock share is stated coverage, not
hidden. End-locks (183) exceed applied start-locks (148) because the start
snap additionally requires head coverage before trusting itself.

## Every offending video

**178 clips** with |startDelta| > 2 s or |endDelta| > 2 s are named with camera
and both deltas in `docs/perf/2026-08-19-marker-soak-offenders.csv` (committed
alongside). Worst cameras by offender count: `hiwatch-04eecdd44fd6` (21),
`hiwatch-50e538da373d` (17), `hiwatch-083bc1df3a4b` (12),
`hiwatch-083bc14effb8` (11), `hiwatch-04eecdd44b03` (11), `hiwatch-849459c4f00a` (9).

## The algorithm fix

Client (shipped BEFORE the soak, v1.1.121, and what made this measurement
possible): the yellow's START and now its END snap to pixel-measured motion
once the scan has honestly covered the window — measured truth replaces the
stamp wherever measurement exists, and never where it doesn't. Given the END
finding, the end-snap is the biggest honesty gain in the events player to
date: a median 12 s of dead yellow tail disappears on measurable clips.
Root cause remains server/camera-side and now has two named components:
per-camera clock skew (letters of 08-17/08-18) and — new tonight —
**motion_ended hold/hysteresis** (letter filed with this report).

## Other issues found

- Seek-timeout rate 1.1 % under 2× full-window playback (vs 0.34 % at 1×
  yesterday) — cold-storage tail amplified by doubled fetch rate; recovered in
  every case; no client defect identified.
- 18 B2 "Invalid data" open errors — known class, already with CV (event ids
  from tonight available on request).
- 3 stall-watchdog rescues, 3/3 recovered — v1.1.98 continues to hold.
- Zero crashes across 10 cold starts; RSS unremarkable.

## Recommendations

1. CV: `motion_ended` trails visible motion by a median 12 s — detector hold
   time worth tuning fleet-wide (letter: 2026-08-19-motion-ended-hysteresis.md).
2. Client (queued): surface "measured vs stamped" visually (two-tone yellow)
   so a guard can tell which truth they are looking at.
3. Re-run this soak in daylight for a contrast-diverse lock-rate reading.
