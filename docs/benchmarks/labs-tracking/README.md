# Kimi / Qwen Labs development benchmark

Challenge ID: `labs-temporal-tracking-v1`.

Source base: `5c628372c7b650591aa20e2b1bd774e825106007`.

The two branches start at the same setup commit, so their source tree, prompt,
contract and public fixtures are identical. No tracking implementation is
included. The setup commit also carries the repository hook's normal version
metadata increment; it is not an application release or deployment.

| Participant | Branch | Prompt |
|---|---|---|
| Kimi | `benchmark/kimi-labs-tracking` | [PROMPT.md](PROMPT.md) |
| Qwen | `benchmark/qwen-labs-tracking` | [PROMPT.md](PROMPT.md) |

The exact same launch instruction may be pasted into either CLI:

> Read `docs/benchmarks/labs-tracking/PROMPT.md` and its linked contract,
> evaluation guide and public fixtures. Start now in the assigned checkout;
> no separate START signal, deadline, isolated runner or private grader is
> required for this autonomous development task. Make routine decisions,
> implement the complete contract, test and fix the solution, then commit with
> the repository hooks and push to your own assigned benchmark branch at origin.
> Stay within the permitted files and offline assignment. Do not inspect the
> other participant's work, contact production, force-push, push other refs or
> tags, merge, or deploy. Report the commit, push result, actual validation and
> remaining limitations honestly. Do not claim a formal blind benchmark score.

On 2026-10-04 the user confirmed that neither CLI had received the earlier
prompt. The current prompt authorizes autonomous implementation immediately
when supplied; the earlier wait-for-coordinator instructions no longer apply.

The user explicitly authorized publication to each participant's own branch on
2026-10-04. Use only the command for your assigned branch, after checking the
current branch and origin:

| Participant | Authorized push |
|---|---|
| Kimi | `git -c push.followTags=false push origin HEAD:refs/heads/benchmark/kimi-labs-tracking` |
| Qwen | `git -c push.followTags=false push origin HEAD:refs/heads/benchmark/qwen-labs-tracking` |

This replaces the earlier no-push instruction. The shared host login can write
more broadly; the branch scope above is an instruction, not a claim that GitHub
credentials enforce per-participant isolation. Record the Git route and actual
development conditions; do not claim the existing host checkouts are sandboxes.

The task, permitted files and submission rules are in [PROMPT.md](PROMPT.md).
Behaviour is defined by [CONTRACT.md](CONTRACT.md). Test families, the published
rubric and later evaluation conditions are in [EVALUATION.md](EVALUATION.md).
The [public cases](fixtures/README.md) are examples and conformance data, not an
implementation or a hidden grader.

`setup-manifest.json` records the source base and public package hashes. The
manifest excludes itself to avoid a circular checksum. The remote branch commit
IDs independently establish identical starting Git trees.

The independent private evaluator and controlled runner isolation are not ready.
They do not block development in the assigned checkouts. Before inspecting either
implementation, the coordinator must freeze an independent evaluator and disclose
its hashes and timestamp; it must not be described as frozen before development.
A future formally controlled run needs its own frozen evaluator and environment
before launch. The eight-hour allowance and one-hour repair round in the guide
are proposals for that future run, not current deadlines. This preparation does
not claim measured results, a completed grader or a timed benchmark launch.

The development CLIs may have different commands and authentication flows. Their
task text is intentionally provider-neutral, and provider-specific launch details
belong to the recorded development conditions rather than a different task prompt.

Reference dependency inventory measured on the preparation host (not a claim
that evaluation containers already exist): Python 3.12.3, NumPy 2.4.4,
opencv-python 4.13.0.92, psutil 7.2.2. Record the versions actually used for
development. Later comparative scoring uses the same package versions and
resource conditions for both submissions; concurrent local timings are diagnostic.
