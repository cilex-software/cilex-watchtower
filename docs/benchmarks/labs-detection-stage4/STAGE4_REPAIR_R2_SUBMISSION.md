# Stage 4 — targeted correction round R2 (provenance, scoring, product paths)

**Bounded R2 correction outcome.** The five findings in the coordinator's R2 packet
were reproduced in this checkout and repaired: revision selection is now one
verified registry used by the product, the controls and the evidence; ordinary
result clicks seek and switches clear through the real application; the historical
initialization claim is corrected without inventing a starting state and future
capture is fixed; scoring implements the EVALUATION.md matching, ignore-region and
coverage contract against a frozen prediction set; and the controls now exercise
production paths with a consistent machine-readable log.

**Overall Stage 4 readiness stays PARTIAL**, and this report says why: detector
recognition is still weak (micro F1 0.0067 A / 0.0273 B on the public validation
groups), one control fails on genuine stationary-object misses, playback with
visible video pixels remains NOT VERIFIED, and the historical initialization
comparison is unverifiable. Nothing here is an independent grade.

Frozen in this round: weights, ONNX exports, architecture, recipes, annotations,
split, inference geometry, colour extraction, sampling, confidence 0.30, primary
IoU 0.50. No training, no optimizer step, no threshold or NMS change.

## 0. Preservation and drift

| | |
|---|---|
| Branch / HEAD at start | `benchmark/deepseek-labs-tracking`, `701a1d26d6fb9e894beed3e05cc4caf6a66dad11` |
| Drift since the coordinator's audit | **none**: `stage4_data.py`, `stage4_train.py`, `stage4_eval_frames.py`, `stage4_evaluate.py` and `labs-stage4-geometry.py` all match the audited SHA-256 values |
| R0/R1 preservation | `build/stage4/R0-archive/` (untouched), `build/stage4/R2-archive/` — 28 sources copied with hashes verified (`ARCHIVE_MANIFEST.json`), training manifests/logs copied, weight files **hashed in place** and not duplicated or modified |
| R1 artifacts unchanged | `R1-training/R1-A/final.pt` `de75734020a283a9…`, `R1-training/R1-B/final.pt` `559d7a3b539cfb76…` (hashes re-verified after all R2 edits) |
| Packet verification | `MANIFEST.json` verified: 12 files, all sizes and SHA-256 match; packet treated read-only |

## 1. Finding 1 — revision selection (reproduced, corrected)

**Reproduced.** `src/models/LabsStage4.cpp:309` resolved
`build/stage4/training/<tag>/final.pt` (the R0 artifacts) while the R1 models live
in `build/stage4/R1-training/R1-{A,B}/`; `stage4_checks.py` preferred R1 checkpoints
but read R0 manifests; the CLI default resolved the R0 path as well. Three
resolvers, three revisions.

**Corrected** by one registry, `tools/labs/stage4_revisions.py`:

* every artifact is declared with its expected SHA-256; `resolve()` verifies and
  **raises instead of substituting another revision**;
* `build/stage4/revisions.json` is emitted for the product, which reads it, verifies
  the checkpoint hash itself (`QCryptographicHash`) and shows the revision, the
  verified hash and the ONNX runtime in the model card;
* the R0 artifacts remain selectable but are labelled historical, and are never a
  fallback;
* `WT_STAGE4_REVISION` selects explicitly; a missing/unverified selection disables
  Run with an explicit message.

Evidence (real application, `WT_LABS_STAGE4_STATEDUMP`):
`{"model_ready": true, "model_verified": true, "model_revision": "r1",
"model_onnx": …}` and `"matches_registry": true` inside a run envelope. A tampered
registry (expected hash replaced by zeros) makes the product report *"checkpoint
hash … does not match the registered … — refusing to run"* (S4-C12).

## 2. Finding 2 — selection, seeking, switching, persistence (reproduced, corrected)

**Reproduced.** `qml/LabsStage4Panel.qml` ordinary click called `select()`, which
only set the selection; the seek function existed unused by the list. Input and
approach switches left `m_obsPts` and `m_videoPath` behind, and a superseded
process could still deliver output into the new run.

**Corrected.**

* one path: `select()` → `seekToObservation(id)` → the player seeks to that
  observation's own `frame_pts_ms`; identity is the observation id, never a row
  index, so filtering and reopening select the same object; a click arriving before
  the media is ready is applied on `durationChanged`;
* `setRecording()` / `setApproach()` clear observations, summary, metrics,
  selection, run directory, **video path, observation timestamps and run state**,
  and bump a generation counter;
* each run process carries its `runDir` and `generation`; `onRunOutput` /
  `onRunFinished` ignore anything from a superseded process ("late output must not
  repopulate the new run");
* `loadResult()` validates before mutating: **corrupt JSON, a missing video or
  missing evidence leave the displayed run untouched** and are reported explicitly;
  `runState` distinguishes an immutable completed run from currently unavailable
  playback/evidence (`video_available`, `evidence_present/referenced`,
  `problems[]`); `verifyRunArtifacts()` recomputes manifest hashes.

Three defects were found *by* this round's own product-path checks (they are not in
the coordinator's list because they were introduced or hidden here):

| Defect | How it was found | Fix |
|---|---|---|
| `loadResult()` re-read `run.json` from an **unopened** `QFile`, so every reopened run showed an empty summary and 0 observations while `run_state` looked fine | application state dump showed `run_state.observations=228` but `observations=0` | open the file and handle failure (`LabsStage4.cpp`) |
| relative run paths silently failed to open | probe log: `QIODevice::read … device not open` | normalise with `QFileInfo::absoluteFilePath()` |
| a bounded 200-file artifact sample reported an *altered* file as verified when the change was outside the sample | S4-C10 "altered evidence NOT HANDLED" | the test hook verifies all listed files; the UI keeps the bounded sample and reports the bound |

Real-application evidence (S4-C09, S4-C10): load → 398 observations, selection
`o00001`, revision `r1` verified, evidence 1416/1416 present, video available;
approach B→A clears to 0 observations, input switch clears to 0, re-selecting the
same approach correctly keeps 398 (a no-op, asserted deliberately); corrupt
`run.json` → refused with *"not valid JSON (illegal number at offset 56)"*; missing
video → loads as history with `video_available=false` and the recording named in
`problems`; altered crop → detected by the in-app verification.

## 3. Finding 3 — initialization provenance (reproduced, not invented)

**Reproduced.** The trainer captured the "initial" snapshot *after* the training
loop, and the coordinator's tensor-storage audit found every recorded payload equal
to the final one. `tools/tests/labs-stage4-provenance.py` re-derives it here
independently: for both approaches, *all* recorded tensor payloads equal the final
weights, while the container hashes differ — which proves nothing about the tensors.

**Corrected, without inventing anything:**

* the preserved `initial-weights.pt` files and manifests are **untouched**;
* the historical initialization comparison is reported **UNVERIFIED** (S4-C01 says
  so in its own detail line), and no recovered starting state is claimed from final
  weights, a seed or a regenerated state;
* `capture_initial_state()` now runs **before the first optimizer update**, records
  the capture point inside the file, computes the state hash from the same detached
  copies it saves, and clones every tensor so later in-place updates cannot alias
  into the snapshot. Verified with synthetic fixtures only — **no optimizer step, no
  training run**: ordering (capture precedes the loop), immutability (in-place
  `add_` on the live parameters leaves the snapshot unchanged), no shared storage,
  and the recorded capture point;
* **archive overstatement corrected:** the R1 report said cache384 was inside the
  R0 archive; the audit and this round's check both find it is **not** there. The
  R0 cache lives at `build/stage4/cache384` (with `cache_manifest.json` and
  `cache_entries.json`); the archive holds the R0 sources, reports, manifests, logs
  and weight hashes. The original R1 report is preserved unedited and this document
  is the correction.

This finding does not establish that historical training never happened, and this
round does not claim it does.

## 4. Finding 4 — scoring around frozen predictions (reproduced, corrected)

The R1 reference loader dropped `ignore_regions`, the tie-break was a local swap
heuristic, and coverage was whatever frames happened to be present. Corrections in
`tools/labs/stage4_scoring.py`:

* **exact matching** — maximum cardinality by augmenting paths, then the maximum
  total IoU among maximum-cardinality matchings solved as a min-cost max-flow of
  exactly K units. Checked against **brute-force enumeration** on 120 small cases
  (all pass). Differential test over 400 random cases: cardinality never differed,
  the R1 heuristic's total IoU was lower in 204 of them (51 %) — so the correction is
  real for matched-pair identity, mean IoU and any matched-pair analysis, while
  TP/FP/FN cannot move with it;
* **class-scoped ignore regions** applied only to unmatched predictions, inclusive
  at half the predicted area (a float-precision defect at exactly 0.5 was found by
  this suite and fixed), 459 regions in the pack, 78 in validation;
* **coverage** — missing images, absent or duplicate prediction records, timestamp
  disagreement and identity mismatches are explicit evaluation failures; an empty
  prediction list is valid coverage. This immediately caught a real defect: keying
  frames by `frame_index` alone collided across clips (135 frames → 84 keys), which
  is now keyed by clip+frame;
* **denominators** — raw TP/FP/FN plus ignored counts, per-class support, and
  micro/macro with the macro denominator declared; a supported class with no
  predictions keeps its false negatives, an unsupported class reports `not measured`
  rather than a perfect score.

**Frozen prediction identities** (`build/stage4/R2-frozen-predictions/`, the
prompt's regenerate-once rule — R1 saved only summaries): one pass per preserved R1
checkpoint, confidence 0.30, input 256, validation split `7309d722e1362ecd…`,
cache256 `size 256`; A `de75734020a283a9…` → 57 predictions over 135 frames,
B `559d7a3b539cfb76…` → 51 — matching R1's reported totals, so the set reproduces.

| | old (R1 semantics) | corrected | delta |
|---|---|---|---|
| A micro TP/FP/FN | 1 / 56 / 241 | 1 / 56 / 241 | none |
| A micro F1 | 0.006689 | 0.006689 | none |
| B micro TP/FP/FN | 4 / 47 / 238 | 4 / 47 / 238 | none |
| B micro F1 | 0.027304 | 0.027304 | none |
| ignored predictions | not implemented | 0 (A), 0 (B) | no prediction of either model falls inside a released ignore region |
| coverage | unverified | 135/135 requested = recorded, 101 empty frames counted, complete | newly verified |

**A scoring correction is not improved recognition:** on this prediction set the
corrected path changes no headline number. What changed is verifiability — coverage
is now proven complete, ignore handling exists and is tested, and the matcher is
exact by construction rather than by assertion. The 51 % differential is evidence
about the algorithm, not about these weights.

## 5. Finding 5 — controls that substantiate their claims

The preserved R1 log contains 13 pass / 2 real fail / 1 deliberate fail, a
non-JSON `DONE` trailer, and a report that claimed no real failures. The
discrepancy is reproduced and explained: the committed log was an **earlier run**
(C03 and C09 failed then), while the report's "15 passed, 0 real failures" came
from a later run that was never committed. The report was wrong to cite an
uncommitted run as the submission's evidence.

R2 rebuilds the controls on production paths and on the frozen artifacts:

| ID | R2 status | What it now exercises |
|---|---|---|
| S4-C01 | PASS | the **selected R1** artifacts verified by hash, same frozen split, epoch counts; states the historical-initialization limitation in its own detail |
| S4-C02 | PASS | renamed copy → identical detections; unseen synthetic input; torch cache hidden, proxy closed |
| S4-C03 | **FAIL** | 12 reviewed stationary reference pairs (reference IoU ≥ 0.85 across distinct frames) judged by actual frozen inference: **0 detected, 12 missed** — a genuine failure, not a control artefact |
| S4-C04 | PASS | size boundaries exact; truncation abstains |
| S4-C05 | PASS | 33 published CIEDE2000 pairs within 4.9e-5 |
| S4-C06 | PASS | neighbour/bag isolation plus real colours with crop, mask, support count and numeric sRGB/Lab |
| S4-C07 | PASS | 13 shared filter cases agree in Python and C++ |
| S4-C08 | PASS | 44/44 scheduled frames with coverage, no drift, no duplicates |
| S4-C09 | PASS | real application: load, approach switch, input switch, and a deliberate same-approach no-op |
| S4-C10 | PASS | real application loader: 398 observations, 1416/1416 evidence, plus corrupt JSON, missing video and altered evidence |
| S4-C11 | PASS | SIGTERM → `cancelled`, no orphan analyser processes |
| S4-C12 | PASS | missing/corrupt/empty input, absent and wrong-hash weights, **and a tampered registry refused in-app** |
| S4-C13 | **NEGATIVE CONTROL** | the deliberate failure is reported as `negative_control` when detected — neither a pass nor a real failure — and the summary string is derived from the same events as the log |
| S4-C14 | PASS | sampled tree RSS 373.9 / 377.7 / 375.8 MiB (target 512 MiB met, maximum 1 GiB met) |
| S4-C15 | **PARTIAL** | names the tested boundary (isolated adapter + product controller) and states that playback with visible video pixels is NOT VERIFIED |
| S4-C16 | PASS | tracking 316, worker, shape 79/79, object profile 40/40, plus the units, geometry, provenance and scoring suites, `git diff --check`, real build |

Final log: `build/stage4/R2-controls-final.jsonl` → `evidence-r2/controls-r2.jsonl`
(strict JSONL, one event per line, no trailer), with the counters, the `done`
summary string and this report generated from the same events. **The tally is
reported exactly as it lands, including the C03 failure.**

## 6. Regressions, build and resources

* `labs-stage4-units.py` 49 PASS/0 FAIL, `labs-stage4-geometry.py` 18/0,
  `labs-stage4-provenance.py` 19/0, `labs-stage4-scoring.py` 17/0;
  tracking 316 PASS, Labs worker suite, shape 79/79, object profile 40/40;
  `git diff --check` clean; the application was rebuilt and smoke-launched
  (offscreen, no QML errors).
* Bounded serial A/B inference with the frozen configuration and cancellation,
  measured on the complete analyser tree with independent sampling every 50 ms
  (S4-C14 above). Shared-host conditions apply; the 512 MiB target is met and the
  1 GiB maximum is met with margin; training memory is reported separately in R1
  and unchanged. Runtime modules are recorded per run (`torch_loaded: false` on the
  default path).

## 7. Remaining limitations (explicit)

1. **Recognition is weak**: micro F1 0.0067 (A) and 0.0273 (B) at the frozen
   operating point, and S4-C03 fails with 0 of 12 stationary reviewed objects
   detected. R2 repairs provenance, scoring and product behaviour; it does not
   improve detection.
2. **Historical initialization stays unverified** and cannot be recovered from the
   preserved artifacts. Future runs are captured correctly.
3. **Playback with visible video pixels is NOT VERIFIED.** The offscreen platform
   used for automated checks does not composite video; overlay *timestamps* and
   selection-driven seeking are verified in the controller, and detached crops are
   not accepted as overlay evidence.
4. **The worker boundary is adapter-level.** `stage4_analyse.py` is the entry point
   both the panel and a worker call, but no live registration, no server findings
   and no production integration were exercised.
5. **Ignore-region effect is zero on this prediction set** (no prediction falls
   inside a released region), so its correctness rests on unit tests and the
   contract, not on a changed total.
6. **No accuracy claim, no grade**: all numbers are public development data, and the
   private evaluation remains outstanding.
7. Two controls have non-binary statuses by design (`partial`, `negative_control`);
   neither is a pass, and no combination here is an acceptance banner.

## 8. Files changed by R2

New: `tools/labs/stage4_revisions.py`, `tools/labs/stage4_scoring.py`,
`tools/labs/stage4_frozen_predictions.py`, `tools/labs/stage4_score_compare.py`,
`tools/tests/labs-stage4-provenance.py`, `tools/tests/labs-stage4-scoring.py`,
this report, `evidence-r2/`.
Modified: `tools/labs/stage4_checks.py` (registry-based C01, product-path
C03/C09/C10, negative-control C13, boundary-honest C15, strict statuses and tally),
`tools/labs/stage4_train.py` (capture before the first update),
`tools/labs/stage4_detect.py` (registry default checkpoint, `--revision`, revision
identity in the envelope), `tools/labs/stage4_eval_frames.py` (registry identity),
`tools/labs/stage4_eval_public.py` (unchanged scoring remains historical),
`src/models/LabsStage4.{h,cpp}` (registry resolver with in-app hash verification,
generation guards, non-destructive loader, run state, artifact verification, state
dump), `qml/LabsStage4Panel.qml` (click-to-seek, revision card, run gating,
startup-once hook), `src/main.cpp` (revision/state-dump/switch hooks),
`CMakeLists.txt` (unchanged this round unless required by the above).

R0 and R1 reports are preserved verbatim; this document supersedes their claims only
where it says so explicitly.
