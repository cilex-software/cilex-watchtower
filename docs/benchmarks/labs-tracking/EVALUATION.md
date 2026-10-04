# Evaluation protocol — labs-temporal-tracking-v1

## State of this package

This is the common starting specification and public fixture package. The task
implementation is deliberately absent. On 2026-10-04 the user confirmed that
neither CLI had received an earlier task prompt and authorized autonomous
implementation when the current launch prompt is supplied. Start in the assigned
checkout without another START signal, a fixed deadline, an isolated runner or
a private evaluator. Make routine implementation and testing decisions within
the assignment's scope, complete the work and publish it to the assigned branch.

The private evaluator and controlled runner isolation are coordinator-owned and
are not ready. These development runs must not be described as a formally timed,
isolated blind benchmark. The rubric below is published; private checks have not
been frozen before development. Before inspecting either implementation, the
coordinator must validate the public cases and independently prepare and freeze
the evaluator's checks, seeds, scoring groups and environment manifest outside
both participant environments. Publish their hashes and freeze timestamp, not
hidden data or solutions, and disclose that the freeze occurred after development
was authorized. Do not claim an earlier freeze. Any contract correction must
reach both participants identically and be recorded before evaluation.
No undisclosed rule, later threshold, or preferred implementation may affect a
score. A defect in the contract pauses affected scoring; it is not charged to
one model.
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

## Development conditions and later evaluation

- Both remote branches initially point to the SAME setup commit:
  `benchmark/kimi-labs-tracking` and `benchmark/qwen-labs-tracking`.
- Both receive exactly `PROMPT.md` as their task, the complete same source
  snapshot, this contract, and the same public cases and documentation.
- Use the existing separate, shallow, single-branch checkout assigned to each
  participant. The published source snapshot is sufficient; older history and
  other refs are not participant input. Do not fetch additional history or
  inspect the other checkout. These host checkouts do not isolate the host home,
  credentials or other files; the scope restrictions still apply.
- Record the actual development Python/package versions, platform, timezone,
  locale, resource conditions and CLI settings. For later comparative scoring,
  supply identical package versions and CPU/memory limits, capture the evaluator
  environment and evaluate performance serially on the same otherwise idle
  worker. Local measurements, especially while both agents run concurrently,
  are diagnostic and must be labelled with their conditions.
- A future controlled rerun requires separate disposable runners with only
  each participant's own tree/history visible, common environment settings and
  evaluator/environment artifact hashes frozen before that rerun starts. This
  preparation does not block the current autonomous development assignment.
- Do not run the contest on a recording/guard station or give the runners a
  host Docker socket, production mounts, backend credentials or station access.
- Supply both with the same local documentation. Runtime code/tests are
  offline. Agent network access is limited to its authenticated model endpoint,
  identically documented provider login requirements, and normal authenticated
  Git operations on its own assigned branch at the supplied
  `romayankin/cilex-watchtower` origin. The user authorizes non-force pushes only
  to `benchmark/kimi-labs-tracking` for Kimi and
  `benchmark/qwen-labs-tracking` for Qwen. No fetching competitor work, pushing
  other refs/tags, force-pushing, deleting refs, or changing repository access
  rules. Git authentication may be used normally; credential contents must not
  be inspected or exposed. No outside coding assistants or competitor outputs.
  Do not supply additional provider-specific task coaching, skills or hidden
  project memory. Record the allowed Git route in the development report; the
  current host's shared GitHub login is not itself a branch-access sandbox.
- Use the native CLI of each candidate. This measures the CLI plus model as a
  development assistant, not a controlled claim about a bare language model.
  Pin CLI version, effective model ID/snapshot, reasoning setting, context limit
  and all automatic fallback settings. Require the highest supported reasoning
  setting of the selected flagship; disable fallback to another model.
- Up to two concurrent subagents are permitted, only using that participant's
  selected model. Do not delegate to another LLM or enable model fallback. If
  the CLI cannot keep subagents on the selected model, work alone and record
  that limitation; do not wait for coordinator action. Record subagent usage,
  time/cost and any difference between the two participants' CLI capabilities.

## Time, feedback and collection

The current assignment has no imposed eight-hour stop or scheduled repair round.
Start when the user supplies the launch prompt and continue through implementation,
validation, commit and assigned-branch push. Report elapsed time and resource use
where available; do not invent measurements. Existing authenticated model use is
part of this authorized task. Purchases, unrelated installations and production
operations remain outside scope.

For a future controlled rerun, the proposed common allowance is eight hours of
implementation plus one 60-minute repair round. Freeze any such allowance and
spend cap identically before that rerun. Its clock includes planning, tool
execution, model responses, tests, commit hooks and branch pushes; pause only for
an externally verified provider outage or coordinator-caused environment fault
under the same policy for both participants. These are future timing rules, not
conditions for starting the current assignment.

Record available active and wall time, provider failures, tool usage, subagent
usage, human interventions and actual billed cost or a clearly labelled estimate.
At submission collect the full diff, commit, remote branch/ref and push result,
clean/dirty status, test output and submission report. Pin the submitted SHA;
later pushes cannot silently replace that scored submission. A failed push is
reported and the local committed snapshot remains collectable. Uncommitted work
is preserved for diagnosis but does not silently replace the submitted commit.

Score the initial submissions privately. If a repair round is subsequently
authorized, each participant gets its own reproducible failing-case diagnostics
(input, expected/actual behaviour and error), at the same level of detail.
Do not provide implementation patches or
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
Freeze assertion counts with the independent evaluator before inspecting either
implementation. A malformed response or crash fails the affected checks;
repeated copies of one easy case cannot increase its weight.

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
runs serially after one unscored warmup. Before comparative scoring, verify that
the common evaluator can supply an isolated CPU and the contract's resource
conditions. If it cannot, defer throughput scoring; local timings remain
diagnostic and development continues. The workload limits are contract
requirements, not a claim that this preparation has validated their feasibility
or measured either implementation. Incorrect output earns no throughput points.
Timeouts and resource limits are specified in `CONTRACT.md`.

The test-quality rubric gives one coverage point each for association, ambiguity,
time boundaries, replay/checkpoints, and validation/adapter coverage. Mutation
points use one independently planted defect from each family; publish these
families now, freeze the actual mutations with the independent evaluator before
inspecting either implementation. A test must fail for the defect and pass on
the participant's unmutated implementation. A mutation that cannot be applied
semantically is replaced by a pre-frozen reserve
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
