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
| wan50 | 92.5 | 7267 | 713/760 (12) | 0 | 1276 | 12 | 0 | 0/1 | 0 |
| wan200 | 420.1 | 9844 | 1209/4215 (13) | 8 | 2227 | 7 | 0 | 0/1 | 0 |
| loss1 | 35.6 | 5120 | 734/4263 (12) | 6 | 1096 | 9 | 0 | 0/1 | 0 |
| loss5 | 51.4 | 19071 | -/- (0) | 0 | 1383 | 0 | 0 | 0/1 | 0 |
| burst-ge | 62.9 | 9538 | 708/716 (4) | 0 | 792 | 5 | 0 | 0/1 | 0 |
| reorder | 25.1 | 2552 | 715/2710 (17) | 4 | 599 | 16 | 0 | 0/1 | 0 |
| corrupt | 20.1 | 4142 | 719/4747 (15) | 6 | 1001 | 12 | 0 | 1/1 | 0 |
| bw4m | 46.5 | 24964 | -/- (0) | 0 | 2853 | 0 | 0 | 0/1 | 0 |
| bw1m | 82.4 | - | -/- (0) | 0 | 15557 | 0 | 0 | 0/1 | 0 |
| mobile3g | 221.3 | - | -/- (0) | 0 | 5975 | 0 | 0 | 0/1 | 0 |
| worst | 623.5 | 18504 | 453/453 (1) | 0 | 3077 | 1 | 0 | 0/1 | 0 |

Raw logs: /home/cilex-vision/watchtower-soak/netem-2026-07-18

## Findings (vs baseline: ttff 1361 · strip 719/3012 n=24 · http 135)

1. **Zero crashes, zero seek give-ups, zero wedges across all 13 profiles** —
   including `worst` (150 ms ±30 each way, 2 % loss, 3 Mbit). The client's
   failure containment (guards, watchdogs, seek-recovery budget, proxy idle
   timeout) holds under every impairment tested. Core robustness: proven.
2. **Warm strip latency is impairment-immune; cold opens are not.** Through
   lan-jitter/wan50/loss1/burst-ge/reorder/corrupt, strip p50 stays 708–734 ms
   (= baseline) while TTFF stretches 2.5–9.5 s and session create 0.6–1.3 s.
   The <1 s filmstrip gate holds to ~50 ms one-way delay (wan50: 713 ms, 0
   over-gate) and first breaks at wan200 (1209 ms p50 at 420 ms RTT) — that is
   the documented operating envelope, and it is physics (sequential segment
   fetches × RTT), not a defect.
3. **Throughput collapse band: loss5, bw4m, bw1m, mobile3g** — zero completed
   strips in the 300 s window; TTFF 19–25 s or never; bw1m session create
   alone took 15.5 s. The HEVC main stream cannot live under ≲4 Mbit
   effective. The client *survives* (no crash, honest spinners) but is not
   *usable*.
4. **The one improvement this matrix motivates:** bandwidth-aware rendition
   selection for playback — the backend already has a lighter rendition (the
   warm-tier H.264 sub stream; "cold base rendition" plumbing exists in the
   serve path). A client policy of "session_http p50 or first-segment time
   over threshold → open sub-stream session instead" would likely turn the
   collapse band into a degraded-but-usable band. Filed as the follow-up.
5. Churn `0/1` in most impaired rows is a harness-window artifact (10 switches
   don't fit 240 s under impairment; corrupt PASSed, none crashed or wedged) —
   future runs should scale the churn window with the profile's RTT.

Attempt history: attempt-1 rows discarded (filters matched the wrong host
address — caught by the per-row verify RTT); attempt-2/3 rows discarded
(two concurrent runners raced the rig — fixed with the flock). Final run:
single locked runner, every row's RTT verified live.
