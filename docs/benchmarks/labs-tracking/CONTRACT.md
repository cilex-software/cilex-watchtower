# Labs temporal tracking benchmark: contract v1

This is the normative, shared implementation contract. Public examples illustrate it;
hidden tests use other instances of these same rules. No camera, backend, station,
credential, production database, model download, or real footage is needed.
This task measures temporal association of supplied observations. It does not identify
cars, people, children, clothes, breeds, activities, or persistent real-world identities.

## 1. Deliverables and isolation

Implement `tools/labs/temporal_tracks.py`, `tools/labs/replay_temporal_tracks.py`, and
`tools/labs/temporal_tracks_adapter.py`, with focused offline tests and documentation.
The core and CLI may use Python's standard library and the existing NumPy dependency.
The adapter may use existing OpenCV, but must not require images or OpenCV to import.
Do not add dependencies, neural code, trained parameters, network calls, or subprocesses
to the implementation. The adapter is used only through an explicit import/call.
Do not register an analyzer, change any worker/plugin default, change API payloads sent
by existing analyzers, or modify a vendored `labs_*.py` module. Existing behavior stays
on its existing path. There is no station rollout or production activation in this task.

## 2. Python API and common rules

Export `TrackingError(ValueError)`, with a public string attribute `code`, and `Tracker`:

```python
tracker = Tracker(camera_id="cam-a", unit_id="unit-a", config=None)
receipt = tracker.feed(batch)              # dict; described below
episodes = tracker.drain()                 # list[dict]; clears pending output
closed = tracker.finish()                  # list[str]; newly closed track IDs
checkpoint = tracker.snapshot()            # JSON-compatible dict, independent copy
restored = Tracker.restore(checkpoint)      # classmethod; independent new Tracker
```

All public data is ordinary JSON-compatible dictionaries/lists/scalars, not NumPy
objects. Returned data, supplied inputs, configuration, and snapshots must not alias
mutable internal state. Mutating one must not change a tracker or another return value.
Booleans do not count as integers or real numbers. Reject NaN, infinity, and numeric
strings wherever numbers are required. Floats in outputs must also be finite.
IDs match `[A-Za-z0-9_.:-]{1,64}`. Dictionary key order has no meaning.
Malformed constructor camera/unit IDs raise `invalid_input`.
Unknown keys are errors in configuration, batches, detections, and CLI commands.
Use `TrackingError` for expected validation/state failures; human error wording is free.
Unless stated otherwise, a rejected operation leaves the entire observable state intact,
including counters, replay history, pending output, and subsequent deterministic IDs.

## 3. Configuration

An omitted key takes its default. These are the only keys; all bounds are inclusive
except a bound written with `>`:

| Key | Default | Type and permitted range |
| --- | ---: | --- |
| `gate_base` | 0.15 | real, >0 and <=1 |
| `gate_speed` | 0.10 | real, 0..2 |
| `max_speed` | 1.0 | real, >0 and <=10 |
| `max_gap_ms` | 2000 | integer, 1..10000 |
| `max_span_ms` | 299000 | integer, 1..299000 |
| `max_area_ratio` | 4.0 | real, 1..100 |
| `appearance_weight` | 0.25 | real, 0..2 |
| `appearance_gate` | 0.50 | real, 0..1 |
| `ambiguity_margin` | 1000 | integer, 0..1000000 |
| `max_tracks` | 64 | integer, 1..128 |
| `max_detections` | 64 | integer, 1..128 |
| `max_pending` | 256 | integer, 1..1024 |
| `replay_batches` | 32 | integer, 1..128 |
| `path_points` | 32 | integer, 2..128 |

Require max_pending>=max_tracks. Invalid configuration raises `invalid_config`. Store
the resolved configuration. Association coefficients are this benchmark's fixed policy, not a claim
that thresholds have been calibrated for the production cameras.

## 4. Input batches and ordering

```json
{"camera_id":"cam-a","unit_id":"unit-a","seq":0,"t_ms":0,
 "detections":[{"id":"d0","bbox":[0.10,0.20,0.10,0.20]}]}
```

Required batch keys are `camera_id`, `unit_id`, `seq`, `t_ms`, and `detections`.
The only optional batch key is `reset`, a boolean defaulting to false.
`seq` is an integer in 0..2147483647, scoped to this one camera/unit tracker.
The first new batch has seq=0; each subsequent new batch has previous seq+1.
`t_ms` is an integer in 0..9007199254740991, relative to a caller-chosen origin.
New batches have strictly increasing timestamps; an empty batch still advances time.
Equal-time observations belong in one batch. No automatic sorting of batch timestamps.
Camera and unit must equal the constructor values; a scope mismatch is `wrong_scope`.
A new nonconsecutive seq, or nonincreasing new timestamp, is `sequence_error`.

Each detection has required `id` and `bbox`, and optional `appearance` defaulting to null.
Detection IDs are unique within a batch; they need not be unique across batches.
`bbox` is `[x,y,w,h]`, four finite real numbers: x,y>=0; w,h>=1e-6; x+w<=1; y+h<=1.
Its center is `(x+w/2,y+h/2)` and its area is w*h. Use these box centers throughout;
there are no pixel centroids, confidence values, labels, masks, or inferred classes.
`appearance` is null or a four-element list of finite reals in 0..1 whose sum differs
from 1 by at most 1e-9. It represents an already supplied coarse appearance histogram.
Never normalize, clip, repair, or invent malformed measurements silently.
`detections` is a list of length <=`max_detections`; an empty list is valid.
Malformed input, duplicate detection IDs, or excess detections raises `invalid_input`.
Detection-list order is immaterial: normalize by ascending detection ID before processing.

## 5. Bounded replay and atomicity

Retain normalized input identity and the original receipt for only the latest
`replay_batches` accepted NEW batches. No unbounded seen-ID or payload history is allowed.
Within that window, feeding the same seq with equivalent normalized content returns the
original receipt with `replayed=true`, without association, new IDs, output requeueing,
time advancement, or any other state change. The stored receipt has `replayed=false`.
In this comparison, detection permutation, omitted optional defaults, and equivalent
integer/float measurements (such as bbox 0 versus 0.0) are the same normalized input.
Different normalized content at a retained seq raises `replay_conflict`.
A seq <= the accepted high-water mark but outside the retained window raises
`stale_replay`; no claim is made about its historical content. There is no rewind.
Replay never restores already drained episodes. Its receipt describes the original
operation, including the IDs it originally closed, rather than current queue contents.
Validate a complete operation before committing it. In particular, output/track capacity
failure must not partially expire tracks, update measurements, or advance seq.
This is replay at a specified checkpoint boundary, not external exactly-once delivery.

## 6. Track lifetime and prediction

Track IDs are `t` followed by an increasing counter padded to at least eight decimal
digits, starting `t00000001`. Allocate new IDs in ascending detection-ID order per batch.
IDs are local to the camera/unit; a tracker never attaches a detection from another scope.
Before association on a NEW batch: a reset closes every active track with reason `reset`.
Otherwise close a track if t-last_observed_t>`max_gap_ms` (reason `gap`), or, only if that
test fails, t-first_observed_t>`max_span_ms` (reason `span`). Boundaries are strict `>`.
Closure ends at the last actual observation, never at the later timeout or reset time.
Closed tracks are never reattached. Remaining tracks coast through empty/unmatched
batches until those limits; missing time does not create synthetic observations.
New detections on the same reset/expiry batch may immediately create fresh tracks.

Prediction uses the last TWO accepted observations on a track; with only one, velocity
is zero. Divide their center difference by elapsed seconds, then cap vector magnitude
at `max_speed` without changing direction. Predict from the last center over the actual
elapsed seconds to the current batch. Do not clip predicted centers to the image.
Distance is Euclidean in normalized x/y coordinates; do not apply an aspect correction.
Only successful, unambiguous assignments update velocity, last box, or appearance.
The track's appearance is its most recent non-null accepted appearance, initially null.

## 7. Feasible edges, matching, and explicit ambiguity

For each remaining track i and detection j, let dt be seconds since its last observation,
g=`gate_base + gate_speed*dt`, and d be distance from its predicted center to j's center.
An edge exists only if d<=g and the ratio of detection box area to last track box area
lies in `[1/max_area_ratio, max_area_ratio]`. These gates are inclusive.
If both appearances exist, a=0.5*sum(abs(track[k]-detection[k])) and require
a<=`appearance_gate`; otherwise a=0 and no appearance gate applies.
The edge's integer cost is `floor(1000000*(d/g + appearance_weight*a)+0.5)`.
Do not add identity, age, input-position, or semantic-class penalties to this cost.

Split this bipartite graph into connected components. For each component with edges,
find a matching of MAXIMUM cardinality K, then MINIMUM summed integer cost C among
size-K matchings. Greedy nearest-neighbor assignment is not an acceptable substitute.
A different matching means a different set of track/detection pairs. If any different
size-K matching has cost <=C+`ambiguity_margin`, the WHOLE component is ambiguous.
One way to test this is to forbid each selected edge in turn and solve again; a brute
force enumeration of all permutations is not acceptable for the supported capacities.
With no alternative size-K matching, the component is unambiguous regardless of margin.

Also mark a component ambiguous as a possible merge if any detection box contains the
predicted centers of at least two adjacent feasible tracks (including box boundaries).
This conservative geometric rule needs no claim that the detector actually merged objects.
The merge rule takes precedence over matching ambiguity when reporting a reason.
All detections in an ambiguous component receive status `ambiguous`, track_id=null,
and reason `merge` or `cost_tie`. None starts or updates a track in that batch.
Each track in that component increments its `ambiguous_batches` once, then coasts.
Thus a completely indistinguishable crossing is allowed to remain unresolved.
Do not manufacture perfect identity recovery from observations that cannot provide it.

For an unambiguous component accept its unique best matching. Every unmatched detection,
including an isolated detection with no feasible edge, starts a new track. Unmatched
tracks coast. If the resulting active count would exceed `max_tracks`, raise `capacity`;
never silently drop detections, evict tracks, or take only the first matching detections.

## 8. Receipts, episode evidence, and output draining

`feed` returns exactly `seq`, `replayed`, `assignments`, and `closed`. `assignments` is
sorted by detection ID; each entry has exactly `detection_id`, `track_id`, `status`,
and `reason`. Status is `born`, `matched`, or `ambiguous`; reason is null except for
ambiguity. Every input detection appears exactly once. `closed` lists IDs of episodes
closed during that operation, ordered by `(start_ms, track_id)`.
An empty accepted batch has an empty assignments list but may have closed IDs.
Joining `(seq,detection_id)` receipts to the input stream gives a complete evidence
ledger for a caller that needs one; bounded episodes do not retain every detection ID.

Each closed episode is a dictionary with exactly these keys:

| Key | Meaning |
| --- | --- |
| `camera_id`, `unit_id`, `track_id` | Scope and local track ID |
| `start_ms`, `end_ms` | First/last accepted observation timestamps |
| `observations` | Number of accepted detections, including birth |
| `ambiguous_batches` | Number of component-abstention batches for this track |
| `reason` | `gap`, `span`, `reset`, or `finish` |
| `bbox`, `bbox_at_ms` | Largest-area accepted box and its timestamp; earliest wins a tie |
| `first_center`, `last_center` | Two-element center lists from actual observations |
| `path_length` | Sum of distances between consecutive accepted centers |
| `net_displacement` | Distance from first to last accepted center |
| `mean_speed` | path_length / elapsed seconds; null for zero duration |
| `max_observation_gap_ms` | Largest gap between consecutive accepted observations; 0 for one |
| `path` | Bounded list of `[t_ms,cx,cy]` actual-observation samples |

No interpolation contributes to counts, timestamps, paths, boxes, speed, or evidence.
Appearance gates association only; it does not become a color or semantic verdict.
Maintain measurement accumulators from EVERY accepted observation, independent of path
sampling. Append each observation to `path`. If it exceeds `path_points`, remove the
interior sample minimizing the absolute 2D cross product of its two adjacent spatial
segments; break exact ties by removing the earliest interior timestamp. Repeat as needed.
Never remove the first/latest samples. This is a prescribed bounded online simplifier;
it need not equal a simplification that could inspect a complete future trajectory.

Closed episodes are appended to a FIFO outbox, operation by operation, with the above
per-operation ordering. `drain()` returns all currently pending episodes in that order
and empties the outbox. Repeated drain returns `[]`. There is no retained completed-track
archive. If an operation would exceed `max_pending`, raise `capacity` atomically; callers
can drain then retry the exact operation. Merely returning closed IDs does not drain.
`finish()` closes all active tracks with reason `finish`, subject to the same capacity
rule; it returns newly closed IDs in the same ordering and seals the tracker. Successful
repeated finish returns `[]` and emits nothing. Any feed after finish raises `finished`,
including a replay. Drain, snapshot, and restore still work on a finished tracker.

## 9. Checkpoints, bounded state, and invalid snapshots

`snapshot()` does not mutate, drain, or close anything. Its envelope has exactly
`schema`, `state`, and `sha256`, with schema=`labs-temporal-tracker/v1`.
`state` is an implementation-defined JSON object containing everything required to
continue: resolved config, scope, counters, active measurements, outbox, replay window,
and finish status. `sha256` is the lowercase SHA-256 hex digest of UTF-8 bytes of
`json.dumps(state, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)`.
This detects accidental corruption; it is not authentication or a security boundary.
Restore must validate schema, checksum, types, numeric finiteness, configuration, bounds,
scope, IDs, time/counter consistency, and its own state invariants; a checksum recomputed
over an invalid state does not make it valid. Raise `invalid_snapshot` for invalid input.
Reject unknown envelope keys and incompatible versions; never load pickle or execute data.

Snapshots survive JSON serialization and a fresh Python process. After restore, every
subsequent receipt, episode, ID and snapshot is equivalent to uninterrupted execution at
the same operation boundary. Snapshots from the same state are equivalent JSON values.
Floating comparisons in evaluator measurements use abs/relative tolerance 1e-9; IDs,
counts, statuses, quantized costs, ordering, and integer times are exact.
No file path, process hash seed, clock time, random state, or object address affects output.
Do not store whole input streams, frames, raw pixels, or all previous output records.
State storage must be bounded by the configured active tracks/path samples, pending
episodes/path samples, and replay entries/detections, independent of elapsed run length.
Numeric counters and aggregate distances may grow. Caller-retained drained output is
outside this bound. Section 13 sets resource workloads/budgets; EVALUATION.md sets scoring.

## 10. Offline adapter and Labs wire preview

The adapter exports pure `mask_frame_batch(frame, *, camera_id, unit_id, seq,
previous_run=None)`. It accepts the existing MaskFrame/Blob interface by duck typing:
frame has `t_s`, `run`, `scored`, `blobs`; each blob has integer `label` and normalized
`bbox`. No pixels are read. `t_ms=floor(1000*t_s+0.5)`; t_s must be finite and >=0.
`run` is a nonnegative integer, `previous_run` is null or a nonnegative integer,
and `scored` is boolean. Malformed adapter input raises `invalid_input`.
`reset` is true exactly when previous_run is not null and frame.run!=previous_run.
Scored frames map every blob to `{id: "b"+str(label), bbox: list(blob.bbox)}`; unscored
frames map to no detections, without inspecting/validating their blobs. Scored labels
must be distinct nonnegative integers. Appearance is omitted. Validate scope, structure,
and measurements here; feed enforces its configured capacities/time order. Timestamp collisions
after millisecond rounding are rejected by feed, not silently combined or discarded.
An explicit caller supplies the previous run and handles pre-roll/origin placement.
The new adapter's reset policy is this contract's; it need not imitate B6's cross-run
episode stitching. B6 and its normal plugin execution must remain unchanged.

Also export pure `labs_rows(episodes, *, hour_start)` for an offline wire PREVIEW only.
`hour_start` is an aware datetime; normalize to UTC, then require minute=second=microsecond=0.
Materialize and validate every episode against section 8 before returning anything;
require <=500 episodes, each start_ms in
0..3599999, end_ms>=start_ms, and end_ms-start_ms<300000. Reject violations with
`invalid_input`. Never truncate, coarsely merge, submit, or claim this preview as live.
Preserve episode order. Each row contains exactly `start_time`, `end_time`, `object_count`,
`bbox_x`, `bbox_y`, `bbox_w`, `bbox_h`, and `metrics`, matching existing ObservationIn names.
The times are hour_start+start_ms/end_ms, in UTC `YYYY-MM-DDTHH:MM:SS.mmmZ` format;
object_count=1. Bbox uses episode.bbox. No `ts` or `span_s` aliases are emitted.
Metrics contain exactly `track_id`, `observations`, `ambiguous_batches`, `path_length`,
`net_displacement`, `mean_speed`, `max_gap_s`, and `end_reason`; the last two map from
max_observation_gap_ms/1000 and reason. No `object_class`, confidence, or kind is added.
Keep <=24 metric keys, each <=40 lowercase ASCII letters/digits/underscores; scalar
values only, finite numbers, and strings <=120 characters. No nested path in metrics.

## 11. JSONL command line protocol

`python3 tools/labs/replay_temporal_tracks.py` reads UTF-8 JSONL from stdin and writes
exactly one JSON response per nonblank input line to stdout, with no banners/logging.
Commands are objects with the following exact shapes (config may be omitted on init):

```json
{"op":"init","camera_id":"cam-a","unit_id":"unit-a","config":{}}
{"op":"feed","batch":{"camera_id":"cam-a","unit_id":"unit-a","seq":0,"t_ms":0,"detections":[]}}
{"op":"drain"}
{"op":"snapshot"}
{"op":"restore","snapshot":{"schema":"labs-temporal-tracker/v1","state":{},"sha256":"..."}}
{"op":"finish"}
```

There is one in-memory tracker. Init/restore creates or replaces it ONLY after validation;
failed replacement preserves the previous tracker. Other commands before initialization
return `not_initialized`. A successful response is exactly `{"ok":true,"result":VALUE}`;
init/restore result is null, and other results are the Python API return values.
A failed response is exactly `{"ok":false,"error":{"code":"CODE"}}`. Bad JSON,
unknown op, duplicate object keys, NaN/Infinity JSON tokens, or malformed command is
`invalid_input`. API error codes pass through. Continue with later lines after errors.
Each line is processed atomically. EOF does NOT implicitly finish or drain. Exit 0 if
all lines succeeded (including empty input), 1 if any line produced an error response.
Unexpected internal errors are failures, not successes or silently swallowed data loss.
JSON whitespace/key formatting is free; stdout must remain valid JSONL and finite.

## 12. Public examples and evaluation boundaries

Public examples and tests accompany this contract. Additional tests may vary valid
configurations, reorder detections, form non-greedy matching cases, supply appearance
gates, create merges/crossings, exercise empty/gapped streams and boundaries, mutate
snapshots, replay within/outside the window, and check backpressure/retry equivalence.
Identity tests provide distinguishable evidence or expect the specified abstention.
No undocumented semantic labels, private footage accuracy targets, optional service,
neighboring checkout, GPU, internet connection, or new dependency is an acceptance need.

## 13. Fixed streaming resource workload

Run these two independent default-config trackers in one process, sequentially. Generate
each batch on demand, feed it, and drain/discard output immediately; retain no stream or
episode archive in the harness. Detections have no appearance and IDs `d0`, `d1`, etc.
Both runs use seq=n and t_ms=200*n, starting n=0; finish and drain at each run's end.

1. 100000 batches, eight detections per batch. For j=0..7, let c=j%4, r=j//4,
   q=n%1000, u=q/250-1 if q<500 else 3-q/250. The center is
   `(0.12+0.25*c+0.02*u, 0.25+0.50*r)` and box width/height are 0.04/0.04.
2. 250 batches, 32 detections per batch. For j=0..31, let c=j%8, r=j//8,
   q=n%50, u=q/12.5-1 if q<25 else 3-q/12.5. The center is
   `((c+0.5)/8+0.005*u, (r+0.5)/4)` and box width/height are 0.02/0.02.

In both, bbox x/y=center minus half width/height. Camera IDs are `resource-a` and
`resource-b`; unit_id=`resource`. These longer synthetic units test core storage, not
Labs hour submission. At n=0 and each n divisible by 1000, after drain, serialize a
snapshot to canonical UTF-8 JSON and discard it. Each must be <=2097152 bytes.
At every batch a correct run assigns all detections, with no ambiguity; span closures
may start new tracks. Evaluators also verify aggregate observation accounting and
checkpoint equivalence, not just successful process exit. Input generation, feed,
drain, sampled serialization, finish, and final drain are inside the measured interval.

Limit: 180 seconds on one isolated CPU and <=128 MiB additional peak RSS above the
post-import baseline, for both streams together. The evaluator measures process RSS
and elapsed time externally; tracemalloc alone is not a substitute. Report three fresh
measured-process runs serially after one unscored warmup, as EVALUATION.md specifies.
These are declared limits, not reported reference measurements. Participants may
start autonomous implementation and local measurement immediately; evaluator
preparation is not a prerequisite for their development. Before comparative
resource scoring, the coordinator must independently validate workload semantics
and feasibility on a common evaluation environment. Any necessary adjustment
must be documented and sent identically to both participants before examining
their performance results. No adjustment to favor an observed submission is
permitted. Shared-host local timings are diagnostic until controlled reruns.
