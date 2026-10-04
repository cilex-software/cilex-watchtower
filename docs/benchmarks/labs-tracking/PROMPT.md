# Labs temporal tracking benchmark — identical participant prompt

You are implementing the same task, from the same starting commit, as another
coding agent. Work independently on the benchmark branch already checked out.
Do not inspect another participant's branch, worktree, logs, implementation or
results. Your model/provider identity does not change this assignment.

## Goal

Implement a deterministic, resumable, streaming temporal tracking and evidence
engine for Cilex Watchtower Labs. It consumes timestamped batches of foreground
detections and produces stable tracks and passage records. It must handle
multiple objects, crossings, short occlusions, unresolved associations, recording
discontinuities, checkpoint/resume and bounded retained state.

The result is a tracking foundation for later recognition. It must not infer
person, vehicle, child, clothing, dog or cyclist classes from geometric shapes.
No trained model, model download, new detector or image-decoding pipeline is part
of this task. Detections and optional appearance descriptors are supplied inputs.

## Read these first

1. `CLAUDE.md` for repository conventions and the live-system context.
2. `docs/benchmarks/labs-tracking/CONTRACT.md` for the normative interfaces and
   behaviour. Hidden tests may vary inputs, not invent additional requirements.
3. `docs/benchmarks/labs-tracking/EVALUATION.md` for scoring, gates and run rules.
4. `docs/benchmarks/labs-tracking/fixtures/README.md` and its public cases.
5. These existing integration seams, reading their actual definitions rather than
   assuming line numbers or old deployment notes are current:
   - `tools/labs/labs_foreground_mask.py`: `Blob`, `MaskFrame`.
   - `tools/labs/labs_track_linking.py`: `Linker`, `Episode`, `to_observations`.
   - `tools/labs/plugins.py`: `TrackLinkingPlugin`.
   - `tools/labs/worker.py`: observation/metrics validation and hour boundaries.
   - `tools/tests/labs-worker.py`: hermetic worker tests and vendored hash pins.

The existing tracker is vendored. Read it for compatibility; do not edit it.
The current `object_profile` observer sees a dominant blob, so it is not a
substitute for the batched-detection interface required here.

## Deliverables

- `tools/labs/temporal_tracks.py`: the engine/API defined in the contract.
- `tools/labs/temporal_tracks_adapter.py`: explicit offline adaptation from
  existing `MaskFrame` batches and to compatible observation records.
- `tools/labs/replay_temporal_tracks.py`: the contract's offline CLI.
- `tools/tests/labs-temporal-tracks.py`: executable, meaningful tests, with a
  nonzero exit code on failure. Additional test helpers and fixtures may be added
  under `tools/tests/fixtures/temporal_tracks/`; never modify the published
  benchmark cases.
- `docs/benchmarks/labs-tracking/SUBMISSION.md`: design decisions, commands and
  actual results, performance measurements, limitations, and the starting setup
  commit. Identify the final implementation commit in your final response, not
  inside the file committed by that same commit.

Small private helper modules named `tools/labs/temporal_tracks_*.py` are allowed.
Use Python 3.12 and the supplied dependencies. The core may use the standard
library and NumPy; the adapter may use the existing OpenCV dependency. Do not add
runtime packages. Algorithms and code structure are your choices within the
published contract.

## Scope and branch rules

This is an explicitly requested isolated experiment. For this task, these branch
instructions supersede the repository's normal straight-to-main/push workflow:

- Stay on your assigned benchmark branch. Do not merge, rebase onto newer main,
  or fetch other branches.
- The user authorizes normal, non-force pushes to `origin` in
  `romayankin/cilex-watchtower`, only for your assigned branch:
  `benchmark/kimi-labs-tracking` for Kimi or `benchmark/qwen-labs-tracking` for
  Qwen. Confirm the current branch and remote before each push, and name that
  destination ref explicitly. Do not push to `main`, the other participant's
  branch, any other branch, or tags. Do not force-push, delete remote refs, or
  use `--all`/`--mirror`/`--tags`. Do not change branch protection or credentials.
  Use the supplied Git authentication normally without inspecting or exposing
  credential files or token values. Publishing work does not start the run or
  authorize changes after the coordinator has collected a submission.
- Do not read host credentials, histories, private evaluation files or other
  projects. Do not contact cameras, stations, the production API/database, or
  Docker's host socket. Do not start Watchtower, Warden or a live Labs worker.
- Do not alter existing production files, vendored analysers, existing tests,
  hooks, published benchmark files or the default plugin registry. The adapter
  is selected by explicit import/offline CLI use only; it is never registered
  with `run_worker.py` or activated against the server.
- The only existing-file changes allowed are the four version metadata files
  automatically updated by the repository's normal commit hook. Do not manually
  change them or bypass hooks. New implementation/test/submission files above
  are the permitted implementation scope.
- Keep the benchmark's optional adapter independently testable. Do not claim a
  Windows runtime check or deployment from a Linux test or a source inspection.

## Validation and submission

Exercise the supplied public cases, error cases, replay and checkpoint
boundaries, permutations, and a long streaming workload. Also run:

```sh
python3 tools/tests/labs-temporal-tracks.py
python3 tools/tests/labs-worker.py
python3 tools/labs/selftest_shape_observations.py
python3 tools/labs/selftest_object_profile.py
git diff --check
```

Run tests only in the assigned evaluation environment. The existing worker suite
uses temporary state and fake clients; never substitute a live station config.
Document genuine pre-existing failures or platform skips with their evidence.
Do not weaken a test to obtain a pass.

Commit your implementation using the repository hooks, and push it to your own
assigned branch before the submission deadline. Leave a clean working tree and
identify the commit for the coordinator to collect. The final response must list
implemented behaviour, exact validation results, unresolved limitations, the
commit and push result. If a push fails, preserve the local commit and report
the failure; never claim publication without a successful push. Report
incomplete work honestly.

The coordinator, not this prompt's arrival or a commit timestamp, starts and
stops the timed run. There is no permission here to purchase services, install
CLIs globally, deploy anything or change the benchmark rules. If a normative
ambiguity blocks you, ask the coordinator once; any clarification will be sent
identically to both participants and recorded before evaluation.
