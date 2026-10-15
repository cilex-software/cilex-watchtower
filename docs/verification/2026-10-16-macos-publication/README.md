# macOS installer source publication checks — 2026-10-16

The existing macOS installer/deployment work was integrated with current GitHub
main for source publication. This is a development implementation; the original
production and sustained real-camera acceptance limits remain in force.

## Current checks

- Generic installer suite: 278 tests run, 277 passed, one expected skip.
- Darwin Warden suite: 31 passed, including native isolated process recovery.
- Recovery-harness fixtures: 19 passed.
- Native macOS application, identity harness and reconnect harness: built.
- Loopback identity/readiness regression: passed.
- Production QML silent-stall regression: old component failed as expected
  (one connection); corrected component recovered (two connections).
- Python/JSON/Bash syntax, staged cross-system claim lint and source whitespace
  checks passed. Raw historical evidence whitespace was preserved verbatim.

Logs and the machine-readable summary are adjacent. Builds ran in a temporary
workspace; the installed Watchtower/Warden were not launched or deployed. These
checks do not establish production signing/notarization, clean/older/remote Mac
compatibility, actual sign-in/reboot, protected machine-scope installation or
sustained real-camera freshness. See the retained [development acceptance
record](../2026-10-13-generic-macos-deployment/README.md).
