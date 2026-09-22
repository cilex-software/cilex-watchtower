# Playback jump latency: the read-ahead is the whole problem (macOS, measured)

**Operator ask, 2026-09-22:** "measure the time between requesting a video fragment
and it playing — 50 jumps between 22:00 Mon 21 Sep and 03:00 Tue 22 Sep on
192.168.1.117 (10 Улица 15); instrument which functions take what time."

**Answer: a jump takes ~16 s, and ~15.9 s of that is the proxy's own read-ahead
starving the one segment the player is waiting for. Disabling read-ahead makes the
same 25 jumps 21× faster at the median.**

## Method

New harness (`WT_SEEK_COUNT` / `WT_SEEK_WINDOW` / `WT_SEEK_DWELL`, `seekProbe` in
`qml/PlaybackScreen.qml`) drives N scrubber jumps to pseudo-random targets from a
FIXED seed, so two builds hit identical targets. Each jump is timed request →
first rendered frame. `WT_TRACE=1` gives the `[PBTIME]` stage breakdown,
`WT_HLS_LOG=1` the per-segment upstream timings.

Also instrumented: the **in-window direct seek** path (`player.position = pd`) had
no timing mark at all, so half of a scrubbing session was invisible to TTFF, which
only measures an OPEN. Both paths now report `[PBSEEK] kind=far|direct dt=…ms`.

macOS, build 1.1.497, over the tailnet, camera `hiwatch-083bc14f0040`.

**Methodology correction, stated because the first run's numbers are wrong:** run 1
used a fixed 13 s dwell against a 20 s p50, so jumps overlapped and coalesced and
8 landings were mis-scored as lost. The harness now WAITS for each landing. Only
the run-2 numbers below are sound.

## Where the time goes (50 jumps, read-ahead ON)

| stage (dt from the jump) | p50 | p90 | max |
|---|---|---|---|
| `session_http` — CV answers | **218 ms** | 522 ms | 3,606 ms |
| `session_ready` — manifest parsed | 239 ms | 451 ms | 826 ms |
| `source_set` — player handed the URL | **242 ms** | 453 ms | 831 ms |
| `first_frame` | **16,189 ms** | 28,821 ms | 37,181 ms |

Everything up to handing the player a URL costs a quarter of a second. **The other
~15.9 s is entirely inside the fetch of the first segment.** The backend is not the
bottleneck.

## Why that segment is slow

Per-segment upstream timings over the run:

- **884 prefetches, 4,167 MB** vs **196 served, 286 MB** — **14.6× more speculative
  bytes than useful ones**
- Time-to-**headers** on a segment the player is actually waiting for:
  **p50 4,852 ms**, p90 8,079 ms. The upstream has not begun replying for ~5 s.
- Typical line: the needed 322 KB `0.ts` took `ms=8591 hdr=8107` while 5 MB
  read-ahead segments for OTHER sessions were in flight.
- **51 distinct session UUIDs were still being prefetched during the run.** Every
  jump abandons a session, and its read-ahead chain is never cancelled — so the
  waste accumulates across a scrubbing session.

## The A/B (same 25 targets, fixed seed)

| | landed | p50 | mean | p90 | max |
|---|---|---|---|---|---|
| read-ahead **ON** | 23/25 | **15,171 ms** | 13,738 ms | 18,984 ms | 22,004 ms |
| read-ahead **OFF** (`WT_NO_PREFETCH=1`) | **25/25** | **708 ms** | 1,492 ms | 2,616 ms | 9,753 ms |

**21× better at the median, 9× on the mean, and nothing is lost.** With read-ahead
off the run also gets *faster* as it warms (last-third mean 577 ms); with it on the
app degrades instead.

This reproduces and extends the 2026-08-31 finding already in `HlsProxy.cpp`
(read-ahead inflating time-to-headers ~3.6×). What that measurement could not see
is the accumulation: one open pays 3.6×, fifty jumps pay 14.6× because abandoned
chains keep running.

## What to change (proposal, not yet done)

1. **Cancel a session's read-ahead when the session is abandoned.** A jump makes the
   previous session's prefetches pure waste, and they are what starve the new one.
2. **Never prefetch while a player-requested segment is in flight.** The existing
   first-segment exemption (`m_seededSessions`) is per-session and cannot see the
   cross-session contention that dominates here.
3. Until either lands, `WT_NO_PREFETCH=1` is a one-line mitigation with a measured
   21× win for scrubbing — the operator's actual complaint.

Read-ahead exists to make backward seeks inside a warm session cheap (460–670 ms,
measured 2026-06-14). That benefit is real but small, and it is being paid for with
15 s on every jump.

## The exact stack, function by function (one real jump, 22.00 s)

Reconstructed from a single `seekfar` in the 50-jump trace (`WT_TRACE=1`,
`WT_HLS_LOG=1`). Δ is from the moment the operator's jump was issued.

| Δ | function | note |
|---|---|---|
| 0.000 s | `qml/PlaybackScreen.qml:246` `seekToWall()` | operator's jump |
| 0.000 s | `qml/PlaybackScreen.qml:327` `seekFar()` | `_snapToFootage()`, `_obMark("seekfar")` |
| 0.016 s | `src/models/PlaybackClient.cpp:291` `requestSession()` | `POST /review/sessions` dispatched |
| 0.225 s | ← CV replies, **208 ms** | server self-report: `serve 14.6 ms, queue 9.3 ms, index 1.8 ms` |
| 0.225 s | `onSessionReady` (QML) | 61 fragments parsed |
| 0.228 s | `qml/PlaybackScreen.qml:1301` `player.source = …` | **`source_set`, marshal 3 ms** |
| | **— everything above costs 228 ms —** | |
| 0.228 s | AVFoundation asks the loopback proxy for the media playlist | |
| | `src/models/HlsProxy.cpp:182` `onNewConnection()` → `:207` `serveRequest()` → `:449` `forward()` | |
| | `src/models/HlsProxy.cpp:490` `m_nam->get(req)` | **← the stall is here** |
| 8.349 s | ← playlist returns: `ms=8119 hdr=8118 bytes=4797` | **8.1 s to first byte of a 4.8 KB file** |
| 17.066 s | ← second playlist: `ms=8710 hdr=8706 bytes=4797` | another **8.7 s** |
| 17.080 s | `src/models/HlsProxy.cpp:362` `prefetchAround()` | `prefetch-hold first-seg` — the exemption DOES fire |
| 18.129 s | segment `0.ts` served | |
| 22.003 s | `first_frame dt=22003ms` | |

**16.8 s of the 22.0 s is two 4.8 KB playlist requests waiting for a free socket.**

### Why `m_nam->get()` blocks for 8 s on a 4.8 KB object

`forward()` (`:490`) and `startPrefetch()` (`:402`) issue their GETs on the **same
`QNetworkAccessManager`**, and Qt caps that at **6 connections per host**. In the
window above, six read-ahead transfers of ~5 MB each were in flight, for **six
different abandoned sessions** (`679d2917`, `171d3e2c`, `29aac7a3`, `36922ffa`,
`c8a6904a`, `e1e2ae98`). Every connection slot was occupied by megabytes nobody
would watch, so the player's tiny playlist request could not get a socket until one
freed — `hdr=8118 ms` with `work=0 ms` is precisely that: our own code did nothing
for eight seconds, it was queued.

`kReadAhead = 2` (`HlsProxy.h:118`) chains forward, and nothing cancels a chain when
its session is abandoned — which is why 51 session UUIDs were still prefetching
during a 50-jump run. The first-segment exemption is per-session and cannot see this.

**The fix follows directly:** cancel a session's read-ahead when it is abandoned, and
never let read-ahead occupy a connection slot while a player-requested fetch is
outstanding. Either alone breaks the starvation; `WT_NO_PREFETCH=1` proves the
ceiling (p50 15,171 ms → 708 ms).
