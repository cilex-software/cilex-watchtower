# Stage 2 submission — Labs tracking product integration (Kimi)

Branch: `benchmark/kimi-labs-tracking`.
Original-stage (preserved) commit: `90b1f2a4be1749a2dbcbb437aacf003e987f1103`
— untouched; `docs/benchmarks/labs-tracking/SUBMISSION.md` remains its record.
Integration started at that revision; all Stage 2 work is new commits on top.
The final integration commit is named in the closing agent response.

## What changed

New files:
- `tools/labs/track_run.py` — the product-owned helper process (probe / run /
  verify), never registered with the worker, never touching the network.
- `src/models/LabsTrackRunner.{h,cpp}` — `QML_ELEMENT` driving the helper via
  QProcess (ClipTranscoder pattern): progress, cancellation, run records under
  `wtlabs::stateDir()/track-runs/`, verification check streaming.
- `qml/LabsTracks.qml` — the Labs "Tracking" view (new run, runs on this
  computer, verification panel).
- `qml/LabsTrackReview.qml` — run review: the recording beside its tracks,
  observed-detection overlays, path trails, timeline, engineering details view.
- `tools/tests/labs-tracks-harness.qml` — WT_TEST_QML harness for the view.

Modified existing files (allowed by the Stage 2 assignment):
- `qml/LabsScreen.qml` — a third LabsSeg choice "Tracking" mounts the view;
  `WT_LABS_VIEW=tracks` opens it directly.
- `src/main.cpp` — dev-hook context properties `wtLabsTracksOpen`,
  `wtLabsRunFile/Camera/Start/CancelMs`, `wtLabsVerify` (validation/screenshot
  hooks driving the real UI path, in the repo's existing hook style).
- `CMakeLists.txt` — the two QML files and the C++ runner registered.
- `i18n/watchtower_en.ts`, `i18n/watchtower_ru.ts` — regenerated with
  `update_translations`; the 40+ new strings carry Russian translations.
- `tools/tests/labs-temporal-tracks.py` — additive `--jsonl` output mode (the
  in-app contract suite streams it). No check was removed, added-to-pass, or
  weakened; plain output and exit codes are unchanged.

Engine fixes during integration: **none**. The Stage 1 engine
(`temporal_tracks.py`) is byte-identical to the original submission. One helper
fix happened during UI validation, recorded here separately as required: the
export-filename suggestion now refuses a parsed "camera" that fails the
contract's scope-id pattern (an event-description export name had prefilled
junk into the camera field); verified by re-running the same cancelled-run
scenario afterwards.

## Build and launch

```
cmake --preset default && cmake --build build --parallel 2
WT_NO_SCHEME_REG=1 ./run.sh
```

(Qt 6.12.0 here; the build is clean. As always, `WT_NO_SCHEME_REG=1` on any dev
run. One build at a time, `--parallel 2` throughout, per the operator's rule.)

## Operator walkthrough

1. Open **Labs** (flask icon) → the **TRACKING** tab.
2. Click **Choose recording…** and pick a Watchtower export or any local
   recording (`*.mp4`, `*.ts`, …). The card shows the file's measured identity:
   codec, size, fps, duration, sha256 — read from the bytes, never invented.
   A Watchtower export name (`<camera>_<yyyymmdd>_<hhmmss>.mp4`) prefills the
   camera label and start time and says so; confirm or correct them.
3. **Run tracking**. Progress is live; **Cancel** stops it. The run appears in
   **Runs on this computer** and persists across restarts (reopen by clicking).
   Completed, cancelled, failed and no-detection runs are visually distinct.
4. The review pane plays the recording with the observed detection boxes of the
   current instant (never interpolated), a selected track's path trail at its
   actual sample times, and the timeline with every track's span. Clicking a
   track or the timeline seeks the recording to that time. Uncertain
   associations are marked amber, per batch and per track. **details** opens the
   engineering view (input hash, engine revision, resolved config, timings).
5. **Verification** runs the real suites in place: contract checks (the public
   cases through the actual CLI plus the engine's own battery), Labs
   regressions (worker + analyser self-tests, untouched), the streaming
   workload with its measurements, and the integration checks (real helper
   invocation, input identity, timestamp alignment, replay, error surfacing,
   cancellation, repeat runs). "Include deliberate failure control" adds a
   check that fails by request, proving a failure renders red. These are
   self-checks on synthetic inputs where so labelled — never camera findings,
   never a benchmark grade.

## Validation (all performed, this checkout, this host)

Environment: Ubuntu 24.04 (Linux 7.0.0-31-generic, i5-13500, 20 CPUs), Qt
6.12.0, Python 3.12.3, numpy 2.4.4, cv2 4.13.0, ffmpeg 7.x; Wayland session
`wayland-0`; timezone MSK (UTC+3). The dev instance ran against the live pilot
backend (read-only: the Tracking feature itself performs no network I/O).
Host-load caveat: this host is shared and busy; timings are diagnostic.

- Build: `cmake --preset default && cmake --build build --parallel 2` — clean.
- Full app on the real session boots into Labs → TRACKING; screenshot
  `/tmp/app1.png`.
- **Real footage — VERIFIED inside the product.** Input: an existing Watchtower
  export made through the product's own export flow,
  `~/Videos/Watchtower/A woman in brown jacket … - Street Cam 1.1 20261005_152521.mp4`
  (h264 2560x1440, 15.05 fps, 53.0 s, 22,551,606 bytes,
  sha256 `ba2ecd144a01b9a64725b644ebddc1a24559d1ff1c4619e88df4b906e757324f`).
  Scope entered from the file name: camera `street-cam-1.1`, start
  `2026-10-05T15:25:21+03:00`. In-app run (driven by the WT_LABS_RUN_* hooks,
  which call the same code the buttons call): **completed, 181 detections, 20
  tracks**, run id `d4c28a08876f790d`; review shows the tracks over the footage
  with an aligned box and path trail on the moving person (`/tmp/app-run-done.png`,
  crop `/tmp/app-crop2.png`). The same run through the terminal helper produces
  the identical run id and episode digest (input-identity evidence).
  A second real export (`…/A woman in red jump suit … - Street Cam 10.1_20261005_153009.mp4`)
  demonstrated **cancellation**: stopped at ~2.5 s, recorded as
  `cancelled — incomplete`, no completed evidence left behind
  (`/tmp/app-cancel.png`).
- The in-repo mosaic fixture
  (`docs/letters/fixtures/2026-05-31-mosaic/mosaic-segment.ts`, synthetic colour
  cards — not real footage per its own README) runs the full pipeline and lands
  on the honest **completed — no detections** state (24 frames, 0 detections).
- **Verification suites in-app** (`WT_LABS_VERIFY=…` on the Tracking view):
  - `contract`: **351 passed, 0 failed, 0 skipped · 3.401 s**
    (`/tmp/app-verify-contract.png`; the eight public cases run through the real
    JSONL CLI subprocesses).
  - `regressions`: **438 passed, 0 failed, 1 skipped (winqos, Windows-only) ·
    32.476 s** (`/tmp/app-verify-regressions.png`).
  - `workload`: warmup + 3 measured runs completed within limits, walls
    **17.18 / 18.50 / 18.62 s**, peak RSS delta **+0.6 MiB** each, median wall
    **18.50 s**, snapshots ≤ 55,889 bytes — shown in-app with the "shared-host
    diagnostic" note (`/tmp/app-verify-workload.png`).
  - `integration`: **10 passed + the deliberate failure control FAILs red** by
    request (`/tmp/app-verify.png`): clip generation, probe identity, run
    completion, evidence hash match, timestamp alignment (episode 1.00–4.80 s
    vs true motion 1.00–5.00 s), receipt-joinable overlay evidence, replay,
    error surfacing, cancellation, repeat determinism.
- Stage 1 checks re-run on this tree: `tools/tests/labs-temporal-tracks.py`
  351 PASS / 0 FAIL (also in `--jsonl` mode); `tools/tests/labs-worker.py` all
  passed (exit 0); `selftest_shape_observations.py` 79/79;
  `selftest_object_profile.py` 40/40; `git diff --check` clean.
- Offscreen harness smoke of the view (`/tmp/tracks1.png` also caught the
  missing-prerequisite display working when run under an isolated HOME without
  numpy — an honest unavailable state, not a crash).

## Skipped checks, caveats, limitations

- **No camera-hour-scale real run**: the validated real inputs are two ~50 s
  fleet exports. The pilot's full-hour footage was not pulled for this (host
  load rules); the pipeline is the same one the worker uses, but an hour-scale
  in-product run is NOT VERIFIED.
- The fleet's real export names here carry event descriptions before the camera
  token, so the filename suggestion only fires for the plain
  `<camera>_<date>_<time>` shape; otherwise the operator types the scope in
  (validated, never invented).
- In-app workload walls (17.2–18.6 s) ran beside a live wall on a busy shared
  host; they are diagnostic, not controlled scores.
- The overlay draws only observed detections (nearest batch within half a
  sampling step); between batches the box simply is not drawn. Path trails use
  the episodes' bounded samples at their real timestamps.
- Everything is local: no server writes, no analyser enabled or replaced, no
  worker/Warden started, no footage or credentials committed, no production
  state touched. Trial records live under the Labs state dir and deletable from
  the list (×).
- i18n: new strings are translated to Russian; English .ts entries stay empty
  per the repo's convention (source text is the English UI).
- Screenshot files are validation artifacts on this host (paths above), not
  committed per the assignment's no-artifacts rule.
