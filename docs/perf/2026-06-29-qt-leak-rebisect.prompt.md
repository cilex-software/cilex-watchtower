# Prompt — Re-bisect the per-open Qt-FFmpeg decode leak (GStreamer backend, then a newer Qt)

## Problem
Opening a recording leaks **~8 MB per playback open** (per source-change) — the dominant driver of RSS growth
during a triage/review shift (climbs past 1 GB). Bisection (commit `a9d9dd0`) localized it to **Qt's FFmpeg
MediaPlayer decode pipeline**: freed by **neither** source-clear **nor** destroying + recreating the player —
**Qt-internal, not fixable from QML/C++**. The continuous-timeline work removed the per-*scrub* re-opens, so
scrubbing no longer feeds it, but the per-*event* open leak remains. The only levers left are **a different
media backend** or **a newer Qt**. This task measures both.

## Baseline to beat (Qt 6.8.3)
Open-only bisect — the `WT_HERO_OPENONLY` harness loops event-opens (no seeks); `WT_HERO_NOPLAY` opens the
session but skips the decode — + the `/proc` RSS sampler. Data: `docs/perf/2026-06-28-hero-leak-bisect.*`.

| variant | RSS slope |
|---|---|
| open **+ decode** (play) | **+66 MB/min** (~8 MB/open) |
| open, **no decode** (session/proxy only) | **flat (−0 MB/min)** |
| open + decode **+ recreate the MediaPlayer** | **+59 MB/min** (no help) |

Reproduce this **exactly** on each new config and compare the slope.

## Task — find a config that doesn't leak, cheap-first

### Step 1 (cheap, ~hours): the GStreamer backend on the CURRENT Qt 6.8.3
QtMultimedia has two backends; we're on **FFmpeg** (default). The **GStreamer** backend is a different decode
pipeline that may not have this leak — and it's one env var, **no rebuild**:
```
# install plugins first: gstreamer1.0-plugins-{base,good,bad,libav}, gstreamer1.0-vaapi
QT_MEDIA_BACKEND=gstreamer <the usual WT_HERO_OPENONLY run>
```
Re-run `WT_HERO_OPENONLY` + the sampler; compare to +66 MB/min.
- **Flat** → the GStreamer backend fixes the leak with no Qt upgrade. **But it's a fork, not a free win — see
  the caveat — do the full regression pass before adopting.**
- **Leaks, or won't decode** → go to Step 2.

> **Feasibility note (checked 2026-06-29):** this Qt install ships **only the FFmpeg backend plugin** —
> `ls /home/cilex-vision/Qt/6.8.3/gcc_64/plugins/multimedia/` → just `libffmpegmediaplugin.so`, no
> `libgstreamermediaplugin.so`. So `QT_MEDIA_BACKEND=gstreamer` will **fail to load** as-is; Step 1 first
> needs the GStreamer backend plugin — add the Multimedia component via the Qt online installer, or use a Qt
> that ships both plugins. (System libgstreamer is partially present, `gst-vaapi` is absent.) So Step 1 is
> *not* zero-cost on this box; if adding the plugin is awkward, Step 2 (a newer Qt that bundles both) may be
> the better first move.

> **Big caveat (do not skip):** the GStreamer backend swaps the HLS demuxer from libavformat `hls.c` to
> GStreamer's `hlsdemux2`. Per Cilex Vision's reply8 (the hls.js note), hlsdemux2 already seeks across
> per-fragment discontinuities — only `hls.c` stalled. So on this backend **our entire continuous-seek +
> boundary-only-re-open machinery (`EvHeroPlayer` / `PlaybackScreen`) may be unnecessary or even wrong**, and
> VA-API decode + the 16-stream wall behave differently. Treat it as a real platform fork: re-validate every
> seek surface (`WT_HERO_TEST`, `WT_SEEK_TEST`), VA-API hardware decode, and the 3 stress tests before
> adopting. Cheap to *test*, expensive to *adopt*.

### Step 2: re-bisect against a newer Qt (keep the FFmpeg backend)
Install a newer Qt **alongside** 6.8.3 (don't remove it) and add a parallel build:
- Versions, newest-first: the newest available release (6.9 / 6.10), or a 6.12 dev snapshot for the bleeding
  edge. Qt 6.8 is LTS; the next LTS (≈6.11) is the eventual *production* target, but for the leak *question*
  test the newest first (most likely to carry the fix). A non-LTS that proves the leak is fixed still tells us
  it lands in the next LTS.
- Install to `/home/cilex-vision/Qt/<ver>/gcc_64` (online installer or `aqtinstall`); add a `build<ver>`
  CMake dir mirroring `build68`.
Re-run the same open-only bisect; compare to +66 MB/min.
- **Flat** → the upgrade fixes it → recommend it (after the regression pass). Cleanest outcome: keeps the
  FFmpeg backend and all the continuous-seek work intact.
- **Still leaks** → not fixed in that release; try the next, or escalate (minimal reproducer + Qt bug report),
  or accept + mitigate.

## Method (identical to the baseline so slopes are comparable)
1. On-screen: `WT_CV_AUTOLOGIN=1 WT_SECTION=events WT_HERO_TEST=1 WT_HERO_OPENONLY=1 WT_HERO_AUTOPLAY=1
   ./build<ver>/watchtower` + `python3 /tmp/sampler.py <pid> out.csv 300` (sampler reads `/proc/<pid>` RSS+CPU
   every 150 ms; re-create it if gone — columns `t_ms,rss_mb,cpu_pct`).
2. Slope = `numpy.polyfit(relmin, rss, 1)[0]` for `relmin > 0.5` (skip the view-load ramp).
3. Also run `WT_HERO_NOPLAY=1` on each config to confirm the no-decode path stays flat (controls for any
   baseline shift).
4. **Standalone reproducer** (do this for any Qt bug report): a ~50-line Qt app that `setSource()`s a local
   HLS playlist in a loop (open → play 1 s → clear → repeat) and prints RSS — far cleaner evidence than the
   whole client, and it isolates QMediaPlayer from Watchtower.

## Files
- `qml/EvTriage.qml` / `qml/EvHeroPlayer.qml` — the `WT_HERO_OPENONLY` / `WT_HERO_NOPLAY` harness (committed,
  inert unless set).
- `docs/perf/2026-06-28-hero-leak-bisect.{play,noplay,recreate}.csv` + `…-bisect.png` — the 6.8.3 baseline.
- `CMakeLists.txt` + the `build68` invocation — mirror for `build<ver>`.
- `/home/cilex-vision/Qt/6.8.3/gcc_64` — the current Qt; install new versions beside it.

## Decision tree
- **GStreamer flat + passes regression** → switch backend (cheapest *test*, but a fork — re-validate seeks +
  VA-API; the continuous-seek code may become dead/wrong).
- **Newer Qt flat + passes regression** → upgrade Qt (cleaner — FFmpeg backend + continuous-seek work stay
  intact; set the production target to the next LTS).
- **Neither** → accept + mitigate: the leak is bounded **per event opened**, not per frame (~8 MB × events/
  shift), so document the ceiling; if a realistic shift exceeds memory, consider a periodic full
  playback-subsystem teardown (the A2 recreate-hero leaked more, so scope carefully); file the Qt bug with the
  standalone reproducer.

## Result (2026-06-29) — re-bisected against Qt 6.12.0: NOT fixed

Installed Qt **6.12.0** (newest available; `aqtinstall`, beside 6.8.3) and built `build612`. Needed
`-DWT_ONLY_BYTECODE=ON` — **6.12.0's `qmlcachegen` SEGFAULTs during AOT codegen on our QML** (Error 139 on
`Main.qml`), a 6.12.0 toolchain bug; the escape hatch (added to CMakeLists, no-op for the normal builds)
skips AOT and the rest builds clean. Ran the identical open-only bisect (on-screen, FFmpeg backend):

| Qt | open-only RSS slope |
|---|---|
| 6.8.3 (baseline) | +66.3 MB/min |
| **6.12.0** | **+68.1 MB/min** (207→1191 MB, 121 opens) |

**Identical → the per-open leak is NOT fixed through Qt 6.12.0.** Both ship the same FFmpeg backend
(`libffmpegmediaplugin.so`); the leak is unchanged across 6.8→6.12 — a persistent QtMultimedia FFmpeg
per-source-change defect. (Data: `docs/perf/2026-06-29-qt612-leak.{csv,ht.log}`.)

**Step 1 (GStreamer backend) isn't testable from binaries:** both Qt releases ship ONLY
`libffmpegmediaplugin.so` — no `libgstreamermediaplugin.so` — so `QT_MEDIA_BACKEND=gstreamer` needs Qt built
from source with GStreamer enabled (a much bigger task, and it forks the seek model — see the caveat above).

**Conclusion → ACCEPT + MITIGATE + file a Qt bug.** No upgrade fixes it through the newest Qt, and the other
backend isn't in the binaries:
- **Stay on Qt 6.8.3 (LTS)** — upgrading buys nothing for this leak, and 6.12.0's qmlcachegen is buggy for
  our QML.
- The leak is **bounded per event opened** (~8 MB × events/shift); the continuous-seek work already removed
  the per-*scrub* re-opens. Document the ceiling; revisit only if a real shift exceeds memory (then a
  periodic playback-subsystem teardown).
- **File a Qt bug** with the standalone `setSource`-loop reproducer (FFmpeg backend leaks ~8 MB/source-change,
  reproducible 6.8.3 → 6.12.0).
- (Optional, large) build Qt from source with the GStreamer backend and re-test Step 1 — only if the leak
  becomes shift-breaking.

## Gotchas / regression pass (before adopting anything)
- **VA-API hardware decode must still work** — the wall + the 16-stream goal depend on it. Check decode logs +
  real playback, not just "it ran".
- A newer Qt may break the build (deprecated APIs) and/or QML (type changes) — budget for fixes; **6.8.3 AND
  6.4.2 must keep building** (both are required today).
- Re-run the 3 stress tests (resize / seek / events-browse) **and** the continuous-seek tests (`WT_HERO_TEST`,
  `WT_SEEK_TEST`) on the new config — don't trade the leak for a regression.
- The GStreamer-backend seek behavior is **not** the FFmpeg one — the continuous-seek/boundary logic is
  FFmpeg-specific; do not assume it carries over.
- Record the new slope(s) in `docs/perf/`; auto-commit + push the harness/build changes.
