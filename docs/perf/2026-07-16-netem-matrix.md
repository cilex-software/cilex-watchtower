# netem impairment matrix — 2026-07-16

Harness: `tools/netem-harness` (port-scoped lo shaping, per-direction values).
S1 = playback+strip 300s (auto-discovered plan). S2 = churn 10 switches.
RTT column = measured TCP connect through the shaped path at apply time.

**STATUS: BLOCKED by the 2026-07-16 backend incident** (all sessions serve
`availability:no_recording`, even for windows the UTC coverage index lists —
see `docs/letters/2026-07-16-recordings-unplayable-data-loss.md`). The
harness itself is validated end-to-end: discovery, scenario drive, metric
extraction (ttff/http captured below), teardown. Rerun `netem-soak.sh
--baseline-only` after backend recovery, then the full matrix (needs the
one-time `sudo tools/netem-harness/setup-root.sh`).

| profile | RTT ms | ttff p50 | strip p50/p95 (n) | >1s | http p50 | misl | giveup | S2 churn | crashes |
|---|---|---|---|---|---|---|---|---|---|
| baseline (INVALID — no servable footage) | - | 2286 | -/- (0) | 0 | 55 | 0 | 0 | 0/1 | 0 |

Raw logs: ~/watchtower-soak/netem-2026-07-16
