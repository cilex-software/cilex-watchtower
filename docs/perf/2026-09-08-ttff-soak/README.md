# Open-latency soak — playback ≤ 1 s · 16-wall ≤ 2 s · live ≤ 500 ms (2026-09-08)

**Result so far, one sentence per target.** LIVE is met (141–216 ms, 6 of 6 baseline
cycles; 128–212 ms in the morning's five-camera run). PLAYBACK is met when the pilot's
database is idle (284 and 690 ms) and missed or failed when it is not (1,827 / 5,690 ms,
two runs with no frame inside 70 s) — the request itself costs the server 155–163 ms.
The 16-WALL cannot meet 2 s from the client: on an idle server the mosaic session create
plus the first rendered segment is 2.3–2.6 s before our player has a byte, and on the
loaded server every wall run either got no session inside 150 s or **crashed** in the
FFmpeg VA-API path (4 of 5). Fixes shipped for the client's share of both; the rest is
in two letters to CV (keyframe period; IO-bound database).

The credential: the operator created the `soak` account this afternoon
(`~/.config/watchtower-warden/ttff-soak.cred`, 0600, operator role) — the first
review-scoped login this box has had, so these are the first playback/wall numbers.

## Harness

`tools/ttff-soak.sh --cycles N --out <rows.jsonl>`: per cycle one playback open
(`WT_PLAYBACK_IP` + `WT_TTFF_DAYS`, `[TTFF] ttff=`), one wall open (`WT_WALL_DAY=live`,
`[WALLTIME] first_frame dt=`), one live open from a lit wall (`WT_FOCUS_IP` +
`WT_FOCUS_DELAY_MS=12000`, `[LIVETIME] playing dt=`). Camera 192.168.1.105
(hiwatch-083bc17adca6: records continuously AND sits on the wall's first page). Rows carry
the git rev + binary time; logs of runs that miss are kept in `<out>-logs/`. Launched
detached (`systemd-run --user`) with the warden stopped. Two harness defects found and
fixed today, both of which had made earlier numbers wrong:

- `WT_PLAYBACK_DAY` boot-opened the day COLD (whole-day manifest, 12–17 s of server index)
  and the measured click 12 s later landed on top of it. Dropped from the driver.
- The wall's `[WALLTIME] first_frame` hook was enabled only while `_settling` (a seek
  state) — a fresh open could never report a frame. Armed on fresh opens now.

## Baseline (6 cycles, binary `e9bfda5`, 11:33–11:54 UTC)

| cycle | playback (ms) | wall | live (ms) |
|---|---|---|---|
| 1 | 5,690 | session 19.8 s → **crash SIGABRT** at +80 s | 141 |
| 2 | no frame in 70 s | no session in 150 s | 193 |
| 3 | 1,827 | session 10.6 s → **crash SIGABRT** | 159 |
| 4 | **284** | session **0.28 s** → **crash SIGSEGV** | 210 |
| 5 | 690 | session 30.4 s → **crash SIGSEGV** | 141 |
| 6 | no frame in 70 s | no session in 150 s | 216 |

`baseline.jsonl`, logs in `baseline-logs/`. The wall column shows `session_ready`; no wall
run reported a frame — partly the crash, partly the blind hook above.

### What the same request costs, by load (server's own `Server-Timing`)

Bounded 30-min session, 61 fragments, `POST /review/sessions`: `index;dur` **91–126 ms**
on an idle server (replay), 429–875 ms with our own second session in flight, 4,046 ms
with one orphaned mosaic chase running, ~28,000 ms with two. 16-camera mosaic, 6 h window,
3,594 fragments: **275 ms** idle (cycle 4), 10.6 s, 19.8–22.4 s, and no answer inside
150 s as the load grew. `GET /streams` (243 KB) 2.9–14.2 s; `GET /review/coverage`
(1.2 KB) 13.2–30.2 s (`acquire;dur=6426, db;dur=7068`). A 15-minute wall entry window
was tried on the fragment-count theory and withdrawn: the window is not the cost.

### What the database was doing

`docker stats` at 11:41 UTC: timescaledb **149 % CPU** (859 MB / 1.2 GB), recorder-service
80 %, query-api 41 %. `pg_stat_activity`: 15 active backends, all `wait_event_type = IO`;
the shapes were the coverage day-group aggregate over `video_segments` (×2, 4–7 s), `SELECT
SUM(bytes) FROM video_segments` (6 s) and `COUNT(*)` over events joined to cameras and
groups (4 s) — i.e. `/review/coverage`, `/health`, `/events`. Request mix in the ten
minutes around it: 82 × `/events`, 33 × `/streams`, 17 × `/health`, 6 session creates —
our events rail polls every 15 s per app instance and the soak ran three instances a cycle,
so part of that load is ours. Letter: `docs/letters/2026-09-08-the-database-is-io-bound-…`.

### The wall crash, end to end

Every crash followed the same lines: `Packet corrupt (stream = 0, dts = 525000)` and
`(dts = 532500)` at the head of **every** mosaic segment (the validation run: 44 in 80 s
with zero 503s and zero proxy retries — so not truncation; the segments look cut mid-PES),
then `vaSyncSurface failed`, `Failed to sync surface`, `Error transferring the data to
system memory: -5`, `Cannot map a video frame in ReadOnly mode!`, and heap corruption at
the next `free` — in the QML GC (`free(): invalid next size (fast)`, SIGABRT) or in Mesa's
gallium worker (SIGSEGV). Six of the seven wall runs that got a session died (baseline
4/5, validation 2/2 — the second with `QT_FFMPEG_DROP_CORRUPT_FRAMES=1` and the proxy
relaying whole TS packets: the decode itself corrupts, so dropping frames afterwards
cannot help). `live_pipelines=0 parked=0` at every crash: the live parking change was not
involved. Same neighbourhood as the July `QFFmpegVideoBuffer` work (`docs/qt-upstream/`),
a different failure mode. The `Stream ends prematurely at N, should be
18446744073709551615` line I read as truncation this morning is FFmpeg's message for any
close-delimited body of unknown length ending; it appears on clean segments too.

### Orphaned chases

A crashed client cannot `DELETE` its mosaic session; two were still rendering when found
and deleted by id at 11:41 (`204` ×2; five more `204`s at 11:55 after the baseline). The
table above is what they cost everyone in between.

## Replays on an idle server (12:55–12:58 UTC, `replay.py`)

Single-camera: create 155 / 163 ms, playlist 12–22 ms, first segment (419 KB, head_split,
cache hit) 56–67 ms, second segment (4.07 MB) 141–359 ms. Mosaic, 6 h window: create
666–850 ms; `seg/0` **404 immediately after** — it is rendered on demand — then served
**2,027 / 2,140 ms** after create with `prewarm_at: 0` and **2,977 / 4,125 ms** without,
the create no slower with it (285–460 vs 1,410–1,702 ms); `seg/1` still 503 the moment
`seg/0` lands. So the server-side floor for the wall is ~2.3–2.6 s before the client's
own HLS start (measured 0.6–1.3 s on single-camera opens).

## What changed in the client (this build)

- `HlsProxy`: streamed TS bodies are handed to the player in whole 188-byte packets; the
  remainder is written only on a clean finish, dropped on a mid-body failure.
- `PlaybackClient`: the mosaic session id is persisted at create (`mosaic/lastSession`),
  cleared on dispose, and any id found at the next open is deleted first.
- `WallPlayback`: `prewarm_at: 0` on create (measured above); `[WALLTIME] mediaStatus /
  playbackState / error` stage lines (the gap after `source_set` was unattributable);
  `first_frame` armed on fresh opens; coverage union fetched after `session_ready`, not
  against it; the 6 h window kept, with the measurement in its comment.
- `PlaybackScreen`: the network coverage refresh is deferred behind the first frame when
  the disk cache already has the camera (bounded at 4 s).
- `tools/ttff-soak.sh`: no cold boot-open; kept logs; wall timeout knob; build stamp.

## Validation on the fixed build (2 cycles, binary 14:59, `QT_FFMPEG_DROP_CORRUPT_FRAMES=1`, 12:00–12:06 UTC)

| cycle | playback | wall | live |
|---|---|---|---|
| 1 | 23,327 ms — `fast_open_from_cache` as designed, then `index;dur=14,762` for the 61-fragment session (91–126 ms idle 20 min earlier), coverage 26.6 s, `/streams` 15.4 s; recorder-service at 277 % CPU, timescaledb 160 % | session 11.9 s, **first frame 34.6 s** (`mediaStatus=2` 22.5 s after `source_set`: the on-demand render), then **crash SIGABRT** at ~82 s — `Packet corrupt` ×44 at the head of every segment with zero 503s and zero retries, one `vaSyncSurface failed` | **170 ms** (adopted, `parked_for=14ms`) |
| 2 | no session answer in 70 s | no session answer in 150 s (`cells=?`) — the crashed cycle's chase was still running: the persisted id never reached disk (QSettings syncs lazily; fixed with `sync()`) | **128 ms** |

`validate2.jsonl`, all logs in `validate2-logs/`. What this proves: the wall's first-frame
marker now reports; the corrupt-frame drop does not prevent the crash (the decode itself
corrupts); the coverage deferral engaged on the open path but not on `onCamerasResolved`
(fixed); the reaper needs an immediate `sync()` (fixed). What it cannot prove: any
playback or wall number under a loaded pilot database — see the baseline section.

### Software decode for the FFmpeg backend (`QT_FFMPEG_DECODING_HW_DEVICE_TYPES=,`, 2 wall runs, 12:07–12:13 UTC)

| run | session_ready | first frame | corrupt packets | VA failures | outcome |
|---|---|---|---|---|---|
| 1 | 768 ms | 8,467 ms | 130 | **0** | played the full 150 s (harness SIGTERM) |
| 2 | 575 ms | 6,315 ms | 118 | **0** | played the full 150 s (harness SIGTERM) |

Mid-run server load with one mosaic session playing: timescaledb 58–59 %, query-api
20–86 %, recorder-service 103–181 %. Idle afterwards (no session alive): timescaledb
2–9 %, query-api ~1 %, recorder-service 238–302 % — the recorder's own motion pipeline
(≈5 `motion_event_received` a second, alert-stream reconnects, segment uploads), not ours.
Qt reads the env once into a static (`qffmpeghwaccel.cpp`, `HWAccel::decodingDeviceTypes`),
so it is process-wide: the app now exposes it as `WT_PB_SW_DECODE=1` (set in `main()`
before the backend loads), default off. The overnight soak runs with it on and prices it
on single-camera 1440p HEVC playback; the product default is decided from that data.

## Overnight

Three units, one binary (14:59 → `d0220af`), all with `WT_PB_SW_DECODE=1`, the warden
stopped for the duration and restarted by the last unit at its end:

| unit | rows | cycles | cadence | why it ended |
|---|---|---|---|---|
| `ttff-overnight-0908-1518` | `overnight.jsonl` | 41 (12:19–15:21 UTC) | wall 150 s, pause 30 s | stopped by me: the soak was feeding the evening saturation — a wall stage killed at its timeout left its 6 h chase running through the next playback measurement |
| `ttff-overnight-0908-1824` | `overnight2.jsonl` | 4 (15:25–15:48) | wall 90 s, pause 240 s, per-cycle disposal | stopped by me: the driver's disposal answered 401 (cookie-jar replay of the HttpOnly cookie) |
| `ttff-overnight-0908-1853` | `overnight3.jsonl` | 9 (15:53–16:51) | wall 90 s, pause 240 s, disposal via the login-body token (204 ×8, verified in-soak) | died silently: a wall stage with no session line made the driver's `sid=$(grep …)` pipeline fail under `set -euo pipefail` |
| `ttff-overnight-0908-1954` | `overnight4.jsonl` | up to 100 (from 16:54) | as above, both new pipelines `\|\| true`-guarded | the night's run |

Also in the timeline: query-api was recreated at 14:19:24 UTC (restart count 0, exit 0 —
a deploy on CV's side, not a crash); the driver's login probe answered `000` at 15:22 (a
10 s timeout against the saturated backend), so the launcher now retries the probe every
two minutes instead of giving up. Miss logs sit in `overnight*-logs/`. One caveat on every
row: the pilot's database load, not this client, decides most playback and wall numbers —
`docker stats`/`pg_stat_activity` samples in the sections above are the evidence.

Morning job: per-target distribution over all three files (`replay.py`'s sibling
`soak-progress.py` in the session scratchpad prints it), crash count (expected 0 with
software decode), the software-decode cost on single-camera playback against the
afternoon's hardware-decode rows, and the `WT_PB_SW_DECODE` default decision.
