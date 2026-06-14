# Investigate & fix client-side mosaic playback preroll

Self-contained brief for a Claude Code session in the **cilex-watchtower** repo.
Measure rigorously, attribute the cost to a stage, fix the dominant one, prove it
with A/B numbers on the real display. No fabricated data.

## Context

Wall playback (`qml/WallPlayback.qml`) renders ONE server-composited HLS stream
through `QMediaPlayer` (Qt 6.4.2 QtMultimedia, GStreamer backend, VA-API HW
decode on the Intel iGPU). Recorded perf (`docs/perf/2026-06-14-playback-perf-report.html`):

- Wall **day-jump → first frame ≈ 4.3–4.6 s** end-to-end.
- Backend cold render re-measured ≈ **1.5 s** (mosaic session create 0.07 s +
  cold segment 1.48 s; backend `3043dbe`). Verified, not the bottleneck.
- ⇒ the remaining **~2.5–3 s is CLIENT-SIDE**: HLS buffering + GStreamer
  prerolling a large 16-cell HEVC composite frame, from `player.source = url`
  (in `onMosaicSessionReady`) to the first frame painted + playhead advancing.

That client preroll is the target. In-session seeks are already fast
(0.3–1.2 s); this is specifically the **cold open / session swap** preroll.

## Goal & acceptance

Cut wall cold-open-to-first-frame from ~4.5 s toward ≤ ~2.5 s **without**
regressing: single-camera playback, the `source=""` unload (2026-06-11
stop()-preroll fix), the render watchdog, the deferred event-seek, or the
round-3 seek/event benches.

Deliver: (1) a measured **stage breakdown** (fetch / pipeline-build / decode /
buffer) for cold+warm × {single, 4, 9, 16 cells}; (2) the dominant stage
reduced, A/B-measured **on the real Wayland display**; (3) a short findings note
in `docs/perf/`. If the root cause is backend (grid resolution/fps), stop and
write a `docs/letters/` letter + `.prompt.md` with the breakdown instead.

## ⚠️ Methodology rule #1 — measure on the real display

`QT_QPA_PLATFORM=offscreen` may bypass or alter the GPU decode path and video
sink, so its preroll is **not representative**. Drive on the real compositor:
`WT_WALL_DAY=<day>` + the `WT_SCREENSHOT`/`WT_SCREENSHOT_MS` hook (renders on the
real Wayland surface), needs `/dev/dri/renderD128`. Offscreen is only valid for
catching QML errors, never for decode/preroll timing.

## Phase 1 — Instrument & decompose (TEMP-VERIFY)

Add timestamped, machine-parseable logging — emit `WTPRE stage=<x> ms=<n>` lines.

Client lifecycle (in `WallPlayback.qml`, and `PlaybackScreen.qml` as the
single-camera control), anchored at `t0 = player.source assignment`:
- `MediaPlayer.onMediaStatusChanged` → log status + elapsed (LoadingMedia,
  LoadedMedia, BufferedMedia, Stalled, EndOfMedia).
- `onPlaybackStateChanged` → PlayingState + elapsed.
- first `position > 0` → elapsed (practical "first presented frame" proxy; the
  existing benches use this).
- precise first frame (optional, better): tap `vout.videoSink.videoFrameChanged`
  → first-frame elapsed.
- `onDurationChanged`, `onSeekableChanged` → elapsed (when the pipeline is ready
  to seek — relevant to the deferred-seek path).

Network stage: `WT_HLS_LOG=1` already logs every proxy request with timing
(`HlsProxy.cpp`) — playlist `.m3u8` fetch + first `seg/N.ts`. Interleave with
`WTPRE` to separate fetch time from pipeline/decode time.

GStreamer stage (the decode suspect):
- `GST_DEBUG="GST_STATES:4,hlsdemux2:5,decodebin:4,vah265dec:5,avdec_h265:4,v4l2*:4"`
  — shows decoder element SELECTED (hardware `vah265dec`/`vaapidecode` vs
  software `avdec_h265`), state transitions, and first-frame latency.
- `GST_DEBUG_DUMP_DOT_DIR=/tmp/dot` → dump the pipeline graph; render with
  `dot -Tpng` and read the decode element + the composite caps (resolution).
  **A software HEVC decode of a ≥1080p composite is the prime suspect.**
- Confirm HW decode actually engaged during preroll: `vainfo` (HEVC profiles),
  and `intel_gpu_top` (is the Video/VEBOX engine busy during the preroll window,
  or is a CPU core pegged → software decode?).

## Phase 2 — Measurement matrix

Cold (untouched window) AND warm (immediate re-open), **3 runs each**, report
median + spread (preroll is load-sensitive):
- **Single camera** .108 (hot HEVC 1440p): baseline preroll — same codec, one
  frame, no composite.
- **Wall grids 1 / 4 / 9 / 16 cameras**: frame resolution scales with the grid.
  Drive via the camera picker or a fixed set per grid.

The decisive comparison: does preroll **scale with grid frame-area** (→
decode-bound) or stay **~constant** (→ pipeline-build / buffer-bound)? And
single-cam 1440p vs a 16-cell composite of similar pixel count isolates
"composite-specific decode cost" vs "raw frame size".

## Phase 3 — Attribute (decision tree)

- **Fetch dominates** (playlist+seg ≫ rest) → backend/proxy; already optimized,
  note residual, done.
- **Pipeline build ~constant across grids** → GStreamer pipeline (re)construction
  on every source swap. Suspect the `player.stop(); source=""` full
  teardown+rebuild.
- **Decode scales with grid/frame-area** → decoder:
  - software fallback (`avdec_h265`, CPU pegged) → force/repair VA-API (element
    rank, or a composite pixel-format/profile the HW decoder rejects).
  - HW but slow → first-keyframe decode of a large frame; likely needs the
    backend lever (lower preroll resolution/fps).
- **Buffer-bound** (long gap LoadedMedia→PlayingState with segments already
  fetched) → playbin/QMediaPlayer pre-roll buffer threshold.

## Phase 4 — Targeted fixes (A/B each, on display)

Apply per the dominant cause; measure before/after:
1. **Warm/persistent pipeline** — reuse the `MediaPlayer` across session swaps
   (swap the playlist without the `source=""` rebuild), or pre-warm a hidden
   pipeline. ⚠️ tension with the 2026-06-11 stop()-preroll re-download fix —
   re-verify that doesn't regress (watch `WT_HLS_LOG` for old-segment refetch).
2. **VA-API HEVC** — if software fallback found, force/repair HW decode for the
   composite caps.
3. **Buffering** — lower the VOD pre-roll buffer threshold so playback starts on
   fewer buffered frames (playbin `buffer-duration`/`buffer-size`, or the
   QMediaPlayer/RHI knobs; mirror what the live path does with rtspsrc latency).
4. **First-frame fast path** — paint the first keyframe before full buffering.
5. **Backend lever (letter, only if client can't close it)** — a low-res poster
   first segment or lower-fps preroll grid, upgraded after first frame.

## Constraints / workflow

- `TEMP-VERIFY` tag on ALL scaffolding (the `WTPRE` bench, env hooks); revert +
  `grep -rn "TEMP-VERIFY\|WTPRE"` clean before commit.
- Build `cmake --build build`. On-display run for real decode timing; offscreen
  only to confirm no QML errors.
- Regression gate: re-run the round-3 seek + event benches and the single-cam
  control; confirm the picker/drag/wall-layout still work.
- Real measurements only; report backend-load dependence (quiet box vs busy) and
  the median+spread, not a single lucky number.
- Commit the genuine fix + `docs/perf/` findings note. Backend cause → letter +
  `.prompt.md` handoff for the cilex-vision session.

## Code pointers

- `qml/WallPlayback.qml`: `MediaPlayer { id: player }`, `onMosaicSessionReady`
  (source set + `play()`), `seekToWall`, `renderGuard`, `VideoOutput { id: vout }`.
- `qml/PlaybackScreen.qml`: single-camera control, same player pattern + the
  `_pendingArmed`/`applyPendingSeek` deferred-seek.
- `src/models/HlsProxy.cpp`: `WT_HLS_LOG=1` per-request timing.
- `src/models/PlaybackClient.cpp`: `mosaicPlaylistUrl`.
- `src/main.cpp`: dev hooks (`WT_WALL_DAY`, `WT_SCREENSHOT[_MS]`), OpenGL RHI
  pinned, NativeTextRendering.
- Stack: Qt 6.4.2 QtMultimedia (GStreamer) · hlsdemux2 (rank primary+1) · VA-API
  · Intel iGPU `/dev/dri/renderD128`. Live path (RtspVideoSource) is a separate
  custom GStreamer pipeline — playback uses QMediaPlayer, don't conflate.
