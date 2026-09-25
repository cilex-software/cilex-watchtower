# Standing capture on the macOS client — install, read, remove

**Status (2026-09-25):** client half LIVE on the operator's MacBook since 08:46Z.
Server half proposed to CV (`docs/letters/2026-09-22-…reply6-macos.md`), not yet running.

Why it exists: the 2026-09-22 111 s API stall could not be attributed because nothing
was recording on either side. Two readings stayed alive — a tunnel path change that
wedges *established* flows while *new* ones succeed, or scoped server-side queueing.
This records, continuously, what separates them.

## What runs

| stream | where | rate / size | retention |
|---|---|---|---|
| `keep` — GET /health on ONE persistent connection (local port logged per connect) | `~/Library/Logs/watchtower-capture/netprobe-YYYYMMDD.log` | 1 Hz | 14 days, older days gzipped |
| `fresh` — GET /health on a NEW connection, connect time separate | same file | 1 Hz | same |
| `path` — Tailscale path to the server peer: direct/relay, exit node | same file | every 10 s, logged on CHANGE | same |
| `route` — default route AND the physical network under the tunnel | same file | every 10 s, on CHANGE | same |
| `min` / `hb` — per-minute p50/max/err rollup + current path | same file | 1/min | same |
| `GAP` — wall vs monotonic clock: the laptop slept | same file | on event | same |
| app log with `WT_TRACE` — every API request's latency, GUI stalls > 150 ms | `~/Library/Application Support/Cilex Vision/Watchtower/flightrec/` | 549 B/s ≈ 47 MB/day* | 20 MB × 10 = 200 MB ≈ 4 days |
| image-response ledger (E1 P0) | `~/Library/Logs/watchtower-imgresp.log` | ≈ 11 MB/hour | unbounded — see E3 |

\* Measured over the first 103 s after a launch, which includes the startup burst
(every wall still at once), so it is an upper bound.

`WT_TRACE` and the flight-recorder sizing reach the app through `launchctl setenv`,
re-applied at every login by an agent, so a Watchtower started from the Dock, Finder
or `open` traces without anyone remembering a flag. A Watchtower started from a
terminal inherits the terminal's environment instead.

## Install, check, remove

    tools/capture/install-macos.sh              # install or refresh (idempotent)
    tools/capture/install-macos.sh --status     # agents, env, current log file
    tools/capture/install-macos.sh --uninstall  # both agents + the env; logs kept

Two per-user LaunchAgents, nothing outside `~/Library`, no sudo:
`com.cilex.watchtower.netprobe` (KeepAlive) and `com.cilex.watchtower.traceenv`
(RunAtLoad). The probe script is COPIED to
`~/Library/Application Support/Cilex Vision/capture/` so a branch switch in the
checkout cannot change what launchd runs. Re-run the installer after editing it.

## Reading a stall

Find the app's slow requests in the flight recorder (`[EVTIME]`, `[PBTIME]`,
`[EVIMG]`, `[EVPOLL]`; its clock is local time, the probe's is UTC), then look at
the probe for the same seconds:

| app | keep | fresh | reading |
|---|---|---|---|
| slow | fast | fast | server-side and scoped — needs CV's `pg_stat_activity` |
| slow | STALL | fast | established flows wedged — look for a `path` CHANGE |
| slow | STALL/refused | STALL/refused | server process or whole path down |
| — | — | — | interval contains a `GAP`: the laptop slept; not evidence |

`ConnectionRefusedError` means the host answered and nothing listened on the port —
a server process restart, not a network fault. `/health` does not touch the
database, so the probe alone cannot see DB queueing; that is the server half's job.

## Facts about this machine the capture surfaced (2026-09-25)

- **Tailscale exit node ON** (`100.95.220.35`): the default route is `utun8`; all of
  this laptop's internet traffic is tunnelled. Tailnet traffic to the server is a
  direct WireGuard peer path (`109.195.85.73:1024`, DERP home `hel`), not via the
  exit node. Physical network: `en0` 192.168.0.121 → 192.168.0.1, i.e. NOT the
  camera LAN (192.168.1.x). The probe logs a change in any of these.
- Probe latency was cross-checked against `curl` from an interactive shell in the
  same seconds (connect 90–540 ms both) — the LaunchAgent's scheduling does not
  inflate its numbers.

## First catch: API down ~16 s at 08:47:44Z, 90 s after install

Connection dropped by the server at 08:47:44.098Z; 29 refusals on keep and fresh
alike 08:47:45.236 → 08:47:59.180Z; back 08:48:00.244Z on a new flow. Watchtower's
events poll had a 5,392 ms answer 2.4 s before. RTSP never stopped (25 pipelines,
frame counters advancing). Cause asked of CV (reply6), not assumed here. The client
had restarted at 08:43:46Z.
