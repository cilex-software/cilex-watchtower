# Agent memory (snapshot mirror)

**Latest Codex restart handoff, 6 November 2026:** read
[`../handoffs/SESSION_RESTART_2026-11-06.md`](../handoffs/SESSION_RESTART_2026-11-06.md)
first. It records the remote migration and preserved dirty checkout, archive/
memory implementation and remaining rollout gates, original-recognition Task04B
release blocker, analyser work and exact local evidence/recovery paths. Dated
runtime observations in that handoff are not current health checks.

This directory is a **point-in-time backup** of the AI coding agent's (Claude Code)
persistent file-based memory for this project. The live memory lives **outside the
repo** at `~/.claude/projects/<project>/memory/` — which is local-only and not
otherwise backed up — so it's mirrored here for crash recovery.

**These are point-in-time observations, not live state.** They may drift from the
code and from the live memory dir; file:line citations can go stale. The
**canonical, maintained records are [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md)
(current status) and [`../DEVELOPMENT.md`](../DEVELOPMENT.md) (implementation)** —
prefer those. `MEMORY.md` here is the agent's own index of the memories.

Contents (see `MEMORY.md` for the indexed view):

- **Status / roadmap** — `build-roadmap.md` (current phases), `stack-and-build-direction.md` (locked stack + scope rationale).
- **Rules / feedback** — `product-rules.md`, `design-fidelity-required.md`, `feedback-no-placeholder-content.md`, `handling-design-backend-gaps.md`, `feedback-long-shell-commands.md`.
- **Implementation** — `toolchain-setup.md`, `video-pipeline-approach.md`, `data-persistence-and-naming.md`.
- **cilex-vision API** — `playback-via-cilex-vision.md`, `cilex-vision-playback-api.md`, `s06-playback-gaps.md`.

To refresh this mirror: copy `~/.claude/projects/<project>/memory/*.md` here and commit.
