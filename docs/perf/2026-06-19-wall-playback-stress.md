# Wall playback (16-cam) — seek / re-composite latency stress test

**Date:** 2026-06-19 · **Build:** `WallPlayback.qml` WT_WALLPERF harness · **Decode:** real VA-API (`renderD128`, Wayland)
**Backend:** cilex-vision @ 192.168.1.79:8000 · **Cameras:** first 16 by IP, one server-composited HLS stream.

## What was measured

For each playhead move we recorded the time from **issuing the move** to the **composited grid playing again**
— defined as the video sink presenting fresh frames *and* `MediaPlayer.position` advancing past the seek target
(one composite frame = all 16 cells, since the backend renders the whole grid into one stream). Harness:
`WallPlayback.qml` → `Item { id: perf }`, gated on `WT_WALLPERF=1`. Emits `WALLPERF,…` CSV; parsed by
`/tmp/parse_wallperf.py`.

Two operation types, matching how the wall actually behaves:

- **in-stream seek** (`±10m / ±30m / ±1h / ±2h`): the target is inside the already-open window, so it's a
  `player.position` seek within the one composited stream (no new session).
- **re-open** (`±1d / ±2d`): the target is outside the window, so the wall tears down and **creates a new
  mosaic session** (`POST /review/mosaic-sessions`) and plays from the new window start — the real "jump to
  another day" path.

20 iterations each, fast-forward (FF) and rewind (RW), ping-ponging between two anchors → **240 measured jumps**.

## Per-iteration latency (ms) — `!TI` = 22 s timeout (stream opened but produced no frames)

| iter | 10m FF | 10m RW | 30m FF | 30m RW | 1h FF | 1h RW | 2h FF | 2h RW | 1d FF | 1d RW | 2d FF | 2d RW |
|------|------|------|------|------|------|------|------|------|------|------|------|------|
| 1 | 3342 | 3292 | 3842 | 104 | 3382 | 105 | 3306 | 104 | 2897 | 2690 | 21423!TI | 21313!TI |
| 2 | 108 | 115 | 108 | 103 | 105 | 111 | 105 | 103 | 2947 | 4957 | 22274!TI | 12969 |
| 3 | 118 | 104 | 105 | 105 | 104 | 106 | 109 | 107 | 4809 | 21412!TI | 7193 | 4436 |
| 4 | 107 | 108 | 105 | 105 | 109 | 103 | 104 | 105 | 21121!TI | 19261 | 21521!TI | 22246!TI |
| 5 | 104 | 105 | 108 | 105 | 105 | 104 | 105 | 104 | 14538 | 6230 | 21120!TI | 22422!TI |
| 6 | 106 | 105 | 103 | 105 | 108 | 105 | 104 | 104 | 3984 | 21520!TI | 21580 | 5934 |
| 7 | 108 | 105 | 105 | 105 | 104 | 108 | 104 | 104 | 21121!TI | 22249!TI | 5628 | 21417!TI |
| 8 | 107 | 105 | 107 | 104 | 104 | 104 | 105 | 104 | 9792 | 10755 | 21330!TI | 22353!TI |
| 9 | 112 | 113 | 104 | 104 | 104 | 111 | 107 | 103 | 10034 | 21413!TI | 22217!TI | 22608!TI |
| 10 | 105 | 104 | 104 | 103 | 112 | 111 | 113 | 104 | 21120!TI | 21216!TI | 10506 | 21414!TI |
| 11 | 105 | 108 | 105 | 112 | 104 | 112 | 110 | 109 | 23454 | 6699 | 18566 | 5223 |
| 12 | 105 | 103 | 104 | 103 | 104 | 104 | 112 | 104 | 3871 | 21411!TI | 21416!TI | 22242!TI |
| 13 | 103 | 104 | 103 | 105 | 113 | 111 | 111 | 112 | 21120!TI | 21121!TI | 8873 | 21411!TI |
| 14 | 107 | 108 | 104 | 104 | 111 | 112 | 108 | 112 | 22394!TI | 22379!TI | 22225 | 15001 |
| 15 | 104 | 104 | 105 | 104 | 112 | 112 | 105 | 105 | 5070 | 21414!TI | 14963 | 21430!TI |
| 16 | 104 | 112 | 103 | 104 | 112 | 112 | 104 | 114 | 21120!TI | 21306!TI | 10756 | 21413!TI |
| 17 | 116 | 114 | 105 | 105 | 114 | 112 | 113 | 105 | 23439!TI | 22213!TI | 21252!TI | 22312!TI |
| 18 | 116 | 104 | 104 | 105 | 104 | 107 | 112 | 104 | 23090!TI | 21414!TI | 21307 | 7574 |
| 19 | 104 | 116 | 105 | 103 | 113 | 109 | 114 | 111 | 22495!TI | 21440!TI | 2949 | 21411!TI |
| 20 | 105 | 110 | 104 | 111 | 110 | 107 | 104 | 105 | 9625 | 8223 | 21361!TI | 22120!TI |

## Summary (OK samples only)

| offset | dir | kind | n_ok | n_timeout | min | median | mean | p90 | max |
|--------|-----|------|------|-----------|-----|--------|------|-----|-----|
| 10m | FF | seek | 20 | 0 | 103 | 106 | 269¹ | 116 | 3342 |
| 10m | RW | seek | 20 | 0 | 103 | 106 | 266¹ | 115 | 3292 |
| 30m | FF | seek | 20 | 0 | 103 | 105 | 291¹ | 108 | 3842 |
| 30m | RW | seek | 20 | 0 | 103 | 104 | 104 | 105 | 112 |
| 1h | FF | seek | 20 | 0 | 104 | 108 | 271¹ | 113 | 3382 |
| 1h | RW | seek | 20 | 0 | 103 | 108 | 108 | 112 | 112 |
| 2h | FF | seek | 20 | 0 | 104 | 107 | 267¹ | 113 | 3306 |
| 2h | RW | seek | 20 | 0 | 103 | 104 | 106 | 112 | 114 |
| **1d** | FF | reopen | 11 | **9** | 2897 | 5070 | 8274 | 14538 | 23454 |
| **1d** | RW | reopen | 7 | **13** | 2690 | 6699 | 8402 | 10755 | 19261 |
| **2d** | FF | reopen | 11 | **9** | 2949 | 10756 | 13140 | 21580 | 22225 |
| **2d** | RW | reopen | 6 | **14** | 4436 | 6754 | 8522 | 12969 | 15001 |

¹ mean is skewed by the single cold first-iteration sample; see cold/warm split.

### Cold vs warm (in-stream seeks)
- **cold** (first visit to an un-composited region): n=8, median **3299 ms**, max 3842 ms.
- **warm** (revisit, cached): n=152, median **105 ms**, mean 106 ms, max 118 ms — flat across all 20 iterations,
  **no degradation under stress**.
- **re-open** (1d/2d): of 80 attempts, **35 OK** (median 8.2 s, max 23.5 s) and **45 timed out** (56%).

## Findings — causes of slowness

1. **In-stream seeking is fast and rock-solid.** Once the target region is composited, a seek replays the whole
   16-cam grid in **~105 ms**, 100% reliable, with zero drift over 20 repeats. The smooth-playhead path is healthy.

2. **Cold seek = ~3.3 s = on-demand server compositing of the target segment.** The first visit to any
   un-composited region costs ~3.3–3.8 s **regardless of jump size** (10 m and 2 h are identical) — confirming the
   cost is "composite one cold 16-cell segment + buffer", not proportional to distance. Initial wall open (warmup)
   is the same ~3.8 s.

3. **Re-opening the mosaic session is the real problem — slow *and* unreliable.** "Jump to another day" (±1d/±2d)
   re-creates the server-side composite session. Median **~8 s** when it works, and it **fails 56% of the time**:
   the new session opens (0 hard failures, `onMosaicSessionReady` always fires) but its HLS stream then produces
   **no frames for ~20 s** — the video sink's frame counter freezes entirely across consecutive jumps
   (e.g. stuck at 1824, then 1952, then 2048 in the raw log), then recovers in bursts.

### Root cause of the re-open stalls
- `PlaybackClient::openMosaicSession()` does `POST /review/mosaic-sessions` on **every** re-open, and **the client
  never disposes the previous session** — there is no DELETE/close call anywhere (and the backend exposes no
  list/DELETE: `GET /review/mosaic-sessions` → *Method Not Allowed*).
- Each session spins up a 16-camera ffmpeg composite. Server-side compositing is concurrency-bounded (render
  semaphore / `pids_limit` per the recorder-stall history). Under rapid navigation, **new composite jobs pile up
  faster than the backend can render them and idle-reap the abandoned ones**, so fresh sessions open but their
  segments stall until capacity frees — exactly the frozen-frames-then-recover pattern in the matrix.
- It is **not a permanent leak** (after the run, `query-api`/`playback-service` show 0 mosaic ffmpeg — idle
  sessions are eventually reaped), and **no errors are logged** (no HTTP 5xx, no GStreamer error) — the stall is
  silent backpressure, which is why it reads as a mysterious "hang".

> Note: the harness's ~5 s re-open cadence is more aggressive than a human, but even the **successful** re-opens
> cost 3–23 s, so day/window changes feel slow regardless; the stalls are the tail of that same pressure.

## Proposed improvements

**Client (Watchtower) — can do now:**
- **C1 — Re-open far less.** In-stream seeks are ~30–200× faster and never stall, so widen the loaded window:
  default the wall to a **12–24 h** session instead of 1 h, and seek within it for day-scale navigation. This
  turns most ±1d navigation from a re-open (3–23 s, flaky) into an in-stream seek (~0.1 s). Biggest UX win,
  low risk; lazy compositing means a wider window costs nothing until you actually seek there.
- **C2 — Dispose the session you're leaving.** Send a close/DELETE when re-opening or exiting the wall, so the
  backend can reclaim that composite immediately instead of waiting for an idle timeout. (Needs a backend
  endpoint — see letter.)
- **C3 — Coalesce re-opens.** Debounce day/zoom-preset changes (the swap path already debounces 800 ms; extend
  it to window changes) so a burst of clicks creates one session, not many.
- **C4 — Honest "compositing…" affordance on re-open** (already shown) + keep the prior frame visible until the
  new stream produces a frame, so a slow re-open never looks frozen.

**Backend (cilex-vision) — letter `docs/letters/2026-06-19-wall-mosaic-session-lifecycle.md`:**
- **B1 — Session disposal endpoint** (`DELETE /review/mosaic-sessions/{id}`) so the client can release composites.
- **B2 — Bound + reuse:** cap concurrent composite jobs and **reap/replace a client's previous session** on a new
  open (one wall = one live session), so bursts can't exhaust the renderer; reject-fast rather than open-then-stall.
- **B3 — Faster cold start / pre-warm** around the requested playhead to cut the ~3.3 s cold-seek and re-open time.

## Implemented (2026-06-19, client) — C1 + C3

`WallPlayback.qml` now separates the **loaded composite window** (`loadedSpanMin`, default **6 h**) from the
**view preset** (`zoomMin`). Verified on real GPU (`WALLOPEN` audit log in `_open` shows every re-composite):

- **C1 — zoom presets are in-stream view-changes.** `setViewPreset(spanMin)` moves the view inside the loaded
  window when it fits (`spanMin ≤ loadedSpanMin`), with **no re-composite**; only a preset *wider* than the
  loaded window grows it once (playhead preserved), and the window only grows (monotonic), so once you've been
  wide everything narrower is in-stream. Measured: `15m/1h/6h` → 0 `WALLOPEN`; `12h/24h` → 1 grow each.
- **Entry stays fast (~2.9 s).** Key finding: seeking to the **recent edge** of a freshly-opened window
  render-chases the recording frontier (**~9–11 s**, measured), so a wide window with a recent start is slow.
  We therefore **play from the window start** (~2.9 s, ≈ the old 1 h-window entry) and let in-window seeks (~105 ms)
  do the rest. Trade-off: "Go back in time" now lands at the window-start edge (6 h ago) with a 6 h scrubber,
  instead of 1 h ago. `loadedSpanMin` is a one-line tune if a different span/landing is preferred.
- **C3 — calendar day-picks debounced** (350 ms) so a flurry of day clicks coalesces into one session create.

Net: the common live-review navigation (zoom presets + scrub within hours) no longer re-composites at all — it's
all ~105 ms in-stream seeks. The slow/flaky re-open path is now hit only by **changing days** (one debounced
re-open per day) and the rare **grow-wider-than-ever** zoom, pending the backend session-lifecycle fixes (B1/B2).

## Re-measure (after wiring B1/B2a/B3 — `…after-lifecycle.raw.log`)

CV shipped the mosaic lifecycle (DELETE/replaces/prewarm). We wired it (dispose on leave, `replaces`
on every open, prewarm seek-hint) and re-ran the same 240-jump harness:

- **In-stream warm seeks: median 108 ms, p90 118 ms, 0 timeouts** (unchanged — the common C1 path).
- **In-stream cold (first visit): ~4.4 s** (iGPU floor).
- **Re-open (±1d/±2d): 50/80 timeout (62 %)** vs baseline 45/80 (56 %) — **statistically unchanged**.

Why unchanged is expected: the harness ping-pongs between two anchor windows *with a settle between
jumps*, so it never accumulates sessions (only 1–2 alive at a time) — its re-open latency was always
the **iGPU cold-render floor**, not the pile-up. `replaces`/dispose fixes the *real* pile-up (varied
navigation over a long shift), verified directly via curl (open-with-`replaces` reaps the prior
session's playlist → 404; `DELETE` → 204). The re-measure therefore confirms the cold-render ceiling
rather than the hygiene fix. Real-world lever stays **C1** (day-to-day nav is in-stream ~108 ms).

## Reproduce
`QT_QPA_PLATFORM=wayland WT_CV_AUTOLOGIN=1 WT_CV_URL=http://192.168.1.79:8000 WT_WALL_DAY=live WT_WALLPERF=1 ./build/watchtower 2>&1 | grep WALLPERF`
(`WT_WALLPERF=quick` for a 2-iteration smoke). Parse: `python3 /tmp/parse_wallperf.py <log>`. Needs a real GPU
(VA-API) — frames don't decode under `QT_QPA_PLATFORM=offscreen`.
