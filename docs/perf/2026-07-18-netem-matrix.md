# netem impairment matrix — 2026-07-18

Harness: `tools/netem-harness` (docker-bridge egress + ifb ingress-redirect,
host-scoped so other backend clients — e.g. Cilex Pro Mobile — are exempt;
per-direction values). S1 = playback+strip 300 s (footage-discovered plan:
.67/.50, days 07-17+07-18). S2 = churn 10 switches 07-18↔07-17. RTT column =
measured connect through the shaped path at apply time (expect ≈2× delay).

Run history: attempt-3 rows were discarded too — a tracked runner survived its kill and raced the detached one (interleaved duplicate profiles, one wan200 verifying 0.0 ms); netem-soak.sh now takes an flock so a second runner cannot start. Earlier, the first attempt's four "impaired" rows ran UNSHAPED (host-scoping
bug: filters matched the bridge IP while host sockets bind the LAN IP — their
0.2–0.3 ms verify RTTs exposed it exactly as the verify column is designed to)
and were discarded. Fix behaviorally proven (wan50 → 109 ms connect, both
netem counters advancing) before this relaunch.

| profile | RTT ms | ttff p50 | strip p50/p95 (n) | >1s | http p50 | misl | giveup | S2 churn | crashes |
|---|---|---|---|---|---|---|---|---|---|
| baseline | - | 1361 | 719/3012 (24) | 4 | 135 | 22 | 0 | 1/1 PASS | 0 |
| lan-jitter | 7.7 | 4713 | 718/1967 (12) | 4 | 168 | 10 | 0 | 0/1 | 0 |
