# Cilex Watchtower — agent working agreement

Read `CLAUDE.md` and `docs/PROJECT_STATUS.md` for project conventions,
verification requirements and current work. Preserve unrelated changes in this
shared checkout.

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
