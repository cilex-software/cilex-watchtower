# Prompt — Wire the Playback wall to continuous-timeline seeks (port the hero's logic to PlaybackScreen)

## Context
Cilex Vision shipped continuous-timeline HLS (`seek_mode:"continuous"`, now the **server default**): one
continuous-PTS timeline instead of a per-fragment `EXT-X-DISCONTINUITY` chain, so a mid-session seek lands
without the FFmpeg `hls.c` stall. We adopted it in the **Triage hero** (`EvHeroPlayer`, commits `8dadde2` +
`7685435`): on a continuous session it seeks **directly** and re-opens only across a kept boundary, with a
freeze-watchdog for the rare cold tail. **The Playback wall (`PlaybackScreen.qml`) still uses its legacy A1
path** — it re-opens a short window for **every** far seek. It needs the same treatment.

Already done for you:
- `PlaybackClient` requests `seek_mode:"continuous"` by default and echoes `meta.seek_mode` (`8dadde2`,
  `requestSession`). **The wall uses the same `PlaybackClient`, so it already RECEIVES continuous sessions** —
  it just doesn't exploit them.
- The C++ passes the per-fragment `discontinuity`/`boundary` fields through to QML (`fo.toVariantMap()`), so
  they're available with no backend or C++ change.
- The boundary marking is **semantic + mode-independent** and `compact_start/end`+`wall_start` are
  byte-identical across modes (verified) — so the existing wall mapping is unaffected.

## The reference (`EvHeroPlayer.qml`)
- `_continuous` from `meta.seek_mode === "continuous"`; parses `disc: !!f.discontinuity` per fragment.
- `seekToWall(wall)`: `_continuous` → seek **directly** (`player.position`), re-open (`_seekFar`) only when
  `_crossesBoundary(currentWall, wall)`; a **6 s last-resort freeze-watchdog** (`seekWatch`) re-opens only a
  genuine >6 s hang. Legacy → the every-far-seek re-open.
- `_crossesBoundary(from, to)`: any frag with `disc && ws in (min(from,to), max(from,to)]`.
- `_frameSeq`: an always-on `vout.videoSink.onVideoFrameChanged` counter feeding the watchdog.

## The KEY difference for the wall
The hero loads the **whole** (short) episode, so direct seeks work anywhere in the loaded session. **The wall
loads a SUB-WINDOW** — `win*` (≈30 min of a multi-hour timeline `tl*`); see the A1 polish (`32a0337`) that
split the loaded player session (`winStartMs/winEndMs/frags`) from the scrubber timeline
(`tlStartMs/tlEndMs/tlFrags`). So the wall must re-open in **two** cases, not one:
1. **Target OUTSIDE the loaded `win*`** → re-open at the target to fetch that region. This is *loading*, not a
   discontinuity — unchanged from A1, and stays even on continuous.
2. **Target inside `win*` but the jump crosses a kept boundary** (`_crossesBoundary`) → re-open.

Otherwise (inside `win*`, same contiguous run) → **direct seek** + the watchdog. The gain: far seeks *within
the already-loaded window* — which today always re-open via `seekFar` — become direct on continuous.

## Task (in `qml/PlaybackScreen.qml`)
1. In `onSessionReady`, parse `disc: !!f.discontinuity` (+ `boundary`) into the loaded-window frags, and set
   `_continuous = (meta && meta.seek_mode === "continuous")`.
2. Add `_crossesBoundary(fromWall, toWall)` over the loaded `win*` frags (mirror the hero).
3. Add the freeze-watchdog: `_frameSeq` (always-on `videoSink.onVideoFrameChanged`), a `seekWatch` Timer
   (6000 ms), `_seekWatchSeq`/`_seekWatchWall`; stop/clear it in `seekFar` and on reset/open.
4. Rework `seekToWall(wall)`:
   - `_continuous` && target is within the loaded `win*` (footage there) && `!_crossesBoundary(curWall, wall)`
     → **direct** `player.position` seek + arm `seekWatch`.
   - else → `seekFar(wall)` (the existing A1 re-open at the target — loads the region; the re-opened window is
     continuous, so subsequent in-window seeks are direct).
   - Keep the legacy branch (the current >20 s `seekFar`) under `!_continuous` for the `WT_SEEK_MODE=legacy`
     diagnostic.
5. **Preserve the tl*/win* decouple** — a continuous re-open still updates only `win*` and keeps the `tl*`
   timeline/scrubber via `_seekReopen` (don't regress `32a0337`).

## Files
- `qml/PlaybackScreen.qml` — `seekToWall`, `seekFar`, `onSessionReady`, the `tl*`/`win*` state, `_seekReopen`.
- `qml/EvHeroPlayer.qml` — the **reference** implementation.
- `src/models/PlaybackClient.cpp` — already done; no change.

## Verify
Run the wall's seek harness (env hooks in `src/main.cpp`: `WT_SEEK_TEST`, `WT_PLAYBACK_IP`, `WT_SEEK_ITERS`,
`WT_SEEK_SPAN`) on-screen against a **continuous** session (the default now; or force
`WT_SEEK_MODE=continuous`). It anchors seeks to `tl*`+playhead across 1 s … 24 h.
**PASS** = all step sizes render (no TIMEOUT); the **re-open rate drops** vs legacy (in-window far seeks now
land **directly**, ~hundreds ms, instead of re-opening); and the `tl*` scrubber/timeline doesn't regress
(the A1-polish on-screen check). Baseline to beat: the legacy A1 run rendered everything (`ok=1524/TIMEOUT=3`)
but re-opened **every** far seek. Cross-check `WT_SEEK_MODE=legacy` still works.

## Gotchas
- Multi-hour timelines have **many** real boundaries (gaps / codec changes H.265 main→H.264 sub) → the
  boundary re-open fires legitimately at each. That's correct — don't suppress it.
- The cold-base latency tail (~2–4 s on cold/far regions) is a known backend prewarm matter (declined for
  now). Don't fix it client-side: the watchdog must **tolerate** it (6 s), not re-open it — a re-open hits the
  same cold base. (See `2026-06-28-continuous-postcache.*` + reply7.)
- Builds must pass on **Qt 6.8.3 (`build68`) AND 6.4.2 (`build`)**.
- Auto-commit + push when verified (Conventional Commits + the Co-Authored-By/Claude-Session trailers).

## After it lands
1. Send Cilex Vision the `WT_SEEK_TEST` numbers — they're expecting confirmation, no backend work
   (thread `2026-06-27-playback-seek-discontinuities-and-session-span`, reply8 loose ends).
2. Then flag **mosaic seeking**: `/review/mosaic-sessions` still emits per-segment discontinuities — ask
   Cilex Vision for the same continuous treatment when multi-cam wall scrubbing starts.
