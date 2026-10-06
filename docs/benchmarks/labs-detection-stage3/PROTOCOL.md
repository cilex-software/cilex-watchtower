# Stage 3 — recording detection evaluation protocol

Status: public development test specification, not a completed detector evaluation.
The supplied set contains eight operator-described videos. The first release uses
their filename descriptions as partial positive annotations. Sampled visual review,
where recorded in the case materials, supplements those descriptions; it does not
establish exhaustive frame annotations. No detector accuracy is measured here.

## Scope and difficulty

This stage adds semantic detection to the existing Watchtower Labs recording
workflow. It expressly supersedes the earlier prohibition on trained models and
person/vehicle/clothing classification for this local evaluation. It does not
change the original temporal-tracking contract or
retroactively rescore earlier submissions.

Add the new analysers alongside the current analyser set, preserving existing
analysers and their behavior. Make the additions available as local experimental
analysers in Watchtower Labs. Do not replace current analysers or enable the new
ones on the live fleet. A detector helper without the required Watchtower
integration is a partial submission.

Implementation policy for this prepared assignment: local pretrained models are
allowed. This is the stated default following the operator's in-product scope
clarification; record any later operator-authorized policy change. Inference runs locally;
do not send recordings, frames or crops to hosted AI services. Record model source,
license, version, checkpoint hash, dependencies, device and settings. A missing
model is a prerequisite failure, not a successful no-detection result. Do not
install globally, purchase services, or activate a live analyser under this task.

The buckets below are planning judgments, not measured difficulty guarantees:

| Bucket | Proposed metadata | Qualification |
| --- | --- | --- |
| Easy / required first | Visible person; visible car; coarse vehicle-body or clothing color linked to the correct detected object | Require actual image evidence. Visibility, scale, occlusion and lighting can make a particular occurrence harder. |
| Medium / later | Dog, bag or scooter; finer clothing type; partially obscured or distant object detection | Preserve these filename claims for later tests; they do not gate the first easy-target checklist. |
| Hard / later | Entering a car, car departure, opening a gate/door, carrying or moving bags, temporal order and interactions; plate transcription | These require more detailed spatial/temporal evidence. No first-stage action or OCR accuracy claim. |
| Uncertain or provenance only | “Supposedly grandma”; inferred age/family role/gender; camera label and filename date/time | Retain the original wording and uncertainty. Do not require demographic inference or infer capture time, timezone or IP address from a filename. |

A tiny seated figure is not an easy person target solely because `person` is an
easy class. Conversely, motion is not a requirement for a visible car or person.
The case list identifies the easy targets actually proposed for each clip. A
reviewer may mark a target unscorable with a recorded reason; never silently change
its difficulty or expected label after seeing a detector's result.

## Inputs and independence

All eight supplied videos are public development inputs. They are not a hidden
test set. The original descriptions are human assertions, not detector output.
Keep a provenance record of original filename, neutral clip identifier, bytes/hash
and the source of each asserted fact. Preserve the original files unchanged.

Runtime detection must use decoded
video pixels, not descriptive filenames, expected-label manifests or a lookup
table keyed by clip identifier/hash. Neutral filenames reduce accidental leakage;
they do not prove independence by themselves. Input hashes are for provenance,
cache correctness and saved-run identity, never for choosing expected detections.
The checker may compare output with expected facts only after inference finishes.

Stay in the current checkout and branch. PROMPT.md defines the exact additional
task files that may be read; do not explore outside that scope.
Develop and test with the supplied clips and any
explicitly approved dependencies. Preserve the earlier submitted revisions and
reports; record later detector or tracker changes separately.

## Public checklist: evidence first

The first pack supports a **positive-target development checklist**. A filename
mention such as “person” supplies a target to find; omission of a car, person or
color does not assert its absence. Names do not establish exact object counts,
object boxes, event intervals or complete negative labels. Additional detections
therefore remain unadjudicated unless a reviewer checks them.

For each proposed easy target, the app must show a candidate observation with:

- The selected input identity and the current analysis run.
- An actual decoded frame timestamp and an object bounding box on that frame.
- The predicted class, detector confidence and, when relevant, an object-linked
  color prediction with confidence or an explicit unknown value.
- The original frame and a reviewable crop inside Watchtower. A crop must come from
  the stated frame and box; it cannot substitute for scene context.
- For clothing, the relevant clothing region on the detected person. For a car,
  its body region. A blue bag, background patch or adjacent white dog cannot prove
  the person's clothing color.

Candidate evidence starts as **review required**. A human reviewer compares it
with the clip and target inside Watchtower before accepting that target. Record
the reviewer decision, evidence reference and any disagreement or uncertainty.
Automatic checks may reject malformed or missing evidence; valid JSON, a high
confidence value, or a matching class string alone cannot establish recognition.

A target with no candidate is visibly not demonstrated. An interrupted run,
missing prerequisite, unreviewed candidate or unscorable target is distinct from
an accepted target. Do not turn any of those states into a pass. State which
targets were checked, accepted, rejected or still require review; do not silently
drop hard occurrences from the denominator.

The first pack deliberately has no authoritative per-frame box annotations. It
does not support precision, recall, F1, IoU-based scores, exhaustive object counts
or false-positive rates now. CASES.md predeclares a later annotation schedule and
IoU criterion; those specifications do not create ground truth or a current score.
Do not invent negatives to manufacture scores. A checklist completion fraction, if displayed, must be named as such
and accompanied by review status; it is not detector accuracy.

## Common output and reproducibility

The implementation prompt and common result checker define the exact JSON contract.
The shared evidence model must carry these concepts:

| Record | Required concepts |
| --- | --- |
| Run | Run ID, input hash, source revision, effective configuration, detector/model provenance, start/end status, errors and actual measured resource/timing fields |
| Observation | Unique observation ID, decoded frame timestamp, class, confidence, normalized box and optional track ID |
| Color evidence | Reference to the same observation, region being classified, coarse color/confidence or explicit unknown, and its frame/crop evidence |
| Target review | Case/target reference, candidate observation references, review state, reviewer decision and reason |

Preserve actual recording timestamps and discontinuities. Display observed boxes
at their observed times; distinguish interpolation. This preserves the existing
tracking evidence requirements.
Keep measured time and memory separate from unavailable measurements. Record
shared-host conditions; a busy-host run is not a controlled throughput measurement.

## Execution and controls inside Watchtower

Use the real Labs recording-selection, analysis and evidence workflow. Operators
must be able to choose a clip, start analysis, inspect boxes/crops/colors alongside
playback, review targets, cancel, and save/reopen the evidence inside Watchtower.
Product-owned helper processes and development automation are allowed; a terminal
report or standalone viewer is not the acceptance surface.

Include meaningful checks for:

- Same video under a different neutral filename: labels must not come from names.
  Disclose nondeterminism rather than demand identical floating-point output.
- Input A, then input B, then A again: no stale observations, crops or review
  decisions belonging to another input/run.
- Cancellation and shutdown: stop work, retain an honest incomplete status and
  avoid orphan processing.
- Missing, unreadable or undecodable input and missing model: visible failures
  with no recycled successful result.
- Saved/reopened evidence: verify input identity and preserve configuration,
  observations and review decisions; an absent recording is reported honestly.
- Deliberate failure control: the interface must display a genuine check failure.
- Applicable existing tracking and product regression checks, without weakening
  protected tests or relabelling synthetic results as recording accuracy.

These checks prove workflow properties, not object-recognition accuracy. Synthetic
data may test contracts and failure handling but cannot count as one of the real
recording detection cases. Keep all trial findings local; do not write production
findings, change the live registry, contact cameras, deploy, or commit footage and
local run artifacts.

## Later unseen-video evaluation

Before the operator supplies new test videos, freeze the implementation's source
revision, model/checkpoint hashes, dependencies and effective configuration. Run
that unchanged implementation on the new videos first. Any subsequent tuning must
have a separate revision and result, never replace the initial unseen result.

Apply the same in-app evidence review to new clips. To add full detection metrics,
first create and freeze verified frame annotations: evaluated classes, complete
labels within reviewed regions, boxes, timestamps, color-region labels and explicit
ignore/uncertain regions. Agree scoring rules before inspecting detector outputs.
No such complete annotation set is claimed by this initial pack.

Report public-development and unseen results separately, with per-clip outcomes
and unresolved cases. Similar subjects or views across supplied clips do not make
them independent proof of generalization. Report reproducible evidence and
effective resource use; do not claim general detection accuracy from filename
checklist completion alone.

## Submission evidence

Run development checks and record limitations while implementing. Preserve the
finished source/configuration/weights and write the submission report required by
PROMPT.md. Separate measured outcomes from unverified claims, include per-case
evidence and failures, and explain the implementation choices. Keep this Stage 3
evidence separate from earlier tracking results and earlier quota snapshots.
Report development time, tokens and spending only where the Stage 3 interval and
source are observed. Independent acceptance remains separate from self-checks.
