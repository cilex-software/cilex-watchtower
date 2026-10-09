# Stage 4 submission — compact learned object, size and colour analysers

**Development record. No Stage 4 accuracy has been independently evaluated.** Every
number below was measured in this checkout, on the released public
training/development data, by the commands quoted with it. The private evaluation
described in `EVALUATION.md` has not happened, and nothing here is a grade.

**Accuracy headline, stated first because it is the most important result:**
neither frozen approach reaches usable detection quality on the held-out public
groups. Both learn (training loss falls, and the same model overfits a 12-frame
batch to p≈0.9 in 300 steps), but on unseen clips the class scores stay near the
initialization prior and the localisation does not converge, so fixed-threshold
precision/recall on validation is **0.000** for both A and B. The controls,
the contract, the product integration and the resource budget are verified; the
recognition quality is not, and §9 says exactly what that means and what would be
needed. This is reported rather than smoothed over: the assignment anticipates it
("a small public data set may not support reliable unseen scenes; state that
limitation").

## 1. Identity

| | |
|---|---|
| Checkout | `/home/cilex-vision/projects/cilex-watchtower-deepseek` |
| Branch | `benchmark/deepseek-labs-tracking` |
| Starting revision | `701a1d26d6fb9e894beed3e05cc4caf6a66dad11` (Stage 3, pushed), working tree **dirty** with Stage 4 |
| Preserved | Stage 1 `e7fd18b`, Stage 2 `7018c87`, Stage 3 `701a1d2` — reports, evidence and weights untouched; no earlier submission file was overwritten |
| Commit/push | **Not authorised and not done.** All work is local; `git status --porcelain` lists the Stage 4 additions |
| Agent/runtime | DeepSeek Harness 0.2.0-rc.2, provider `deepseek-official`, model `deepseek-flash`, `reasoningEffort: max` (read from the active profile patch, `agent-default-model`). UNVERIFIED from inside the session: the provider's immutable model snapshot id and its server-side fallback configuration |
| Task inputs read | only `docs/benchmarks/labs-detection-stage4/*` and `/home/cilex-vision/Videos/Watchtower-Stage4/` (the files listed in its `inputs.json`) |

Nothing was registered, activated or written to the live server; no camera, export
or production-findings path was touched.

## 2. What was built

Two approaches with one shared inference path, selectable in the product:

| Approach | Trunk | Learned components | Params |
|---|---|---|---|
| **A — from scratch** | 5 strided convolutions, GroupNorm, seeded random init | everything | 284,255 |
| **B — pretrained encoder + trained head** | torchvision **ResNet-18**, IMAGENET1K_V1 (BSD-3-Clause), **frozen** | 1×1 laterals + the whole anchor-free head | 11,230,503 total, 110,591 trained |

Both use the same anchor-free head (3 class heatmap channels + 4 box channels at
stride 4), the same Gaussian target encoding, the same decode/NMS, the same colour
sampler and the same product surface, so a difference between them measures the
trunk. Explicitly **not used**: any YOLO implementation, weight, derived backbone,
teacher or YOLO-generated label — enforced by a unit check that scans the Stage 4
executable code for such references, and by the fact that nothing is downloaded
except the ResNet-18 classification weights (training time only).

Files (all new, nothing overwritten):

| File | Role |
|---|---|
| `tools/labs/stage4_analyse.py` | the contract entry point; thin, so the app and the CLI cannot diverge |
| `tools/labs/stage4_detect.py` | decode with real PTS, scheduled inference, colour, coverage, run envelope v4 |
| `tools/labs/stage4_model.py` | A and B architectures, targets, focal/box losses, decode, NMS, offline checkpoint load |
| `tools/labs/stage4_data.py` | released labels → frozen grouped split → cache, augmentation, letterbox mapping |
| `tools/labs/stage4_colour.py` | sRGB↔Lab D65, CIEDE2000, per-region support with crop/mask, unknown with a reason |
| `tools/labs/stage4_filters.py` | the V1 filters (type/size/colour/location/time/camera) |
| `tools/labs/stage4_train.py` | real training for both approaches: logs, checkpoints, before/after validation |
| `tools/labs/stage4_evaluate.py` | max-cardinality matching, P/R/F1, size confusion, colour scoring |
| `tools/labs/stage4_eval_public.py` | the public-development evaluation report |
| `tools/labs/stage4_checks.py` | S4-C01…S4-C16 as JSONL |
| `tools/tests/labs-stage4-units.py` | 49 hermetic unit checks |
| `tools/tests/fixtures/stage4/` | the published CIEDE2000 pairs (+ provenance), the shared filter cases, the memory probe |
| `src/models/LabsStage4.{h,cpp}`, `qml/LabsStage4Panel.qml` | the product workspace: A/B choice, filters, evidence, runs, verification |
| `CMakeLists.txt`, `qml/LabsScreen.qml`, `qml/Main.qml`, `src/main.cpp` | a fifth Labs tab plus the filter-selftest hook |

## 3. Training, and the data it used

The split is frozen in `tools/labs/stage4_data.py` and `build/stage4/split.json`
before any training, with the rule recorded:

* unit = the released `minimum_leakage_group`, so neighbouring frames, crops and
  augmentations of one scene can never straddle fitting and validation;
* validation = `archive-scene-008`, `archive-scene-016`, `archive-scene-019`
  (146 human / 52 car / 44 animal instances over 135 frames) — chosen by label
  coverage so each class has validation positives while the fitting side keeps 57
  of the 101 animal instances;
* fitting = the other 25 clips (1214 frames, 621 human / 105 car / 57 animal).

Inputs are the released decoded keyframes (declared, as `DATASET.md` permits);
official video inference runs on decoded video pixels instead. Cache and
checkpoints live under `build/stage4/` (git-ignored); **no footage or checkpoint
enters Git.**

Measured training (real optimization, per-epoch logs in
`build/stage4/training/*/train-log.jsonl`, manifests beside them):

| | A — from scratch | B — ResNet-18 trunk |
|---|---|---|
| Command | `python3 tools/labs/stage4_train.py --approach A --epochs 50 --batch 12 --seed 20261006 --threads 4 --lr 0.005 --val-every 10 --tag A-scratch` | `… --approach B --epochs 40 --batch 12 --seed 20261006 --threads 4 --lr 0.003 --val-every 10 --tag B-resnet18` |
| Epochs / wall time | see `manifest.json` | see `manifest.json` |
| Checkpoint sha256 | see §8 | see §8 |
| Initialization | random (seed 20261006) | ImageNet ResNet-18 trunk, frozen; head/laterals random |

Measured results, both from `build/stage4/training/*/manifest.json` and the per-epoch
JSONL beside them:

| | A — from scratch | B — ResNet-18 trunk |
|---|---|---|
| Final checkpoint | `build/stage4/training/A-scratch/final.pt` | `build/stage4/training/B-resnet18/final.pt` |
| Checkpoint sha256 | `a913cb25df8392c3984e00084005a6a2f7343d61410f7e6d9a12e4c117685a90` | `bbf26d0dc59401fd685ea77215068e2696c4667008b1c3714dd6449d3a066686` |
| Parameters | 284,255 (all trained) | 11,230,503 total, **110,591 trained** — the manifest says 53,991 trainable |
| Wall time | 941 s (50 epochs, ~19 s/epoch) | 1811 s (40 epochs, ~45 s/epoch) |
| Training peak RSS | 702 MiB | 877 MiB |
| Training data | 1214 fitting frames (621 human / 105 car / 57 animal) | same frames, same split hash |
| Validation | 135 frames (146 human / 52 car / 44 animal) | same frames |

Learning happened — the losses fall and a 12-frame batch is memorized to p≈0.9 in
300 steps — but **generalisation did not**: on the validation groups both models
put every class score at or below 0.10 (the initialization prior) and the
fixed-threshold result is 0 TP with 242 FN. The measured scores and their best
achievable IoU on validation are in the evidence directory, and §9 discusses it.

## 4. The V1 contract

* **Object type**: `human`, `car`, `animal`; no bicycle/bus/truck relabelling —
  the released labels are used exactly as published.
* **Apparent size**: `area_fraction = w·h` in normalized source coordinates after
  reversing the detector's letterboxing, with the exact 0.01 / 0.10 boundaries and
  a `truncated` flag when the box touches a frame edge.
* **Colour**: one dominant record per region, with broad label, representative
  sRGB (0–255), CIELAB D65, support bbox, support mask, supporting pixel count and
  a source-bound crop; `unknown` carries a reason and null numerics.
* **Colour location**: `upper_clothing`, `lower_clothing`, `vehicle_body`, `coat`;
  `either` is a query option, not an observation region.
* **Query**: picked sRGB → Lab D65 → `ΔE00 ≤ tolerance`, with the control spanning
  0–40 and 10/20/30 as the frozen evaluation points.
* **Time / camera / area**: metadata filters; a recording without that metadata
  cannot satisfy them (unknown is not "matches everything").

## 5. Product workflow

Labs → **Stage 4** (a fifth tab beside Statistics / Analyser Settings / Tracking /
Detection): choose a recording, choose **A** or **B**, run, then filter by type,
size, colour (swatches or the tolerance slider), colour location, with the
uncertain bucket opt-in and shown separately. Selecting an observation shows its
crop, each region's support crop and numeric colour, the ΔE to the query and the
reason when it does not match. Saved runs can be reopened; verification runs
S4-C01…S4-C16 in the panel.

The filters exist twice on purpose (C++ for interaction, Python for scoring) and
are pinned together: `tools/tests/fixtures/stage4/filter_cases.json` is run through
both, and `WT_LABS_STAGE4_FILTER_SELFTEST=<file>` makes the product print its
verdicts so a divergence fails a control.

Evidence: `docs/benchmarks/labs-detection-stage4/evidence/` (panel screenshots and
the check records). Runs and their crops/masks live under
`build/stage4/runs/` — local only, no footage in Git.

## 6. Controls S4-C01…S4-C16

Definitive run (`python3 tools/labs/stage4_checks.py --group all`, record in
`evidence/checks-2026-10-06.jsonl`): **12 passed, 2 skipped, 1 real failure, 1
deliberate control failure** (151 s).

| ID | Status | What the record says |
|---|---|---|
| S4-C01 | PASS | A sha `a913cb25df83` (50 epochs) and B sha `bbf26d0dc594` (40 epochs) are distinct, both trained on the same frozen split, with before/after validation on identical frames |
| S4-C02 | PASS | a renamed byte-identical copy gives the same input hash and identical detections; an unseen synthetic `testsrc` recording is analysed to `completed` with its own identity; runs executed with the torch cache hidden and the proxy pointed at a closed port |
| S4-C03 | **SKIP** | the frozen-threshold validation runs hold no detections at all, so there is no stationary example to judge: **not measured**, not passed. No motion gate exists in the inference path (checked) |
| S4-C04 | PASS | boundaries 0.01/0.10 exact for 0, 0.005, 0.009999, 0.01, 0.0999, 0.10, 0.5, 1.0; source-coordinate restoration exact to 5.6e-17; a truncated object abstains with a reason |
| S4-C05 | PASS | all 33 published CIEDE2000 pairs within 4.9e-5; black/dark_gray/light_gray/white distinct, mid grey abstains; the tolerance boundary is inclusive and raising it never removes a match |
| S4-C06 | **SKIP** | the synthetic part passes (a red neighbour and a red bag outside the region do not supply the colour); the real-example part has nothing to check because the validation runs are empty |
| S4-C07 | PASS | all 13 shared filter cases agree with their expectation in **both** the Python and the C++ boundary; no disagreements; the C++ CIEDE2000 matches the published pairs to 4.9e-5 |
| S4-C08 | PASS | 44 scheduled frames, 44 coverage records, 44 analysed, 0 failed; no PTS drift, no duplicate ids, no out-of-range boxes, no disagreement with the released frame manifest |
| S4-C09 | PASS | A→B→A: A's checkpoint identical both times, B's distinct, architectures `scratch-cnn-anchorfree` vs `resnet18-frozen-trunk-anchorfree-head`; observation ids are per-run and crops live inside each run directory |
| S4-C10 | PASS | every required envelope key present; referenced evidence listed in the artifact manifest; a removed crop is detectable as absent |
| S4-C11 | PASS | after SIGTERM the run reports `cancelled` with no orphan analyser processes; a cancelled run is never reported as completed |
| S4-C12 | PASS | missing input, corrupt input, empty file, absent weights and a wrong weight hash each fail with a nonzero exit and no reused detections |
| S4-C13 | FAIL (deliberate) | the control that must fail; the harness asserts it saw the failure |
| S4-C14 | **FAIL** | peak summed RSS of the analyser tree (python + ffmpeg, 0.05 s sampling): 793.9 / 818.0 / 809.6 MiB on the three runs; **1 GiB maximum met, 512 MiB target exceeded** — §7 |
| S4-C15 | PASS | playback timestamps equal the scheduled PTS within 1 ms; produced by the same entry point the worker calls. **Isolated adapter boundary**: no server registration, no live findings, and the video surface was not shown with pixels (see §9) |
| S4-C16 | PASS | tracking suite 316 PASS, Labs worker all passed, shape self-test, object-profile self-test, the 49 Stage 4 unit checks, `git diff --check` clean, product binary present |

Two earlier control runs were wrong and are reported as such: four checks died with
`NotADirectoryError` because the run glob also matched the `<run>.log` files beside
each run, the cancel check sent SIGTERM after such fast runs had already finished
(so it "cancelled" nothing), the stationary check failed where it should have
skipped, and the orphan test blamed a stale analyser from a pre-fix batch. All four
harness bugs are fixed; the failure record above is from the fixed harness.

## 7. Resources

**The budget is not met, and this is the honest headline for resources:**
1 GiB maximum **met** (worst tree peak measured 901 MiB on B's torch path, 821 MiB
on B's ONNX path), 512 MiB target **exceeded** (best tree peak 700 MiB).

Measured with `tools/tests/fixtures/stage4/mem_probe.py` (samples the whole
process tree's summed RSS every 0.05 s; 220-465 samples per run; probes saved in
`evidence/`). Hardware: shared 20-core Linux box, CPU only, `torch.set_num_threads(2)`
/ two ONNX threads, ffmpeg decode at 1280 wide.

| Run | Runtime | Peak tree RSS | Notes |
|---|---|---:|---|
| A, validation clip | ONNX | **703 MiB** | cold load of the export |
| B, validation clip | ONNX | **700 MiB** | cold |
| A, validation clip | torch | 793 MiB | same clip, torch path |
| B, validation clip | torch | 901 MiB | worst measured |
| A / B, decode width 640 | ONNX | 700 / 721 MiB | width barely matters |
| A / B, decode width 960 | ONNX | 749 / 759 MiB | |
| C14 control (A, B, A) | ONNX | 794 / 818 / 810 MiB | sampling noise makes single runs ±60 MiB |

What dominates: the Python + NumPy + **OpenCV** + ONNX Runtime baselines and
ffmpeg's decode buffers, not the model (A's checkpoint is 1.1 MiB, B's 45 MB) and
not the frame width. What was tried, and what it did: ONNX Runtime instead of torch
at inference (**−90 to −200 MiB** and a reported runtime in every run), a decoder
fix that stopped ffmpeg duplicating frames (1124 → 680 frames per clip), removing a
hidden `import torch` that existed only to read a version string, capping OpenCV /
OpenMP threads at two, disabling the ORT CPU arena, `malloc_trim(0)` after load, and
decode widths 640/960/1280 (no material effect). Reaching 512 MiB would need an
inference stack without OpenCV and without a Python-grade runtime baseline; that is
future work, not something this submission claims.

Speed, from the runs' own metrics (44 scheduled frames per clip, 1 Hz policy):

| | A | B |
|---|---|---|
| Inference | 7.5 ms/frame mean | 7.5 ms/frame mean |
| Colour sampling + evidence | ~0 ms/frame on empty frames; 78 s total on a 1333-observation demonstration run | same code |
| Decode (timestamp pass + pixel pass) | ~5.4 s per 45 s clip | same |
| Whole run | 6-14 s per clip | 8-17 s per clip |

That is well inside the "≥ 1 analysed frame per second of video" requirement, and
the colour sampler is what costs when there is something to describe (≈ 58 ms per
observation including crops and masks).

Separately measured training resources (not part of the inference budget):
A 941 s / 702 MiB peak, B 1811 s / 877 MiB peak, both on the same 4-thread
allowance, with no GPU (`torch.cuda.is_available()` false).

## 8. Frozen identities

Frozen for later evaluation — source, configuration, checkpoints and runtime:

| Item | Identity |
|---|---|
| Source revision | `701a1d26d6fb9e894beed3e05cc4caf6a66dad11` + the Stage 4 working tree (dirty; `git status --porcelain` lists every file) |
| Implementation hash | every `run.json` carries `implementation.source_files_sha256` for `stage4_detect.py`, `stage4_model.py`, `stage4_colour.py`, `stage4_data.py`, `stage4_evaluate.py` plus an `implementation_sha256` over them |
| A checkpoint | `build/stage4/training/A-scratch/final.pt`, sha256 `a913cb25df8392c3984e00084005a6a2f7343d61410f7e6d9a12e4c117685a90`, 1,143,603 bytes, 284,255 params, 50 epochs, seed 20261006 |
| B checkpoint | `build/stage4/training/B-resnet18/final.pt`, sha256 `bbf26d0dc59401fd685ea77215068e2696c4667008b1c3714dd6449d3a066686`, 44,997,475 bytes, 11,230,503 params (53,991 trained), 40 epochs, seed 20261006 |
| A ONNX export | `build/stage4/training/A-scratch/final.onnx`, 164,115 bytes, opset 17, verified against torch at max abs difference 1.34e-5 |
| B ONNX export | `build/stage4/training/B-resnet18/final.onnx`, 799,093 bytes, opset 17, same verification |
| B's pretrained trunk | torchvision **ResNet-18 IMAGENET1K_V1** (`https://download.pytorch.org/models/resnet18-f37072fd.pth`), BSD-3-Clause, frozen — **not** a YOLO weight and not the MobileNetV3-Large used in Stage 3 |
| Split | `build/stage4/split.json`, `split_sha256` recorded identically in both manifests; rule and group list in §3 |
| Configs | each run stores the complete effective configuration (threshold, decode width, sampling policy, colour thresholds, region geometry, threads, runtime, seed) |
| Runtime versions | Python 3.12.3, NumPy 2.4.4, OpenCV 4.13.0, ONNX Runtime 1.24.4, torch 2.11.0+cu130 / torchvision 0.26.0+cu130 (training only) |
| Unit checks | `tools/tests/labs-stage4-units.py`: **49 PASS, 0 FAIL** |

Usage for the coordinator:

```sh
python3 tools/labs/stage4_analyse.py --input /abs/clip.mp4 --approach A \
    --config /abs/config.json --schedule /abs/schedule.json --output /abs/new-run-dir
```

`--approach B` selects the other frozen model; `--schedule` is optional (without it
the fixed native 1 Hz PTS policy is recorded in the run). A schedule carries only
`input_sha256` and frame index/PTS pairs — never expected classes, boxes or colours
— and a schedule that disagrees with the input is rejected rather than
approximated.

## 9. Limitations, failures and unverified items

1. **Recognition accuracy is not demonstrated.** On the held-out public groups
   both frozen approaches produce no detection above the frozen operating point
   (0 TP / 242 FN, precision undefined because nothing was predicted). Lowering the
   threshold to 0.05 buys 29 TP at the cost of 3190 FP (F1 0.017 at IoU 0.5, 0.028
   at IoU 0.3) — no usable operating point exists on this evidence. The A/B
   comparison therefore reports a *learning* difference, not an accuracy contest:
   B (pretrained trunk) reaches higher scores and lower loss sooner, and both fail
   the same way — high-confidence peaks do not appear on unseen scenes.
2. **Why it failed, as far as the measurements go.** The models memorize a
   12-frame batch (p ≈ 0.9) but do not generalise: 1214 fitting frames with 783
   object instances is very little for a from-scratch detector, and ~46% of the
   instances are `small` (area < 0.01, under 26 px at the 256-px input), which the
   chosen input size renders nearly invisible. BatchNorm's running statistics also
   collapsed approach A's heatmap at evaluation time (eval 0.08 vs train 0.20 on
   one checkpoint), fixed by switching A to GroupNorm — that change makes A and B
   differ in *two* ways (trunk and normalisation) and is disclosed here for that
   reason.
3. **What was NOT tuned against anything private.** No private data exists yet; the
   operating point, split, architecture and thresholds were chosen on public
   development evidence only, and the split was frozen before training.
4. **Colour and size metrics are `not measured`, not zero.** With no matched
   objects in the validation runs there are no matched colours to score; the
   colour machinery is verified by formula and synthetic checks (S4-C04, C05, C06,
   C07) and exercised end-to-end on the demonstration runs, whose broad-colour
   accuracy is reported only as a plumbing figure.
5. **Demonstration runs are not accuracy evidence.** `build/stage4/demo-runs/*`
   analyse a *fitting* clip (the model trained on it) at threshold 0.05 to exercise
   crops, masks, colours, coverage and filters. They are labelled `demo` and must
   not be read as generalisation.
6. **Numeric colour references do not exist in the public pack** (`srgb: null`,
   `numeric_reference_status: not_annotated`), so numeric colour accuracy against
   references is `not measured`; the numeric path is exercised through the filter
   queries, whose observed side is real measured sRGB.
7. **The memory target was not met** (700-820 MiB tree against a 512 MiB target;
   the 1 GiB maximum is met). Details and everything tried in §7.
8. **The video surface was not shown with pixels.** The panel screenshot was taken
   through the offscreen QPA, which does not composite video, so overlay alignment
   is *not* claimed from it. Playback timestamps are verified against the scheduled
   PTS (S4-C15), and overlay drawing is the same code path Stage 3 verified.
   A session on a real display would be needed to claim visual alignment.
9. **The product boundary is isolated.** The analyser runs as a local child process
   from the Labs tab; nothing was registered on the server, no analyser default was
   changed, no live findings were written and no camera was touched. The worker's
   own delivery path was not exercised, because that would mean a live registration.
10. **Animal coverage is thin by construction**: 101 animal instances across a few
    scenes (mostly dogs), so no species claim is made — §2 of the objective asks for
    an honest statement, and this is it: the animal class has training data for
    roughly one species family and no validation positives in some groups.
11. **Two check groups are skipped**, and a skipped control is not a passed one:
    S4-C03 (stationary) and S4-C06's real-example half, both because the frozen
    runs contain no detections to judge.
12. **The panel screenshot shows the empty state.** The loaded-run view was not
    captured because the offscreen harness cannot click "open"; the panel code path
    is the same one that renders the observation list once a run is loaded.
