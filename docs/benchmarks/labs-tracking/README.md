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
> evaluation protocol and public fixtures. Complete the assignment on the
> benchmark branch already checked out. Follow the coordinator's run-start
> signal; do not start the timed implementation during environment preparation.

The task, permitted files and submission rules are in [PROMPT.md](PROMPT.md).
Behaviour is defined by [CONTRACT.md](CONTRACT.md). Test families, scoring and
fairness are in [EVALUATION.md](EVALUATION.md). The [public cases](fixtures/README.md)
are examples and conformance data, not an implementation or a hidden grader.

`setup-manifest.json` records the source base and public package hashes. The
manifest excludes itself to avoid a circular checksum. The remote branch commit
IDs independently establish identical starting Git trees.

Before launch, the coordinator still provisions isolated environments, validates
the effective flagship model/CLI settings and freezes the independent evaluator.
No provider login, CLI installation, model invocation, production operation or
timed run is performed by this package.

The development CLIs may have different commands and authentication flows. Their
task text is intentionally provider-neutral, and provider-specific launch details
belong to the coordinator's run manifest rather than a different task prompt.

Reference dependency inventory measured on the preparation host (not a claim
that evaluation containers already exist): Python 3.12.3, NumPy 2.4.4,
opencv-python 4.13.0.92, psutil 7.2.2. The coordinator supplies these same package
versions to both runners and records the OS/image details before starting.
