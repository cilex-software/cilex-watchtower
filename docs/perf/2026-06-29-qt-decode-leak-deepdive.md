# Qt-FFmpeg per-open decode leak — deep dive (cause / symptoms / fixes)

> **✅ RESOLVED 2026-06-29 — read "Revision 3" (bottom) first; it supersedes everything above.**
> The growth is **glibc arena retention** (freed playback buffers the allocator doesn't return to the OS —
> `mallinfo2` in-use stays FLAT while RSS climbs) **+ full-resolution snapshot decode**, **NOT** a Qt-internal
> *unfreed* leak. Localized with an `LD_PRELOAD` malloc-site tracer (`leak-tools/`). Fixed in-client
> (`mallopt`+`malloc_trim` in `main.cpp`; `sourceSize` + provider downscale): **+66 → +39 MB/min (~41 %)**,
> snapshot baseline **323 → 98 MB**. The "Qt-internal/unfixable" and "emergent/profiler-blocked" sections
> below are the (now-corrected) investigation journey, kept for the record.

Investigation of the ~8 MB-per-playback-open leak (the dominant RSS driver), 2026-06-29. Builds on the
localization in `a9d9dd0` (it's the decode path, Qt-internal) and the Qt-6.12 re-bisect
(`2026-06-29-qt-leak-rebisect.prompt.md` — not fixed by upgrade). Method: the `WT_HERO_OPENONLY` harness
(loops event-opens, no seeks) on Qt 6.8.3, with the `/proc` RSS sampler **and** a per-region `/proc/<pid>/
smaps` sampler, plus environment A/Bs.

## Experiments (open-only loop, RSS slope)

| config | slope | reads |
|---|---|---|
| Qt 6.8.3, HW (VA-API) decode — **baseline** | **+66 MB/min** (~8 MB/open) | the leak |
| Qt 6.12.0, HW decode | +68 MB/min | **not fixed by upgrade** (6.8→6.12) |
| `MALLOC_ARENA_MAX=2` | +74 MB/min | **not** glibc arena fragmentation |
| **SW decode** (VA-API broken → FFmpeg SW fallback; CPU 106 %→206 %) | **+64 MB/min** | **HW/SW-agnostic** |

### Memory composition (smaps, ~98 opens, what *grew*)
| region | grew |
|---|---|
| **anonymous mmap** | **+405 MB** (≈ the ~4–5 MB frame buffers — 1440p YUV ≈ 5.5 MB, mmap'd as > 128 KB) |
| **heap** (`[heap]`) | **+220 MB** (the decoder/context structs + small buffers) |
| GPU / DRM (`/dev/dri`) | +0.0 MB |
| dmabuf | +0.1 MB |
| Qt/FFmpeg `.so` | +0.1 MB |

→ **It is CPU RAM (heap + anonymous mmap), not GPU/VA-API surfaces** (those are freed correctly — dmabuf
and DRM are flat).

## Cause

Per `QMediaPlayer::setSource()` (a source-change — every event open, and previously every far-seek re-open),
the Qt FFmpeg backend stands up a decode pipeline (demuxer thread + decoder context + a frame-buffer pool +
the buffered `QVideoFrame`s). **When the source changes (or on `stop()` + `source=""`), the *previous*
pipeline's CPU memory is not fully released** — roughly one frame's worth of mmap'd buffer (~4–5 MB) plus the
context structs (~2–3 MB) per open. The evidence pins it precisely:

- **Not the GPU / VA-API surface pool** — DRM + dmabuf are flat; and it reproduces **identically under
  software decode** (+64 vs +66), so it is HW-path-independent.
- **Not glibc arena fragmentation / retained-freed memory** — `MALLOC_ARENA_MAX=2` does not change it, and
  the leaked buffers are mmap'd (they would be `munmap`'d on `free`, returning RSS, if they were actually
  freed). They are **genuinely not freed**.
- **Not freed by any client teardown** — clearing the source, and destroying + recreating the `MediaPlayer`,
  both still leak (`a9d9dd0`).
- **Persistent across Qt 6.8.3 → 6.12.0** — a backend lifecycle defect, not a fixed-and-shipped bug.

It is a **Qt-internal QtMultimedia FFmpeg-backend defect**: the decoder + its frame pool are not torn down on
source-change. Confirmed unreachable from QML/C++.

## Symptoms

- Process **RSS grows ~6–8 MB every time a recording is opened** (any `setSource`), HW or SW decode.
- ~⅓ heap, ~⅔ anonymous mmap; **linear, no plateau** across the tested ~100 opens ⇒ effectively unbounded
  over a shift.
- Watchtower exposure: a triage/review shift opening *N* events ⇒ ~8·*N* MB. The continuous-timeline work
  already removed the per-*scrub* re-opens, so it is now **per-event-opened only** — but on the 16 GB,
  OOM-sensitive box (shared with the recording backend) a long shift can still push the client to 1–2 GB+.

## Potential fixes (ranked)

1. **Upstream Qt fix (the real one).** The FFmpeg backend must release the prior decoder's frame pool +
   buffers on source-change/stop. **File a Qt bug** with a standalone ~50-line `QMediaPlayer` `setSource`-loop
   reproducer — the diagnosis is clean and damning: HW/SW-agnostic, 6.8.3→6.12.0, ~8 MB/source-change, CPU
   heap+anon, GPU flat. (Reproducer spec in `2026-06-29-qt-leak-rebisect.prompt.md`.)
2. **Reduce source-changes (done where possible).** The continuous-seek + boundary-only re-open work already
   eliminated the per-scrub re-opens (the biggest contributor during active review). The per-event open is
   inherent (different footage).
3. **Operational bound + auto-reset.** Document the ~8 MB/event ceiling; watch RSS; when it crosses a
   threshold, tear down and recreate the **whole playback subsystem** (or relaunch) — note: recreating the
   *player* doesn't free it (tested), so the reset must be at the process/subsystem level. Last resort.
4. **GStreamer backend.** A different decode pipeline that may not leak this way — but Qt's binary releases
   ship **no** GStreamer media plugin (FFmpeg only), so it needs Qt built from source *and* re-validating the
   whole seek model (`hlsdemux2` ≠ `hls.c`). Large; only if the leak becomes shift-breaking.

### Tried and ruled out (do not re-attempt)
source-clear · destroy+recreate the `MediaPlayer` · `MALLOC_ARENA_MAX` · Qt upgrade to 6.12.0 · (the GPU
surface pool is not the leak).

## ⚠ Revision (2026-06-29, later) — the standalone reproducer does NOT reproduce it; the leak is CLIENT-side

Built the minimal `QMediaPlayer` `setSource`-loop reproducer (`qt-leak-repro/`) and ran it every way that
matters — **all plateau**, none reproduce the sustained +66 MB/min:

| reproducer variant | result |
|---|---|
| bare `QVideoSink`, mp4 | plateaus ~190 MB after ~10 opens |
| `QVideoWidget` (on-screen render), HEVC 1440p | plateaus ~330 MB |
| local HLS / HTTP-served HLS (Qt's own libavformat fetch) | plateaus |
| unique URL per open (`?i=N`) | plateaus |
| distinct content per open (6 different 1440p clips) | plateaus |

**A bare QMediaPlayer reaches a bounded ~180–330 MB plateau and stays** — so the sustained leak is **not** a
generic QMediaPlayer/libavformat `setSource` bug, and **not** the bare decode pipeline. **This overturns the
"Qt-internal / file a Qt bug" conclusion above.**

The leak is in the **client's playback integration** — real-backend HLS served through our **`HlsProxy`**
(libavformat → localhost `HlsProxy` → QNAM → query-api), which the synthetic reproducer doesn't exercise.
In-client bisect:
- **`HlsProxy` read-ahead ≈ 18%**: `WT_NO_PREFETCH=1` drops +66 → **+54 MB/min**.
- the remaining ~+54 is the main serve/decode path (proxy `forward` + QNAM + decode of the real segments).

So it is most likely **client-fixable** (the proxy / QNAM segment path), not a Qt bug. **Corrected fix
ranking:**
1. **Localize within the client** — targeted bisection of `HlsProxy::forward` / the segment cache / the shared
   QNAM (heaptrack is unusable on this stack; bisect with gates like `WT_NO_PREFETCH`). The smaps signature
   (heap + anon, ~1–2 segments' worth/open) fits leaked segment `QByteArray`s or QNAM/reply state.
2. **Cheap partial win:** the read-ahead is ~18% — consider disabling it (continuous-HLS already cut the
   seek/re-open need for it), or bounding inflight more tightly.
3. The standalone reproducer is **kept as the control** that rules out the bare Qt player — useful, but it is
   NOT a Qt-bug reproducer (do not file the Qt bug on this evidence).

## Revision 2 (2026-06-29) — exhaustive elimination: the leak is EMERGENT in the full client

Extended the bisection until every isolatable piece was tested. **Everything in isolation plateaus
(~150–330 MB, bounded); only the full client sustains (+66 MB/min):**

| isolated test | result |
|---|---|
| standalone player — bare `QVideoSink` / `QVideoWidget` / **QML `VideoOutput`** (client's exact render path) | plateau |
| × mp4 / local-HLS / HTTP-HLS / **real captured HEVC segments** (file:// AND http://) | plateau |
| × offscreen / on-screen / unique-URL-per-open / 6 distinct clips | plateau |
| **QNAM alone** — 3000 sequential GETs, no player | **flat** (+0.001 MB/GET) |
| **`HlsProxy` internals** (`WT_PROXY_STATS`): cache (LRU-bounded ≤160 MB), inflight ≤2, sockets ≤1, replies ≤3 | **all bounded** |
| client open-only, `WT_NO_PREFETCH` | +66 → +54 (read-ahead ≈ 18 %; rest remains) |

So the leak is **NOT** the player (any output, any content incl. real footage), **NOT** the QNAM, **NOT** the
proxy's tracked objects. It is **emergent in the full client's hero-play path** — reproducible only with the
real app, not with any standalone combination of its parts. (Note: the `HlsProxy` cache is never cleared in
code; the `0`s in the proxy stats were a *second, idle* `HlsProxy` from the Playback-wall client, not a
clear.) The proxy code audits clean (replies/sockets `deleteLater`'d, cache LRU-bounded, 503-retry timers
one-shot).

**Honest conclusion:** the leak resists component-isolation — it is a subtle interaction or an untracked
allocation in the full client's playback path. Black-box bisection has gone as far as it usefully can.
Pinning the exact malloc site now requires a **working heap profiler**, and that is the blocker: heaptrack is
unusable on this VA-API/FFmpeg/Qt stack (per `dev-box`/memory), and valgrind/massif is impractical on the
full client (SW-HEVC × valgrind ≈ unusably slow; VA-API × valgrind ≈ crash). An `LD_PRELOAD` mmap-site logger
(intercept >1 MB allocations + backtrace, aggregate the never-freed ones) is the most promising remaining
tool and the recommended next attempt.

**Corrected fix status:** NOT a generic Qt bug (do not file one), and NOT localized to a single fixable
client component despite exhaustive bisection. **Actionable now:**
1. The leak is **bounded per event opened** (~8 MB × events/shift) and the continuous-seek work already
   removed the per-scrub multiplier — so it is **not shift-breaking today**; document the ceiling + monitor.
2. If it ever is: a **process/subsystem-level reset** at an RSS threshold (player-recreate does NOT free it).
3. `WT_NO_PREFETCH` reclaims ~18 % cheaply (continuous-HLS already cut the seek/re-open need for read-ahead).
4. Kept for a profiler-assisted pass: the control reproducer (`qt-leak-repro/`) + the gates `WT_PROXY_STATS`,
   `WT_NO_PREFETCH`, `WT_DUMP_SEG`.

## Revision 3 (2026-06-29) — SOLVED: localized with an LD_PRELOAD malloc-site tracer

The blocker (Revision 2) was the profiler. heaptrack/valgrind are unusable on this stack, so I wrote a tiny
**`LD_PRELOAD` malloc-site tracer** (`leak-tools/malloctrace.cpp`: interpose malloc/calloc/realloc/
posix_memalign/free, record live ≥16 KB allocations by backtrace, dump the top sites by live bytes + a
`mallinfo2` summary on SIGUSR1). It cracked it on the first run. **The earlier "genuinely not freed /
Qt-internal unfixable" conclusion was WRONG.** Two real, client-side causes:

### (1) glibc arena RETENTION — the dominant +RSS mechanism (NOT an unfreed leak)
`mallinfo2` **in-use (uordblks) is FLAT (~270 MB)** across the whole run while RSS climbs +66 MB/min, and the
mmap tracer found **0 live >1 MB anon mmaps**. So nothing is unfreed. Instead: the large transient playback
buffers churned every open (decoded frames ~5.5 MB, HLS segments, snapshot `QImage`s) ratchet up glibc's
**dynamic** `M_MMAP_THRESHOLD`; later same-size allocations then land in the **main arena** instead of being
individually mmap'd, and their freed space is retained on the arena free-lists (never returned to the OS) and
fragmented by the churn — so the arena high-water-mark grows unboundedly even though *live* bytes are flat.
- **Fix (`main.cpp`):** pin a low fixed `mallopt(M_MMAP_THRESHOLD/M_TRIM_THRESHOLD, 128 KB)` so large allocs
  are mmap'd → `munmap`'d straight back to the OS on free, + a 15 s `malloc_trim(0)`.
- **Measured: +66.3 → +39.2 MB/min (~41 %).** Threshold sweep (open-only slope): **128 KB → +39.2** (sweet
  spot), 64 KB → +52.1, 32 KB → +46.4 — *lower is worse* (small mmaps add 4 KB-page rounding waste). Env
  `WT_MMAP_KB` tunes it.

### (2) Full-resolution snapshot decode — a large bounded baseline
`EvSnapshot`'s two `Image`s (event still + live-frame) had **no `sourceSize`**, and `CvImageProvider` ignored
`requestedSize` — so every snapshot was decoded **and QtQuick-cached at full 2560×1440 (~14 MB)** for
thumbnail/poster display. That was the **#1 live-allocation site at 323 MB** (decoded JPEGs via
`QImageReader`/`QImageIOHandler`).
- **Fix:** `sourceSize: Qt.size(width, height)` on both `Image`s + `CvImageProvider` downscales the `QImage`
  to `requestedSize` before caching. **Baseline 323 → 98 MB.** Bounded, so it doesn't move the *slope*, but
  it's a big RSS + texture-upload saving and removes wasteful churn (which also feeds cause #1).

### Net
Two small, **zero-risk client changes** (no Qt rebuild, no GStreamer switch): per-open growth **−41 %** and the
snapshot baseline **−3×**. The residual +39 MB/min is sub-128 KB arena fragmentation that allocator tuning
can't fully reclaim (lower thresholds regress). The process-level reset (operational mitigation) still applies
for very long shifts — but now at a much lower rate and baseline. **Files:** `src/main.cpp` (mallopt+trim),
`qml/EvSnapshot.qml` + `src/models/CvImageProvider.{h,cpp}` (sourceSize/downscale). **Tooling kept:**
`leak-tools/{malloctrace,mmaptrace}.cpp` (the only profilers that work here) + gates `WT_PROXY_STATS`,
`WT_DUMP_SEG`, `WT_NO_PREFETCH`, `WT_MMAP_KB`.

## Data
`2026-06-29-qt-leak-smaps.csv` (per-region), `…-swdec.csv`, `…-arena2.csv`, `2026-06-29-qt612-leak.csv`;
harness = `WT_HERO_OPENONLY`; samplers = `/tmp/sampler.py` (RSS) + `/tmp/smaps_cat.py` (per-region).
