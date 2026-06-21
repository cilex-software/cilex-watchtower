---
name: feedback-auto-commit-push
description: "Always commit AND push completed, verified changes immediately — straight to main — without asking first."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 057dd61f-f06d-42c8-ac7c-9035085a07c1
---

After finishing a change the user asked for, **commit and push it straight away** — do not stop to ask "want me to commit?".

**Why:** Solo developer (Roman Yankin), solo repo with a linear direct-to-`main` history pushed to GitHub (`romayankin/cilex-watchtower`). Asking each time is pure friction; the user wants changes shipped to the remote as they land.

**How to apply:**
- Commit directly to `main` and `git push origin main`. This is an explicit standing override of the harness "branch first on the default branch" default for THIS repo.
- Use the repo's Conventional-Commits style: `type(scope): lowercase summary` (e.g. `feat(live): …`, `fix(events): …`), with a short body explaining the why, and end with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
- Stage only the files the change touched (build/ is gitignored). 
- **Judgment gate:** only auto-commit when the change is COMPLETE and VERIFIED (build passes, smoke/render or test checked). Never commit broken, partial, or mid-investigation states. This is a working agreement applied with judgment, not a blind Stop-hook.

See [[feedback-long-shell-commands]], [[feedback-letters-single-problem]].
