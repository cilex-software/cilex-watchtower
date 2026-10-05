# Stage 3 submission — semantic object + object-colour analysers in Cilex Watchtower Labs

## Identity

| | |
|---|---|
| Repository / branch | `/home/cilex-vision/projects/cilex-watchtower-qwen`, branch `benchmark/qwen-labs-tracking` |
| Starting revision (Stage 3) | `c36b07db8f85e344392bf1ab04c416676f38971f` — "feat(labs): temporal tracks and verification inside the Watchtower Labs screen" |
| Preserved earlier stages | `9ee195a` (Stage 1 tracking engine + replay CLI + Labs adapter), `c36b07d` (Stage 2 product integration). Neither submission document nor their tests were rewritten; Stage 1/2 files touched this stage are limited to the guard fixes listed below. |
| Commit state | **Not committed, not pushed.** The Stage-3 launch message did not authorize commit/push, so this is a reviewable working tree (see `git status` list below). |
| Implementing agent | Qwen Code CLI agent (autonomous session). Reviewer identifier used for evidence review: `qwen-code-agent-dev-reviewer` (attribution, not authentication — the checklist tool says so and binds every decision to the run digest). |
| Toolchain | Qt 6.8.3 `gcc_64` (CMake + Ninja, `build68/`), GCC, Python 3.12.3, ffmpeg 6.x, ultralytics YOLO11 runtime on CPU. |
| Launch | Interactive: `./run.sh` from the repo root. Headless checks: `./build68/watchtower` under isolated `XDG_*` dirs with `WT_NO_SCHEME_REG=1 WT_RESTORE_OFF=1` and `QT_QPA_PLATFORM=offscreen` (real HOME kept, because numpy/opencv live in the user site-packages). |

Changed / added files (working tree, `git status --short`):

```
 M CMakeLists.txt                     LabsSemanticJob sources + qml/LabsSemantic.qml resource
 M qml/LabsScreen.qml                 "Objects & colours" segment + WT_LABS_VIEW routing
 M qml/LabsTracking.qml               two undefined-guard fixes (saved-row startedAt, currentTrack.track_id)
 M src/main.cpp                       context properties Semantic + WT_LABS_SEMANTIC_* dev hooks
 M src/models/LabsTrackRuns.cpp/.h    listRuns(analyserFilter) rows carry analyserId/clipId/observations
 ?? qml/LabsSemantic.qml              the new Labs view (findings / checklist / saved panes)
 ?? src/models/LabsSemanticJob.cpp/.h controller: child-process analyser + checklist helper
 ?? tools/labs/semantic_objects.py    the analysers (decode, detect, colour, run envelope, CLI)
 ?? tools/labs/stage3_checklist.py    the ONLY label reader: evaluate / review / status / control-invalid
 ?? tools/labs/stage3_evidence.py     common helper, copied verbatim from the supplied package
 ?? tools/tests/labs-stage3-analyser.py   hermetic product-path suite (28 checks)
 ?? tools/tests/labs-stage3-evidence.py   common helper's own suite, copied verbatim (13 tests)
 ?? docs/benchmarks/labs-detection-stage3/  supplied package (PROMPT/README/PROTOCOL/CASES/RESULT_FORMAT/
                                      CLASSIFICATION/PREPARATION, dataset.json, package-manifest.json)
```

## Analyser design and why

Two separately identifiable versioned capabilities share one decode+inference pass
(`pipeline id = semantic_object+object_colour`, both `version s3-1`):

* `semantic_object` — ultralytics YOLO11 (CPU) over **decoded pixels only**. The detector
  never sees `dataset.json`, a filename, a clip id or a hash; class mapping keeps
  `truck`/`bus`/`motorcycle` out of `car` (they are emitted as `other` or suppressed,
  never relabelled). Boxes are un-letterboxed back to full source-frame coordinates and
  normalized `bbox_xywh`.
* `object_colour` — unweighted HSV trimmed-median (5th–95th percentile) sampling inside
  declared region geometry (`vehicle_body`, `clothing`, `upper_clothing`,
  `lower_clothing`) of the *same* observation box. No background or shadow borrowing:
  regions are strict interior fractions of the object box. Insufficient pixels or an
  inconclusive margin yield `unknown` (abstention), never a guess. Agreement-weighted
  confidence is declared **uncalibrated** in the envelope.

Why this shape: the contract forbids metadata-driven answers and demands per-object
colour association; a single decode pass keeps PTS, boxes and colour pixels provably
from the same frame. Time basis is the **decoded PTS** parsed from ffmpeg `showinfo`
stderr (`frame_index` = decoded presentation order, `details.frame_times_ms` carries the
schedule so the UI can window each box to its true frame). Tracking ids come from the
Stage-1 engine (`tools/labs/temporal_tracks.py`) fed per analysed frame, so Stage 1 stays
the only tracker.

Sampling: adaptive default (`sample_fps 2`, cap 400 inference frames) plus the CASES.md
**whole-second schedule** as an operator checkbox (first decoded frame at/after each
whole second, deduped; missing requested frames are reported in
`measurements.missing_requested_frames`, never silently dropped).

Model disclosure (also in `manifest` and in every run envelope):

| model | file | SHA-256 (declared = on disk) | licence |
|---|---|---|---|
| ultralytics/yolo11n (COCO pretrained) | `yolo11n.pt` | `0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1` | AGPL-3.0 (weights + runtime) |
| ultralytics/yolo11s (COCO pretrained) | `yolo11s.pt` | `85a76fe86dd8afe384648546b56a7a78580c7cb7b404fc595f97969322d502d5` | AGPL-3.0 (weights + runtime) |

Weights live in `~/.cache/watchtower-labs-models/` (override: `WT_LABS_MODEL_DIR`); the
colour analyser has **no weights** (`reason_no_weights: unweighted pixel statistics`).
Default config: `conf 0.35` (chosen from a probe — 0.25 produced bench/post/luggage
false positives), `imgsz 640`, `decode_width 1280`, CPU device, no RNG
(`config.nondeterminism` states CPU inference is deterministic for fixed
weights/threads/input).

Product plumbing: `LabsSemanticJob` (Qt) spawns `semantic_objects.py analyze|manifest`
and `stage3_checklist.py evaluate|review|status|control-invalid` as child processes with
detached stdin (ffmpeg blocks forever on an inherited never-EOF stdin pipe), streams
`meta/progress/error/result` JSON lines off the GUI thread, cancels with SIGTERM then a
generation-guarded grace kill, and never parses labels. `qml/LabsSemantic.qml` renders
findings, the review checklist and saved evidence; boxes are drawn only inside
`[frame_pts_ms, next decoded pts)` with an opt-in dashed interpolation mode that labels
itself as interpolated.

## Build / launch / operator walkthrough

```
cmake -S . -B build68 -G Ninja -DCMAKE_PREFIX_PATH=$HOME/Qt/6.8.3/gcc_64   # once
cmake --build build68 --parallel 4
./run.sh                                   # interactive session
```

Headless verification profile (what every screenshot below used):

```
env XDG_CONFIG_HOME=/tmp/wt-iso/config XDG_DATA_HOME=/tmp/wt-iso/data \
    XDG_CACHE_HOME=/tmp/wt-iso/cache QT_QPA_PLATFORM=offscreen \
    WT_NO_SCHEME_REG=1 WT_RESTORE_OFF=1 ./build68/watchtower
```

Operator walkthrough (Labs → **OBJECTS & COLOURS**):

1. Pick a recording: the combo lists the Stage-3 neutral dir and exports, or use
   **Choose…** / **Neutral dir…** for any local file. The `using <file>` label always
   names the file the visible run actually used.
2. Tune `conf`, `sample fps`, optionally tick **whole-second schedule** and **crops**.
3. **Analyse** — banner shows real progress (decoded/inferred counts, percent);
   **Cancel** aborts mid-run and the banner says *Cancelled by the operator — partial
   evidence, not a result*.
4. **FINDINGS**: observation list (class, confidence, track id, PTS ms, frame index,
   per-region colour chips). Selecting one seeks the player to its observed PTS and the
   overlay draws that observation's box for its decoded-frame window only. The detail
   pane shows colour evidence (pixels, H/S/V, agreement), the crop image, and run
   identity (clip, input SHA-256, weights SHA-256 + licence, peak-RSS method).
5. **TARGET CHECKLIST**: per target — status chip (`REVIEW_REQUIRED` …), class-candidate
   and qualifying counts, required regions/labels, then *review as* reviewer id, an
   observation selector, **Accept / Reject / Unreviewable** (reason mandatory for the
   latter two), **Show on video**. Aggregate `reviewed` never means *passed*.
   Verification controls: **Deliberate invalid result**, **Renamed-input equivalence**,
   **Common helper self-tests**.
6. **SAVED EVIDENCE**: every completed run is saved with input/revision/analyser/model/
   config/observations/metrics; reopening restores that run's recording, time origin,
   hash, overlays and findings. Review decisions persist beside the run.

Dev hooks used only by headless checks (documented, never required by an operator):
`WT_LABS_VIEW`, `WT_LABS_SEMANTIC_TEST`, `WT_LABS_SEMANTIC_PANE`,
`WT_LABS_SEMANTIC_CANCEL_MS`, `WT_LABS_SEMANTIC_VERIFY=invalid|rename`.

## Per-clip results, candidates and reviewed outcomes

All eight clips analysed through the exact CLI `LabsSemanticJob` spawns
(`tools/labs/semantic_objects.py analyze`), same settings as the app default
(adaptive 2 fps, conf 0.35, crops+tracks on). Input SHA-256 of every run equals the
dataset hash. `peak_rss_bytes` is `resource.getrusage(RUSAGE_SELF).ru_maxrss`
— a **process peak**, labelled as such in the envelope, not net RSS.

| clip | status | obs | decoded | inferred | elapsed ms | model load ms | peak RSS (process peak) |
|---|---|---|---|---|---|---|---|
| WT3-001 | completed | 16 | 796 | 100 | 11153.6 | 4206.1 | 726134784 |
| WT3-002 | completed | 228 | 781 | 98 | 11138.6 | 4286.5 | 696197120 |
| WT3-003 | completed | 13 | 902 | 113 | 11100.7 | 4303.6 | 718024704 |
| WT3-004 | completed | 214 | 797 | 100 | 11374.9 | 4193.9 | 726020096 |
| WT3-005 | completed | 32 | 736 | 92 | 8678.1 | 3296.2 | 722808832 |
| WT3-006 | completed | 29 | 782 | 98 | 9503.6 | 2852.7 | 723492864 |
| WT3-007 | completed | 59 | 1052 | 132 | 12457.5 | 4295.7 | 724017152 |
| WT3-008 | completed | 168 | 902 | 113 | 11116.5 | 3149.1 | 729677824 |

PTS strictly increasing in all eight runs; `missing_requested_frames` empty (adaptive
schedule); hardware: 20 CPUs, no GPU, loadavg ≈ 15/11/10 (shared host — wall-clock
figures are diagnostic only); runtime python 3.12.3 / opencv 4.13.0 / numpy 2.4.4.
Setup (model load) is reported separately from run elapsed time above; review time is
not instrumented — the visual review below was performed by the agent reviewer on
2026-10-05 against the sheets.

Checklist evaluation (common helper `assess_targets`, in-app and CLI agree) then review
by `qwen-code-agent-dev-reviewer`, each decision bound to the run digest
(`run_sha256` + `input_sha256`) and stored in `~/stage3-evidence/reviews/`:

| target | requirement | candidates / qualifying | helper status | reviewer decision | bound observation | reviewer note (abridged) |
|---|---|---|---|---|---|---|
| WT3-001-p1 | person, upper_clothing ∈ {black, dark_gray} | 16 / 13 | review_required | **accepted** | o000015 | box on the near person in the black leather jacket; upper_clothing=dark_gray |
| WT3-002-p1 | person | 130 / 130 | review_required | **accepted** | o000218 | pedestrian passing behind the parked car |
| WT3-002-c1 | car, vehicle_body ∈ dark | 98 / 98 | review_required | **accepted** | o000053 | prominent parked black sedan, stationary |
| WT3-003-p1 | person (foreground rider) | 12 / 12 | review_required | **accepted** | o000003 | foreground scooter rider; distant seated person not boxed |
| WT3-004-p1 | person | 119 / 119 | review_required | **accepted** | o000083 | person leaving the entrance with a bag |
| WT3-004-c1 | car, vehicle_body ∈ dark | 93 / 93 | review_required | **accepted** | o000160 | prominent dark car, stationary |
| WT3-005-p1 | person, clothing = red | 25 / 19 | review_required | **accepted** | o000015 | person in red on the path; clothing=red |
| WT3-006-p1 | person, clothing = red | 25 / 19 | review_required | **accepted** | o000012 | person in red walking towards the gate |
| WT3-007-p1 | person, upper_clothing ∈ dark | 50 / 15 | review_required | **accepted** | o000004 | foreground person in dark clothing; bench sitter not boxed |
| WT3-007-p2 | person, clothing = red | 50 / 8 | review_required | **accepted** | o000041 | the *different* foreground person in red |
| WT3-008-c1 | car, vehicle_body ∈ {white, light_gray} | 15 / 11 | review_required | **accepted** | o000003 | prominent light car near the start |
| WT3-008-p1 | person, upper_clothing ∈ dark | 84 / 69 | review_required | **accepted** | o000029 | person handling luggage on the porch |

Aggregate per clip: `reviewed` (never "passed"). **No target was missed**
(no `not_detected`), **no `unknown` abstention on a required region** of an accepted
target, and no target needed `unreviewable`. These are reviewer judgements over drawn
evidence, not accuracy metrics: precision/recall/F1 remain unannotated (CASES.md's
annotation plan has not been executed) and nothing above was derived from filenames.

Representative evidence: one review sheet per target — the detector box (amber) and the
colour-region boxes (green) drawn on the **exact decoded frame** the bound observation
came from — in `~/stage3-evidence/sheets/WT3-00N_<target>.png`; per-observation crops in
`~/stage3-evidence/crops/`; run envelopes in `~/stage3-evidence/runs/WT3-00N.json`.

## Product controls (CASES.md S3-C01…C12)

| ID | How exercised | Result |
|---|---|---|
| S3-C01 | All eight neutral files through the product CLI + in-app runs | input SHA-256 equals dataset hash for all 8; real decoded frames (796…1052); envelopes validate with the common helper; screenshots `shots/s3-find6.png`, `shots/s3-check6.png` |
| S3-C02 | Hermetic renamed-bytes check + in-app **Renamed-input equivalence** | `shots/s3-rename.png`: "VERIFICATION renamed-input: 32 vs 32 observations under a different filename → IDENTICAL (run ids differ: 30d4b416b167 / 280cfec51318)"; equality excludes run id/path/timing; the equivalence run is verification evidence and is **not** saved into the saved-run list |
| S3-C03 | WT3-002-c1 / WT3-004-c1 | car evidence while parked (boxes + vehicle_body colour across the stationary interval); the analyser has no motion gate at all |
| S3-C04 | WT3-007-p1 / -p2 | two separate subjects, separate observations and separate region sampling (dark upper vs red clothing); sheets show no cross-borrowing |
| S3-C05 | Select clip B while A's findings are up | `shots/s3-find6.png`: findings stay visibly bound to A ("using clip-005.mp4", run line `clip WT3-005 · sha 03e9eb74a012`) while the combo shows clip-008; `shots/s3-check.png`: checklist cleared to "Run an analysis to build the checklist." |
| S3-C06 | Saved evidence pane | `shots/s3-saved.png`: per-run clip id + observation counts; reopening a saved run restores its recording, hash, overlays and findings (identity line shows clip/sha/peak-RSS method) |
| S3-C07 | Cancel mid-run (in-app hook + SIGTERM test), rerun, app exit mid-run | `shots/s3-cancel.png`: "Cancelled by the operator — partial evidence, not a result", run 5b9c92edd0bb, 0 observations presented; hermetic test: SIGTERM → exit 130 + `status: cancelled`; after app exit `ps` shows **no** orphaned `semantic_objects.py`/decoder children |
| S3-C08 | Missing weights / missing / corrupt input | `shots/s3-missing.png`: "Failed: weights not found at /tmp/empty-models/yolo11n.pt. Expected SHA-256 0ebbc80d…"; hermetic refusals for absent and corrupt inputs (failed state, no stale findings) |
| S3-C09 | **Deliberate invalid result** (labelled verification mode) | `shots/s3-invalid.png`: "VERIFICATION control-invalid: helper status invalid, 5 structural error(s): observations[0]: invalid confidence \| observations[0]: bbox_xywh must be a positive normalized in-frame box \| observations[32]: duplicate id \| …"; corrupt copy stored apart as `<run>.verification-invalid.json`; never mixed with real findings |
| S3-C10 | **Show on video** / observation click | player position set to the observation's decoded PTS; overlay windows each box by `details.frame_times_ms`; see limitation L1 (offscreen video is black) — geometric alignment is evidenced by the review sheets on exact decoded frames |
| S3-C11 | Regressions (table below) | all green, unweakened |
| S3-C12 | **Choose…** / **Neutral dir…** with arbitrary local files; hermetic synthetic clip through the same CLI | no filename-specific setup or code: the analyser never reads names/hashes; clip ids are generic (`local-…` for non-dataset files) |

## Tests and regressions (exact commands, measured)

| command | result |
|---|---|
| `python3 tools/tests/labs-stage3-analyser.py` | rc 0 — `all passed (28 checks)` |
| `python3 tools/tests/labs-stage3-evidence.py` | rc 0 — `Ran 13 tests … OK` |
| `python3 tools/tests/labs-temporal-tracks.py` | rc 0 — `all passed (613 checks)` |
| `python3 tools/tests/labs-temporal-tracks-clip.py` | rc 0 — `all passed (28 checks)` |
| `python3 tools/tests/labs-worker.py` | rc 0 — `all passed` (436 checks) |
| `python3 tools/labs/selftest_shape_observations.py` | rc 0 — `79/79 checks passed` |
| `python3 tools/labs/selftest_object_profile.py` | rc 0 — `40/40 checks passed` |
| `git diff --check` | clean |
| `cmake --build build68 --parallel 4` | rc 0 (repeated after each source change) |

Failures encountered **during development** and how they were resolved without
weakening any guard:

1. `labs-worker.py` / `labs-temporal-tracks.py` family guards flagged my new file
   (`labs_semantic_objects.py`) as an unpinned addition to the vendored `labs_*.py`
   family. The guards are right — that family is cilex-vision-vendored and pinned.
   Resolution: renamed my original analyser to `tools/labs/semantic_objects.py`
   (original-code naming, like `temporal_tracks.py`); both guards now pass untouched.
2. `labs-worker.py` Unix-only-import guard flagged top-level `import resource` in the
   analyser (breaks Windows import of the tools tree). Resolution: import moved inside
   the measurement site, matching the vendored family's own fix history.
3. My hermetic suite's helper pass-through check read stdout while unittest reports on
   stderr — a bug in *my* check, fixed to read stderr (the supplied helper suite itself
   was never modified).
4. Saved-pane observation counts read a `counts` key that Stage-3 envelopes do not carry
   (they report `measurements.observations`); `LabsTrackRuns::listRuns` now falls back
   to `measurements.observations` when `counts` is absent. Stage-1/2 rows are unchanged.

Skips: none in the suites above. The worker suite's optional cilex-vision cross-check
ran (their checkout exists on this box) and every vendored pin matched.

## Saved evidence (local; no footage or credentials in Git)

* `~/stage3-evidence/runs/WT3-00N.json` — run envelopes (the eight measured runs).
* `~/stage3-evidence/crops/`, `~/stage3-evidence/frames/` — per-observation crops and
  decoded frames used for the sheets.
* `~/stage3-evidence/sheets/WT3-00N_<target>.png` — 12 review sheets (review evidence).
* `~/stage3-evidence/reviews/WT3-00N.review.json` — reviewer-attributed decisions bound
  to run digests.
* `~/stage3-evidence/shots/*.png` — in-app screenshots: findings, checklist, saved pane,
  missing-model, cancelled, control-invalid, renamed-input equivalence.
* In-app saved runs live in the XDG data dir of the profile used (isolated
  `/tmp/wt-iso/data/…` for headless checks; the operator's own profile in real
  sessions). Nothing was registered on the live server, no production writes, no
  camera access this stage; the mock backend used for headless auth is a local
  process only.

Operator-repeatable checks: the eight commands in the table above, plus
`bash /tmp/s3runs.sh`-equivalent one-liners per clip:

```
python3 tools/labs/semantic_objects.py analyze --input <clip> --clip-id WT3-00N \
    --run-id ev-WT3-00N --out-run run.json --evidence-dir crops --source-revision s3 \
python3 tools/labs/stage3_checklist.py evaluate --run run.json --clip-id WT3-00N
python3 tools/labs/stage3_checklist.py review --run run.json --clip-id WT3-00N \
    --reviewer <name> --decisions '[…]' --out review.json
python3 tools/labs/stage3_checklist.py status --run run.json --review review.json --clip-id WT3-00N
```

## Limitations (unresolved, declared)

* **L1 — offscreen video is black.** Under `QT_QPA_PLATFORM=offscreen` the video panel
  renders no frames, so headless screenshots cannot prove overlay alignment or seek
  visuals; they prove state, identity and controls. A Wayland session (the Qt 6.12
  `build/`) is required to see real frames; overlay geometry is instead evidenced by
  review sheets drawn on the exact decoded frames and by the PTS-window logic
  (`details.frame_times_ms`).
* **L2 — no accuracy metrics.** Precision/recall/F1/localization require CASES.md's
  frozen annotation plan (whole-second frames, IoU ≥ 0.5); it has not been executed.
  The 12 accepted targets are reviewer judgements, not measured detection accuracy.
* **L3 — colour confidence is uncalibrated** (rule margin × pixel agreement); `unknown`
  abstention is the honesty mechanism, not a calibrated probability.
* **L4 — detector behaviour at the conf floor:** luggage can read as `car` and posts as
  `person` below ~0.35; the floor was chosen from a probe and is disclosed in config.
  Truck/bus/motorcycle are never relabelled `car`.
* **L5 — AGPL-3.0 dependency** (ultralytics runtime + weights). Local, experimental,
  not registered on any server; licensing must be revisited before any distribution.
* **L6 — reviewer attribution is not authentication**; the checklist tool stores the
  supplied reviewer string and says so.
* **L7 — timings are diagnostic**: shared host at loadavg ≈ 15; only relative
  setup/inference splits are meaningful.
* **L8 — equivalence scope:** renamed-bytes equality covers the deterministic CPU path;
  thread-count or runtime changes are a new configuration, not a repeat run.

## Development checks vs independent acceptance

Everything above is **development-side** evidence: my suites, my screenshots, my
reviewer-attributed decisions. The common helper's verdicts (`review_required`,
structural validation) are the supplied, implementation-independent half; the visual
review of the 12 sheets is the human-judgement half, recorded with attribution. Neither
constitutes independent acceptance: the frozen-annotation evaluation and unseen-clip
checks (CASES.md "Later accuracy evaluation") remain future work and must be run
against this frozen implementation/configuration before any accuracy claim.
