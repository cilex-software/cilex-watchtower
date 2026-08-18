# 8-hour Events soak — final report (2026-08-18, 02:46–10:45)

Operator order: play clips sequentially, verify playback + yellow-marker-vs-motion,
15–30 random seeks per clip, export each clip and verify integrity, fix errors and
continue, report bugs + clips tested. Ran on the dev box (station stopped) as two
session-independent systemd user units; app relaunched every ~40 min (cold-start soak).

## Headline numbers (measured; commands in scratchpad/soak/)

| metric | value |
|---|---|
| app cycles (cold starts) | **39** — zero crashes (0 non-supervisor FATALs), zero session failures |
| clips opened w/ RENDERED first frame | **803** (open timeouts: 4 = 0.5 %) |
| open → first frame | median **578 ms**, p95 1.68 s, max 3.18 s |
| random scrubber seeks RENDERED | **13,414** (timeouts: 46 = 0.34 %) |
| seek → rendered frame | median **223 ms**, p95 6.3 s (cold-base tail), max 8.3 s |
| motion-marker measurements (MotionScan) | **476** clips |
| exports attempted post-harness-fix | **376** → **223 PASS (59 %)** |
| PASS artifact profile | h264 full-res, avg 18 MB, duration = requested window ±3.5 s |
| RSS across cycles | 636–795 MB, no growth trend |

## Yellow-marker vs measured motion (the 476-clip distribution)

`detectorDeltaMs` = first VISIBLE motion (pixel-measured) − camera motion stamp:

- median **−0.36 s**; 67 % of clips within ±2 s — for two-thirds of the fleet's
  events the yellow is honest to within a couple of seconds.
- **29 clips (6 %) stamp >2 s LATE** (motion visible before the yellow; worst −4.6 s
  here, −20 s observed manually on 2026-08-17).
- **128 clips (27 %) stamp >2 s EARLY** — p90 +7.4 s, max **+26.3 s**: the yellow
  starts while the frame is still empty. Camera clock skew + detector zone triggers
  (background roads) — CV threads already open:
  `2026-08-17-motion-stamp-jitter-two-events.md`, `2026-08-17-null-clock-fields-block-marker-sync.md`.
- Boundary: span END is not verified (scanner measures starts); low-contrast movers
  don't lock (conservative by design), so the 476 samples skew toward clear motion.

## Bugs found

**B1 — Export silently truncates at the finalization horizon (server).** The
dominant export defect, one root, two severities: windows whose tail is not yet
finalized return `state=ready` with a SHORTER artifact — 49 exports came back
15–35 s short of the requested window; 93 more (windows mostly/entirely beyond the
horizon) returned ~10–45 KB stub containers. No error, no actual-vs-requested
indication in the job payload. The app's own Export button inherits this: an
operator exporting a recent event gets a silently short clip. **Fleet-visible; CV letter to follow.**

**B2 — Clip open fails with FFmpeg "Invalid data found when processing input"
(server cut / client-visible).** 41 of 803 opens (5.1 %) — the session's leading
segment cut poisons the demuxer at open. The client shows an honest error with
tap-to-retry; only 4 opens never recovered within the driver's 15 s patience.

**B3 — Export download requires the signed per-job token.** `download` with the
auth token 404s; only the `download_url` from the ready payload works. Cost three
harness rounds; documented so no future client repeats it.

**B4 — Failed/expired export jobs VANISH** (404 mid-poll) instead of reporting a
terminal `failed` state; consumers cannot distinguish "failed" from "never existed".

**B5 — Cameras without a main-stream recording cannot export**: 11 events answered
422 "High-quality export needs the high-res original (main stream)". The app UI
does not surface this camera class distinction.

**B6 — Seek cold tail**: 46/13,414 seeks (0.34 %) exceeded the 9 s render bar
(cold-base S3 fetch class, known); p95 6.3 s. No client defect; number recorded.

**B7 — Stall watchdog fired 4×** over 8 h, each recovered on the first re-open —
the v1.1.98 rescue works at soak scale; zero gave-up errors.

## Fixes shipped during the test window

- Harness: signed-URL export download (B3), export deferral until window
  finalization (partially mitigates B1 for short episodes), failure-stage tagging.
- App: none required — no client defect surfaced that wasn't already handled
  (honest error + retry paths held; zero crashes across 39 cold starts).

## Recommendations

1. CV: export jobs should report delivered-vs-requested range (or fail/wait) — B1.
2. CV: terminal `failed` state instead of job deletion — B4.
3. CV: the leading-segment cut behind B2's 5 % open-error rate.
4. Client (queued): surface B5's no-main-export camera class in the export UI;
   contrast-adaptive MotionScan thresholds to widen marker coverage.

Raw data: scratchpad/soak/ (exports.csv, supervisor logs, per-cycle logs gz).
