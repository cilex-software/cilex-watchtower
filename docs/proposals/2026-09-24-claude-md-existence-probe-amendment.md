# Proposed amendment to CLAUDE.md lines 66–68 — NOT APPLIED

**Status: awaiting the operator.** `CLAUDE.md` governs four agents; neither this box
nor cilex-vision will edit it on the other's say-so, and a peer agreeing is not an
approval. cilex-vision is raising the same proposal independently so the operator sees
it from both sides rather than one of us relaying the other.

## Why

The rule endorses a method that is **silent on this fleet's firmware, and silent in the
direction that produces false confirmations.** Measured 2026-09-24, both agents, with
an impossible-path control:

```
unauthenticated   401 on EVERY path, including /ISAPI/Nonexistent/madeup
authenticated     403 on /ISAPI/Nonexistent/madeup, 200 on the real paths
```

The firmware challenges authentication before routing, and refuses an unknown path with
403 rather than 404. **It never reveals existence through a status code in either
direction.**

Without a control, this box would have reported four camera endpoints as confirmed
present; cilex-vision would have run three real paths, received three 200s, and
recorded "authenticated probing works" without learning that 403 does not mean absent.

## Current text (lines 66–68)

```
- **Never guess camera credentials** — HiWatch/Hikvision firmware locks
  after ~7 failures. Existence-probe with an unauthenticated request and
  read 401-vs-404 instead (Codex's method, adopted repo-wide).
```

## Proposed replacement

```
- **Never guess camera credentials** — HiWatch/Hikvision firmware locks
  after ~7 failures.
  **MEASURED 2026-09-24: status codes do NOT establish existence on this
  firmware.** Unauthenticated it returns 401 on every path including an
  impossible one; authenticated it returns 403 on an impossible path. The
  401-vs-404 method (Codex's, previously adopted repo-wide) is silent here.
  Existence is established only by an authenticated request returning 200
  with a parseable body, or not at all.
  **Always include an impossible-path control.** Both agents who probed this
  firmware reported wrong conclusions without one.
```

**The protective half is unchanged and verbatim** — it is what stops a lockout on a
fleet real guards are watching, and nothing measured affects it.

## The sentence to keep if anything is trimmed

cilex-vision's argument, and it is right: *"the measured status codes are a fact about
one firmware and will age; 'run a control that cannot succeed' is the transferable
half, and it is the only thing that caught either of us."*

A fresh session on either box tomorrow starts with the habit uninstalled and no memory
of why the control matters. **So the rule should carry the control, not the finding** —
the finding will be stale before the habit is.
