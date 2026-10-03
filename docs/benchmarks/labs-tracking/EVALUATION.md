# Evaluation protocol — labs-temporal-tracking-v1

## State of this package

This is the common starting specification and public fixture package. The task
implementation is deliberately absent. No participant has started a timed run.
The private evaluator and runner isolation are coordinator-owned and are not
implemented or claimed complete by this setup commit.

Before either participant starts, the coordinator must validate the public cases,
prepare an independent private evaluator, and freeze its checks, seeds, scoring
groups and environment manifest outside both participant environments. Publish
the evaluator/environment artifact hashes, not hidden data or solutions. Any
contract correction before launch must reach both branches in the same commit.
No undisclosed rule, later threshold, or preferred implementation may affect a
score. A defect in the contract pauses both runs; it is not charged to one model.
Snapshot state is intentionally implementation-defined. Automated corruption
tests use the public envelope, JSON/type/finiteness rules and black-box recovery
properties; they must not assume one participant's internal field names or
layout. Any implementation-aware invariant review needs a code-backed,
reproducible violation of the published contract, applied under the same review
standard to both submissions. It cannot introduce a new hidden state schema.
Randomized discrete-decision cases must stay clear of floating-point roundoff:
at least 1e-8 from normalized geometric/area/appearance gate boundaries and 1e-6
from a half-integer boundary in the unrounded integer-cost expression. Dedicated
inclusive/exclusive boundary cases use exactly representable, simple geometry.
The contract's output tolerance does not justify scoring two mathematically
equivalent implementations differently on an unstable rounding-boundary case.

## Identical starting opportunity

- Both remote branches initially point to the SAME setup commit:
  `benchmark/kimi-labs-tracking` and `benchmark/qwen-labs-tracking`.
- Both receive exactly `PROMPT.md` as their task, the complete same source
  snapshot, this contract, and the same public cases and documentation.
- Run each in a separate disposable checkout/container, with only its own
  working tree and Git history visible. Git branches/worktrees alone do not
  isolate files, refs, the host home, credentials or a private evaluator.
  Use shallow, single-branch clones of the common setup commit, not the full
  project history: `git clone --single-branch --depth 1 --branch <assigned-branch>`.
  The published source snapshot is sufficient; older history and other refs are
  not part of the participant input. Do not fetch additional history during runs.
- Pin identical Python/package versions, CPU/memory limits, platform, timezone
  and locale. Capture a package inventory and runner-image digest. Evaluate
  performance serially on the same otherwise idle evaluation worker.
- Do not run the contest on a recording/guard station or give the runners a
  host Docker socket, production mounts, backend credentials or station access.
- Supply both with the same local documentation. Runtime code/tests are
  offline. Agent network access is limited to its authenticated model endpoint
  and any identically documented provider login requirements; no outside coding
  assistants or competitor outputs. Do not supply additional provider-specific
  task coaching, skills or hidden project memory.
- Use the native CLI of each candidate. This measures the CLI plus model as a
  development assistant, not a controlled claim about a bare language model.
  Pin CLI version, effective model ID/snapshot, reasoning setting, context limit
  and all automatic fallback settings. Require the highest supported reasoning
  setting of the selected flagship; disable fallback to another model.
- Up to two concurrent subagents are permitted for either participant, only
  using that participant's selected model. Their time/cost counts toward the
  same run. If either CLI cannot enforce this rule, disable subagents for BOTH
  before starting and record that common decision.

## Time, feedback and collection

The proposed and common allowance is eight hours of implementation plus one
60-minute repair round. These are maximums, not mandatory idle time. Freeze the
actual launch allowance and any spend cap identically before starting. Neither
CLI is launched by this setup work, and no API spend is authorized here.

The clock includes planning, tool execution, normal model responses, tests and
local commits. Pause it only for an externally verified provider outage or a
coordinator-caused environment fault, using the same policy for both models.
Record active and wall time, provider failures, tool usage, subagent usage,
human interventions and actual billed cost or a clearly labelled estimate.

At each submission/deadline collect the full diff, commit, clean/dirty status,
test output and submission report without allowing the agent to modify them
after scoring starts. Uncommitted work is preserved for diagnosis but does not
silently replace the submitted commit.

Score round one privately. For the repair round each participant gets its own
reproducible failing-case diagnostics (input, expected/actual behaviour and
error), at the same level of detail. Do not provide implementation patches or
the competitor's results. Grade the repaired submissions using both the original
tests and frozen reserve instances of the SAME published requirements. Report
first-pass and repaired scores separately; do not average away an initial flaw.

Clarifying questions and answers are logged. Any factual correction or contract
clarification is delivered verbatim to both participants. The reviewer should
inspect anonymised diffs first where feasible; automated results are authoritative
for their specified properties, not the agent's prose or confidence.

## Score: 100 points

Each listed subcategory has the stated weight. Its earned points are its weight
times the fraction of frozen independent assertions passed in that subcategory.
Freeze assertion counts before launch. A malformed response or crash fails the
affected checks; repeated copies of one easy case cannot increase its weight.

| Category | Points | Fixed subcategories |
|---|---:|---|
| Association and ambiguity | 40 | unique/global assignments 15; prediction/occlusion 10; ambiguity/merge handling 10; detection accounting 5 |
| Time and recovery | 20 | discontinuities/expiry/isolation 7; checkpoint equivalence 7; duplicate/conflict/error atomicity 6 |
| Integration and regression | 15 | MaskFrame mapping 5; observation adapter limits 5; existing regressions/defaults/vendor hashes 5 |
| Resources | 10 | bounded retained state/checkpoint size 5; declared streaming workload completion and comparative throughput 5 |
| Participant tests | 10 | published contract coverage 5; independent planted defects detected 5 |
| Maintainability and report | 5 | scoped/readable design 2; documented interfaces/recovery 1; reproducible measured claims 2 |

For the five throughput points, two are for completing the resource workload
without a timeout/crash; three are proportional to median throughput relative
to the faster correct submission, capped at three. Compare three fresh-process
runs serially after one unscored warmup. Timing is diagnostic only if the common
host cannot supply an isolated CPU; in that case neither participant runs until
a suitable evaluator host is available. Incorrect output earns no throughput
points. Timeouts and resource limits are specified in `CONTRACT.md`.

The test-quality rubric gives one coverage point each for association, ambiguity,
time boundaries, replay/checkpoints, and validation/adapter coverage. Mutation
points use one independently planted defect from each family; publish these
families now, freeze the actual mutations privately before launch. A test must
fail for the defect and pass on the participant's unmutated implementation. A
mutation that cannot be applied semantically is replaced by a pre-frozen reserve
defect in the same family, never by a new criterion.

Maintainability points require identifiable evidence: clear separation of core
state, I/O and adapter concerns; limited duplication and scope; documentation of
recovery/API decisions; and commands that reproduce claimed checks. Style taste,
code length alone, confident prose and number of tests do not earn points.

## Release gates and uncertainty

Report numeric scores even if a release gate fails. A submission is not
mergeable when it fabricates observed evidence, duplicates terminal events in
the specified replay model, connects across a declared discontinuity/camera
boundary, changes production defaults, edits protected tests/vendor files, or
violates the allowed execution scope. A gate needs a reproducible case or logged
action, not a reviewer's suspicion. Recovery guarantees apply to complete
snapshots at the specified operation boundaries; no external exactly-once
delivery or unacknowledged downstream write is part of this benchmark.

A submission must pass all contract conformance checks and release gates before
being called complete. A partially working implementation can still be compared
and scored, but cannot be described as deployed or production-ready.

Recommend the higher-scoring mergeable submission, showing elapsed time, cost,
defect severity and repair effort separately. If neither is mergeable, report
that neither passed. If scores differ by fewer than five points, call the first
run inconclusive and repeat from fresh identical snapshots before recommending
a winner. One task measures suitability for this Labs work; it does not establish
a universal model ranking.
