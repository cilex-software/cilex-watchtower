# Labs temporal tracking benchmark — Qwen submission

Participant: Qwen (branch `benchmark/qwen-labs-tracking`).
Starting setup commit: **`f442cb5b7092406d3f026d54d8791d5afaec4586`**
("docs(benchmark): authorize autonomous implementation and publication",
2026-10-04 03:37:15 +0300). Work was done offline in the assigned checkout
`/home/cilex-vision/projects/cilex-watchtower-qwen`, on a shared 20-CPU Linux
host (Python 3.12.3, NumPy 2.4.4, opencv-python 4.13.0.92). The other
participant's branch, worktree and results were never inspected.

The final implementation commit is identified in the conversation's final
response, not here, because this file is part of that commit.

## 1. What was added

| File | Lines | Role |
|---|---:|---|
| `tools/labs/temporal_tracks.py` | 1318 | The engine: validation, state, tracks, evidence, receipts, replay window, checkpoints |
| `tools/labs/temporal_tracks_matching.py` | 235 | Private helper: maximum-cardinality minimum-cost bipartite matching and the ambiguity test |
| `tools/labs/temporal_tracks_adapter.py` | 241 | Private offline adapter: `MaskFrame` → batch, episodes → wire preview |
| `tools/labs/replay_temporal_tracks.py` | 185 | Private offline JSONL CLI |
| `tools/tests/labs-temporal-tracks.py` | 2159 | The test suite (613 checks) |
| `tools/tests/fixtures/temporal_tracks/case_harness.py` | 449 | Test helper: interprets the published `cases.json` annotations |
| `tools/tests/fixtures/temporal_tracks/workload.py` | 302 | Test helper: contract section 13's fixed streaming workload |
| `tools/tests/fixtures/temporal_tracks/mutation_check.py` | 439 | Test helper: plants defects and requires the suite to fail |

No existing file was edited. `git status` before the commit listed only these
new paths; the four version-metadata files changed in the commit were written by
the repository's own `pre-commit` hook, as the prompt allows. Nothing was
registered with `run_worker.py`, no plugin default changed, no vendored
`labs_*.py` module was touched (their hash pins in `tools/tests/labs-worker.py`
still verify), and B6 `labs_track_linking` remains the default track linker.

## 2. Implemented behaviour

Everything `CONTRACT.md` v1 specifies, including the parts the public examples
do not exercise:

* **API** — `TrackingError(ValueError)` with a public `code`, and `Tracker` with
  `feed`/`drain`/`finish`/`snapshot`/`Tracker.restore`. All returned data is
  JSON-compatible and never aliases tracker state, supplied input, configuration
  or a snapshot; each is copied or ownership-transferred at the boundary.
* **Configuration** — the 14 documented keys with their defaults, types and
  bounds (inclusive except where written `>`), `max_pending >= max_tracks`, and
  unknown keys refused. A real-valued key accepts an integer (the published
  merge case passes `max_area_ratio: 100`); an integer-valued key refuses a
  float, a bool or a numeric string.
* **Association** — per-track constant-velocity prediction from the last two
  *accepted* observations, magnitude-capped at `max_speed` without changing
  direction and never clipped to the frame; inclusive gates on distance
  (`gate_base + gate_speed*dt` against the predicted centre), box-area ratio and
  — only when both sides supplied one — half the L1 appearance distance;
  the contract's quantised integer edge cost with no extra penalties.
* **Matching** — per connected component, maximum cardinality first, then
  minimum cost among matchings of that size. Greedy nearest-edge assignment is
  not used anywhere.
* **Explicit ambiguity** — a component abstains when a *different*
  size-K matching costs no more than the best plus `ambiguity_margin`
  (`cost_tie`), or when one detection box contains the predicted centres of at
  least two tracks feasible for it (`merge`, which takes precedence in
  reporting). Every detection in the component is reported `ambiguous` with no
  track ID, every track in it counts the batch once and coasts, and no detection
  in it starts a track.
* **Lifetime** — `gap` then `span` on a new batch, `reset` instead of both when
  declared, all with strict `>` boundaries and closure at the last actual
  observation; `finish` seals; closed tracks are never reattached; IDs are
  `t` + an 8-digit counter allocated in ascending detection-ID order and are
  local to the camera/unit.
* **Evidence** — the 17 section-8 fields, accumulated from accepted observations
  only, with the prescribed bounded online path simplifier. Nothing is
  interpolated: a coasting track predicts in order to associate, and that
  prediction never becomes a timestamp, centre, box, count or speed.
* **Replay and atomicity** — the latest `replay_batches` accepted new batches
  retain a normalised input identity and the original receipt. An equivalent
  replay returns that receipt with `replayed: true` and changes nothing,
  including no requeueing of drained episodes; different content is
  `replay_conflict`; a seq at or below the high-water mark outside the window is
  `stale_replay`. Every refusal — input, scope, sequence, both capacities,
  finish — leaves counters, replay history, pending output and the next ID
  untouched, so `drain()` then retrying the identical batch is a real recovery.
* **Checkpoints** — `snapshot()` mutates nothing and returns an envelope of
  exactly `schema`/`state`/`sha256`, the digest being SHA-256 over the contract's
  canonical JSON of `state`. `restore` validates the envelope, the checksum, and
  then the state on its own terms, because a checksum recomputed over an invalid
  state does not make it valid.
* **CLI** — `replay_temporal_tracks.py`, one response per non-blank line, no
  banner or logging on stdout, `{"ok":true,"result":...}` /
  `{"ok":false,"error":{"code":...}}`, `not_initialized` before init/restore,
  replacement only after validation, continuation after errors, no implicit
  finish or drain at EOF, exit 1 if any line errored.
* **Adapter** — `mask_frame_batch` (duck-typed `MaskFrame`/`Blob`, no pixel read,
  `t_ms = floor(1000*t_s + 0.5)`, `b<label>` detection IDs, `reset` exactly when
  a previous run was supplied and differs, unscored frames mapped to no
  detections without inspecting their blobs) and `labs_rows` (offline wire
  preview only: existing `ObservationIn` names, `object_count = 1`, no
  `ts`/`span_s` aliases, no `object_class`/confidence/kind, the eight metric keys
  inside `worker.check_metrics`' caps, every episode materialised and validated
  before any row is returned, order preserved, never truncated).

The core and adapter are pure Python standard library plus each other: no
NumPy, no OpenCV, no images, no network, no subprocess, no clock and no random
state in any decision. `tools/tests/labs-temporal-tracks.py` proves the adapter
and core import and run with `cv2` and `numpy` blocked outright.

## 3. Design decisions worth reviewing

* **Three private modules instead of one file.** The matching algorithm is the
  one part with a textbook shape and no state, so it lives alone in
  `temporal_tracks_matching.py`; validation/state/evidence/checkpoints live in
  `temporal_tracks.py`; the two offline surfaces (adapter, CLI) import the core
  and are never imported by it. Nothing in `tools/labs/plugins.py` or
  `run_worker.py` knows these files exist.
* **Successive shortest augmenting paths with a work queue (SPFA), not Dijkstra
  with potentials.** Matched edges contribute negative residual arcs. A
  potential-based Dijkstra would need a dual-feasibility argument about unreached
  nodes that this code does not have to make; SPFA is unconditionally correct
  with negative arcs and, at these component sizes, fast enough. Two properties
  are what make one pass over the tracks sufficient: if no augmenting path leaves
  track *i*, none can pass through it either (an alternating path enters a track
  only along its matched edge), so the induction over processed tracks gives
  maximum cardinality; and a maximum matching whose residual graph has no
  negative cycle is already minimum-cost among maximum matchings, because two
  maximum matchings differ only by even alternating cycles — a differing path
  would be an augmenting path for one of them.
* **Ambiguity by forbidding each selected edge**, the method the contract names:
  K+1 solves, not K! permutations. Two exact shortcuts keep common batches
  cheap without weakening the answer — when a component's edge count equals its
  matching size every edge is used, so no different matching of that size exists;
  and `forced_pairs()` recognises the whole-batch case where every non-isolated
  track and detection has exactly one edge, so every component is a single forced
  edge and no solve is needed at all. Section 13's 800 000-detection stream takes
  the second path almost entirely.
* **The path simplifier keeps its cross-product weights beside the path.** The
  contract's rule (drop the interior sample minimising the absolute 2D cross
  product of its adjacent segments, earliest timestamp on an exact tie) is
  O(path_points) per observation if rescanned. Only three weights can change per
  append — the sample that just became interior and the two neighbours of the
  one removed — so the minimum becomes two C-level list scans (`min`, then
  `index`, which returns the earliest tie). The weights are derived state:
  rebuilt on restore, never serialised.
* **Retained replay identity is a tuple, not a JSON string.** Comparison is
  value equality on normalised floats, which is what "equivalent integer/float
  measurements are the same normalized input" means, and it costs nothing per
  batch. `snapshot()` renders it as JSON and `restore` rebuilds the tuple, so a
  checkpoint round trip through a file keeps replay comparisons exact.
* **Atomicity by ordering, not by rollback.** `feed` validates, resolves expiry,
  associates and checks both capacities on scratch values; the first mutation
  happens after the last check, in a block that cannot raise. There is no undo
  log to get wrong.
* **Strict numbers.** Booleans are not numbers, `NaN`/infinity are refused,
  numeric strings are refused, and integer-typed fields refuse floats. Silent
  repair of a measurement was treated as worse than a refusal, per section 2.
* **Error precedence.** `finished` is checked before anything else ("any feed
  after finish raises finished"); then batch structure (`invalid_input`), then
  scope (`wrong_scope`), then replay/sequence. The contract does not order these
  against each other; this order is a documented choice, and the public cases
  agree with it.
* **Equal-area ties keep the earliest box.** The contract says the episode's
  `bbox` is the largest-area accepted box and `bbox_at_ms` its timestamp, without
  naming a tie-break. The published case
  `one-object-unique-and-bounded-path` feeds four boxes of identical area and
  expects `bbox_at_ms: 0`, which fixes earliest-wins; the implementation uses a
  strict `>` and the suite pins it.

## 4. Validation actually run

All on this host, offline, in the assigned checkout, at the commit this file is
part of. Load average was 15–22 on 20 CPUs during these runs (shared host, other
tenants), so timings are diagnostic rather than controlled.

| Command | Exit | Result |
|---|---:|---|
| `python3 tools/tests/labs-temporal-tracks.py` | 0 | `all passed (613 checks)`, 14.6 s wall |
| `python3 tools/tests/labs-worker.py` | 0 | `all passed`, 436 PASS lines, 29.7 s wall — including all 9 vendored `labs_*.py` hash pins and the "every vendored file has a pin" check |
| `python3 tools/labs/selftest_shape_observations.py` | 0 | `=== 79/79 checks passed ===`, `all good` |
| `python3 tools/labs/selftest_object_profile.py` | 0 | `=== 40/40 checks passed ===`, `all good` |
| `git diff --check` | 0 | no output (no whitespace errors, no conflict markers) |

No pre-existing failure was observed and no platform skip was needed: numpy and
cv2 are both installed here, so the worker gate ran rather than skipping.

### Published cases

`tools/tests/labs-temporal-tracks.py` runs every operation of all eight published
cases twice, through two independent paths, using the annotations in
`fixtures/README.md` (`on`, `expect.ok`, `expect.result`, `expect.result_subset`,
`expect.error`, `capture_result`, `snapshot_from`, `expect_result_equal`):

* **API path** — 102 operations across the eight cases, in process (8 checks,
  one per case, each asserting every operation in it).
* **CLI path** — the same operations grouped per `on` environment and replayed as
  `replay_temporal_tracks.py` subprocesses: 112 per-operation and exit-status
  assertions (8 checks). The `sealed` stream must exit 1 and every other stream
  must exit 0.
* 21 checks in all come from the published fixture; the remaining 592 do not.
* **Adapter examples** — all five published example/variant expectations, run
  against a real `labs_foreground_mask.Blob`.

Where an operation's `expect` carries only `ok`, the harness checks the
normative result *shape* for that op (exact receipt key set and per-assignment
invariants, section-8 episode validation, the three-key snapshot envelope with a
checksum that recomputes) rather than nothing at all. Measurement floats compare
at absolute/relative tolerance 1e-9; IDs, counts, statuses, quantised costs,
ordering and integer timestamps compare exactly.

### Beyond the published cases

The other 592 checks are written against the contract rather than the examples:
76 configuration-bound checks (every key at both bounds and one step outside
each, plus type refusals), 61 snapshot-refusal checks, 39 malformed-batch
refusals, 13 ID checks, 36 CLI-protocol checks and 58 adapter checks among them.
Subjects include:
non-greedy three-track assignment; inclusive gate, area-ratio and appearance
boundaries at exactly-representable dyadic values with a hair-beyond control for
each; prediction versus last position; magnitude capping versus component
clipping (the geometry is checked to separate them before it is used); coasting
through five empty batches and re-acquisition at the predicted place;
`ambiguity_margin` inclusive at exactly the difference and decisive one unit
past it; whole-component abstention including a member with a single feasible
edge; merge precedence over both a cost tie and a unique matching; merge box
boundaries inclusive; strict `>` gap/span boundaries; gap-before-span precedence;
reset versus expiry; scope isolation; sequence rules; replay equivalence under
permutation, explicit defaults and int/float spellings; conflict on a changed
measurement, detection set, timestamp, reset flag or appearance descriptor;
window eviction at exactly `replay_batches`; replay after drain; both capacities
with snapshot-identity before/after and drain-then-retry equivalence; finish
capacity leaving the tracker unsealed; every episode field; the online
simplifier's tie-break; detection accounting for a mixed matched/ambiguous/born
batch; ~40 malformed-batch refusals; checkpoint determinism, restore equivalence
through a JSON file in a fresh process under three `PYTHONHASHSEED` values;
corrupted snapshots (including mutations whose checksum is recomputed, so only a
real invariant check can catch them); aliasing of config, batch, receipt,
snapshot and drained episode; bounded retained state at small *and* maximum
configuration (128 tracks × 128 path samples × 128 retained batches); the CLI
protocol (unknown op, duplicate keys at any depth, `NaN`/`Infinity` tokens,
non-object lines, blank lines, `not_initialized`, failed init/restore preserving
the previous tracker, exit codes); and the adapter's limits cross-checked against
`worker.check_metrics` itself.

### Mutation check

`tools/tests/fixtures/temporal_tracks/mutation_check.py` plants single-edit
semantic defects in a throwaway copy of the tree — one working tracker per
defect, each still answering most questions correctly — and requires the suite to
fail. It also plants one no-op control edit and fails if that is reported as a
defect. This was run iteratively while writing the suite: the first full run
killed 52 of 56 defects and exposed four real holes (a component-abstention case
in which every detection happened to have two edges; no replay-conflict test that
changed only the appearance descriptor; a frame-overflow test that overshot the
tolerance it was meant to probe; and a 300 000 ms episode whose inconsistent
`mean_speed` meant a different rule refused it first). All four were closed and
re-verified.

The final complete run, against the committed tree, killed **58 of 58** planted
defects with **no survivors**, and correctly did *not* report the no-op control
edit (`ok C0 control CONTROL: not reported, as it must be`). Exit status 0,
242 s for all 58:

```
58/58 planted defects killed in 242 s
   association  9 killed: A1 A2 A3 A4 A5 A6 A7 A8 A9
   ambiguity    9 killed: B1 B2 B3 B4 B5 B6 B7 B8 B9
   time         8 killed: C1 C2 C3 C4 C5 C7 C8 C9
   replay      12 killed: D1 D2 D3 D4 D5 D6 D7 D8 D9 D10 D11 D12
   validation  20 killed: E1 E2 E3 E4 E5 E6 E7 E8 E9 E20 E10 E11 E12 E13 E14 E15 E16 E17 E18 E19
```

All five families the rubric names are covered, and the defects are the kind a
plausible implementation actually makes rather than syntax errors: greedy
cheapest-edge-first assignment (A1); gating on the last position instead of the
prediction (A2); no `max_speed` cap (A3); an exclusive gate where the contract is
inclusive (A4); no area-ratio gate (A5); input-order-dependent IDs and receipts
(A6); a one-band appearance distance (A7); `gate_speed` never widening the gate
(A8); a null descriptor clearing the track's descriptor (A9); the ambiguity test
never running (B1); only one track of a component counting an abstention (B2); no
merge rule (B3); an exclusive `ambiguity_margin` (B4); a smaller-cardinality
alternative voiding the matching (B5); a merge needing three centres (B6); only
multiply-linked detections abstaining (B7); a merge reported but the matching
applied anyway (B8); box boundaries excluded from the merge test (B9); an
inclusive gap boundary (C1); no span closure (C2); span tested before gap (C3);
equal timestamps accepted (C4); `reset` reported as `gap` (C5);
`max_observation_gap_ms` never recording a coast (C7); `mean_speed` dividing by
the wrong elapsed time (C8); the latest box winning an equal-area tie (C9); a
replay requeueing drained episodes (D1); a replay reporting today's queue (D2); a
replay window that never evicts (D3); an identity that ignores the appearance
descriptor (D4); a snapshot that forgets the outbox (D5); restore not verifying
the checksum (D6); restore trusting a corrupted track (D7); a stored receipt
marked as a replay (D8); conflicting content replayed instead of refused (D9); a
repeated seq treated as the next new batch (D10); tracks stored out of creation
order (D11); a restored tracker restarting its ID counter (D12); and the
validation/adapter/CLI family (E1–E20) covering unknown config keys, booleans as
integers, appearance sums, duplicate detection IDs, `max_detections`, an
off-by-one `max_tracks` bound, boxes leaving the frame by less than a millionth,
unenforced config upper bounds, millisecond truncation, the millisecond product
overflowing, the adapter's `reset` policy, silent truncation past 500 episodes,
`max_gap_s` in milliseconds, a non-whole-hour `hour_start`, inspecting an
unscored frame's blobs, a 300 000 ms episode, unknown CLI ops, duplicate JSON
keys, a failed init destroying the previous tracker, and a CLI that exits 0 after
an error response.

Two of those defects were found by this harness while it was being written and
then fixed in the implementation itself, not only in the tests: unknown
configuration keys were being ignored (`resolve_config` walked the specification
but never the supplied mapping), and a finite `t_s` of 1e308 overflowed the
`1000*t_s` product to infinity, where `math.floor` raises `OverflowError` instead
of refusing. Both are now refused with `invalid_config` and `invalid_input`
respectively and both are pinned by a test.

## 5. Resource measurements

Contract section 13's workload, exactly as specified: two independent
default-config trackers in one process, sequentially, each batch generated on
demand, fed, drained and discarded; 100 000 batches × 8 detections and 250
batches × 32 detections; `seq = n`, `t_ms = 200*n`; a snapshot serialised to
canonical UTF-8 JSON at n = 0 and every n divisible by 1000 and then discarded;
`finish` and a final `drain` at each run's end. Input generation, feed, drain,
sampled serialisation, finish and the final drain are all inside the measured
interval.

Protocol: one unscored warmup run, then three fresh measured processes, serially,
each measured externally with `/usr/bin/time -f` as well as internally.

```sh
for i in 0 1 2 3; do      # i=0 is the unscored warmup
  /usr/bin/time -f "wall=%e s maxrss_kib=%M" taskset -c 7 \
    python3 tools/tests/fixtures/temporal_tracks/workload.py --json
done
```

Pinned to a single CPU (`taskset -c 7`), which is the closest this shared host
offers to the contract's "one isolated CPU":

| Run | External wall | External max RSS | Internal measured interval | Additional peak RSS over post-import baseline | Throughput |
|---|---:|---:|---:|---:|---:|
| warmup (unscored) | 7.18 s | 20.9 MiB | 7.152 s | 3.29 MiB | 14 018 batches/s |
| run 1 | 7.28 s | 20.9 MiB | 7.209 s | 3.30 MiB | 13 906 batches/s |
| run 2 | 7.15 s | 20.8 MiB | 7.109 s | 3.30 MiB | 14 102 batches/s |
| run 3 | 7.22 s | 20.9 MiB | 7.145 s | 3.30 MiB | 14 031 batches/s |
| **median of the three** | **7.22 s** | **20.9 MiB** | **7.145 s** | **3.30 MiB** | **14 031 batches/s (113 090 detections/s)** |

Unpinned on the same host at the same time, for comparison: warmup 7.69 s, then
8.41 / 8.09 / 7.85 s (median 8.09 s), additional peak RSS 2.99–3.18 MiB,
11 963–13 238 batches/s.

Against the declared limits: **7.22 s of a 180 s budget (4.0 %)** and
**3.30 MiB of additional peak RSS of a 128 MiB budget (2.6 %)**. External max RSS
(~21 MiB) includes the ~17 MiB interpreter-and-import baseline; the contract
limits the *additional* peak, which is the 3.30 MiB column.

Every invariant the contract says a correct run must show was checked inside the
measured interval and held on all four runs:

```
stream resource-a: 100000 batches, 800000 detections, 800000 assigned
  (536 born, 799464 matched, 0 ambiguous), 536 episodes holding 800000
  observations, closes={'span': 528, 'finish': 8}, 100 snapshots max 43412 B
stream resource-b: 250 batches, 8000 detections, 8000 assigned
  (32 born, 7968 matched, 0 ambiguous), 32 episodes holding 8000 observations,
  closes={'finish': 32}, 1 snapshot max 14698 B
every contract invariant held
```

Aggregate observation accounting balances exactly (accepted detections = summed
episode observations = summed track observations; tracks born = episodes
emitted), no batch of either stream was ambiguous, every sampled snapshot is far
under the 2 MiB cap, and checkpoint equivalence is verified inside the workload:
at batch 500 a snapshot is round-tripped through JSON into a second `Tracker`
which then reproduces 25 further batches' receipts, episodes and canonical states
byte for byte.

Bounded retained state was measured separately at the largest configuration the
contract allows (128 tracks × 128 path samples, 128 retained batch identities ×
128 detections, `max_pending` 1024): the checkpoint reaches 2 638 423 bytes once
its bounds are saturated and then grows by under 2 % over the next 49 batches,
which is the digit-width of the timestamps, not the length of the run.

One measurement caveat: when the workload runs *inside* the test suite (as the
resource section of `tools/tests/labs-temporal-tracks.py` does) the process has
already imported NumPy and OpenCV for the adapter cross-checks, so its peak RSS
is above anything the workload needs and the harness reports "+0.0 MiB
additional". The numbers in the table above come from fresh standalone processes,
which is what the contract describes and what an external evaluator measures.

Caveats, stated plainly: this is a shared host, not an isolated runner. Load
average was 15–22 on 20 CPUs while these numbers were taken, other tenants were
active, and no cgroup, CPU-frequency or cache isolation was applied. `taskset`
pins to one CPU but does not give it exclusively. These are local diagnostic
measurements; the comparative throughput score belongs to the coordinator's
controlled reruns.

## 6. Reproducing

```sh
cd /home/cilex-vision/projects/cilex-watchtower-qwen

# the five required checks
python3 tools/tests/labs-temporal-tracks.py
python3 tools/tests/labs-worker.py
python3 tools/labs/selftest_shape_observations.py
python3 tools/labs/selftest_object_profile.py
git diff --check

# contract section 13's workload, with its invariant checks and measurements
python3 tools/tests/fixtures/temporal_tracks/workload.py            # full
python3 tools/tests/fixtures/temporal_tracks/workload.py --json     # machine-readable
python3 tools/tests/fixtures/temporal_tracks/workload.py --batches-a 2000 --batches-b 60

# the suite without the 100k-batch workload (about 4 s instead of 13 s)
WT_SHORT=1 python3 tools/tests/labs-temporal-tracks.py

# mutation check: plant defects in a throwaway copy, require the suite to fail
python3 tools/tests/fixtures/temporal_tracks/mutation_check.py --list
python3 tools/tests/fixtures/temporal_tracks/mutation_check.py

# the CLI by hand
printf '%s\n' \
  '{"op":"init","camera_id":"cam-a","unit_id":"unit-a"}' \
  '{"op":"feed","batch":{"camera_id":"cam-a","unit_id":"unit-a","seq":0,"t_ms":0,"detections":[{"id":"d0","bbox":[0.1,0.2,0.1,0.2]}]}}' \
  '{"op":"finish"}' '{"op":"drain"}' \
  | python3 tools/labs/replay_temporal_tracks.py; echo "exit=$?"
```

## 7. Limitations and known gaps

* **Worst-case component cost.** The ambiguity test is K+1 solves, as the
  contract suggests. On a *fully dense* 128-track × 128-detection component whose
  best matching is unambiguous — every one of the 16 384 pairs feasible, so all
  129 solves run to completion — one batch measured 8.9 s. Realistic geometry
  (gates of 0.15–0.35 over a unit frame) produces small components: section 13's
  stream B, whose 0.125 column spacing is inside its 0.17 gate, solves four
  banded 8×8 components per batch and the whole workload finishes in ~7 s. A
  min-cost alternating-cycle formulation would cut the worst case by roughly a
  factor of K, but it needs a residual-graph argument the simple re-solve does
  not, and correctness in the two highest-weighted scoring families was worth
  more than a corner-case constant.
* **No NumPy or OpenCV in the engine.** The contract permits NumPy in the core;
  it was deliberately not used, because at these per-batch sizes (≤128×128, and
  typically ≤8) array construction costs more than the arithmetic it would
  vectorise, and a standard-library-only core imports in ~20 ms warm (importing
  `numpy` and `cv2` into the same interpreter costs 90–360 ms here) and runs
  anywhere the worker runs.
* **Interpretation choices where the contract is silent**, each pinned by a test:
  error precedence (`finished` → structure → scope → sequence/replay);
  earliest-wins on an equal-area box tie (fixed by the published case); strict
  `int` for integer-typed fields, so `t_ms: 1000.0` is `invalid_input` while
  `bbox: [0, 0, 1, 1]` is fine; `-0.0` normalised to `0.0` so that equal
  measurements serialise equally; a merge tested per detection against the tracks
  feasible *for that detection* ("adjacent feasible tracks").
* **State schema is version 1 and implementation-defined.** It is stable across
  processes and Python runs, and `restore` refuses anything else, but it is not a
  published interchange format and a later version may not read it.
* **Linux only, by observation rather than by claim.** The code is pure standard
  library and the repo's other boxes are Windows and macOS, but no runtime check
  was performed on either, and none is claimed. `resource.getrusage` reporting in
  the workload harness handles the macOS `ru_maxrss` unit difference, untested
  there.
* **The adapter is offline and unregistered.** `mask_frame_batch` and `labs_rows`
  are pure functions for an explicit caller. Nothing here places a pre-roll,
  chooses a time origin, stitches across runs the way B6 does, or submits
  anything; `labs_rows` is a preview and says so in its docstring.
* **Single-threaded by contract.** A `Tracker` is not synchronised; concurrent
  `feed` from several threads is out of scope and untested.
* **Test-suite runtime.** The full suite takes ~13 s, of which ~8 s is the
  section-13 workload; `WT_SHORT=1` skips that and the CLI fixture replay. The
  repository's `pre-commit` hook does not run this suite (it is not in the hook's
  gate list, and adding it would mean editing a hook, which the prompt forbids),
  so it must be run explicitly.
