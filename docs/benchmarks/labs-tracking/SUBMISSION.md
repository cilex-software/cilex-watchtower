# Labs temporal tracking — submission (original stage)

Challenge `labs-temporal-tracking-v1`. This is the ORIGINAL-STAGE record. It is
preserved unchanged by the later product-integration stage, whose record lives
in `STAGE2_SUBMISSION.md`.

- Start commit: `f442cb5b7092406d3f026d54d8791d5afaec4586`
  (tree `a6d8eec8665ec9f291e91b465887f0b519e69bd6`), branch
  `benchmark/deepseek-labs-tracking`, checkout
  `/home/cilex-vision/projects/cilex-watchtower-deepseek`.
- The implementation commit is identified in the final response, not here: this
  file is committed BY that commit, so it cannot contain its own hash.
- Contract: `docs/benchmarks/labs-tracking/CONTRACT.md` (unchanged, SHA-256
  `a9502e7f44c65f748ecdbc69212653ab83f809f8ca8d3d6671dd88346512a66e`).
  Public cases read from `fixtures/cases.json` (unchanged, SHA-256
  `78b9e64c3f02224f6922b43bdb34eb24b4de9b93e39c9c24f899ffabf7dd0ced`).
- All 32 files listed in `setup-manifest.json` (`public_package_sha256` and
  `protected_labs_source_sha256`) were re-hashed after development: 32 checked,
  0 mismatches. No vendored analyser, existing test, hook, plugin registry or
  benchmark file was modified.

## 1. What was delivered

| File | Role |
| --- | --- |
| `tools/labs/temporal_tracks.py` | The engine: `TrackingError`, `Tracker` (`feed`/`drain`/`finish`/`snapshot`/`restore`), config resolution, matching, episodes, snapshot validation. Standard library + `math`/`json`/`hashlib` only. |
| `tools/labs/temporal_tracks_adapter.py` | `mask_frame_batch()` (existing `MaskFrame`/`Blob` → contract batch, duck typed, no pixels) and `labs_rows()` (offline Labs wire PREVIEW). Imports without OpenCV. |
| `tools/labs/replay_temporal_tracks.py` | The contract's JSONL CLI: one response per nonblank line, exit 1 after any error response. |
| `tools/tests/labs-temporal-tracks.py` | 316 executable checks; nonzero exit on failure. |
| `tools/tests/fixtures/temporal_tracks/workload_measure.py` | The declared section-13 workload as a measured process (time, RSS, snapshot sizes, accounting). |

No analyzer was registered, no worker/plugin default changed, no API payload of
an existing analyzer was touched, and nothing in `tools/labs/labs_*.py` was
modified. The adapter runs only when a caller imports it.

## 2. Design decisions (and why)

**Plan, then commit.** `feed()` validates the batch, plans every closure,
solves association, and checks both capacities *before* writing a field. The
public case `bounded-replay-conflict-and-atomic-capacity` pins the consequence:
after a rejected `capacity` batch the snapshot is byte-identical, the clock has
not moved, the replay window is unchanged, and the next born track still gets
the ID the rejection did not consume.

**Association is min-cost maximum-cardinality matching, per component.** The
feasible bipartite graph is split into connected components; each is solved
with successive shortest augmenting paths (min-cost max-flow), which yields
maximum cardinality first and minimum cost among those. Greedy
nearest-neighbour loses a whole track on the public
`maximum-cardinality-before-nearest-edge` case. A component is reported
`ambiguous` when (a) any detection box encloses the predicted centres of two
feasible tracks (`merge`, which takes precedence), or (b) some different
matching of the SAME cardinality costs no more than the best matching plus
`ambiguity_margin` (`cost_tie`). (b) is tested by forbidding each selected edge
in turn and re-solving — complete, because a different matching of equal size
must omit at least one edge the chosen one uses — never by permutation
enumeration.

*Correctness evidence:* 400 random bipartite graphs (0–4 tracks, 0–4
detections, random edges and costs) were compared exhaustively against brute
force for (i) the maximum cardinality, (ii) the minimum cost at that
cardinality, (iii) the returned pairs being a real matching, and (iv) the
ambiguity decision at margins 0, 1000 and 100000. Zero disagreements.

**Evidence is counted from every observation; only the path is bounded.** The
bounded path uses the contract's prescribed ONLINE simplifier: on overflow,
drop the interior sample whose two adjacent spatial segments have the smallest
absolute cross product, earliest timestamp winning an exact tie, and never drop
the first or latest sample. Cross products are maintained incrementally (one
append, at most one removal, two recomputed neighbours), and a restore
recomputes them from the path. A dedicated test drives a saturating wandering
trajectory through `path_points` 3/4/8, checkpoints it mid-run, resumes, and
requires identical receipts, snapshots and episodes — so the incremental and
recomputed forms provably agree.

**Replay is a bounded identity, not a log.** Only the latest `replay_batches`
accepted NEW batches keep their normalised identity and original receipt. The
identity folds away detection permutation, omitted-optional defaults and
`0`/`0.0` spellings; `reset` is content. Within the window, an equivalent
re-submission returns the stored receipt with `replayed=true` and changes
nothing — no association, no IDs, no requeueing, no clock movement (verified:
`drain()` after a replay of a closing batch returns `[]`). Beyond it, a seq at
or below the high-water mark is `stale_replay`; there is no rewind.

**Snapshots are validated, not trusted.** The envelope carries exactly
`schema`, `state` and `sha256`, where the digest is the contract's canonical
serialisation of `state`. `restore()` re-checks the whole state — configuration
(and that it is a *resolved* configuration), scope, clock/counter consistency,
track paths and centres, episode shape, outbox bounds, replay window ordering
and the high-water mark — because a checksum recomputed over an invalid state
does not make it valid. 21 mutation/garble cases are in the suite, including
leaf mutations with the checksum recomputed.

**Aliasing.** `drain()` and `snapshot()` return deep copies of episodes: an
early draft shared the inner `path`/`bbox` lists, and the aliasing test caught
it (mutating a drained episode changed a previously taken snapshot's checksum).
Receipts, configuration and validated state are copies too.

**Two orderings the contract leaves open** (recorded, since a reviewer may
reasonably have chosen otherwise): structural batch validation (`invalid_input`)
is reported before the seal; the seal (`finished`) before a scope mismatch; and
a scope mismatch before replay/window handling. Rationale: a malformed request
is a property of the request; a sealed tracker cannot accept anything; a
wrong-scope batch is not this tracker's replay.

## 3. Commands and actual results

All commands run offline in this checkout, Python 3.12.3 with NumPy 2.4.4,
`opencv-python` 4.13.0.92, psutil 7.2.2, `en_US.UTF-8`, TZ MSK (UTC+3), on a
shared 20-core Linux host.

```sh
python3 tools/tests/labs-temporal-tracks.py                 # 316 PASS, 0 FAIL (2.8 s)
python3 tools/tests/labs-temporal-tracks.py --full-workload  # 316 PASS, 0 FAIL (12.9 s)
python3 tools/tests/labs-worker.py                          # 436 PASS, "all passed"
python3 tools/labs/selftest_shape_observations.py           # 79/79 checks passed
python3 tools/labs/selftest_object_profile.py               # 40/40 checks passed
git diff --check                                            # clean
```

Suite composition: 109 checks replay every operation of the eight public cases
through real CLI subprocesses (results, `result_subset`, error objects,
captures, `snapshot_from`, `expect_result_equal`, and each `on` stream's exit
status), 15 cover the public adapter examples and the Labs wire preview, and
the remaining 192 are the contract's own cases: validation and ordering,
association quality (prediction, coasting, speed cap, inclusive gates), time
boundaries (gap/span/reset, empty batches), episode evidence and path
bounding, replay/atomicity, aliasing, checkpoints and corruption, CLI protocol,
matching exactness, path-simplifier checkpoint equivalence, and the workload.

## 4. Performance measurements

The declared workload (contract section 13): both streams in ONE process,
sequentially, batches generated on demand, output drained and discarded,
snapshots serialised and discarded at n=0 and each n divisible by 1000,
input generation and feed inside the measured interval. Harness:
`tools/tests/fixtures/temporal_tracks/workload_measure.py`.

| Run | Stream 1 (100000×8) | Stream 2 (250×32) | Total | Added peak RSS | Max snapshot |
| --- | ---: | ---: | ---: | ---: | ---: |
| warmup (unscored) | 9.92 s | 0.57 s | 10.49 s | — | 53118 B |
| 1 | 9.70 s | 0.63 s | 10.33 s | 3.5 MiB | 53118 B |
| 2 | 11.02 s | 0.57 s | 11.59 s | 3.2 MiB | 53118 B |
| 3 | 10.41 s | 0.90 s | 11.31 s | 3.2 MiB | 53118 B |

Contract limits are 180 s for both streams together and ≤128 MiB of added peak
RSS; measured worst case is 11.59 s and 3.5 MiB. Accounting was verified
inside the runs: 800000 detections assigned in stream 1 and 8000 in stream 2,
every one exactly once, no ambiguity, 536 births in stream 1 (8 initial plus
528 reborn after `span` closures) and 32 in stream 2, and the drained episodes
sum to exactly the accepted observation count.

**Caveat, stated plainly:** this host is shared (load average 13.5–16.8 on 20
cores while measuring) and no CPU isolation was applied. These are diagnostic
local numbers, not a controlled comparative score; the contract's own 180 s /
128 MiB figures are declared limits, not measurements of this implementation.

## 5. Development conditions and model

Recorded before development, from the operator's launch configuration and the
host, not inferred from a label:

- Harness: DeepSeek Harness (`@deepseek-ai/dsh`) 0.2.0-rc.2 on Node v24.18.0.
- Provider/model/reasoning read from the active profile patch layer
  (`~/.dsh/profiles/web/cordis.patch.yml`, entry `agent-default-model`):
  provider `deepseek-official`, model `deepseek-flash`, `reasoningEffort: max`.
- UNVERIFIED from inside the session: the provider's underlying immutable model
  snapshot ID, its server-side maximum context/output limits, and whether any
  provider-side automatic fallback is configured. No fallback was requested or
  used; no subagents were used for this work, so the ≥2-subagent allowance was
  simply not exercised.
- No network access was used except normal authenticated Git operations; no
  camera, station, production API/database, Docker socket, Warden or live Labs
  worker was contacted.

**Briefing chronology (recorded as the entry document requires):** this
participant received BOTH stages at launch (2026-10-04), while the historical
Kimi/Qwen participants received the integration follow-up later. Stage results
must therefore be compared separately; no identical briefing chronology,
enforced common clock or pre-frozen controlled trial is claimed.

## 6. Limitations and unverified items

- The resource numbers above are shared-host diagnostics (section 4).
- The throughput points in EVALUATION.md depend on a coordinator-side isolated
  runner and a frozen evaluator; nothing here is a comparative score, and no
  claim is made about another participant.
- `labs_rows()` is an offline wire PREVIEW and validates against the row/metric
  caps mirrored from `tools/labs/worker.py` (500 rows/unit, 300 s group span,
  24 metric keys). It never submits, and it was not exercised against a live
  server; the live worker path is unchanged and was not used.
- `mask_frame_batch()` was tested against the real `labs_foreground_mask.Blob`
  and a lightweight frame object, plus malformed-input cases. It was NOT run
  over decoded footage in this stage: the adapter is offline-only by contract,
  and stage-1 scope forbids launching the product.
- No Windows runtime behaviour was claimed or tested from this Linux host.
- Snapshot state is implementation-defined; the validator's field set is ours,
  so an evaluator's mutation of an *internal* field to another in-range value
  can yield a different (but still valid) state rather than
  `invalid_snapshot`. Envelope, type, finiteness, bounds, scope, clock/counter
  and cross-field consistency are all enforced.

## 7. Scope compliance

New files only (see section 1) plus this report. The only existing files this
commit changes are the four version-metadata files the repository's own
pre-commit hook bumps (`CMakeLists.txt`, `packaging/windows/watchtower.rc`,
`packaging/windows/installer.nsi`, `packaging/windows/app.manifest`); they were
not edited by hand and the hook was not bypassed. Documentation of the run
`tools/tests/fixtures/temporal_tracks/workload_measure.py` is a helper under
the path the assignment allows for extra test helpers.
