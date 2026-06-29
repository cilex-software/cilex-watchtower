# Qt-FFmpeg per-open decode leak — deep dive (cause / symptoms / fixes)

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

## Data
`2026-06-29-qt-leak-smaps.csv` (per-region), `…-swdec.csv`, `…-arena2.csv`, `2026-06-29-qt612-leak.csv`;
harness = `WT_HERO_OPENONLY`; samplers = `/tmp/sampler.py` (RSS) + `/tmp/smaps_cat.py` (per-region).
