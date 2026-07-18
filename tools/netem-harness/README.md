# netem harness — network-impairment testing for Watchtower

Applies kernel-level network impairments (delay/jitter/loss/reorder/corruption/
bandwidth) to **exactly the client↔backend traffic** and runs the existing soak
gates under each profile, producing a matrix report. Fills the #1 coverage gap
from the 2026-07-16 research: every prior test ran over an unimpaired localhost
path.

## How the traffic is scoped (CORRECTED 2026-07-18, packet-proven)

The original lo-based design was wrong and the pre-flight smoke caught it
(lo qdisc counters stayed at **0 packets** while curls completed): Docker's
**OUTPUT-chain DNAT** rewrites locally-generated traffic to published ports
toward the container IPs *before routing*, so it rides the **docker bridge**
(`br-…`, the 10.0.0.0/24 network), not loopback. docker-proxy only fronts the
127.0.0.1 path, which the client doesn't use.

- **Requests (host→container):** `prio` root on the bridge egress, `netem`
  branch, `u32 dport` filters for 8000/8554/1984 only. Proven: 50 ms profile →
  connect 0.2 ms → 50.2 ms, 17 pkts on the netem counter.
- **Responses (container→host):** bridge **ingress** qdisc with `u32 sport`
  filters redirecting (mirred) to **`ifb0`**, which carries the same `netem`
  plus the `tbf` rate cap — the download direction is where bandwidth caps
  belong. `ifb0` is created once by `setup-root.sh` (root required for ifb).
- Inter-container traffic switches through the bridge at L2 and never enters
  the host qdisc — server-internal hops stay unshaped, as intended.
- `verify` now expects connect ≈ 2× delay (SYN shaped egress, SYN-ACK shaped
  via ifb).

## One-time root setup (run in YOUR terminal)

    sudo tools/netem-harness/setup-root.sh

It does four things, each idempotent: loads `sch_netem` (+persists via
modules-load.d), disables TSO/GSO/GRO on `lo` (netem loss must act per-packet,
not per-64k-superpacket; resets on reboot — `impair.sh` warns if back on),
installs `/etc/sudoers.d/watchtower-netem` (NOPASSWD for `/usr/sbin/tc` only,
validated with `visudo -cf` before install), and self-verifies.
Remove everything: `sudo tools/netem-harness/setup-root.sh --remove`.

## Usage

    impair.sh list                 # profiles + parameters
    impair.sh apply wan50          # shape backend ports (per-direction values)
    impair.sh verify               # measured TCP connect RTT vs expectation
    impair.sh status               # qdisc tree + netem packet stats
    impair.sh off                  # remove ALL impairment (idempotent)
    impair.sh --dry apply loss5    # print tc commands only

    netem-soak.sh                  # full matrix (needs setup); ~12 min/profile
    netem-soak.sh --baseline-only  # no-root plumbing check + baseline row
    netem-soak.sh --profiles "wan50 loss5 bw4m"

`netem-soak.sh` refuses to run while a NON-harness watchtower is up (the
impairment would hit the operator's session too) unless `--force`. Impairment
is removed on any exit path (trap), and every profile row records the
*measured* connect RTT so a row can never silently run unimpaired — the
2026-07-12 validation lesson (a false PASS from a misresolved path) is baked
in as "verify before trust".

## Profiles (per-direction; RTT ≈ 2× delay)

| profile | netem | rate cap | models |
|---|---|---|---|
| baseline | — | — | control row |
| lan-jitter | delay 5ms ±3ms | — | busy switch |
| wan50 | delay 50ms ±10ms | — | metro WAN |
| wan200 | delay 200ms ±40ms | — | satellite/far WAN |
| loss1 | delay 20ms ±5ms, loss 1% | — | typical congested wired |
| loss5 | delay 30ms ±8ms, loss 5% | — | bad wireless |
| burst-ge | delay 30ms ±8ms, loss gemodel 1% 25% 80% 0.1% | — | Gilbert-Elliott bursty loss |
| reorder | delay 15ms, reorder 25% 50% gap 5 | — | multipath reordering |
| corrupt | delay 10ms, corrupt 0.5% | — | L2 corruption → checksum drops |
| bw4m | delay 20ms ±5ms | 4 Mbit | HD stream at its bitrate ceiling |
| bw1m | delay 40ms ±10ms | 1 Mbit | sub-stream-class link |
| mobile3g | delay 100ms ±20ms, loss 1% | 2 Mbit | cellular |
| worst | delay 150ms ±30ms, loss 2% | 3 Mbit | everything at once |

(1 %/5 % loss and the delay bands follow the standard streaming-testbed
matrices; gemodel parameters are the classic Gilbert-Elliott wireless set.)

## Scenarios per profile

- **S1 playback+strip** — `WT_FSOAK`, 2-cam mini-plan (current .201 day +
  archived .106 day), 300 s. Metrics: TTFF p50 (`first_frame dt=`), strip
  p50/p95/n/>1 s, session_http p50, mislanded count, GIVE-UPs, crashes.
- **S2 churn** — `WT_CHURNTEST=10` (.201 2026-07-10 ↔ 2026-07-08, frame
  mode), 240 s cap. Metrics: SUMMARY PASS, crashes, wedge (no SUMMARY).

Both run the patched-Qt default runtime, isolated XDG configs under
`~/watchtower-soak/netem-<date>/<profile>/`, gdb-wrapped for inline
backtraces. Output: `docs/perf/<date>-netem-matrix.md` + raw logs.

## Caveats

- Values are applied per direction; a 50 ms profile ⇒ ~100 ms RTT (recorded
  by `verify`).
- IPv4 filters only — the client URL is a literal IPv4 address.
- `corrupt` on a checksum-verifying TCP path behaves as loss with a different
  kernel path; kept for completeness.
- Live-wall (8554/1984) is in the port scope but has no scenario yet; add an
  S3 when the live wall gets its sustained-decode benchmark.
