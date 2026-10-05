# Submission — labs-temporal-tracking-v1 (Kimi)

Branch: `benchmark/kimi-labs-tracking`.
Starting setup commit (HEAD at launch): `f442cb5b7092406d3f026d54d8791d5afaec4586`
(`docs(benchmark): authorize autonomous implementation and publication`; the README's
pinned source base is `5c628372c7b650591aa20e2b1bd774e825106007`).
The final implementation commit is named in the closing agent response, per the
prompt's rule that it cannot be named inside the commit that creates it.

## Deliverables

- `tools/labs/temporal_tracks.py` — the engine: `TrackingError(ValueError)` with a
  public `code`, and `Tracker` with `feed`/`drain`/`finish`/`snapshot`/`restore`.
- `tools/labs/temporal_tracks_adapter.py` — pure `mask_frame_batch(...)` and
  `labs_rows(...)`; imports only the engine, never OpenCV or image data.
- `tools/labs/replay_temporal_tracks.py` — the section-11 JSONL CLI on stdin/stdout.
- `tools/tests/labs-temporal-tracks.py` — 351 checks; exit 1 on any failure.
  `--workload` runs the measured section-13 workload.

No existing file was modified; the only version-metadata changes in the commit are
the four files the repository's pre-commit hook rewrites itself.

## Design decisions

- **State IS the snapshot.** All mutable state lives in JSON-native dicts/lists that
  are exactly the checkpoint document: `snapshot()` deep-copies the live structures
  and hashes their canonical JSON (`sort_keys`, `separators=(",", ":")`,
  `ensure_ascii`, `allow_nan=False`); `restore()` validates and rebuilds from the
  same shape. With no second representation, a restored tracker cannot drift from an
  uninterrupted one — the test suite proves it by running restored twins in lockstep
  against uninterrupted runs (20 seeded fuzz trials plus the published checkpoint
  case), comparing every receipt, drain and snapshot for exact JSON equality.
- **Functional-then-commit atomicity.** `feed()` validates the batch completely,
  computes closures/association/ambiguity/births into locals, checks BOTH capacities
  (`max_tracks`, `max_pending`), and only then mutates. A rejected operation provably
  leaves the snapshot bit-identical (asserted in the suite for every rejection class,
  matching the published atomic-capacity case).
- **Matching is global, never greedy.** Feasible edges (inclusive distance gate
  `d <= gate_base + gate_speed*dt`, inclusive area-ratio and appearance gates,
  integer cost `floor(1e6*(d/g + appearance_weight*a) + 0.5)`) form connected
  components; each component is solved by min-cost max-flow (successive shortest
  augmenting paths, Dijkstra with Johnson potentials; costs are non-negative so zero
  potentials are a valid start). Ambiguity re-solves with each selected edge
  forbidden in turn: a different size-K matching omits at least one selected edge, so
  this is sound and complete for "any different size-K matching within the margin",
  with no permutation enumeration. A matching tie-break is unobservable by
  construction: any equal-cost alternative triggers abstention at any margin >= 0.
- **Ambiguity precedence.** The merge rule (a detection box containing the predicted
  centers of two tracks it has a feasible edge to, boundaries inclusive) is evaluated
  before the cost-tie rule, so `merge` wins the reason, as published. "Adjacent
  feasible tracks" is read as graph-adjacent: tracks with a feasible edge to that
  detection; a track whose edge was area-gated out does not count (pinned by a test).
- **Prediction.** Velocity is the capped displacement of the last two accepted
  observations, recomputed on each accepted assignment only; prediction starts from
  the last center over the actual elapsed seconds and is never clipped to the image.
- **Replay.** The retained window holds, per accepted NEW batch, the canonical input
  identity (JSON of the normalized batch: detections sorted by id, omitted defaults
  materialized, all measurements coerced to float so `0` and `0.0` coincide) and the
  original receipt with `replayed=false`. A same-identity retry returns a fresh copy
  with `replayed=true` and describes the original closures even after a drain;
  a mismatch raises `replay_conflict`; below the window, `stale_replay`. Restore
  requires the window to be exactly the latest `replay_batches` seqs.
- **Bounded evidence.** Per-track accumulators (observations, path_length, largest
  box with earliest tie win, max gap) update from every accepted observation; the
  path applies the prescribed online rule (drop the interior sample with the smallest
  absolute 2D cross product, earliest timestamp wins a tie, first/last never drop).
- **CLI.** One in-memory tracker per process; init/restore replace it only after the
  new one validates; response envelopes are exactly `{"ok":true,"result":...}` /
  `{"ok":false,"error":{"code":...}}`; duplicate keys, NaN/Infinity tokens, bad JSON
  and malformed commands are `invalid_input`; uninitialized commands are
  `not_initialized`; later lines still run after errors; exit 1 iff any line failed;
  EOF neither finishes nor drains. stdout is byte-identical across PYTHONHASHSEED
  0/1/42 (tested).
- **Adapter.** `mask_frame_batch` duck-types the MaskFrame (`t_s`, `run`, `scored`,
  `blobs`), reads no pixels, rounds `t_ms=floor(1000*t_s+0.5)`, sets `reset` exactly
  when `previous_run` is not null and differs from `frame.run`, maps scored blobs to
  `{"id": "b"+str(label), "bbox": list(...)}` sorted by label, and never touches
  `blobs` of an unscored frame (tested with a blob container that raises on access).
  `labs_rows` materializes and validates every episode against contract section 8
  before returning anything, enforces <=500 rows, `start_ms` in the hour and
  span < 300 s, and emits exactly the ObservationIn row shape with exactly the eight
  metric keys (`max_gap_s` is integral-typed when whole, matching the fixture).

## Environment and development conditions

Measured on this checkout: Python 3.12.3, NumPy 2.4.4, OpenCV 4.13.0
(`cv2.__version__`; the manifest's 4.13.0.92 is the same wheel), Linux
7.0.0-31-generic x86_64 (Ubuntu 24.04, glibc 2.39), 13th Gen Intel i5-13500, 20
logical CPUs, timezone MSK (UTC+3), locale en_US.UTF-8, Kimi Code CLI 2.1.1.
Everything ran offline except the final authenticated git push. No subagents were
used; no other participant's branch, worktree or results were read. Development ran
autonomously across two sessions (interrupted once by a provider quota pause), over
2026-10-04/05; all numbers below are per-command measurements, not a continuous
clock. Git route: normal authenticated non-force push to `origin`
(`https://github.com/romayankin/cilex-watchtower.git`), ref
`refs/heads/benchmark/kimi-labs-tracking` only; `core.hooksPath tools/git-hooks` was
active, so the commit carries the hook's patch-version bump and gate results.

HOST-LOAD CAVEAT for every timing here: the host is shared and was busy while these
ran (load average 14-18 observed). Wall times below are diagnostic only; the
contract's 180 s / 128 MiB comparison belongs to the coordinator's isolated runner.

## Validation — commands and actual results

All run from the checkout root on this branch:

- `python3 tools/tests/labs-temporal-tracks.py` → **351 PASS, 0 FAIL, exit 0**
  (~8 s). Covers: all 8 published public cases driven through the real CLI as
  subprocesses with per-environment exit codes and capture/snapshot semantics;
  the published `cost_checks` re-derived from the contract formula (incl. the
  brute-forced cardinality/best/alternative costs); both published adapter examples
  with a real `labs_foreground_mask.Blob`; config/batch validation batteries with
  snapshot-intact atomicity after every rejection; sequence/replay/stale rules;
  inclusive gate boundaries on dyadic-exact geometry (distance, area ratio,
  appearance); constant-velocity prediction and the max_speed cap (each shown
  load-bearing by counterfactual geometry); cost-tie abstention and recovery,
  merge precedence, the ambiguity margin made inclusive at C+margin on a constructed
  2x2; a 300-scenario seeded property test against an independent brute-force
  reference (all matchings enumerated, contract ambiguity rules applied);
  gap/span/reset precedence and strictness; capacity atomicity for tracks and
  outbox incl. drain-then-retry and a non-sealing failed finish; episode evidence
  arithmetic; the path simplifier's tie and cross rules; aliasing of inputs,
  receipts, snapshots and configs; checkpoint equivalence through JSON round trips
  and restore chains; a corruption battery of schema/checksum/state mutations with
  recomputed checksums; CLI protocol edges (bad JSON, duplicate keys, NaN/Infinity,
  non-UTF-8 bytes, malformed commands, not_initialized, failed-replacement
  preservation, exit codes, EOF semantics, cross-process restore);
  cross-hash-seed byte-identical CLI output; a 3000-batch bounded streaming slice
  with accounting and snapshot-size invariants; and the full run-2 shape.
- `python3 tools/tests/labs-temporal-tracks.py --workload` → one unscored warmup,
  then three measured runs, serial. Each run feeds 100000x8 + 250x32 detections to
  two independent default-config trackers with per-batch drain and the sampled
  snapshot serialization. Per-run stats were identical across all three runs
  (deterministic): resource-a 800000 observations (536 born / 799464 matched),
  536 episodes; resource-b 8000 observations (32 born), 32 episodes; zero ambiguous
  assignments; aggregate observation accounting exact; largest sampled snapshot
  55889 bytes (bound: 2097152). Wall/CPU per run: **17.59/17.57 s, 17.03/17.02 s,
  16.44/16.44 s — median wall 17.03 s** (declared limit 180 s). Peak RSS delta above
  the post-import baseline (ru_maxrss, self): **1.1 MiB** per run (declared limit
  128 MiB). Diagnostic only, see host-load caveat.
- `python3 tools/tests/labs-worker.py` → **436 PASS, 0 FAIL, exit 0**, one expected
  SKIP (`winqos real calls -- this box is not Windows`), vendored analyser hash pins
  all verified. Run three times: pass, then one failure, then pass — see
  Limitations for the flaky check and its evidence.
- `python3 tools/labs/selftest_shape_observations.py` → **79/79 checks passed, exit 0**.
- `python3 tools/labs/selftest_object_profile.py` → **40/40 checks passed, exit 0**.
- `git diff --check` → clean; after staging, `git diff --cached --check` → clean.
- Mutation self-check (not a deliverable, a test-quality measurement): nine defects
  planted one at a time into a scratch copy — greedy matching, exclusive margin,
  merge needing 3 tracks, inclusive gap, span-before-gap, replay flag not set,
  oversized replay window, NaN bbox accepted, adapter reset inverted — and the suite
  failed every one (exit 1 each, first FAIL lines name the defect's behaviour).

## Limitations and honest caveats

- **Timings are shared-host diagnostics.** The 17.03 s median was measured while the
  host carried unrelated load (load average 14-18); an isolated CPU may differ in
  either direction. The 2 MiB snapshot bound and the accounting invariants held on
  every run, which are load-independent.
- **Worker-suite flake observed once, not caused by this change.** One of three runs
  of the untouched `tools/tests/labs-worker.py` failed exactly one check:
  `unit process: no unit leaves its temporary directory behind`, which asserts the
  set of `wt-labs-unit-*` directories in the SHARED system `/tmp` is unchanged. While
  diagnosing, a foreign `wt-labs-unit-*` directory appeared and disappeared within
  seconds (another suite instance runs on this host), and a week-old leftover
  (`/tmp/wt-labs-unit-_vzcjeck`, 2026-09-29) predates this task. The check is a
  cross-process race on a shared temp dir under concurrent suites; two immediate
  re-runs passed (436 PASS, exit 0). The test was not touched and no behaviour was
  weakened; the evaluator should run suites with private TMPDIRs.
- **Ambiguity re-solve cost.** The per-edge forbidding loop runs the flow solver up
  to K+1 times per component per batch. That is cheap for every published and
  workload component (they are tiny), and polynomial, but a fully-connected
  128x128 component in pure Python would be slow; the declared workload cannot build
  one and no capacity bound was validated for that adversarial case.
- **Snapshot layout is implementation-defined** as the contract allows; restore
  enforces the public envelope plus this layout's own invariants (counter consistency,
  exact replay-window membership, path anchoring, per-track path-length invariant).
- **Interpretation recorded:** in the merge rule, "adjacent feasible tracks" was read
  as tracks with a feasible edge to that detection. The published merge case passes
  under this reading; a wider reading (any two tracks in the component) was not
  implemented.
- **`labs_rows` is a preview only** — nothing in this submission submits, truncates
  or merges, and the adapter is never registered with `run_worker.py`.
- No Windows runtime check was run or claimed; the engine and CLI are pure stdlib
  Python and the adapter imports nothing beyond the engine, but per instructions no
  cross-platform claim is made from this Linux box.
