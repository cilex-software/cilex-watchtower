---
name: feedback-long-shell-commands
description: "Give the user long shell commands as a script file, not a pasted one-liner"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

When the user must run a long shell command themselves (e.g. a `sudo apt install` with many packages), write it into a script file in the repo and have them run a short `sudo bash scripts/foo.sh` — don't hand them a long one-liner to paste.

**Why:** The user's terminal splits long wrapped pastes at the line breaks, so each wrapped segment runs as a separate command (`pkg-name: command not found`) and only the first line's packages actually install. This happened 3× with the apt install on 2026-05-25 before switching to a script.
**How to apply:** Put the payload (package list, etc.) inside the script; keep the command the user types short enough that it can't wrap. Also: this environment's `sudo` needs an interactive terminal — `!`-prefixed / non-interactive Bash can't supply the password, so sudo commands must run in the user's own terminal.
