# Stage 4 repair round R1 — geometry correction and corrected measurement

**This is a separate, explicitly assisted repair round.** The original Stage 4
submission stays as it was: its sources, reports, manifests, logs, split,
checkpoints and evidence are archived under `build/stage4/R0-archive/` (12,041
files, 120.6 MiB, every file hashed in `ARCHIVE_MANIFEST.json`, verified after
copying). Nothing of R0's was overwritten. No independent grade is awarded here.

**Headline.** The audit's geometry finding **reproduces exactly**: the R0 training
path letterboxed frames at cache size 384 and then converted the labels with the
model's 256 divisor, so every target coordinate was 1.5× too large, object centres
sat 16.7 grid cells away from the right cell and **33.1% of all labelled objects
(339 of 1025) fell off the target grid entirely and were silently dropped from
training**. The validation inverse mapping had the same error, so R0 also *scored*
its predictions at the wrong scale. After the correction: A's validation F1 goes
from 0.0000 to **0.0067** (1 TP / 56 FP / 241 FN) and B's to **0.0273**
(4 TP / 47 FP / 238 FN), both at the original frozen confidence 0.30 and IoU 0.50.
Quality is still far from usable; §4 says exactly how far and what did not change.

## 1. Baseline preserved, and what reproduces

| | |
|---|---|
| Checkout / branch | `/home/cilex-vision/projects/cilex-watchtower-deepseek`, `benchmark/deepseek-labs-tracking` |
| HEAD | `701a1d26d6fb` (Stage 3), working tree dirty with Stage 4 and now R1 |
| R0 archive | `build/stage4/R0-archive/` — sources, docs, evidence, split, cache manifests, training manifests/logs, `final.pt` + `final.onnx` for A and B, all runs and demo runs |
| R0 checkpoint hashes (verified in the archive) | A `a913cb25df8392c3984e00084005a6a2…`, B `bbf26d0dc59401fd685ea77215068e26…` |
| Reproducible? | yes: the R0 code, cache (`cache384` + `cache_entries.json`), split and checkpoints are all in the archive, so the defect and the R0 numbers can be re-derived without touching R1 |

Working tree vs reported submission: identical apart from R1's new files. No
earlier artifact was modified while archiving (byte-identical hashes verified).

## 2. The reproduced defect, and the corrections

`tools/tests/labs-stage4-geometry.py` (18 checks, all passing) contains the
reproduction with hand-calculated expectations and the R0 arithmetic beside it:

| measurement | R0 | R1 |
|---|---|---|
| target coordinate vs hand calculation | 1.5× on every axis (`cache 384 / input 256`) | exact |
| object-centre displacement | 16.7 cells on a 64-cell grid (box at S4-001 f120) | 0.0 cells |
| objects off the target grid | **339 of 1025 (33.1%)** | **0 of 1025** |
| drop accounting | not recorded | 40,616 encoded, 0 off-grid, 0 outside-frame, 228 augmentation-clipped |
| inconsistent geometry | accepted silently | rejected by `validate_transform` |

Corrections, all versioned under R1 paths:

* **One explicit transform.** `stage4_data.letterbox_transform()` defines the
  source → letterbox mapping once; `boxes_to_model_frame` / `boxes_to_source_frame`
  take that dict. **`validate_transform()` refuses a scale/padding pair that does
  not belong to its size**, which is precisely the R0 combination — so the failure
  mode is now a loud error, not a silent shift.
* **A new matching-resolution cache** (`build/stage4/cache256`, 1349 frames, size
  recorded per entry, its own manifest and hash). The old `cache384` is untouched
  and still present; nothing was reinterpreted.
* **Forward and inverse paths both fixed**: training targets via
  `boxes_to_model_frame`, and the validation decode via `boxes_to_source_frame`,
  each using the entry's own transform.
* **Drop accounting**: `make_targets(..., stats=...)` counts encoded /
  outside-frame / off-grid per object, and the trainer sums augmentation clipping
  separately, so a mapping error can never be mistaken for legitimate clipping.
* **Visual inspection** (`tools/labs/stage4_overlay.py`): source frame with
  released boxes and decoded predictions, beside the actual model-input pixels with
  the mapped boxes (9 overlays in `evidence-r1/`). After the fix the boxes sit on
  the objects in both panels — e.g. `A-S4-001-f00226-overlay.jpg` shows ref and
  pred boxes on the same walking person (IoU 0.838).

## 3. Measurement separated from training

Same public grouped split (`split_sha256 7309d722e1362ecd…`), same source-frame
schedule (first decoded frame at/after each whole second), same matching protocol
(max cardinality, then max total IoU), same frozen operating point (conf 0.30,
IoU 0.50), same class-scoped ignore handling. Evaluated by
`tools/labs/stage4_eval_frames.py`, which works from checkpoints so all four
variants go through one code path.

| Approach A (scratch, seed 20261006) | preds | TP | FP | FN | precision | recall | F1 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1. R0 saved validation result — **historical**, different geometry/evaluator, not comparable | 0 | 0 | 0 | 242 | n/a | 0.000 | 0.000 |
| 2. R0 frozen checkpoint, corrected evaluator + transforms (weights untouched) | 0 | 0 | 0 | 242 | n/a | 0.000 | 0.000 |
| 3. fresh initialization baseline, same evaluator | 0 | 0 | 0 | 242 | n/a | 0.000 | 0.000 |
| 4. **R1 retrained**, same evaluator | 57 | 1 | 56 | 241 | 0.0175 | 0.0041 | **0.0067** |

| Approach B (ResNet-18 trunk, seed 20261006) | preds | TP | FP | FN | precision | recall | F1 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1. R0 saved validation result — historical, not comparable | 0 | 0 | 0 | 242 | n/a | 0.000 | 0.000 |
| 2. R0 frozen checkpoint, corrected evaluator + transforms | 0 | 0 | 0 | 242 | n/a | 0.000 | 0.000 |
| 3. fresh initialization baseline | 0 | 0 | 0 | 242 | n/a | 0.000 | 0.000 |
| 4. **R1 retrained** | 51 | 4 | 47 | 238 | 0.0784 | 0.0165 | **0.0273** |

Per class (IoU 0.50, conf 0.30): A — animal F1 0.0208, car 0.0, human 0.0 (each
class's recall denominator is its reference count: 146 human, 52 car, 44 animal);
B — animal 0.0556, human 0.0238, car 0.0. `precision` is `n/a` only where nothing
was predicted, and `car: F1 0.0` means "no car was matched", not "no cars exist".

Supplementary threshold sweep (`evidence-r1/R1-threshold-sweep.json`, NOT the
primary comparison): A peaks at F1 0.0162 (conf 0.20), B at 0.0392 (conf 0.15).
Two operating points differ per approach; both remain unusable.

**Training records** (`build/stage4/R1-training/*/manifest.json`, per-epoch JSONL
beside them). A and B keep their original recipes — epochs, batch, learning rate,
optimizer, augmentation, input size, seeds — and differ in the ways they already
did (scratch trunk + GroupNorm vs frozen ResNet-18 trunk + BatchNorm; frozen vs
trained components). **Their comparison therefore does not isolate the backbone**,
and is not presented as if it did.

| | R1-A | R1-B |
|---|---|---|
| epochs / wall time | 50 / 738 s | 40 / 1532 s |
| final checkpoint sha256 | `de75734020a283a945066b5209cb7926fa331f4f3843a1f6e61b673c5f141ea4` | `559d7a3b539cfb76beb3cb65e2521aeda8f7728a2b4637b1622ff237bc280401` |
| initial weights (state sha256, hashed not seeded) | `17da8b7e6a3ce3f988bb4557ee8ac35e…` | `a0447154557571ebe93683c9bc1f9f2d…` |
| training peak RSS | 785 MiB | 855 MiB |
| drop stats | 40,616 encoded / 0 off-grid / 228 clipped | 32,590 encoded / 0 off-grid / 182 clipped |

**Small overfit/debug check before the full runs** (required by the prompt, and
what proved the geometry fix): 24 fitting frames, 300 steps →
**TP 6, FP 2, FN 3, precision 0.750, recall 0.667, F1 0.706** on those same frames
at conf 0.30/IoU 0.50. Under R0 the same test produced zero detections even on
training frames. Falling loss was never accepted as evidence: the check reports
localisation (matched boxes), not loss or confidence.

## 4. What is corrected, what is still poor

Corrected and measured: geometry (above), sampling/coverage, size policy, colour
formula and support, filters, identity handling.

Still poor, reported as such: **both approaches remain unusable detectors on
unseen scenes.** The correction turned "predicts nothing" into "predicts something",
but precision is 1.75% (A) and 7.8% (B) — the models now produce peaks on unseen
frames and occasionally localise correctly (B's animal class reaches F1 0.056),
while most predictions are false. This repair round promised no accuracy outcome
and delivers none; it establishes that the earlier zero result was partly an
artefact of the defect and partly a genuine capability limit.

Not attempted here, and therefore absent: architecture, resolution
(256 px renders ~46% of instances as under-26-px objects), normalisation and
hyperparameter changes. Each would be an additional labelled experiment with its
own artifacts; none is blended into the geometry-only result.

## 5. Acceptance checks repaired

The controls now grant PASS only where something real was exercised
(`evidence-r1/controls-r1-2026-10-07.jsonl`, 16 entries):

| ID | R1 status | What changed and what it now says |
|---|---|---|
| S4-C01 | PASS | distinct R1 checkpoint hashes, same frozen split, before/after on identical frames |
| S4-C02 | PASS | renamed copy → identical detections (56/56); unseen synthetic input analysed; torch cache hidden, proxy closed |
| S4-C03 | PASS | 2 consecutive same-class detections below 0.15 IoU movement, in the run with the most same-class pairs (the check no longer depends on file timestamps); no motion gate exists in the inference path |
| S4-C04 | PASS | boundaries exact; source-coordinate restoration 3.5e-18; truncated objects abstain |
| S4-C05 | PASS | 33 published CIEDE2000 pairs within 4.9e-5 |
| S4-C06 | PASS | synthetic neighbour/bag isolation **and** real examples: every known colour carries a crop, mask, bbox, support count and numeric sRGB/Lab, and each mask matches its crop's dimensions and pixel count |
| S4-C07 | PASS | 13 shared filter cases agree in Python and C++ |
| S4-C08 | PASS | 44/44 scheduled frames with coverage records, no PTS drift, no duplicate ids, boxes in range |
| S4-C09 | PASS | A→B→A with R1 checkpoints; per-run id uniqueness (the contract's requirement), distinct run ids, separate crop directories, non-empty runs |
| S4-C10 | PASS | 147 referenced evidence files, all listed and present; **it now SKIPs on an empty run** — an empty round trip is not save/reopen integrity |
| S4-C11 | PASS | SIGTERM → `cancelled`, no orphan analyser processes |
| S4-C12 | PASS | missing/corrupt/empty input and absent/wrong-hash weights each fail without reused detections |
| S4-C13 | FAIL (deliberate) | the control that must fail, kept separate from real failures |
| S4-C14 | PASS | tree peak 364.3 / 384.2 / 373.1 MiB — **target 512 MiB met, maximum 1 GiB met** |
| S4-C15 | PASS for the adapter boundary; playback separately recorded | 147/147 evidence files present, PTS equal to the schedule within 1 ms. In-app playback is described below and is **not** granted a pass for visual alignment |
| S4-C16 | PASS | tracking 316, Labs worker, shape 79/79, object profile 40/40, 49 Stage-4 unit checks, 18 geometry checks, `git diff --check`, real build |

**Defects the repaired controls found in R1 code**, all fixed: colour crops were
referenced but never written because `colour_crops/` was never created (silent
`cv2.imwrite` failure) — caught by C06/C10/C15 with "100/144 evidence files
present"; and the R1 geometry guard correctly rejected invented scale/padding pairs
in two R0-era test fixtures. Two further control-expectation errors were mine, not
the product's: C03 depended on which run was newest, and C09 demanded observation
ids be unique *across* runs when the contract only requires uniqueness *within* a
run.

**In-app acceptance** (`evidence-r1/01-in-app-seek-and-overlay.png`,
`02-in-app-approach-switch-cleared.png`, captured on the running product through
`WT_LABS_STAGE4_RUN/_OBS/_SWITCH_TO` hooks):

* loading an R1 run shows `COMPLETED · 671 observations · approach A`, the run's
  checkpoint hash, and the legend **"decoded frame at 1.000 s · 14 object(s) · 0 ms
  before playhead"** — selecting an observation seeks the player to its own PTS and
  draws its box;
* switching the approach to B in the running app **clears the previous results**:
  observations 671 → 0, overlay emptied, legend back to "no observation within one
  sampling interval", model card now describing B;
* **the video surface itself showed no pixels**: Qt Multimedia logged "No HW
  decoder found" and the panel stayed black behind the overlay. Playback and
  overlay **timestamps** are therefore verified in-app, while **visual alignment is
  NOT** — recorded as unverified, not as a pass. Detached crops and textual
  timestamps were explicitly not accepted as evidence for this.
* the worker-compatible boundary was exercised through the same
  `stage4_analyse.py` entry point with isolated local data; no server registration
  and no production findings were touched.

## 6. Runtime resources, measured again

The prompt's warning was right: `auto` used to import torch even when it then ran
through ONNX Runtime, because `main()` seeded torch for any runtime that was not
explicitly `onnx`. That is fixed, and every run now records which modules were
actually loaded: `"torch_loaded": false, "torchvision_loaded": false,
"onnxruntime_loaded": true` for the default path.

Independent sampled summed RSS of the complete analyser tree (python + ffmpeg,
0.05 s interval, 142–309 samples per run, cold start included), on the same clip
and schedule as R0:

| run | runtime | peak tree RSS | loaded torch? |
|---|---|---:|---|
| R1-A validation clip | `auto` → ONNX | **367.4 MiB** | no |
| R1-A validation clip | explicit `--runtime onnx` | 373.2 MiB | no |
| R1-A validation clip | explicit `--runtime torch` | 805.5 MiB | yes |
| R1-B validation clip | `auto` → ONNX | **383.9 MiB** | no |
| R1-B validation clip | explicit `onnx` | 396.2 MiB | no |
| R1-B validation clip | explicit `torch` | **945.8 MiB** | yes |
| R1-A, 671 observations (non-empty evidence) | `auto` → ONNX | 407.9 MiB | no |
| S4-C14 control (A, B, A) | `auto` → ONNX | 364.3 / 384.2 / 373.1 MiB | no |

So the 512 MiB target is **met on the shipped configuration** (367–408 MiB,
including a run with real evidence processing), and the torch path would have
nearly reached the 1 GiB maximum (946 MiB). The R0 report's 700–900 MiB figures were
inflated by that hidden torch import. Non-empty evidence processing costs ~25 MiB
over an empty run — explicitly measured rather than inferred, and still labelled
plumbing because it comes from a fitting clip. Effective settings: two threads for
inference, decode width 1280 (unchanged), 1 Hz schedule (unchanged), so the
resource work changed no recognition setting.

ONNX exports were regenerated from the R1 checkpoints and verified numerically
against torch: R1-A max abs difference 1.9e-5, R1-B 1.05e-5 (tolerance 1e-4). The
numpy decoder is compared against the torch decoder in the unit suite, so no old
export can be silently evaluated: each run records its checkpoint hash, and the
ONNX file's hash is recorded beside the checkpoint it came from.

## 7. R1 artifacts and frozen identities

| Item | Path / identity |
|---|---|
| R0 archive | `build/stage4/R0-archive/` + `ARCHIVE_MANIFEST.json` (12,041 files verified) |
| R1 caches | `cache384` (original, untouched) and `cache256` (new, size recorded per entry) |
| R1 training | `build/stage4/R1-training/R1-A/`, `R1-B/` — `manifest.json`, `train-log.jsonl`, `final.pt`, `final.onnx`, `initial-weights.pt` |
| R1 runs | `build/stage4/runs/*-r1-*` (validation clips, frozen threshold) and `build/stage4/demo-runs/*-r1demo-*` (fitting clip, threshold 0.10, **plumbing only**) |
| R1 evidence | `docs/benchmarks/labs-detection-stage4/evidence-r1/` — controls JSONL, six evaluation JSONs, threshold sweep, seven memory probes, two in-app captures, nine overlays |
| Frozen A (for later independent evaluation) | `R1-training/R1-A/final.pt`, sha256 `de75734020a283a945066b5209cb7926fa331f4f3843a1f6e61b673c5f141ea4`, ONNX `R1-A/final.onnx` |
| Frozen B | `R1-training/R1-B/final.pt`, sha256 `559d7a3b539cfb76beb3cb65e2521aeda8f7728a2b4637b1622ff237bc280401`, ONNX `R1-B/final.onnx` |
| Split (unchanged) | `split_sha256 7309d722e1362ecd…`, validation = `archive-scene-008/016/019` |
| Unit checks | `tools/tests/labs-stage4-units.py` 49 PASS / 0 FAIL; `tools/tests/labs-stage4-geometry.py` 18 PASS / 0 FAIL |

Usage is unchanged:

```sh
python3 tools/labs/stage4_analyse.py --input /abs/clip.mp4 --approach A \
    --checkpoint build/stage4/R1-training/R1-A/final.pt --output /abs/new-run-dir
```

(`--runtime auto` picks the verified ONNX export beside the checkpoint and stays
torch-free; `--schedule` remains optional and cannot carry expected labels.)

## 8. Limitations, unmeasured results and what is NOT claimed

1. **Accuracy is still unusable** (F1 0.0067 A / 0.0273 B at the frozen operating
   point). The repair fixed a defect; it did not produce a working detector, and
   this report does not imply that a further correction would.
2. **The R0 saved numbers are historical.** They were produced by an evaluator with
   the wrong inverse mapping. They are reported in §3 row 1 as such and are not
   directly comparable with rows 2–4.
3. **Initial-weight identity is a hash of the state dict, not proof of identical
   data pipelines.** The R1-A and R1-B initial hashes are recorded
   (`17da8b7e…`, `a0447154…`); the R1-B trunk comes from the local torchvision
   cache, whose file is identified by the published URL, not by a hash in this
   report.
4. **A and B are not a backbone-only comparison** (different trunks,
   normalisations and frozen/trained splits); the difference between their F1
   values is reported as a difference between two recipes.
5. **Visual playback alignment is unverified**: the video surface showed no pixels
   on this host. In-app seek, overlay drawing and PTS agreement (≤1 ms) are
   verified; pixels are not.
6. **Colour/size metrics on validation are `not measured`**, not zero: 1–4 matched
   objects is far too few to score colour or size accuracy, and missing objects stay
   in the joint denominators that are reported instead.
7. **The stationary and colour-support controls pass on the demonstration run and
   the fitting-clip run**, which is plumbing evidence; they do not establish
   validation accuracy, and no species claim is made from animal F1 0.056.
8. **Training resources are reported separately** (A 738 s / 785 MiB, B 1532 s /
   855 MiB) and are not part of the inference budget.
9. **Ignore regions**: the R1 evaluator keeps the released class-scoped ignore
   regions in the reference data, but the primary metrics above are computed without
   applying ignore masking to unmatched predictions; that masking is part of the
   coordinator's protocol and is not claimed as done here.
10. No commit, push, merge, deployment, live activation, production finding,
    private report or new recording was touched; all work is local.

## 9. Files added by R1

`tools/labs/stage4_eval_frames.py`, `tools/labs/stage4_overlay.py`,
`tools/tests/labs-stage4-geometry.py`, this report and
`evidence-r1/`; plus R1 edits inside `tools/labs/stage4_data.py` (explicit
validated transforms, cache records the transform), `stage4_train.py` (cache
selection, corrected forward/inverse mapping, drop accounting, initial-weight
hash), `stage4_model.py` (`make_targets` drop statistics), `stage4_checks.py`
(evidence-requiring PASS/SKIP rules), `stage4_detect.py` (torch-free `auto` path,
runtime-module disclosure, evidence directories), `stage4_colour.py` (evidence
writers verify what they wrote), `tools/tests/labs-stage4-units.py` (fixtures use
consistent geometry), `src/models/LabsStage4.{h,cpp}`, `qml/LabsStage4Panel.qml`
(playback, overlay, seek) and `src/main.cpp` (startup/switch hooks). The R0
sources are archived verbatim for comparison; the scaffold used for the in-app
capture is reverted in the handed-over tree.
