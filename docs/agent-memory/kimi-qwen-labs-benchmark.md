# Kimi and Qwen Labs benchmark memory

Saved on 2026-10-04, Europe/Moscow, at the user's explicit request to remember
the preceding explanation, starter prompt, and evaluation commitments. Updated
the same day for the user's explicit authorization of assigned-branch GitHub pushes.
This is coordinator context; both published assignments receive the same rule update.

## User intent and current state

The user wants to choose between Kimi CLI and Qwen CLI as development assistants
for the Labs project, using one complex task with a precisely defined outcome.
They want each vendor's strongest applicable model at its highest supported
reasoning setting and full supported context/output capabilities. Do not reduce
one model's capabilities merely to make its limits match the other.

Both participant checkouts were clean and their seven benchmark-package files
were byte-for-byte identical when checked on 2026-10-04. No coordinator START
signal or scored implementation run has been issued. The task specification and
public examples are prepared; isolated runners and an independent frozen private
evaluator are not yet prepared. Do not describe those as complete.

## Branches and canonical documents

| Participant | Checkout | Branch |
| --- | --- | --- |
| Kimi | `/home/cilex-vision/projects/cilex-watchtower-kimi` | `benchmark/kimi-labs-tracking` |
| Qwen | `/home/cilex-vision/projects/cilex-watchtower-qwen` | `benchmark/qwen-labs-tracking` |

Both branches were originally pushed with the same setup commit:
`2067735ff110ecf61149577091240286c5428174`.
That is the historical setup commit. The current common starting commit is
`8bfc29c9961b85131695c08c02fc00de0d367ec2`: the authorized-push rule update,
published atomically to both branches on 2026-10-04 and applied to both local
checkouts. The prompt, evaluation protocol, README and manifest hashes were
updated together; the tracking contract and public fixtures were not changed.
The source base was `5c628372c7b650591aa20e2b1bd774e825106007`.
These are standalone shallow single-branch clones. They are not isolated runners
merely because they occupy different directories on the same host.

In each participant checkout, the authoritative package is
`docs/benchmarks/labs-tracking/`:

- `PROMPT.md`: the identical assignment and permitted changes.
- `CONTRACT.md`: normative interfaces, behaviour and resource workload.
- `EVALUATION.md`: grading, mandatory gates, fairness and run protocol.
- `fixtures/README.md` and `fixtures/cases.json`: public conformance examples.
- `README.md` and `setup-manifest.json`: setup status and integrity information.

The package contains no tracking implementation. This memory does not override
its contract or introduce hidden requirements. Coordinator memory updates on
main must not move or contaminate either participant's starting branch.

The user now explicitly authorizes each participant to make normal, non-force
GitHub pushes to its own branch in the table above, using the authorized remote.
This supersedes the previous no-push instruction. It does not authorize pushes
to `main`, the other participant's branch, any other branch, or tags; force-pushes,
merging and deployment remain prohibited. The same provider-neutral prompt can
refer to the assigned branch already checked out; it needs no model-specific text.

## Current common preface

Use this identical text for both models. It preserves the shared preface with
the user's later assigned-branch push authorization applied. It intentionally
waits for START so neither begins unrecorded planning before the evaluation
preparation is ready.

```text
You are participating in the Cilex Watchtower Labs development benchmark.

Confirm your current directory, branch and starting commit, then wait for
the coordinator’s START signal. Do not begin planning or implementation
before that signal.

On START, read docs/benchmarks/labs-tracking/PROMPT.md and every document
it requires. Complete the assignment according to its contract and
evaluation rules.

Work independently on your assigned branch. Make routine implementation
decisions yourself. If a genuine specification ambiguity blocks progress,
ask the coordinator once.

Do not inspect the other participant’s work, change protected files,
access live production services, or modify the benchmark rules.

Implement the complete solution, run the required tests, and document
actual results and limitations in
docs/benchmarks/labs-tracking/SUBMISSION.md.

Commit your work using the repository hooks, then make a normal,
non-force GitHub push only to your assigned benchmark branch already
checked out. Do not push main, the other participant’s branch, any other
branch, or tags. Do not force-push, merge or deploy.

Your final response must identify the commit and pushed branch, completed
behaviour, exact test results and any remaining problems.
```

## Plain-language explanation of the task

Build the part of Labs that follows moving objects over time. Imagine the camera
supplies a succession of pictures with boxes around moving shapes. The program
must work out which boxes belong to the same object, keep a consistent tracking
number, and build a record of its journey.

Example: "Object 7 appeared here, moved along this path, briefly disappeared,
reappeared, and eventually left."

The supplied inputs are timestamped detections, with optional appearance
descriptors; implementing image decoding or a detector is outside the task.
The tracker must handle several objects at once, recording interruptions,
repeated input, and saving and restarting its work.

This is a foundation for later recognition. It does not yet identify cars,
people, children, clothing or dogs. Later recognition can attach descriptions
to the tracks; this benchmark cannot substantiate recognition accuracy.

## Why it challenges the models

- Objects cross paths. Choosing the nearest box independently can swap their
  identities; the program must consider competing matches together.
- Sometimes the evidence is insufficient. It must explicitly report uncertainty
  instead of inventing a confident answer or fabricated observations.
- Objects briefly disappear. It must handle short gaps while respecting the
  contract's rules for ending tracks and recording discontinuities.
- Processing can restart or receive repeated data. It must continue consistently
  without counting observations or emitting completed records twice under the
  specified checkpoint/replay model.
- It must run for a long time while retaining a bounded amount of state.
- It must fit the existing project, with compatible interfaces, useful tests
  and reproducible measurements.

This tests algorithm design, careful reading, programming, debugging, testing
and engineering judgment. Confident prose, code volume or claimed test counts
do not establish success.

## Expected result

Each model must deliver a working software component committed and pushed only
to its assigned benchmark branch:

- Tracking engine: `tools/labs/temporal_tracks.py`.
- Offline replay tool: `tools/labs/replay_temporal_tracks.py`.
- Explicitly selected offline Labs adapter: `tools/labs/temporal_tracks_adapter.py`.
- Meaningful tests: `tools/tests/labs-temporal-tracks.py`, plus permitted helpers.
- Design, actual validation results, measurements and limitations in
  `docs/benchmarks/labs-tracking/SUBMISSION.md`.
- Clean implementation commit, whose ID and pushed branch are reported in the
  final response. Report a failed push honestly rather than claiming publication.

We should demonstrate correct tracking numbers where evidence allows them,
correct uncertainty when it does not, and equivalent results after saving and
restarting versus uninterrupted processing. The result is an offline
implementation ready for evaluation; deployment is a separate step.

## Grading commitments

Prepare and freeze independent tests before seeing either implementation.
Hidden cases exercise published requirements without adding surprise rules.
Freeze assertion counts, seeds, test groups, mutation cases and reserve cases.
Publish evaluator and environment hashes without exposing hidden test data.

| What is judged | Points | Published breakdown |
| --- | ---: | --- |
| Correct tracking, crossings and uncertainty | 40 | Global assignments 15; prediction/occlusion 10; ambiguity/merges 10; detection accounting 5 |
| Gaps, restarts, repeated inputs and errors | 20 | Discontinuities/expiry/isolation 7; checkpoint equivalence 7; replay/conflicts/atomic errors 6 |
| Compatibility with Labs and existing behaviour | 15 | MaskFrame mapping 5; observation adapter 5; regressions/defaults/vendor integrity 5 |
| Memory and processing performance | 10 | Bounded state/checkpoints 5; resource workload and throughput 5 |
| Quality of participant tests | 10 | Contract coverage 5; detection of independently planted defects 5 |
| Maintainability and reproducible reporting | 5 | Scoped/readable design 2; interfaces/recovery documentation 1; reproducible measured claims 2 |
| Total | 100 | |

Each fixed subcategory earns its weight multiplied by the fraction of frozen
independent assertions passed. Do not inflate a score by repeating easy cases.
Test-quality evaluation includes deliberately introducing known defects and
checking that participant tests fail on those defects and pass without them.
Speed points require correct output. Performance is measured serially on the
same otherwise idle isolated CPU, with one warmup and three fresh-process runs.

The published resource workload covers 100000 batches with eight detections and
250 batches with 32 detections. Its declared limits are 180 seconds on one
isolated CPU, 128 MiB additional peak RSS and 2097152-byte sampled checkpoints.
These are requirements to validate for feasibility before launch, not measured
results or claims that either model has already met them.

## Fairness and run protocol

Both receive the same task, source, public examples, dependency versions,
environment limits and clarification messages. The effective native CLI,
model/snapshot, maximum supported reasoning, context/output and fallback
settings must be recorded. Automatic fallback to another model is disabled.
This compares native CLI plus model as a development assistant, not bare models.

Runner network rules must permit each model's authorized provider endpoint and
the GitHub remote operations needed to publish its assigned branch. They must
still prevent fetching or reading the competitor's content and accessing live
production services or the private evaluator. GitHub availability does not grant
permission to inspect other branches or publish outside the assigned branch.
The current host's GitHub credentials are not restricted to one benchmark branch;
the rule is an explicit authorization limit, not a verified technical access
restriction. Future runner isolation and Git access controls remain to be prepared
and verified; do not describe the current host credentials as branch-restricted.

The published proposal is eight hours of implementation plus one 60-minute
repair round. It is a proposed common maximum, not an already-started run or
an obligation to spend all eight hours. Freeze the actual allowance and any
spend cap identically before launch. The coordinator controls start and stop;
a prompt arrival or Git timestamp is not the run clock.

Initial and repaired scores must be reported separately, with time, cost,
defects and human assistance. Repair feedback gives each participant its own
reproducible failing cases at the same level of detail, without patches or the
competitor's results. Any specification clarification reaches both verbatim.

The published protocol allows up to two concurrent subagents using the same
participant model. If that restriction cannot be enforced for either CLI,
disable subagents for both and record the decision before launch.

## Mandatory gates and choosing a winner

A high score cannot excuse fabricated observed evidence, duplicate terminal
events under the specified replay model, links across camera or declared
discontinuity boundaries, changes to production defaults, protected-test/vendor
edits, or actions outside the permitted scope. Gate failures need reproducible
evidence or logged actions. Full completion requires every contract conformance
check and release gate to pass.

- Recommend the higher-scoring submission that qualifies for adoption.
- If neither qualifies, report that neither passed; do not invent a winner
  ready for deployment.
- If scores differ by fewer than five points, repeat from fresh identical
  snapshots before recommending a winner.
- Explain strengths, weaknesses, repair effort, cost and time separately.

The conclusion concerns suitability for this Labs work. One task does not
establish universal model superiority.

## Configuration corrections to remember

The user repeatedly requested maximum capabilities. Kimi Plus and QwenCloud
Standard were reported purchased. Do not assume an upgrade or a final effective
Kimi model has been verified; recheck before freezing the run manifest.

Qwen Code 0.24.7 is installed. Local configuration is
`/home/cilex-vision/.qwen/settings.json`; launcher is
`/home/cilex-vision/.local/bin/qwen-labs`. The model is `qwen3.8-max`, using
`https://token-plan.maas.qwencloudapi.com/compatible-mode/v1` and the environment
key name `CILEX_QWEN_TOKEN_PLAN_API_KEY`. Do not put the actual key in memory,
the repository, prompts or chat. The launcher obtains it privately.

Locally configured settings as checked on 2026-10-04:

- Thinking enabled; provider `reasoning_effort` is `xhigh`, the highest Qwen
  tier. `max` is an alias for that tier, not an additional stronger tier.
- Context is 1000000. This manual override is optional: installed Qwen Code
  already selects 1000000 from its built-in model-name lookup. It is local
  capacity bookkeeping, not a server-capacity upgrade. Setting ten million
  would delay compaction beyond real capacity, not enlarge the model.
- `samplingParams.max_completion_tokens` is 131072. The earlier legacy
  `max_tokens: 131072` was corrected because thinking-mode requests can reject it.
  The completion budget includes thinking plus the answer.
- The launcher now also exports `QWEN_CODE_MAX_OUTPUT_TOKENS=131072`; otherwise
  the normal-chat path could clamp the alternate parameter to a default 64000.
  Available context and explicit per-request clamps still apply.
- Restart via `qwen-labs` to inherit the launcher correction. Its `--check`
  passed; offline source-based checks confirmed the output-budget path. No live
  model request was made by the coordinator to validate API acceptance.

Do not reinterpret the `openai` provider label as use of an OpenAI model or
account: it is the compatible API protocol for the configured Qwen endpoint.

## What remains before START

1. Prepare isolated participant runners that cannot access the competing
   checkout/content, host credentials, production services or private evaluator,
   while providing controlled GitHub access for authorized assigned-branch pushes.
   Verify the enforcement and do not rely on the shared host's broad credentials.
2. Validate public cases and independently implement and freeze the private
   evaluator, assertions, seeds, mutation/reserve cases and environment manifest.
3. Validate feasibility of the published resource workload on the frozen worker.
4. Verify and pin both effective model/CLI configurations and any subagent rule.
5. Freeze the equal time/spend policy, publish artifact hashes and establish
   collection and timing procedures.
6. Issue the same START instruction when ready, collect immutable submissions,
   evaluate first-pass results and then run the common repair protocol.

On context restoration, read this memory and the published benchmark documents,
then verify current checkout and run state. Do not claim the preparation, start,
submission, evaluation, winner or deployment has happened without new evidence.
