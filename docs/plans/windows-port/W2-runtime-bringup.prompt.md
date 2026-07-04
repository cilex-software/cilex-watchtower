# Prompt W2 — Runtime bring-up on real Windows (both video paths, hardware decode)

## Status
OPEN. Depends on W1 (CI artifacts exist). **NEEDS: one physical Win10 or Win11 machine
with a real GPU** (Intel/NVIDIA/AMD — any one to start) on the same LAN as the
cilex-vision backend (`http://192.168.1.79:8000`, cookie auth admin/admin on the dev
deployment; cameras 192.168.1.x). This is the plan's only external dependency and its
highest-risk phase.

## Context — the two video paths and what "works" means
**Qt 6.12 msvc2022_64 MANDATORY.** Install the W1 portable zip (or installer) on the box.

1. **Recorded playback** (PlaybackScreen/EvHeroPlayer → QMediaPlayer → Qt FFmpeg backend →
   localhost HlsProxy): expected near-out-of-the-box. Qt ships the same
   `ffmpegmediaplugin` on Windows with **D3D11VA** hwaccel — no Microsoft Store HEVC pack
   involved (FFmpeg talks to the driver, not Media Foundation). Verify 2560×1440 HEVC
   day-playback decodes on GPU (GPU engine usage in Task Manager + smooth 1×).
2. **Live wall** (RtspVideoSource → custom GStreamer pipeline → QVideoSink): needs the
   bundled GStreamer d3d11 decoders. Run with `WT_TRACE=1` and confirm
   `[WT-DEC] using d3d11h264dec (hardware)` (and h265 where cameras are HEVC) — then
   `WT_HW_ONLY=1` must still build pipelines (it refuses software decoders; if the wall
   goes black under it, decodebin ranked a software path — diagnose plugin set/driver).
   Validate the NV12 negotiation path renders correct colors on the D3D11 RHI
   (`isEmptyGreenNV12` empty-frame drop must still trigger on idle channels).

## Task
1. First launch + login + Live wall on the GPU box; capture `[WT-DEC]` lines; screenshot.
2. Playback: open a heavy day (.106 has multi-thousand-fragment days), verify TTFF <1 s
   bounded-window behavior, scrub (coalescing), export STD+HIGH (HIGH on a recent window),
   export with compression/burn-in (exercises bundled **ffmpeg.exe**), snapshot
   (lands in `Pictures`), clips in `Videos\Watchtower`.
3. Platform sweep: fullscreen/multi-monitor + mixed DPI (manifest is PerMonitorV2),
   Esc/focus in the export drawer, UTF-8/long paths (manifest declares both),
   sleep→resume → live wall + playback session recovery.
4. `[WT-MEM]`/`[MEMTEL]` telemetry sanity (the W0 PSAPI port) — plausible RSS numbers.
5. File every Windows-specific defect as its own dated
   `docs/perf/2026-…-win-….md` finding (house style), fix in-place where small; anything
   structural gets its own prompt.

## Verify (the phase gate)
- 9-camera live wall @ hardware decode (`[WT-DEC]` proof, `WT_HW_ONLY=1` clean) on the GPU
  box; RSS in the plateau band.
- Full playback loop green: calendar → day open → scrub/coalesce → far-seek → export
  (all quality paths incl. ffmpeg post-process) → snapshot.
- No GUI-thread stalls: `WT_SMOOTHTEST=999999` heartbeat gap analysis over a 30 min
  interactive session — max gap <2 s (the 2026-07-03 GC fix must hold on Windows too).

## Gotchas
- **All gates on-hardware.** Windows offscreen QPA is unvalidated (the Linux 6.12
  offscreen SIGBUS story) — never smoke-test decode paths offscreen.
- Camera-IP lockout caveat applies from a NEW client IP too (see memory: cameras lock out
  on repeated probes) — reuse the backend proxy paths, don't hammer cameras directly.
- If d3d11 HEVC is missing on a given driver: document GPU/driver, test H.264 cams first,
  and check the bundled GStreamer version's d3d11 plugin coverage before blaming drivers.
- Auto-commit + push fixes when verified, per the working agreement.
