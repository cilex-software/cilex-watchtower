# Connection diagnosis — security room vs server room, 6 h paired run (2026-08-14)

**Question.** The booth wall (`wt-sm-vnutri-01`, Windows, security room) shows far
more cameras stuck "connecting" than the wall on `cilex-vision-MS-7E06`
(Ubuntu, server room). Is that the **network between booth and server**, the
**server itself**, or the **booth machine**?

**Why paired.** The server-room box *is* `192.168.1.79` — it runs go2rtc, so its
path to the stream source is loopback. Its numbers are therefore the
**server-side floor**: the time the backend takes even with zero network in the
way. The useful quantity is the difference:

```
booth_time  −  server_room_time  ≈  network + booth-side cost
```

If both sides are slow by the same amount, the booth's link is exonerated and
the server is the problem. Neither side can conclude anything alone, which is
why the probe set must be **identical**.

## The probe set — pin these exactly, do not substitute

Three cameras, addressed by their **go2rtc `-sub` stream** (the substream is what
the wall consumes; the main streams are HEVC and only the recorder pulls them):

| camera | stream |
|---|---|
| `192.168.1.102` | `hiwatch-083bc16da380-sub` |
| `192.168.1.126` | `hiwatch-083bc1df39d1-sub` |
| `192.168.1.189` | `hiwatch-04eecdd45e0d-sub` |

## The measurement

**Cadence:** one sample every **300 s**, for **6 h** (72 samples).
**Window:** started 2026-08-14 ~18:14 MSK on the server-room box.

Per sample, per camera — a single JPEG frame, which exercises the whole path
(client → go2rtc → camera → frame) without subscribing to a stream:

```
GET http://192.168.1.79:1984/api/frame.jpeg?src=<stream>
```

Record `http`, **`ttfb_s`** (the headline), `total_s`, `bytes`.

Plus, once per sample:

```
GET http://192.168.1.79:1984/api/streams
```

Record `api_ms`, `api_bytes`, total streams, **producers connected**,
**consumers total**, and — critically — **whether each probed stream already had
a connected producer** (`warm_before`).

### `warm_before` is the whole point

A **warm** stream (producer already connected) should return a frame fast. A
**cold** one makes go2rtc open an RTSP session to the camera first, which is
seconds. "Cameras waiting for connection" is largely a cold-start story, so a
mean that mixes the two is meaningless. **Split every statistic by
`warm_before`.**

Already observed on the server-room box, loopback, ~20 minutes apart: the same
warm stream returned in **0.31 s** and then **2.43 s**. That spread is
server-side and has nothing to do with any network.

## Host metrics — record, but do not compare across OSes

Each side records what its OS exposes. These are **not** comparable
machine-to-machine; they are for correlating a slow probe with local load.

- **Linux (server room):** `load1`; `/proc/meminfo` (swap used); `/proc/vmstat`
  `pswpin`/`pswpout`/`pgmajfault` as raw counters (deltas computed later);
  `/proc/pressure/{cpu,memory,io}` `some`/`full` avg10+avg60; the Watchtower
  process's RSS, CPU seconds and **`alive_s`** — a drop in `alive_s` means a
  restart, and every restart is followed by a reconnect storm.
- **Windows (booth):** the nearest equivalents (CPU %, committed bytes, hard
  faults/s, NIC link speed and errors, and the Watchtower process's working set
  + uptime). Label them clearly; do not attempt to align the numbers with PSI.

**The booth should additionally measure what the server-room box structurally
cannot:** RTT and loss to `192.168.1.79` (e.g. 20 pings per sample), and NIC
negotiated link speed. The server room's answer to both is "loopback" and
"n/a" — that asymmetry is the point, not a gap.

Note: a 100 Mbit uplink fault was found and fixed on the morning of 2026-08-14
(link renegotiated to 1000). Booth samples should confirm the booth's own link
speed rather than assume it inherited that fix.

## Output

One JSON object per sample, JSONL, one file per machine. Reference
implementation: `tools/conn-diag/probe.py` (the host block is Linux-only; the
HTTP probes are portable and are the part that must match).

Server-room run: `docs/perf/2026-08-14-serverroom-6h.jsonl` (committed when the
run completes).

## Reading the result

1. Split `ttfb_s` by `warm_before`; report median and p95 for each.
2. Subtract the server-room figure from the booth figure **per bucket**. What
   remains is network + booth.
3. Correlate the server-room tail against `io full avg60` and swap-out rate —
   if slow frames coincide with swap churn, the backend is the bottleneck and
   the booth is merely the first place it becomes visible.
4. Only if the booth's excess survives that subtraction is it a booth or link
   problem.

**Read-only throughout.** `/proc`, `/sys`, go2rtc's HTTP API, and one JPEG frame
per camera per sample. No PTZ, no acknowledgements, no exports, nothing written
to the fleet.
