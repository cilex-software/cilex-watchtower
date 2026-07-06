# Windows compress/burn export encoder — libx264 → libopenh264 (2026-07-06)

W2 known-issue #1. The compress/burn export (scale and/or burn-in overlay) re-encodes with
`libx264`, which is GPL and **not** in the LGPL ffmpeg we bundle, so those exports fail on Windows.
(Plain STD/HIGH export is a direct download — no ffmpeg — and is unaffected.)

## Measured (bundled ffmpeg on the box)

`ffmpeg -hide_banner -encoders | findstr 264` on the shipped `ffmpeg.exe`
(N-125444, LGPL): `--disable-libx264` confirmed. Available H.264 encoders:

| encoder | type | portable across GPUs? |
|---|---|---|
| `libopenh264` | software (LGPL) | **yes** — identical on any GPU |
| `h264_mf` | Media Foundation (HW via OS) | yes (Windows), but pickier rate-control |
| `h264_nvenc` / `h264_qsv` / `h264_amf` | vendor HW | no — GPU-specific |

`drawtext` (libfreetype) + fontconfig + harfbuzz are all enabled, so the burn-in overlay works;
the font path (`C:/Windows/Fonts/segoeui.ttf`) and filtergraph escaping were already Windows-guarded.

Encoder verified with the app's `scale + drawtext` filter against the bundled ffmpeg → **clean
H.264 mp4, decodes clean** (`h264 Constrained Baseline, yuv420p`). `-preset`/`-crf` are libx264-only
and are dropped on Windows.

## Fix (`src/models/ClipTranscoder.cpp` — `start()`)

`#if defined(Q_OS_WIN)` branch encodes with **libopenh264** and a resolution-scaled average bitrate
(`-b:v = clamp(refH²/180, 800, 8000) kbps` → ~1.3 M @480p, 2.9 M @720p, 6.5 M @1080p); Linux keeps
`libx264 -preset veryfast -crf 23`. Shared `-pix_fmt yuv420p -movflags +faststart`.

**Why libopenh264 (not h264_mf / nvenc):** software encode is deterministic and identical across the
whole W5 multi-GPU matrix (Intel/NVIDIA/AMD); export clips are short and not latency-sensitive, so
the CPU cost is acceptable, and it avoids h264_mf's per-driver rate-control quirks.

## Status

Encoder + filter validated on-hardware via the bundled ffmpeg. End-to-end through the app's export
UI (real recorded clip, exact timestamp-expansion escaping) is a remaining W2 eyes-on gate.
