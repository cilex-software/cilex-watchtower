# Stage 3 common result and review contract — version 1

This is a product-owned interchange format for the new Labs analysers and the
reviewer. The operator uses it through Watchtower. It is not a new application
or a detector implementation. The reference helper is
[`tools/labs/stage3_evidence.py`](../../../tools/labs/stage3_evidence.py:1).

## Run object

| Field | Required value |
|---|---|
| `schema_version` | Integer `1` |
| `run_id` | Nonempty string, unique for every new analysis; immutable after saving |
| `clip_id` | Selected input ID; supplied clips use `WT3-001` through `WT3-008`; later clips can have new IDs |
| `input_sha256` | SHA-256 of actual selected video bytes; must match selected clip manifest |
| `source_revision` | Actual implementation revision, not a model-generated claim; record a dirty-tree hash separately if needed |
| `analyser` | Object containing nonempty `id` and `version`; identify combined pipeline/version if object and colour share execution |
| `model` | `name`, `weights_sha256`; only genuinely unweighted methods may use null hash with nonempty `reason_no_weights` |
| `config` | Actual effective configuration object, including thresholds, resize, sampling, device and seed where applicable |
| `status` | `completed`, `failed` or `cancelled`; running state stays in the UI until a saved snapshot is marked partial/cancelled |
| `observations` | List of the observation records below; empty is allowed and does not imply success on targets |
| `errors` | List of error messages; must be empty on completed runs |
| `measurements` | Object of measured values; unknown measurements are null or omitted, never invented zero |

Use finite JSON values only. Booleans are not numbers. Do not serialize NaN or
Infinity. Include model download/source, licence and dependency versions in the
saved evidence details/submission. Multiple model artifacts should be listed with
their own hashes in additional metadata and represented by a reproducible model
bundle hash in `weights_sha256`.

Recommended measurement keys are `elapsed_ms`, `peak_rss_bytes`,
`decoded_frame_count`, `inference_frame_count`, with hardware/runtime details.
Record the measurement method. End-minus-start RSS is not peak RSS. First model
load and subsequent runs should be reported separately if measured. These fields
do not create a performance score or a budget limit.

## Observations

| Field | Meaning |
|---|---|
| `id` | Unique nonempty observation identifier within this run |
| `frame_index` | Zero-based index in decoded presentation order, before inference sampling |
| `frame_pts_ms` | Actual decoded presentation timestamp minus first decoded frame timestamp, in milliseconds; nonnegative and within clip duration |
| `class` | `person`, `car`, `dog`, `bag`, `scooter` or `other` |
| `confidence` | Finite number from 0 to 1; describe its source, do not claim calibration without measurement |
| `bbox_xywh` | `[x, y, width, height]`, normalized to the full displayed source frame after any declared orientation transform; positive size and entirely within frame |
| `track_id` | Optional nonempty track reference; no cross-camera identity claim |
| `colors` | List of object-linked colour records: `region`, `label`, `confidence` |

Restore detector resize/letterbox coordinates to source coordinates. Multiple
objects may share a frame index and PTS; the same frame index must not carry
different PTS values. Distinct presentation-frame indices must have increasing
PTS. Record and surface malformed/discontinuous timing rather than substituting
average FPS or filename time. Keep a source stream/time-base mapping in evidence
details so the reviewer can verify alignment.

Extra native model classes must map to `other` here, with an optional `native_class`
field preserving the model's label. They do not satisfy required person/car cases.
Do not relabel truck/bus/motorcycle as `car` merely to satisfy a target.

Colour regions: `vehicle_body`, `clothing`, `upper_clothing`, `lower_clothing`.
Labels: `black`, `dark_gray`, `white`, `light_gray`, `red`, `blue`, `brown`, `pink`,
`green`, `yellow`, `orange`, `unknown`. Emit at most one dominant prediction per
region on an observation. Confidence is finite, 0 to 1. Additional distributions
may be retained separately; a list of every possible label cannot satisfy a colour.

Region matching is exact. Whole `clothing` is not silently treated as
`upper_clothing`, or vice versa. The sampler must actually inspect the stated
region of the detected object. Preserve the colour-region box/mask/crop reference
as additional evidence so Watchtower can show what pixels supported the claim.
`unknown` is a valid abstention and never satisfies a required colour.

The helper checks structure, ranges and metadata consistency; it cannot prove
that a box is on an actual person, a timestamp came from decoding, a crop exists,
or a colour was inferred from the right pixels. In-app evidence inspection and
the later independently annotated frames establish those facts.

## Partial positive target definition

Each clip in dataset.json carries `targets`, each with `target_id`, `subject_id`,
`class`, and `required_colors` (`region` plus `accepted_labels`). Only the target
evaluator reads this annotation data. The detector must not consume it. The neutral
dataset's `inputs.json` contains file identities and media metadata only.

`validate_run(run, clip)` returns structural errors. `assess_targets(run, clip)`
returns candidate observation IDs, including `qualifying_observation_ids` where
the required class and every required colour co-occur on **one observation**.
Colours from another object or time do not qualify that observation. Multiple
matching people are candidates for human review, not automatic proof of which
person is the specified target.

## Human review

The review object is separate from immutable analyser output:

| Field | Value |
|---|---|
| `run_id`, `input_sha256` | Must match the reviewed run |
| `run_sha256` | `stage3_evidence.evidence_digest(run)`, binding the full output/config/model to the decision |
| `reviewer` | Nonempty reviewer identifier; a supplied string is attribution, not authentication |
| `targets` | List of target decisions below; partial review is allowed |

Each decision has `target_id`, `decision` (`accepted`, `rejected`, `unreviewable`),
`observation_ids` and `note`. Rejection/unreviewable needs a nonempty reason.
Acceptance requires a completed run and at least one qualifying observation.
Different specified subjects cannot reuse the same accepted observation ID.
The reviewer must also verify that different IDs really describe the required
different subjects; the helper cannot infer physical identity.

`evidence_digest` hashes canonical JSON (sorted keys, compact separators, ASCII
escaping, no NaN). A changed run/config/observation needs a new review. It is a
binding checksum, not cryptographic proof that a human watched the footage.
Preserve the reviewer's decision; do not fabricate reviews. Your own development
reviews must say who performed them.

## Result states and honest UI

| State | Meaning |
|---|---|
| `invalid` | Structural mismatch or invalid/stale review; show exact errors |
| `not_verified` | Failed/cancelled run; partial observations do not create a completed pass |
| `not_detected` | Completed valid run with no class candidate for that target |
| `review_required` | Class candidates exist; verify actual object and required colour; missing colour remains visible in candidate detail |
| `accepted` | Reviewer accepted qualifying evidence for this target |
| `rejected` | Reviewer rejected the target claim; preserve why |
| `unreviewable` | Cannot judge this target reliably; preserve why |
| Aggregate `reviewed` | Every target has a decision; **does not mean passed**, since all may be rejected/unreviewable |

Display individual outcomes and `summary.status_counts`. Do not colour an entire
run green merely because its state is `completed`, schema-valid or `reviewed`.
No precision/recall/F1 or claim of general detector accuracy is produced by this
partial-positive helper. Those require the independent annotation phase in CASES.md.
