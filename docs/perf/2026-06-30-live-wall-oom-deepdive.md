# Live-wall OOM (P0) — deep dive: teardown is robust; the leak needs go2rtc instability; RSS-shed valve shipped

Investigation of the 2026-06-29 Live-wall OOM crash (RSS 2.3→8.6 GB in ~89 s, `playSec=0`, a
`GLib-GObject-CRITICAL: g_object_unref … G_IS_OBJECT failed`, then earlyoom SIGTERM). The growth is the live
GStreamer pipelines (`RtspVideoSource`), not playback (`playSec=0`). Method: a `WT_WALL_CHURN` reproducer at a
low decode cap (safe — the box is OOM-sensitive, shared with the backend).

## What I tested — ALL CLEAN (the teardown path is robust)

| reproducer (cap 2 unless noted) | cycles | RSS slope | livePipes | `G_IS_OBJECT` |
|---|---|---|---|---|
| healthy churn — `reconnect()` every 2 s | 106 | +1 MB/min | 2 (stable) | 0 |
| healthy churn, **cap 6** | 312 | −1 MB/min | ≤6 (stable) | 0 |
| bad-state churn — black-hole URL (rtspsrc hangs connecting) | 98 | +1 MB/min | 2 | 0 |
| play-then-**drop** — socat proxy killed mid-stream, ×4 drop cycles | — | +1 MB/min | 2 | 0 |

~**600 teardown cycles** across healthy, concurrent, never-connecting, and mid-stream-drop states — **zero
leak, zero `G_IS_OBJECT`, `livePipes` always ≤ cap** (the teardown's `--g_livePipelines` is balanced and the
detached worker's `gst_object_unref` succeeds). So the teardown code (`RtspVideoSource::teardown()`: remove bus
watch → unref bus → clear appsink callbacks → worker `set_state(NULL)`+unref, under the
`kMaxConcurrentTeardowns` semaphore) is **not broadly broken** — the obvious "per-teardown leak" hypothesis is
disproven.

## What could NOT be reproduced (and why)
The crash's `G_IS_OBJECT` + RSS climb. The distinguishing condition is **go2rtc actively OOM-looping** — the
Jun-29 go2rtc OOM alerts coincided with the crash, so the wall's RTSP sources were being dropped abnormally
(abrupt/partial RTSP/RTP, repeated mid-decode loss) by a thrashing go2rtc. A clean socat TCP drop doesn't
replicate that, and **go2rtc instability can't be safely induced** here (it hits the backend + other
consumers). So the root fix can't be validated, and the failed `g_object_unref` is plausibly in GStreamer's
`rtspsrc`/`decodebin` handling of an aborted stream (**upstream**), not our teardown (provably clean otherwise).

## Mitigation 1 (already done) — the trigger is largely removed
The crash's trigger was go2rtc OOM-looping. That's addressed by this session's go2rtc work (the cached +
single-flight + concurrency-bounded snapshot endpoint, keyframe fallback, and the 512→1024 MiB cap raise):
go2rtc stayed **stable (RestartCount 0) across all of today's testing**. The specific instability that drove
the crash is now much less likely.

## Mitigation 2 (shipped + verified) — RSS-shed safety valve
Defense-in-depth against **any** memory runaway (this leak or a future one): `MemTelemetry` checks RSS every
5 s; above `WT_RSS_SHED_MB` (default **5000**; `0` disables) it sets `shedLive`, and `LiveMonitor` collapses
`maxLiveDecodes` → **1**, so the wall sheds live decodes to (now-cheap, cached) **snapshot tiles** — capping
RSS instead of OOM-killing the client. Hysteresis (recover at 85 %) prevents flap.
- **Verified mechanism:** at a 200 MB test threshold the wall shed 4→1 live decodes (`[MEMGUARD] … SHEDDING`),
  RSS capped ~277 MB, frames kept flowing, no flap.
- **Inert by default:** at the 5 GB default, normal use logged `livePipes=4`, RSS 302 MB, no shed.

So a runaway now degrades gracefully (live wall → snapshots, still fully usable) rather than crashing.

## Tooling kept (gated, inert by default) — for a future staged-instability repro
- `WT_WALL_CHURN=<ms>` — each live source repeatedly tears down + rebuilds (the `reconnect()` crash path).
- `WT_WALL_BADURL=<url>` — force pipelines onto a bad/dead source (e.g. `rtsp://192.0.2.1:554/x`).
- `WT_RTSP_TCP` — force TCP-interleaved (so a socat proxy can carry + drop the media).
- `WT_RSS_SHED_MB=<MB>` — the safety-valve threshold (also the verification knob).

## Status
- **Teardown path:** robust (verified across ~600 cycles).
- **Root leak (go2rtc-instability-specific):** OPEN — non-reproducible safely, likely upstream; trigger
  mitigated by the go2rtc fix.
- **OOM crash:** PREVENTED by the RSS-shed valve (graceful degradation). P0 contained.
