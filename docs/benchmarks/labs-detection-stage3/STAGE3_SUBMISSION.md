# Stage 3 submission — semantic analysers inside Cilex Watchtower

**Development record. Independent acceptance has NOT happened.** Every result below
is a development check run in this checkout; nothing here is a grade, and no
detector accuracy (precision/recall/F1) is claimed — the pack has no exhaustive
frame annotations and this submission did not create any.

## 1. Identity and preserved work

| | |
|---|---|
| Checkout root | `/home/cilex-vision/projects/cilex-watchtower-deepseek` |
| Branch | `benchmark/deepseek-labs-tracking` (kept throughout; no worktrees, no switches) |
| Starting revision | `7018c87db59c55fecd1e630ac9b1a228e3a2af72` (Stage 2 head), working tree **dirty** with the Stage 3 work below |
| Stage 1 (preserved) | `e7fd18b9dfa6ea93305dd819fcccb2e9f8e62723` — tracking engine, pushed |
| Stage 2 (preserved) | `7018c87db59c55fecd1e630ac9b1a228e3a2af72` — tracking in the product, pushed |
| Commit/push | **NOT authorised** by the launch message and not performed. The tree is left reviewable; `git status --porcelain` lists exactly the files in §9 |
| Stage 3 work | uncommitted; `docs/benchmarks/labs-tracking/SUBMISSION.md` and `STAGE2_SUBMISSION.md` untouched |

Earlier stages did not need completing for this assignment: the Stage 2 Labs
integration was already finished and pushed, and the new analysers reuse its
patterns (child-process analysis, isolated launch, honest states) without
changing it.

**Agent/model/settings** (recorded, not inferred from a label): DeepSeek Harness
`@deepseek-ai/dsh` 0.2.0-rc.2 on Node v24.18.0; provider `deepseek-official`,
model `deepseek-flash`, `reasoningEffort: max` — read from the active profile
patch layer (`~/.dsh/profiles/web/cordis.patch.yml`, entry `agent-default-model`).
UNVERIFIED from inside the session: the provider's immutable model snapshot id,
its server-side context/output limits, and whether any provider-side fallback is
configured. No subagents were used.

**Operator-authorised policy change to record:** this stage supersedes the Stage
1/2 prohibition on trained models and semantic classification, for these new
LOCAL analysers only. Nothing was registered or enabled on the live server, no
analyser default was changed, no footage was uploaded, and no remote/paid vision
API was used.

## 2. What was added, and why it is shaped this way

Two new analyser capabilities, as **one versioned pipeline** (they share one
decode and one inference pass, so they are identified together):

* `stage3-objects-colours` **1.0.0** — semantic object detection (`person`,
  `car`) with decoded-frame timestamps, confidence and normalized boxes, plus
  coarse object-linked colours for named regions (`upper_clothing`, `clothing`,
  `lower_clothing`, `vehicle_body`).

They sit **beside** the existing analysers: the geometric A4–A6 analysers, the
vendored B-series modules and their plugin registry, the Labs worker and the
Stage 1/2 temporal tracker are all untouched. The new pipeline is reachable from
the Labs screen only, as a local experimental workspace.

| File | Role |
|---|---|
| `tools/labs/stage3_evidence.py` | **Copied verbatim** from the coordinator's package (SHA-256 verified, §8). The common validator/evaluator. |
| `tools/tests/labs-stage3-evidence.py` | **Copied verbatim** (13 tests, OK). |
| `tools/labs/stage3_models.py` | Model registry: backend, licence, source URL, weights SHA-256, COCO→contract class map. |
| `tools/labs/stage3_colour.py` | The object-linked colour sampler (regions, HSV palette rule, background and clipped-object guards). |
| `tools/labs/stage3_detect.py` | The analyser run: one ffmpeg decode pass with real PTS per frame, sampled inference, colour sampling, local track references, evidence + `run.json`. **Never opens `dataset.json`.** |
| `tools/labs/stage3_evaluate.py` | The only place annotations are read: binds a run to its clip, calls the helper, reports candidates and coverage, reads the reviewer's decisions. |
| `tools/labs/stage3_checks.py` | The CASES.md product controls (S3-C01…C12) plus the suites, emitted as JSONL for the panel. |
| `tools/tests/labs-stage3-detector.py` | 57 hermetic unit checks for the sampler, geometry, NMS, linker, PTS parsing, observation shape, backend registry, and the "detector never loads annotations" rule. |
| `src/models/LabsDetection.{h,cpp}` | The in-app model: recording list, run lifecycle (child process, cancel, shutdown cleanup), observation index, evaluator calls, reviewer decisions, saved runs, checks. |
| `qml/LabsDetectionPanel.qml` | The Labs **Detection** workspace: player + object overlay, evidence crops, target review, verification. |
| `CMakeLists.txt`, `qml/Main.qml`, `qml/LabsScreen.qml`, `src/main.cpp` | Registration and a fourth Labs segment ("Detection"); review-hook environment flags. |

**Dependencies:** none added to the product's build. The analyser runs on the
host's existing Python 3.12.3 with torch 2.11.0+cu130, torchvision 0.26.0+cu130,
OpenCV 4.13.0, NumPy 2.4.4 (all pre-existing on this box). The C++/QML side uses
only Qt and the existing product libraries.

**Model choice, and the licence reason for it:**

| | |
|---|---|
| Backend | `fasterrcnn-mobilenet320` (default), also selectable: `fasterrcnn-mobilenet800`, `ssdlite320` |
| Weights | `fasterrcnn_mobilenet_v3_large_320_fpn-907ea3f9.pth`, 77,844,807 bytes |
| Source | `https://download.pytorch.org/models/fasterrcnn_mobilenet_v3_large_320_fpn-907ea3f9.pth` (fetched by torchvision itself) |
| Licence | **BSD-3-Clause** (torchvision code and published weights) |
| Local path | `~/.cache/torch/hub/checkpoints/` (outside the repo); `WT_STAGE3_WEIGHTS_DIR` can pin a vetted copy |
| `weights_sha256` | `907ea3f91ff92242bc1baea8049276a3e76bca48ce7560bd268cc029f37977b5` |

Watchtower is a shipped product, so licence was part of the choice rather than a
footnote: Ultralytics YOLO weights are AGPL-3.0 and would need the operator's
deliberate decision before entering a product dependency chain, so they are not
downloaded by this code. A torchvision COCO detector is BSD-3-Clause and already
present. Measured on clip-001, 10 frames: the 320 FPN variant found the person in
2 of 10 sampled frames at 78 ms/frame, the 800 variant in 2 of 10 at 379 ms/frame,
SSDLite in 1 of 10 at 34 ms/frame — the 320 FPN variant is the default for that
speed/quality balance, and the measured per-clip cost is in §7.

**How the pieces stay honest:**

* `stage3_detect.py` and `stage3_colour.py` never read filenames, clip ids or
  annotations — enforced by an AST check in the unit suite that fails if an
  annotation string appears in executable code (comments may say what is not
  read).
* `stage3_evaluate.py` is a separate program and the only reader of
  `dataset.json`; the panel calls it after inference.
* The review is a **separate object** bound to the run hash
  (`run_sha256 = evidence_digest(run)`), written beside the immutable run, and
  re-validated by the helper; an invalid or stale decision comes back as an
  explicit error rather than a silent save.
* Every observation carries its own object crop, and every colour carries the
  region box and the crop of exactly the pixels that produced it.

## 3. Build and launch

```sh
cd /home/cilex-vision/projects/cilex-watchtower-deepseek
cmake --preset default && cmake --build build      # Qt 6.12, clean
./run.sh                                          # the supported launcher
```

Then: sign in → **Labs** → **Detection**. Select a clip with *Stage 3 clips* (the
supplied `clip-001…008`, the ★ rows) or *Browse…* for any local recording; the
clip id fills in from the neutral name; press **Run analysers**. Review a run in
three tabs: **Objects** (boxes, timestamps, confidence, per-region colours, crops),
**Targets** (candidates and the reviewer's decision buttons), **Verification**
(the product controls and suites).

Headless reproduction of the checks and of a run, with the same code the panel
executes:

```sh
python3 tools/labs/stage3_checks.py --group all --workdir /tmp/s3-checks   # the checklist
python3 tools/labs/stage3_detect.py --recording /home/cilex-vision/Videos/Watchtower-Stage3/clip-007.mp4 \
        --clip-id WT3-007 --out /tmp/s3-run --sample-fps 2.5
python3 tools/labs/stage3_evaluate.py --run /tmp/s3-run --clip-id WT3-007
```

## 4. Per-clip candidates and reviewed outcomes

Analysed at 2.5 samples/s over every decoded frame of each clip (8 clips, 12,008
frames decoded, 1,998 analysed, 2,505 observations). A candidate is not a pass:
the table's "review" column is my own development review, performed by **viewing
the annotated frame plus the object and region crops the analyser saved** (the
contact sheets in `evidence/review-sheets/`), recorded through the same review
contract the panel writes. The reviewer string in every saved review says so:
*"deepseek-flash agent — development review (viewed annotated frame +
object/region crops)"*. An operator reviewing in the app presses the same buttons.

| Case | Target | Class | Required colour | Candidate observation (frame / PTS) | Colour evidence | Review |
|---|---|---|---|---|---|---|
| WT3-001 | p1 | person | `upper_clothing` ∈ {black, dark_gray} | `s3o000010` @ 00:17.650 | upper_clothing dark_gray 0.63 | **accepted** — man in a dark jacket; the label re-derives from his own torso crop |
| WT3-002 | p1 | person | `upper_clothing` ∈ {black, dark_gray} | `s3o000365` @ 00:33.200 | upper_clothing dark_gray 0.34 | **accepted** — person in a dark puffer with a bag |
| WT3-002 | c1 | car | `vehicle_body` ∈ {black, dark_gray} | `s3o000126` @ 00:01.000 | vehicle_body black 0.64 | **accepted** — the black sedan, stationary for the whole sampled interval |
| WT3-003 | p1 | person | — | `s3o000015` @ 00:02.400 | upper_clothing blue 0.31 | **accepted** — the foreground child on the scooter; the required class is person |
| WT3-004 | p1 | person | `upper_clothing` ∈ {black, dark_gray} | `s3o000154` @ 00:13.400 | upper_clothing black 0.61 | **accepted** — person from behind in a black jacket |
| WT3-004 | c1 | car | `vehicle_body` ∈ {black, dark_gray} | `s3o000292` @ 00:07.200 | vehicle_body black 0.45 | **accepted** — the black sedan while stationary |
| WT3-005 | p1 | person | `clothing` ∈ {red} | `s3o000012` @ 00:01.200 | clothing red 0.56 | **accepted** — person in a red suit walking the light dog |
| WT3-006 | p1 | person | `clothing` ∈ {red} | `s3o000004` @ 00:02.400 | clothing red 0.67 | **accepted** — person in red at the gate with the dog |
| WT3-007 | p1 | person | `upper_clothing` ∈ {black, dark_gray} | `s3o000040` @ 00:12.800 | upper_clothing dark_gray 0.55 | **accepted** — man in a dark top carrying a bag (the bag no longer supplies the lower band; see §10) |
| WT3-007 | p2 | person | `clothing` ∈ {red} | `s3o000108` @ 00:30.400 | clothing red 0.62 | **accepted** — the other foreground subject, woman in a red tracksuit; a different observation id from p1 |
| WT3-008 | c1 | car | `vehicle_body` ∈ {white, light_gray} | `s3o000014` @ 00:00.400 | vehicle_body white 0.37 | **accepted** — the light car near the start; low confidence, reported as such |
| WT3-008 | p1 | person | `upper_clothing` ∈ {black, dark_gray} | `s3o000264` @ 00:27.600 | upper_clothing black 0.67 | **accepted** — woman in a black coat handling luggage |

Totals for the supplied pack: **12 required targets, 12 candidates found, 12
accepted, 0 rejected, 0 unreviewable, 0 not_detected**, each clip's evaluator
status `reviewed`. Failures to produce evidence: **none** in this pack.

Detections by class over the eight clips: `other` 1664, `person` 512, `car` 261,
`dog` 51, `bag` 17. The `other` rows are dominated by benches (636) and potted
plants (312) with their native class preserved; they are extra labels, honestly
displayed, and they satisfy no target (`bus`/`truck`/`motorcycle`/`bicycle` are
deliberately not relabelled as `car`).

**Unknowns and misses that stay visible** (no required target depends on them):
WT3-003's rider returns `blue` 0.31 on the jacket shown in the classification
notes as blue, while her pink trousers stay `unknown` (medium target, not
required); WT3-007 p1 returns `green` on one of 30 upper-clothing samples (the
background hedge) and `unknown` on two; several observations return colour
confidences of 0.28–0.40 where the region mixes garment and background.

## 5. Product controls (CASES.md)

Full record: `evidence/checks-*.jsonl` (JSONL from the panel's own runner) plus
the screenshots. A check that cannot run reports SKIP with its reason; one check
is deliberately built to fail and the harness asserts it saw that failure.

| ID | Result | Evidence |
|---|---|---|
| S3-C01 ×8 | PASS | every supplied clip: `valid=True`, `input_sha256` equals the manifest hash, decoded frames 736–1052, crops present, no missing crop |
| S3-C02 | PASS | the same bytes under a different neutral filename produced identical detections and the identical input hash |
| S3-C03 | PASS | WT3-002: 130 car observations, longest near-stationary run 51.2 s; WT3-004: 117 observations, 17.6 s — semantic car evidence with no motion gate |
| S3-C04a | PASS | WT3-007 has 5 distinct person tracks |
| S3-C04b | PASS | every colour re-derives from that observation's OWN object crop with the shipped sampler (2,505 observations' regions checked; 0 mismatches, 0 region boxes outside their object box) |
| S3-C04c | PASS | one dark subject (n=30, dark_gray 18/30) and one red subject (n=19, red 17/19) |
| S3-C05/C06 | PASS | two runs stay bound to their own clip id and input hash; reopening A returns A's digest and observations |
| S3-C07 | PASS | SIGTERM mid-run: exit 3, `status=cancelled`, partial observations kept, no orphan process; the rerun completes |
| S3-C08 | PASS | missing input, corrupt input (random bytes as `.mp4`) and missing weights each produce a specific failure with no findings — the missing-model path is a prerequisite failure, never a no-detection result |
| S3-C09 | PASS | a tampered observation (box outside the frame) injected into a labelled verification directory is rejected by the helper/evaluator: `valid=false`, `status=invalid` with errors, never mixed with clip findings |
| S3-C10 ×8 | PASS | every observation's `frame_index` and `frame_pts_ms` match the decoded frame's own PTS in that run's `frames.jsonl` (0 mismatched of 2,505) |
| S3-C11 | PASS | see §6 |
| S3-C12 | PASS | a copy named `future-user-recording.mp4` analysed with no code change and its own clip id; the evaluator honestly reports "not in the dataset" instead of inventing annotations |
| control | FAIL (deliberate) + PASS | the deliberate check is reported as FAIL and the harness confirms it saw it |

Definitive run (final code, `tools/labs/stage3_checks.py --group all`,
2026-10-05): **39 checks passed, 1 deliberate control failure, 0 skipped, 0 real
failures**, 184 s. Group totals: supplied 21/21, controls 12 passed + 1 control,
checks 2/2 (the helper's 13 tests and the detector's 57 units), regressions 4/4.
Two detail points from that record: S3-C02 compared 73 detections under two
filenames with identical hashes, and S3-C07's cancelled run kept 0 observations
(it was stopped before its first sample at 0.2 samples/s) and then a clean rerun
produced 3 — partial and completed are visibly different states, and neither is
reported as a pass.

## 6. Suites and regressions

| Suite | Result |
|---|---|
| `tools/tests/labs-stage3-evidence.py` (copied verbatim) | 13 tests, OK |
| `tools/tests/labs-stage3-detector.py` (new) | 57 PASS, 0 FAIL |
| `tools/tests/labs-temporal-tracks.py` (Stage 1, unmodified) | 316 PASS, 0 FAIL |
| `tools/tests/labs-worker.py` (existing) | 436 assertions, all passed |
| `tools/labs/selftest_shape_observations.py` | 79/79 checks passed |
| `tools/labs/selftest_object_profile.py` | 40/40 checks passed |
| `git diff --check` | clean |

No protected test was modified or weakened. The Stage 1 and Stage 2 files are
byte-identical to their submitted commits.

## 7. Measurements

Method: `time.perf_counter` around the run; peak RSS from
`resource.getrusage(RUSAGE_SELF).ru_maxrss` read once at the end — this is
**peak RSS**, not net RSS, and it includes the torch runtime. Hardware/runtime:
shared 20-core Linux dev box (load 13–17 during these runs), CPU only
(`torch.cuda.is_available()` false), `torch.set_num_threads(6)`, decode width
1280, sampling 2.5/s.

| Clip | Wall | Model load | Peak RSS | Frames decoded | Analysed | Observations |
|---|---:|---:|---:|---:|---:|---:|
| WT3-001 | 17.4 s | 0.38 s | 822 MiB | 796 | 133 | 19 |
| WT3-002 | 18.5 s | 0.19 s | 804 MiB | 781 | 130 | 381 |
| WT3-003 | 17.2 s | 0.15 s | 814 MiB | 902 | 150 | 56 |
| WT3-004 | 19.0 s | 0.17 s | 821 MiB | 797 | 132 | 397 |
| WT3-005 | 13.4 s | 0.13 s | 813 MiB | 736 | 123 | 32 |
| WT3-006 | 16.2 s | 0.16 s | 824 MiB | 782 | 130 | 27 |
| WT3-007 | 20.1 s | 0.18 s | 818 MiB | 1052 | 175 | 199 |
| WT3-008 | 19.5 s | 0.17 s | 819 MiB | 902 | 150 | 399 |

Eight supplied clips: **141 s** of analysis in total, 12,008 frames decoded,
1,998 analysed. Setup (torch/torchvision already present; weights fetch and first
load) ≈ 3 minutes once. Review: ≈ 20 minutes of my own wall-clock to build the 12
contact sheets and view each target's frame, crops and colour regions. These are
shared-host numbers, not a controlled throughput measurement.

## 8. Hashes and provenance

* Supplied package copied into the checkout, byte-identical against
  `package-manifest.json`: all ten copied files verified (the manifest's
  `prepare_stage3_clips.py` is provenance and was not copied).
* Clip hashes: the runs' `input_sha256` equal the manifest hashes for all eight
  clips and the evaluator checks that binding on every run.
* Model weights: `907ea3f91ff92242bc1baea8049276a3e76bca48ce7560bd268cc029f37977b5`
  (source URL above; the model probe compares the file against this value on
  every start).
* Implementation identity: every `run.json` carries `source_revision`
  (`<git HEAD>-dirty`) plus a `files_sha256` map and `implementation_sha256`
  over `stage3_detect.py`, `stage3_colour.py`, `stage3_models.py` and
  `stage3_evidence.py`, so a dirty checkout is still identifiable.
* Effective configuration is stored whole in each run (thresholds, decode width,
  sampling mode/rate, colour geometry and thresholds, device, seed).

## 9. Evidence locations (local, nothing committed)

Inside the checkout (part of the reviewable tree, no footage):

* `docs/benchmarks/labs-detection-stage3/evidence/01-detection-objects-evidence.png`
  — the panel: object boxes with class/confidence/colour, the legend naming the
  decoded frame, and the observation's own crop and per-region crops.
* `…/02-targets-review.png` — the Targets tab: candidates, required colours,
  the reviewer field and the decision buttons.
* `…/03-verification-checks.png` — the Verification tab with 21 passing checks.
* `…/04-panel-completed-run.png` — a completed run's status, model card, clip facts.
* `…/reviews.json` — the development review as data: per clip, the reviewer, the
  run/input digests the decisions bind to, and each target's decision,
  observation ids and note. Pixel-free, so it is committable.
* `…/checks-*.jsonl` — the JSONL check records.

The 12 review sheets (annotated frame beside the object and region crops) that my
review was actually made from are **not committed**: they contain frames of the
supplied recordings, and the pack's rule is that evidence stays local and no
footage enters Git. They are reproducible on any machine with
`tools/labs/stage3_review_sheets.py` (reads a run's own `run.json` and crops,
writes to `$WT_STAGE3_SHEETS`, default a temp directory).

Outside the checkout (never committed): the runs and their evidence
(`~/.local/share/Cilex Vision/Watchtower/stage3/runs/<clip>-<stamp>/`: `run.json`,
`observations.jsonl`, `frames.jsonl`, `crops/*.png`, `review.json`), the model
weights in the torch cache, and the supplied clips at
`/home/cilex-vision/Videos/Watchtower-Stage3/`.

To repeat: `python3 tools/labs/stage3_checks.py --group all` reproduces every
control; `--group supplied` re-validates the existing runs without new inference;
the panel's **Verification** tab runs the same program.

## 9b. macOS / Apple Silicon: what I changed, what I could NOT do

**The Mac binary cannot be produced from this host.** The repo's own flow builds
it *on the Mac*: `packaging/macos/build-local.sh` refuses any machine that is not
`arm64`, links Homebrew Qt, and produces a thin `watchtower.app` zip; launch is
`./run-macos.sh` (the Linux `run.sh` deliberately refuses there). This host is
Linux/x86-64 with no macOS SDK and no arm64 Qt, so **no macOS build was produced
or run, and nothing about macOS behaviour is verified.** What follows is the
command sequence for the Mac plus the portability fixes this assignment did make.

Exact commands on an Apple-Silicon Mac:

```sh
brew install qt qt-multimedia gstreamer           # the documented prerequisites
git switch benchmark/deepseek-labs-tracking       # this checkout/branch
./packaging/macos/build-local.sh                  # configure + build + zip into build-macos/
./run-macos.sh                                    # launch (banner prints the bundle version)
```

Stage 3 needs a Python with torch/torchvision **on the Mac** (the app bundles
ffmpeg but not Python), and the supplied clips in the platform's Movies folder:

```sh
python3 -m venv ~/.local/share/wt-stage3 && ~/.local/share/wt-stage3/bin/pip install \
        torch torchvision opencv-python numpy
mkdir -p ~/Movies/Watchtower-Stage3 && cp <pack>/clip-*.mp4 ~/Movies/Watchtower-Stage3/
WT_PYTHON=~/.local/share/wt-stage3/bin/python3 ./run-macos.sh
```

Portability defects found in my own Stage 3 code and fixed (then re-verified on
Linux: 57 unit checks pass, a live clip run completes, the supplied group still
passes 21/21):

| Was Linux-only | Now |
|---|---|
| `ru_maxrss` treated as KiB | bytes on `darwin`, KiB elsewhere, with the unit stated in the measurement method — the old code would have reported 1024× the true peak RSS on a Mac |
| torch hub cache hardcoded to `~/.cache/torch/hub` | asked of `torch.hub.get_dir()` (macOS: `~/Library/Caches/torch/hub`), with a per-user fallback |
| `ffmpeg`/`ffprobe` from PATH only | `WT_FFMPEG`/`WT_FFPROBE` first; the panel passes the app's own ffmpeg (`ClipTranscoder::ffmpegProgram()`, the bundled LGPL build) into the analyser, then PATH |
| Stage 3 clips at `/home/cilex-vision/Videos/...` | `WT_STAGE3_CLIPS` → `<Movies>/Watchtower-Stage3` → the dev path only if it exists |
| user data dirs under `~/.local/share` | `~/Library/Application Support/...` on macOS, XDG elsewhere |

Still unverified on macOS (stated plainly): the build itself, the QML panel on
Cocoa, `VideoOutput` rendering, the bundled-ffmpeg hand-off, and inference speed
on M1. A Mac-side run of `tools/labs/stage3_checks.py --group all` is the first
thing to do there.

## 10. Limitations, failures and unverified items

1. **No accuracy claim.** The pack has no exhaustive frame annotations, so no
   precision, recall, F1, IoU or false-positive rate is computed or implied. The
   twelve targets are filename-sourced POSITIVE targets; a matching label is a
   candidate awaiting review, never a pass.
2. **The review in §4 was performed by the development agent, not an independent
   operator.** Every saved review names that reviewer. Independent acceptance
   remains outstanding.
3. **Colour sampling is a coarse HSV rule, and it shows.** Measured weaknesses:
   `lower_clothing` mislabels light trousers as `dark_gray` on some frames
   (WT3-001), a bag carried at the hip took the whole lower band before the
   region was narrowed (WT3-007 p1 — the fix is in, the residual cases are
   `unknown`), a mid-grey band abstains by design, and one sample in 30 returned
   `green` from background foliage. No required target depends on
   `lower_clothing`, and every colour's confidence is the share of the region's
   pixels, not a calibrated probability.
4. **Rendered video is not in the screenshots.** The offscreen QPA does not
   composite `VideoOutput`, so the picture area is black in all panel
   screenshots: an empty video panel cannot prove overlay alignment, and it is
   not offered as proof. Alignment is evidenced instead by the panel legend
   naming the decoded frame at the playhead, by S3-C10 (every observation maps to
   the decoded frame's own PTS), and by the review sheets, which draw the boxes
   on frames extracted from the clip.
5. **A real login was not performed in the app.** The Labs screen is behind
   `AuthController.authenticated`; for screenshots only, two `qml/Main.qml`
   visibility lines were temporarily forced and **reverted** — the committed-diff
   of `Main.qml` is exactly the four lines that add the model. Everything else in
   the shots is the real panel running the real analyser.
6. **Small and distant objects are missed** by a 320-pixel COCO detector; the
   pack's medium/hard targets (distant seated person, dog/bag colours, garment
   types, luggage handling, plate text) are not evaluated, and no action, OCR,
   demographic or cross-camera identity capability was added.
7. **Host conditions**: all timings are from a busy shared host and are
   diagnostic. Peak RSS (~820 MiB) is dominated by the torch runtime and is
   reported as peak, not net.
8. **`frame_index` counts decoded frames**, and the clips are genuinely VFR
   (clip-001: 50 ms and 100 ms steps, average 15.05 fps while the container
   claims 20/1). Timestamps come from each decoded frame's own `pts_time`; a
   frame the decoder cannot time is recorded as untimed and never used as
   evidence.
