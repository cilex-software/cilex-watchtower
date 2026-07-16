# netem impairment matrix — 2026-07-16

Harness: `tools/netem-harness` (port-scoped lo shaping on 8000/8554/1984, both
directions, per-direction values). S1 = playback+strip 300 s (footage-discovered
plan). S2 = churn 10 switches. RTT column = measured TCP connect through the
shaped path at apply time — a row can never silently run unimpaired.

Baseline anchored 19:5x MSK against the post-incident backend (footage = one
sparse day, 2026-07-16 from 03:59Z, cams .67/.50 — so this baseline is
cold-heavy: small n, single-day churn). Impaired rows must be compared against
THIS row, same-day. An earlier attempt during the backend data-loss incident
(sessions served `no_recording` fleet-wide) was discarded as invalid.

| profile | RTT ms | ttff p50 | strip p50/p95 (n) | >1s | http p50 | misl | giveup | S2 churn | crashes |
|---|---|---|---|---|---|---|---|---|---|
| baseline | - | 1960 | 721/2000 (24) | 4 | 222 | 7 | 0 | 1/1 PASS | 0 |

Notes: strip p50 721 ms matches the 07-10/07-14 soak baselines (713–722 ms).
The p95/over-1s tail and the 7 mislanded (all single-shot recoveries, 0
give-ups) are the known cold-sparse-day class — today's footage has no warm
history. TTFF p50 1960 ms is a cold day-open.

**Next:** the 12 impaired rows need the one-time root setup
(`sudo tools/netem-harness/setup-root.sh`), then `netem-soak.sh` runs the full
matrix (~2.5 h). Raw logs: `~/watchtower-soak/netem-2026-07-16/`.
