# Cilex Watchtower — agent working agreement

Read `CLAUDE.md` and `docs/PROJECT_STATUS.md` for project conventions,
verification requirements and current work. Preserve unrelated changes in this
shared checkout.

## Windows installation experience — operator decision, 2026-10-31

The default generic Windows installation must be a simple graphical wizard,
using the Cilex Vision server installer as the operator's experience reference.
Normal installation/update must not require pasted PowerShell commands, manual
configuration/task/policy edits, checksum entry or successive repair ZIPs.
Keep scripts and detailed options for advanced use and support. Before future
Windows installer work, read the [wizard requirements and Office lessons](docs/plans/2026-10-13-generic-windows-deployment-specification.md#17-graphical-wizard-and-office-installation-lessons).
The current setup wrapper is only a partial GUI; the full wizard remains to be
implemented. Preserve the verified deployment engine's safety and recovery checks.

## Completion and publication — standing instruction, 2026-10-12

After completing and verifying a task, immediately commit its changes,
integrate them into `main` (merge or fast-forward as appropriate), and push
`origin/main`. Do not ask for the same publication permission again.
This supersedes older default publication or branch restrictions in project
guidance. A later explicit task instruction such as local-only, no-push, or
a different destination branch takes precedence for that task.

Publish only completed task changes. Follow the repository's checks and
version hooks, preserve unrelated or unfinished work, and never force-push
shared history. Verify and report the remote commit after pushing.

The owner reaffirmed this on **2026-11-17**: committing and pushing are part of
finishing every task; the owner must not have to remind the agent. Complete this
delivery autonomously. If a real network, authentication or repository failure
blocks publication, report that exact failure and the local commit instead of
claiming it was pushed. Keep unrelated private work, raw logs and disposable
build outputs out of task commits.

This Git authorization does not itself authorize deployment, service restarts,
messages to others, or other outward-facing actions.

## Original object recognition — ChatGPT only, 2026-10-19

The operator instructed: "I won't use anything but ChatGPT for this task going
forward." All remaining original human/car/animal recognition work belongs to
ChatGPT/Codex, including preparation, annotation and review, implementation,
training experiments, scoring and adoption decisions. Do not assign new work
to DeepSeek, Gemini/Antigravity, Qwen or other AI providers for this task.
Preserve existing participant submissions, attribution, datasets, checkpoints
and evidence. This supersedes the earlier participant allocation; it does not
change experimental results, data-release gates or production permissions.
