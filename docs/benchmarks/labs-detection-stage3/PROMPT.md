# Stage 3 — implement semantic analysers inside Cilex Watchtower

Implement this assignment. Work autonomously until the implementation, in-product
verification and submission record are complete. Use the model and mode selected
by the operator; their selection is the operator's responsibility. Record actual
settings and any configuration problem without substituting another model.

## Working directory and branch

Work in the repository already open in this session, on its current branch.
Record its root with `git rev-parse --show-toplevel`, its branch with
`git branch --show-current`, the starting revision and dirty state. Keep that
checkout and branch throughout the assignment; do not switch or create worktrees.
Preserve Stage 1 and Stage 2 submissions. Work forward; do not rewrite their
reports, commits or historical results. If your Stage 2 product integration is
incomplete, complete the prerequisites within this assignment and report that
extra work separately.

Read CLAUDE.md and docs/DEVELOPMENT.md in your checkout. The only additional
task material you may read/copy outside it is:

- `/home/cilex-vision/projects/cilex-watchtower/docs/benchmarks/labs-detection-stage3/`
  (only PROMPT.md, README.md, PROTOCOL.md, CASES.md, RESULT_FORMAT.md,
  dataset.json, CLASSIFICATION.md, PREPARATION.md and package-manifest.json).
- `/home/cilex-vision/projects/cilex-watchtower/tools/labs/stage3_evidence.py`
  and `/home/cilex-vision/projects/cilex-watchtower/tools/tests/labs-stage3-evidence.py`.
- The neutral recordings and `inputs.json` in
  `/home/cilex-vision/Videos/Watchtower-Stage3/`.

Copy the common evidence helper/tests and public instructions into your checkout
where needed. Keep the supplied contract/helper intact; report defects to the
operator instead of weakening validation. The originals' descriptive filenames
are annotations, not detector inputs. This is a file-specific read exception,
not permission to explore outside your working checkout. Do not enumerate or
inspect other directories, worktrees, branches, sessions or reports outside the
current checkout and the explicitly listed task inputs.

## Implement new analysers alongside the existing set

Add separately identifiable, versioned semantic object and object-colour analyser
capabilities to the existing Watchtower Labs workflow. They may share decoding and
inference internally. Give the operator understandable names, controls and results.
They must be usable on arbitrary newly selected recordings, not just this dataset.
Preserve the existing analysers and their behaviour. Reuse the existing product
interfaces/decoding/evidence components where suitable; do not build a separate app,
viewer, web dashboard or benchmark product.

Stage 3 **supersedes the Stage 2 prohibition on trained models and semantic
classification** for these new local analysers. Local pretrained models and isolated
project dependencies are allowed. Disclose model/weights source, version, hash,
licence, installation and offline prerequisites. Do not upload footage or use paid
or remote vision APIs. If a dependency is unavailable, expose that state and report
it; do not return fabricated detections. Record any operator-authorized policy
change in the submission report.

Use only the eight provided recordings for development/evaluation footage. Do not
fetch additional test videos. Pretrained weights are allowed; fine-tuning on other
footage and filename/clip/hash-specific output lookups are not. Do not train on these
clips and then present their results as unseen accuracy. Model inference must use
decoded pixels. Keep expected targets and evaluation labels out of that code path.

Required new metadata:

- `person` and `car`, with observed bounding boxes, frame timestamps and confidence.
  A tall/wide motion blob is not a semantic class. Detect a stationary car too.
- Broad colours attached to the correct detected object and explicitly named
  region: vehicle body, clothing or upper clothing as specified by each target.
  Show `unknown` where evidence is insufficient. Do not use background, shadows,
  a nearby bag/dog or another person to supply the object's colour.
- Stable object/track references where available. Preserve actual observed boxes
  and timestamps; do not turn interpolated geometry into observed evidence.

Implement all mandatory targets in CASES.md / dataset.json. Medium/hard targets
are classified for later work and are **not required now**. Extra labels emitted
by a general detector are acceptable if honestly displayed, but receive no credit
in place of the easy requirements. Do not expand into action recognition, plate
OCR, age/gender inference or cross-camera identity for this assignment.

## Operator workflow and tests

Within Cilex Watchtower's existing Labs screen, the operator must be able to:

1. Select a supplied clip or another local recording and choose the new analysers.
2. Start/cancel analysis and see real progress, completion, failure, missing-model
   or partial-result states. Keep processing off the GUI thread and clean up
   child processes on cancel/shutdown.
3. See objects and colours on the recording, select a finding and seek to its
   observed frame. Show class, confidence and colour scope. Use actual decoded
   frame PTS relative to the first decoded frame, not a fabricated filename time
   or `frame_index / average_fps`. Preserve gaps and do not change source footage.
4. Run the common Stage 3 evidence/checklist validation through the same product
   integration, see individual results, and review proposed matches with video.
   A structurally valid label is a **candidate awaiting review**, not an accuracy
   pass. Do not auto-accept matches or fabricate a reviewer's decision.
5. Save/reopen a run with its input, revision, analyser/model/configuration,
   observations, metrics and review decisions. Switching inputs must never show
   one clip's evidence over another; repeat runs must not accumulate stale rows.
6. Exercise the controls in CASES.md, including renamed-input equivalence, error
   handling and a deliberate failure. Development-only synthetic control data is
   permitted for plumbing tests, explicitly separate from footage accuracy.

Use the result contract in RESULT_FORMAT.md and the common evidence helper.
Product-owned Python/C++ helpers and internal unit checks are allowed; the operator
must not need a terminal to evaluate the analysers. Automated acceptance must call
the same implementation used by Labs, not an alternative detector or a canned report.

Build Watchtower with the supported toolchain and launch with ./run.sh. Use
isolated settings and WT_NO_SCHEME_REG=1 for checks. Run your original tracking
tests and the relevant existing worker/shape/object-profile regressions without
weakening them. Inspect the new workflow in the actual application. Report any
offscreen video limitations; an empty video panel cannot prove overlay alignment.

Keep the trial local. Do not register/enable new analysers on the live server,
alter the default fleet worker registry, write findings to production, access
cameras, change backend projects, deploy, or upload recordings. Experimental
local analyser registration in Watchtower is part of the assignment.

## Submission

Write `docs/benchmarks/labs-detection-stage3/STAGE3_SUBMISSION.md` with:

- Starting revision and preserved earlier-stage revisions; model/agent/settings.
- Analyser design, why it was chosen, exact changed files and dependencies.
- Build/launch instructions and a short in-app operator walkthrough.
- Per-clip target candidates, reviewed outcomes clearly labelled by reviewer,
  misses/unknowns and representative evidence. Do not declare accuracy from
  filename matching. Full frame-level precision/recall is not annotated yet.
- Exact commands/runs and measured results for product controls and regressions;
  include failures, skips and limits. Do not label net RSS as peak RSS.
- Source/config/weights/input hashes, hardware/runtime, runtime and resource
  measurements where actually measured; separate setup, inference and review time.
- Saved evidence locations (local, not footage committed to Git), tests that can
  be repeated by the operator, and remaining limitations.

Do not commit or push unless the operator's Stage 3 launch message explicitly
authorizes it. If authorized, commit and push only to the branch recorded at the
start, using `git -c push.followTags=false push origin HEAD:refs/heads/<current-branch>`;
preserve hooks and verify the remote head. Never merge, force-push or deploy.
Otherwise leave a reviewable working tree and report its starting revision and
changed files. Preserve the submitted tree/config/weights for repeatable evaluation.

Final response: what is implemented, how to use it inside Watchtower, exact
validation results, unresolved limits and submission identity. Distinguish your
development checks from independent acceptance of the finished implementation.
