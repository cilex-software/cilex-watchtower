# Live open → first real picture — measured 2026-09-08, target 500 ms

**Result (final code, evening): opening a camera from a lit wall shows its picture in
128–212 ms (n=5 first opens, median 164 ms); re-opening inside the 2.5 s parking grace
14–377 ms (n=20, median 44 ms). 25/25 opens under the 500 ms target. Before the fix the same
open measured 1.8–2.5 s in four traced runs. Client-side fix: `RtspVideoSource` PARKS a lit
pipeline for adoption instead of destroying it (`ParkingLot` in `RtspVideoSource.cpp`).**

## Correction of the morning version of this file

The morning version measured "first DECODED frame" with `avdec_h264` and reported warm opens
of 65–183 ms. That probe counted corrupt pre-keyframe frames: joining a held producer,
`avdec_h264` emitted its first buffer at **+137 ms** while `h264parse` saw the first keyframe
at **+1267 ms** (same stream, same minute). The app never shows those frames
(`isEmptyGreenNV12` drops them), so the number that matters is the first REAL picture, and
that is the keyframe wait. The warm-open numbers are withdrawn. The producer-teardown finding
(armed cameras dial cold, 424–1003 ms; letter of this morning) stands — it is the cold-open
cost and is unchanged by this work. `samples.jsonl` keeps the morning probe's raw samples.

## Root cause of the in-app 1.8–2.5 s

`[LIVETIME]` stage markers (`WT_TRACE=1`), one open of 192.168.1.103 from a lit wall,
before the fix:

| stage | after the click |
|---|---|
| `pipeline_playing` | +23 ms |
| decoder chosen (`vah264dec`, hardware) | +255 ms |
| first sample at the appsink (GStreamer thread) | +496 ms |
| first frame delivered to the GUI (`first_deliver`) | **+2298 ms** |
| `playing` | +2299 ms |

The GUI thread was free the whole time (a 20 ms stall detector saw one 207 ms stall at
+240 ms and nothing else). The 1.8 s is the appsink callback discarding green surfaces: a
NEW RTSP consumer joins go2rtc's running producer **mid-GOP** — first buffer a delta frame at
+160–230 ms, first keyframe at **+2.3 s**; keyframe period **3.3 s on `-sub`** (keyframes at
+2298/+5623, +2310/+5621, +2270/+5590 in three joins) and **4.0 s on main** (+2742/+6752).
The VA decoder emits empty surfaces until that keyframe. The wall's cold tiles never wait: a
fresh camera session starts on an IDR (their `first_sample → first_deliver` is 2 ms). Opening
a camera from the wall tore the tile's pipeline down and built a new one — the slow path on
every open. The HD surface showed the identical 2.2 s after its first sample.

Ruled out on the way (so nobody re-runs them): go2rtc contention — 16 simultaneous standalone
opens light at median 502 ms, worst 886 ms; the RTSP handshake under 15 concurrent starts is
7 ms. `rtspsrc`'s UDP-first default — 232–942 ms either way, no fallback lines. The JPEG
snapshot decode on the GUI thread — moved to a worker, no change to the 2 s.

## The fix — park, then adopt

A healthy, already-lit decode pipeline whose owner goes away (tile destroyed, `active`
false, URL changed) is held in a process-wide lot for `WT_PARK_MS` (default 2500 ms; 0
disables) with callbacks detached, its last frame kept and its decoder still running. A
source that wants the same URL inside the grace adopts it: same decoder, keyframe already
seen, last frame shown at once, live samples from the next one. Bounded to `WT_PARK_MAX`
(default 4) — when full, the lot evicts the oldest pipeline nobody is queued for, so the
URL a new view is already waiting on survives a 16-tile teardown. Adoption creates no VA
context, so decode-context churn (the 2026-08-16 relayout-freeze guard) only goes down.
The build pump now defers by one event-loop turn so the old owner's park lands before the
new owner looks. `reconnect()` (watchdog, churn harness) and `setLatencyMs` set `m_noPark`:
a stalled pipeline dies, it is never parked and re-adopted.

## Numbers (final code, 5 cameras × 5 open/close cycles, all 16 tiles decoding)

| camera | first open (wall→detail) | adopted after parking | HD promoted (fresh main) |
|---|---|---|---|
| 192.168.1.101 | 186 ms | +163 ms | 4604 ms |
| 192.168.1.103 | 164 ms | +43 ms | 4604 ms |
| 192.168.1.105 | 156 ms | +39 ms | 4623 ms |
| 192.168.1.193 | 128 ms | +123 ms | 4516 ms |
| 192.168.1.245 | 212 ms | +184 ms | 4691 ms |

- First open (SD adopted): n=5, min 128, median 164, max 212 ms.
- Re-open inside the grace (SD and HD adopted): n=20, min 14, median 44, max 377 ms;
  HD 35–438 ms, median 99.
- Close → the wall tile re-adopts the detail view's pipeline: n=20, 2–15 ms, median 7.
- No crash, no `[WT-SWD]`, no adopt refusal across 25 cycles (`dist-*.log`, each ended by
  the harness SIGTERM at 44 s).

The remaining ~160 ms is the view switch itself (16 tile teardowns and the detail view's
QML, a 231 ms GUI stall in the traced run), not video.

## What is still slow, and why

- **HD promotion on a first open: 4.5–4.7 s (n=5).** The main stream is always warm (the
  recorder consumes it) so a fresh consumer joins mid-GOP on a 4.0 s GOP, and HEVC parameter
  sets arrive in-band so the decoder is only chosen at the keyframe. SD is on screen from
  ~160 ms; HD replaces it in place. Server-side bound — letter to CV of 2026-09-08 (evening).
- **A tile beyond `maxLiveDecodes`** (snapshot + warm-keep) has no decoded pipeline to park
  → fresh build → keyframe wait, 0–3.3 s. The default cap is 64 (`Settings.cpp:30`), so a
  16-wall decodes every tile; the cap only bites where an operator lowered it.
- **Cold opens of armed cameras** (producer dropped at last-consumer exit) — unchanged,
  morning letter.
- **Wall relight after returning from the detail view** — not measured here (the harness
  re-opens within 500 ms). Bounded by the build stagger (120 ms per tile) plus cold producers.

## Reproduce

```
B=<station token>   # ~/.config/watchtower-warden/warden.conf, 0600 — never paste it anywhere
WT_STATION_TOKEN=$B WT_CV_URL=http://127.0.0.1:8000 WT_TRACE=1 WT_MAX_DECODES=16 \
  WT_FOCUS_IP=192.168.1.103 WT_FOCUS_DELAY_MS=12000 WT_FOCUS_CLOSE_MS=6000 timeout 44 ./run.sh
grep -E "LIVETIME\] (open|playing|adopted|hd_promoted|close)|WT-PARK" <log>
```
`WT_FOCUS_DELAY_MS` waits for the wall to light before the click (otherwise the hook measures
a cold open the instant `/streams` lands); `WT_FOCUS_CLOSE_MS` closes the view so the same
run measures the return path. `WT_PARK_MS=0` is the A/B switch back to the old behaviour.
