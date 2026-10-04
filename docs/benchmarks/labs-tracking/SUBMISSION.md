# Labs Temporal Tracking Benchmark — Stage 1 Submission Report

## Metadata

- **Participant**: Gemini
- **Checkout**: `/home/cilex-vision/projects/cilex-watchtower-gemini`
- **Assigned Branch**: `benchmark/gemini-labs-tracking`
- **Starting Setup Commit**: `f442cb5b7092406d3f026d54d8791d5afaec4586`
- **Model**: Gemini 3.8 Flash (High reasoning)
- **Local Date & Time**: 2026-10-05T00:48:00+03:00
- **Environment**:
  - Linux dev box (Ubuntu 24.04 LTS x86_64, kernel 6.8.0)
  - Python: 3.12.3 (GCC 13.3.0)
  - NumPy: 2.4.4
  - OpenCV: 4.13.0
  - psutil: 7.2.2

## Implemented Deliverables

1. `tools/labs/temporal_tracks.py`:
   - `TrackingError(ValueError)` with public string attribute `code`.
   - `Tracker` class implementing:
     - `__init__(camera_id, unit_id, config)`
     - `feed(batch)`
     - `drain()`
     - `finish()`
     - `snapshot()`
     - `restore(checkpoint)` (classmethod)
   - Normative configuration validation, bounding and type enforcement.
   - Deterministic bipartite matching using successive shortest augmenting paths with node potentials to achieve global maximum cardinality $K$ and minimum integer cost $C$.
   - Explicit ambiguity detection: forbidding each matched edge in turn to check for alternative size-$K$ matchings within `ambiguity_margin`.
   - Merge detection: evaluating detection box containment of $\ge 2$ adjacent feasible track predicted centers (inclusive of box boundaries) with priority over cost tie.
   - Bounded path simplification using online 2D cross product area minimization with earliest-timestamp tie-breaking.
   - Atomic state transitions: pre-validating track capacity and pending outbox capacity before committing changes.
   - Canonical JSON snapshot serialization and SHA-256 verification, with deep validation of state invariants upon restore.
   - Bounded replay window preserving receipts and detecting conflicts or stale requests.

2. `tools/labs/temporal_tracks_adapter.py`:
   - `mask_frame_batch(frame, *, camera_id, unit_id, seq, previous_run=None)`:
     - Duck-typed extraction from `MaskFrame` / `Blob` without importing OpenCV or reading pixel buffers.
     - Accurate rounding of `t_s` to `t_ms` (`floor(1000 * t_s + 0.5)`).
     - Distinct blob label validation and `b{label}` detection generation.
     - Reset determination based on `run != previous_run`.
   - `labs_rows(episodes, *, hour_start)`:
     - Strict aware UTC datetime validation aligned to top-of-hour.
     - Validation of episode limits (<= 500) and duration constraints (< 300 s).
     - Exact mapping to `ObservationIn` wire format and metrics keys, passing `check_metrics` requirements.

3. `tools/labs/replay_temporal_tracks.py`:
   - Standalone CLI reading UTF-8 JSONL from stdin and writing JSON responses to stdout.
   - Rejection of duplicate JSON keys and non-finite numeric constants (`NaN`, `Infinity`).
   - Atomic operation execution, preserving prior in-memory tracker state on failed `init` or `restore`.
   - Strict exit code semantics: exit 0 on clean stream, exit 1 on any error response.

4. `tools/tests/labs-temporal-tracks.py`:
   - Comprehensive test suite covering public cases, adapter examples, contract edge cases, rubric mutation families, and Section 13 resource workloads.

## Verification Results

### 1. Benchmark Suite (`python3 tools/tests/labs-temporal-tracks.py`)
- **Public Cases**: 8/8 passed in both Python API and CLI JSONL protocol:
  - `one-object-unique-and-bounded-path`: PASS
  - `maximum-cardinality-before-nearest-edge`: PASS
  - `distinguishable-crossing`: PASS
  - `explicit-cost-tie-and-recovery`: PASS
  - `possible-merge-takes-precedence`: PASS
  - `strict-gap-span-and-reset-boundaries`: PASS
  - `bounded-replay-conflict-and-atomic-capacity`: PASS
  - `checkpoint-undrained-outbox-and-exact-continuation`: PASS
- **Adapter Examples**: 2/2 passed:
  - `pixel-blob-normalization-and-run-reset`: PASS
  - `labs-wire-preview`: PASS
- **Contract Edge Cases**:
  - Configuration boundary and type rejections: PASS
  - Scope mismatch and sequence error handling: PASS
  - Detection geometry, appearance and duplicate ID checks: PASS
  - Snapshot corruption, SHA mismatch, and state invariant checks: PASS
- **Targeted Rubric & Mutation Families**:
  - Association: Non-greedy maximum cardinality preference: PASS
  - Ambiguity: Merge rule containment on exact boundary: PASS
  - Time: Strict gap boundary (`>`) and `end_ms` evidence preservation: PASS
  - Replay: Detection permutation equivalence: PASS
  - CLI: Duplicate keys rejection and exit code verification: PASS
- **Section 13 Fixed Streaming Workload**:
  - Stream 1 (100,000 batches, 8 detections): 0 ambiguities, max snapshot size 52,948 bytes (limit <= 2 MiB).
  - Stream 2 (250 batches, 32 detections): 0 ambiguities, max snapshot size 17,853 bytes (limit <= 2 MiB).
  - Total elapsed time: 18.15 seconds (limit <= 180 seconds).
  - Peak additional RSS: < 0 MiB net change (limit <= 128 MiB).

### 2. Regression & Self-Tests
- `python3 tools/tests/labs-worker.py`: 79/79 checks passed.
- `python3 tools/labs/selftest_shape_observations.py`: passed.
- `python3 tools/labs/selftest_object_profile.py`: 40/40 checks passed.
- `git diff --check`: clean (0 whitespace or conflict errors).

## Limitations and Caveats

1. **Shared-Host Performance**: Measured timings are diagnostic on a shared development workstation.
2. **Offline Boundary**: The tracker and adapter are offline components; no live worker registration or production database interactions were performed.
3. **Stage Boundary**: Per instructions, Stage 1 scope restrictions were strictly observed prior to beginning Stage 2 product integration.
