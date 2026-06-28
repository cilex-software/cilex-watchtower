# Prompt — Fix the Triage-hero frozen seeks (apply the A1 far-seek workaround to EvHeroPlayer)

## Problem
The Triage Queue inline player (`qml/EvHeroPlayer.qml`) freezes on most non-trivial scrubs. Measured with
the `WT_HERO_TEST` harness (commit `6357b80`, graph `docs/perf/2026-06-28-triage-hero-latency-graph.png`),
314 jumps on camera `.106`:

| jump size | froze % | median latency when it *did* render |
|---|---|---|
| ±1 s  | 16 % | 27 ms |
| ±10 s | 62 % | 20 ms |
| ±30 s | 63 % | 20 ms |
| ±1 m  | 57 % | 17 ms |
| ±5 m  | 77 % | 18 ms |

On a frozen seek: `player.position` moves to the target, `playbackState` stays `Playing`, but
`mediaStatus` drops to `LoadedMedia (2)` and **no video frame ever renders** — the picture sticks on the
old frame. Once stuck, the clip stays stuck until re-opened. ~55 % of *all* jumps freeze; the larger the
jump the more it freezes. When a seek does render it is fast (~17–30 ms).

## Root cause
The hero plays the episode's recorded HLS from `POST /review/sessions`. That manifest is a chain of
per-fragment `EXT-X-DISCONTINUITY` segments; Qt's FFmpeg HLS demuxer **stalls when seeking across
discontinuities** → no frame decodes. This is the **identical defect the Playback wall
(`qml/PlaybackScreen.qml`) had**, which was fixed in **A1 (`fb9efa8`)** — but that fix was **never applied
to the Triage hero**. Every hero seek routes through `EvHeroPlayer._seekWall()` → `player.position` (the
transport −10/+10 buttons and the scrubber both call it), which stalls.

## The reference fix, already shipped for PlaybackScreen
- **`fb9efa8`** — `seekToWall(ms)` detects a far target (`compactDuration>60 && |targetPos·1000 −
  player.position| > 20000`) and calls **`seekFar(ms)`**, which **re-opens a short session STARTING ~15 s
  before the target** (`_explicitStart = ms−15000`), with `_pendingSeekMs = ms` applied on load. The target
  then sits near the start of a *fresh short* HLS, so the demuxer never seeks across discontinuities → it
  renders. Near (in-buffer) jumps keep the cheap direct `player.position` seek.
- **`32a0337`** (A1 polish) — decoupled the scrubber **TIMELINE** (`tlStartMs/tlEndMs/tlFrags` — footage
  track, markers, zoom, the operator's whole review window) from the **LOADED PLAYER session**
  (`winStartMs/winEndMs/frags`). A far-seek re-open sets `_seekReopen` so `onSessionReady` swaps **only** the
  player window and KEEPS the timeline; without it, every far seek re-centred the scrubber.

## Task
Make the Triage hero's seeks render at any distance, by porting that pattern into `EvHeroPlayer.qml`:

1. **Far-seek re-open.** In the hero seek path, detect a target outside the cheaply-seekable region (mirror
   `seekToWall`'s >20 s-from-current heuristic). For a far target, instead of `player.position = …`, re-open
   the episode session as a short window **starting ~15 s before the target**:
   `playbackClient.openSession(ev.cam.id, target−15s, episodeEnd+15s, true)` with a pending-seek to the
   target (reuse the `_open()` + `_applySeek` machinery). Keep small in-buffer seeks as direct
   `player.position` — they already render in ~27 ms.

2. **Decouple the hero's transport/scrubber timeline from the loaded player window.** The hero's time
   readout + scrubber reflect `player.duration`/`player.position` (the loaded compact session). After a
   far-seek re-open the loaded window shrinks to `[target−15s, episodeEnd]`, so without a decouple the
   scrubber/time will jump. Mirror the A1 polish: keep the **episode `[start, end]`** (from
   `EventsStore.episodeWindow(ev)`) as the displayed timeline; map player position → wall (`_posToWall`,
   already present for the timestamp overlay) → episode-relative scrubber position. Add a
   `_seekReopen`-style flag so a seek-reopen `onSessionReady` swaps only the player session (`_frags`) and
   keeps the episode timeline + playhead continuity.

3. **Mind the per-open leak.** Re-opening on every far seek MULTIPLIES the per-open session leak (sibling
   prompt `2026-06-28-hero-per-open-leak.prompt.md`, ~6 MB/open). Re-open only when necessary (far seeks),
   and land/coordinate the leak fix first. **The clean long-term fix is the backend continuous-timeline HLS
   already requested in `docs/letters/2026-06-27-playback-seek-discontinuities-and-session-span.md` (Ask 1)**
   — with a continuous manifest, `player.position` seeks just work, and **no** client re-open (or extra
   leak) is needed. The client re-open here is the interim workaround; keep pushing the letter.

## Files
- `qml/EvHeroPlayer.qml` — `_seekWall`, `_open`, `onSessionReady`, the transport block (−10/+10 + scrubber
  bar), `_posToWall`/`_wallToPos`, `EventsStore.episodeWindow` usage.
- `qml/PlaybackScreen.qml` — the **reference implementation**: `seekToWall`, `seekFar`, the `win*`/`tl*`
  decouple, `_seekReopen`, `_applySeek`.
- `qml/EventsStore.qml` — `episodeWindow(ev) → {startMs, endMs}`.

## Verify
Re-run the harness (inert unless set), on-screen so the renderer is live:
```
WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 WT_CV_AUTOLOGIN=1 WT_SECTION=events \
WT_HERO_TEST=1 WT_HERO_AUTOPLAY=1 ./build68/watchtower
```
Analyze with `docs/perf/2026-06-28-triage-hero-latency-analyzer.py` (reads `/tmp/htfull_app.log` +
`/tmp/htfull_samples.csv`). **PASS** = per-step frozen % drops from 57–77 % to ~0 across all jump sizes;
far-jump seek→frame latency becomes the finite re-open latency (~hundreds of ms) instead of frozen; and the
scrubber/timeline does **not** jump on a far seek (the A1-polish on-screen check).

## Gotchas
- heaptrack is unusable on this VA-API/GStreamer/Qt stack — measure via the harness + `/proc` sampler.
- Must build on **Qt 6.8.3 (`build68`) AND 6.4.2 (`build`)**.
- The hero already opens exactly the episode `[start−15s, end+15s]` on the initial open (commit `556760a`);
  keep that, add the re-open only for seeks.
- Auto-commit + push when verified (Conventional Commits + the Co-Authored-By/Claude-Session trailers).
