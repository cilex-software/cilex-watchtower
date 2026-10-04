# Labs temporal tracking — product integration (stage 2 submission)

This is the STAGE-2 record. The original-stage record is
[`SUBMISSION.md`](SUBMISSION.md), preserved unchanged; its engine, contract
behaviour and public fixtures are untouched by this stage.

- Original-stage commit: `e7fd18b9dfa6ea93305dd819fcccb2e9f8e62723`
  (`feat(labs): temporal tracking engine per benchmark contract v1`), pushed to
  `origin/benchmark/deepseek-labs-tracking` and verified there before this stage
  began.
- Integration starting revision: the same commit (this branch, no rebase).
- Submitted commit / branch / push result: in the final response, not in this
  file (this file is committed by that commit).
- Checkout: `/home/cilex-vision/projects/cilex-watchtower-deepseek`,
  branch `benchmark/deepseek-labs-tracking`.

## 1. What the operator can now do inside Watchtower

Labs → **Tracking** (third segment of the Labs tab strip; `WT_LABS_VIEW=tracking`
opens it directly). The panel is `qml/LabsTrackingPanel.qml` over the model
`src/models/LabsTracking.{h,cpp}`; the analysis runs as one child process.

1. **Choose a recording.** *Exports…* lists the product's own export folder
   (the same `Artifacts.exportDir` the export drawer writes to — on this box
   `/home/cilex-vision/Videos/Watchtower`, 9 real exports), or *Browse…* picks
   any local file. No terminal, no backend change, no new service.
2. **Scope and time mapping.** The camera id defaults to the export's own file
   name; the recording's wall-clock start is prefilled from the container's
   `creation_time` when it has one, otherwise from the name's timestamp, and the
   panel SAYS which (*"start source: filename (local time)"*) — the file name is
   written in local time by the export path, so it is converted, not relabelled.
   Both fields are editable. Nothing is invented when neither source exists.
3. **Run.** *Run analysis* decodes the selected stretch with the **existing**
   Labs pipeline (`tools/labs/frame_source.py` → one software ffmpeg pass →
   `tools/labs/labs_foreground_mask.py` MOG2 primed windows → `MaskFrame`/`Blob`)
   and feeds those detections to the contract engine through
   `temporal_tracks_adapter.mask_frame_batch`. Progress, the running detection
   count and the number of closed tracks appear while it runs; *Cancel* stops it
   (SIGTERM → the runner finalises partial evidence → status **CANCELLED ·
   PARTIAL**), and closing the app during a run leaves no orphan process.
4. **Review.** Tracks are listed with their id, real time span, observation
   count and uncertain-batch count (`UNCERTAIN` badge). Selecting a track seeks
   the recording to that track's first observed instant and draws its observed
   polyline. The picture carries the boxes of the **most recent observed frame**
   with that frame's own timestamp and its distance from the playhead
   (*"observed sample 00:00.000 · 1 detection · 0 ms before playhead"*); dashed
   amber boxes are the engine's explicit abstentions with their reason (`merge` /
   `cost_tie`). Nothing is interpolated to fit the player, and the panel says so.
5. **Verify.** The *Verification* tab runs the real suites in this checkout and
   lists every check with its own status, detail and duration: the contract
   suite (all eight public cases plus the contract's own checks), the existing
   Labs worker suite and both analyser self-tests, the declared streaming
   workload with measured time/RSS/snapshot sizes, and the integration checks —
   including the **deliberate failure control**, which is a check that must fail
   and is displayed as `FAIL*` with *(deliberate control)* beside it.
6. **Keep the evidence.** Every run writes a directory under
   `<AppData>/labs-tracking/runs/<UTC stamp>/` (`run.json`, `frames.jsonl`,
   `tracks.jsonl`, `tracks.json`, `engine_snapshot.json`, `job.json`) holding the
   input path, SHA-256 and byte size, scope, time mapping and its source, engine
   config, status, counts, timings and any failure code/message. *Saved runs*
   lists them; opening one re-displays its tracks and ledger without re-running
   (that is also the input cache: `--reuse frames.jsonl` re-runs the engine on
   stored detections with no decoding at all).

**What is deliberately NOT here.** No classifier, no class names, no
recognition claim: a track is a track. No fabricated detections — every box in
the panel comes from the mask pipeline on real frames, and the ledger records
which frame. No standalone viewer, no second application, no backend change, no
production database write, no Warden/fleet worker, no deployment.

## 2. Exact build and launch

```sh
cd /home/cilex-vision/projects/cilex-watchtower-deepseek
cmake --preset default            # Qt 6.12 at ~/Qt/6.12.0/gcc_64
cmake --build build               # 237 targets, clean
./run.sh                          # or build/watchtower with run.sh's Qt env
```

Then: sign in → **Labs** → **Tracking** → *Exports…* → pick a recording →
*Run analysis*. Reproduce a screenshot headlessly (the flags are documented in
`docs/DEVELOPMENT.md`):

```sh
REC=~/Videos/Watchtower/HiWatch_DS-I456Z_B___192.168.1.102__20260810_155745.mp4
WT_NO_SCHEME_REG=1 QT_QPA_PLATFORM=offscreen WT_SECTION=labs WT_LABS_VIEW=tracking \
  WT_LABS_TRACK_RECORDING="$REC" WT_LABS_TRACK_RUN=1 \
  WT_SCREENSHOT=/tmp/track.png WT_SCREENSHOT_MS=12000 timeout 40 ./build/watchtower
```

```sh
# the same checks the panel runs, from the command line
python3 tools/labs/temporal_tracks_checks.py --group all \
  --recording "$REC" --workdir /tmp/labs-checks | python3 -m json.tool --json-lines
```

## 3. Measured checks

Run on 2026-10-04/05, this checkout, Qt 6.12.0, Python 3.12.3, NumPy 2.4.4,
OpenCV 4.13.0.92, shared 20-core host (load 13–17; timings diagnostic).

**In-panel verification (`--group all`, the same code path the UI starts):**
51 checks passed, 0 real failures, 0 skipped, 1 deliberate control failure
reported as such, 64.1 s total.

| Group | Result | Detail |
| --- | --- | --- |
| contract | 30 families PASS | 316 PASS / 0 FAIL in the suite itself; every public case (`one-object…`, `maximum-cardinality…`, `distinguishable-crossing`, `explicit-cost-tie…`, `possible-merge…`, `strict-gap-span…`, `bounded-replay…`, `checkpoint-undrained…`), adapter examples, and the contract's own checks |
| regression | 3 PASS | existing `labs-worker.py` 436 assertions; `selftest_shape_observations.py` 79/79; `selftest_object_profile.py` 40/40 |
| workload | 6 PASS | stream 1 (100000×8) 9.65 s, stream 2 (250×32) 0.56 s, total 10.22 s (limit 180 s); +1.2 MiB peak RSS (limit 128 MiB); largest snapshot 53118 B (limit 2 MiB); every detection accounted for once |
| integration | 12 PASS + 1 control FAIL | below |

**Integration checks (all against the real engine and a real recording):**

| Check | Result |
| --- | --- |
| engine invocation (deterministic scenario) | PASS — 3 receipts, 1 track, 3 observations |
| checkpoint restore equals uninterrupted state | PASS — identical digest |
| duplicate input is a replay, not new evidence | PASS |
| malformed measurement refused atomically | PASS — `invalid_input`, state unchanged |
| `MaskFrame`/`Blob` adapter maps real analyser output | PASS |
| real recording: identity/hash | PASS — `632ecb77be870d97…` = independently computed SHA-256 of the 11,911,139-byte export |
| real recording: bounded run | PASS — 60 frames, `completed`, exit 0 |
| real recording: timestamp alignment | PASS — 60 frames, median step 50 ms (20 fps), **all 14 track samples land on real frame instants** |
| real recording: cancellation | PASS — exit 3, `status=cancelled` |
| repeat runs replace, never append | PASS — second run 30 frames against the first's 60 |
| cached detections re-run without decoding | PASS — `mode=engine-only`, same input hash, 60 frames |
| control: this check is designed to fail | **FAIL (deliberate)** |
| control: the harness reported that failure | PASS — the failure was recorded, not swallowed |

**Real-footage runs through the panel** (the export
`HiWatch_DS-I456Z_B___192.168.1.102__20260810_155745.mp4`, 1280×720 h264
20 fps, SHA-256 `632ecb77be870d97…`):

| Run | Result |
| --- | --- |
| 900 frames (45 s) | completed in 4.7 s of analysis; 742 detections, 50 tracks; 1 mask-model rebuild (at frame 600, the analyser's `prime_max_frames`), which the panel states on screen |
| 300 frames re-run | completed in ~4 s; its own 500 detections / 23 tracks replaced the first run's results in the panel (no stale rows), and both runs appear under *Saved runs* |
| cancelled mid-decode | `CANCELLED · PARTIAL` with 600 frames / 508 detections / 23 tracks kept as partial evidence, explicitly "not a completed analysis" |
| undecodable file (`/dev/urandom` as `.mp4`) | `FAILED — decode_or_engine_error: RuntimeError: could not read a video stream from …`, with that input's SHA-256 still recorded |

**Build/smoke:** `cmake --build build` clean; `WT_NO_SCHEME_REG=1
QT_QPA_PLATFORM=offscreen WT_SECTION=labs timeout 12 ./build/watchtower` →
exit 124 (loaded), **zero** `.qml:` / `Non-existent` / `Unable to assign`
warnings. Quitting the app during a run at 5 s, 6 s and 8 s: exit 0, no fatal,
no surviving helper process (this found and fixed a real crash — see §5).

## 4. Screenshots (evidence locations)

All in [`evidence/`](evidence/), taken from the real application rendering the
real panel; the picture is black because the offscreen QPA does not composite
video frames — the overlay boxes, the legend and every number are real.

| File | Shows |
| --- | --- |
| `01-labs-tracking-idle.png` | the panel on the Labs screen: recording selected, container facts (1280×720 · 20 fps · h264), scope, time mapping and its source, engine knobs, run controls |
| `02-recording-picker-exports.png` | *Exports…* listing the product's own export folder — in-app recording selection, no terminal |
| `03-completed-run-tracks.png` | COMPLETED run: 900 frames / 742 detections / 50 tracks, board of tracks with spans, counts and `UNCERTAIN` badges, selected-track detail, observed-sample legend and two observed boxes drawn on the picture |
| `04-cancelled-partial.png` | CANCELLED · PARTIAL with the partial-evidence warning, 600 frames kept, progress bar mid-run |
| `05-failed-decode.png` | FAILED with the decode error, and the failing input's SHA-256 still shown |
| `06-verification-checks.png` | the Verification tab: 12 passed, 0 failed, 1 deliberate control, per-check PASS/FAIL/SKIP rows with details and timings |
| `07-repeat-run-and-saved-runs.png` | after a second run: the panel shows the SECOND run's 300 frames/23 tracks (first run was 900/50), and *Saved runs* lists the earlier run with its recording and counts |

## 5. What the verification found, and the fixes it produced

1. **Shutdown crash (real, fixed).** Closing the app during a run segfaulted in
   `QProcess::waitForFinished` → `QQmlApplicationEnginePrivate::cleanUp`. Cause:
   the model's `killProcess()` held a reference to the member pointer while
   waiting; the child's `finished` handler set that member to `nullptr`, and the
   next line dereferenced null. Children are now stopped from
   `QCoreApplication::aboutToQuit` (event loop still up), the waiting helper
   detaches and disconnects first, and the destructor only kills. Re-measured:
   clean exits at 5 s, 6 s and 8 s into a run, no orphan processes.
2. **Shutdown state.** Quitting mid-run now leaves the run directory holding the
   partial ledger and a `run.json`, so an interrupted run is reviewable rather
   than invisible.
3. **Track selection needed the media to be loaded** before seeking; a pending
   seek is applied on `durationChanged` (first screenshot of the panel showed a
   selection that had not moved the player).
4. **`Item` has no `color`** and the C++ `LabsTracking` type collided with a QML
   file of the same name (the panel is `LabsTrackingPanel.qml`); both were
   caught by the offscreen smoke test, not by the compiler.

## 6. Limitations, skipped items and honest boundaries

- **The sign-in gate was not passed in this development instance.** The Labs
  screen (like every section) is behind `AuthController.authenticated`; this
  host's local Query API (127.0.0.1:8000) answered *"Wrong username or
  password"* to the dev default, and no credentials were hunted for. For the
  screenshots only, two lines of `qml/Main.qml` (the login overlay and the
  shell's visibility) were temporarily forced and **reverted before commit** —
  the committed tree has the gate exactly as before, verified by `git diff` and
  by a post-revert smoke test. Everything else in the screenshots is the real
  panel, the real engine and a real recording.
- **No video pixels in the screenshots.** The offscreen QPA does not composite
  `VideoOutput` frames, so the picture area is black; boxes, paths, legend and
  timing are drawn by the panel itself and are real. Rendering video frames
  needs a real display session (Wayland/X) — not performed here.
- **No backend, fleet or camera access was used.** Everything above is local.
  The panel reads recordings from disk; it does not touch `/labs/*`, the
  database, Warden or any station. The `LabsModel` statistics above the panel
  show "Stopped by the server" because this instance is genuinely signed out.
- **Real-footage acceptance is verified for ONE recording** (the 45 s/900-frame
  export above, 1280×720 h264 20 fps). Other exports, other resolutions/codecs
  and long recordings were not run. The declared work is bounded by the
  `frames` control; the panel's own runs here were 300–900 frames.
- **The mask model rebuilds every 600 frames** (the analyser's
  `prime_max_frames`), and the tracker resets on a run change by contract. The
  panel states the rebuild count; it does not hide it. Longer continuous
  tracking would need a different priming strategy from `labs_foreground_mask`,
  which this stage deliberately did not change.
- **Timestamps in a full decode come from the probed frame rate**, not per-frame
  PTS (`frame_source` steps by `1/fps` off the header for `keyframes_only=False`;
  measured 20.00 fps on this export). Alignment inside a run is exact because
  the engine's `t_ms` IS the decoder's frame time; the wall-clock column inherits
  that rate assumption.
- **Checks take about a minute** (64 s here) because they run the real suites and
  the declared workload. On a heavily loaded host the workload check may be
  slower than its 180 s limit; it reports the measurement either way and does not
  convert a timeout into a pass.
- **Not run:** the Windows/macOS builds or any platform claim from this Linux
  box; a controlled isolated-CPU performance comparison; any independent
  grader's checks. The deliberate control is the only red row, and it is red on
  purpose.

## 7. Files

New (this stage): `qml/LabsTrackingPanel.qml`, `src/models/LabsTracking.{h,cpp}`,
`tools/labs/temporal_tracks_run.py`, `tools/labs/temporal_tracks_checks.py`,
`docs/benchmarks/labs-tracking/evidence/*.png`, this file.
Modified: `CMakeLists.txt` (registration), `qml/Main.qml` (one model instance +
one property), `qml/LabsScreen.qml` (third segment + the panel),
`src/main.cpp` (four review-hook environment properties),
`docs/DEVELOPMENT.md` (flag table), plus the four version-metadata files the
pre-commit hook bumps. Nothing else: the engine, adapter, CLI, tests,
`SUBMISSION.md`, the contract, the fixtures and every protected
`tools/labs/labs_*.py` file are byte-identical to the original-stage commit.
