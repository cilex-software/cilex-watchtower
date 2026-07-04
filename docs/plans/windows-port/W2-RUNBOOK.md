# W2 On-Hardware Runbook — Windows runtime bring-up

Companion to `W2-runtime-bringup.prompt.md`. This is the step-by-step to run **on the physical
Win10/11 GPU box**, on the same LAN as cilex-vision. Each gate = a command + what PASS looks like.
Automatable checks are wrapped by `packaging/windows/w2-bringup.ps1`; the rest are eyes-on.

## Prereqs (confirmed from the Linux side 2026-07-04)
- Backend up at **`http://192.168.1.79:8000`** (admin/admin), 32 cameras. `.106` =
  `hiwatch-083bc14eff9a` (main-stream, heavy days), `.201` = `hiwatch-0c75d29549ad`. The
  Windows box MUST be on `192.168.1.x` to reach `.79` + the cameras.
- The build is the CI artifact — no compiler needed on the box.

## Step 0 — get the build
1. Open the [windows workflow](https://github.com/romayankin/cilex-watchtower/actions/workflows/windows.yml),
   latest green run → **Artifacts** → download `watchtower-portable` → unzip (e.g. `C:\wt\`).
2. (Or install `watchtower-setup` — same bits, Start-Menu entry.)

## Step 1 — automated harness (launch + live-decode + RSS + crash)
```powershell
cd C:\wt\watchtower-portable
pwsh <repo>\packaging\windows\w2-bringup.ps1 -Dist . -Seconds 45
# hardware-decode enforcement (patent/perf gate):
pwsh <repo>\packaging\windows\w2-bringup.ps1 -Dist . -HwOnly -Seconds 45
```
Reads out PASS/FAIL for: window rendered, no `[WT-FATAL]`, **LIVE wall hardware-decodes
(`d3d11`, no SOFTWARE)**, live pipelines built, RSS bounded. Also prints the decoder lines and
the ffmpeg H.264 encoders present. Artifacts in `w2-out\` (`trace.log`, `render.png`).

**PASS:** `[WT-DEC] using d3d11h264dec (hardware)` (and `d3d11h265dec` for HEVC cams), zero
`SOFTWARE`, `-HwOnly` still builds pipelines (doesn't go black), RSS in a sane plateau.
**If it fails:** read `w2-out\trace.log`. `live_pipelines=0` = backend/login/LAN, not decode
(check the URL + that Live View is enabled server-side). SOFTWARE decode = the bundled
GStreamer d3d11 plugin set is incomplete (see Known issue #2).

## Step 2 — LIVE wall, eyes-on
Launch normally (`.\watchtower.exe` after `set WT_CV_AUTOLOGIN=1`). Confirm:
- the multi-camera wall paints real video; open **Task Manager → Performance → GPU** and see
  **Video Decode** engine active (proves HW decode end-to-end, not just the log).
- fullscreen a tile, swap tiles, change layout — no black tiles, no crash.

## Step 3 — recorded playback, eyes-on (this path is QMediaPlayer/FFmpeg D3D11VA, not `[WT-DEC]`)
`set WT_PLAYBACK_IP=192.168.1.106` then open Playback:
- open a **heavy day** (.106 has multi-thousand-fragment days) → first frame **< 1 s**
  (bounded-window TTFF), GPU Video Decode active, 1440p HEVC smooth at 1×.
- scrub rapidly/chaotically → no GUI freeze (the 2026-07-03 fixes), dead-video recovers < ~2.5 s.
- let it play to a window end → roll-over continues (no stall).

## Step 4 — export matrix
- **STD and HIGH export** of a recent .106 range → clip lands in `Videos\Watchtower`, plays.
  (Plain export = direct download, no ffmpeg — should just work.)
- **Compress / burn-in export** (pick a height, tick name+timestamp) → **EXPECT THIS TO FAIL
  today** with the LGPL ffmpeg (Known issue #1). Capture the exact ffmpeg error for the fix.
- snapshot → lands in `Pictures`.

## Step 5 — platform sweep
Fullscreen + multi-monitor mixed-DPI (manifest is Qt's PerMonitorV2); export-drawer Esc/cancel;
**sleep → resume** mid-session → wall reconnects + playback recovers or fails honestly (no zombie UI);
30-min `set WT_SMOOTHTEST=999999` run → max GUI heartbeat gap < 2 s (GC fix holds on Windows).

## Known issues to expect (from the Linux-side audit — not surprises)
1. **Compress/burn export re-encodes with `libx264`, which is GPL and NOT in the bundled LGPL
   ffmpeg** → those exports fail. On the box run `ffmpeg -hide_banner -encoders | findstr 264`
   to see what IS available (likely `h264_mf` = Media Foundation, LGPL-clean, and maybe
   `libopenh264`). Fix in `src/models/ClipTranscoder.cpp` (`start()`): on Windows use
   `h264_mf`/`libopenh264` with that encoder's rate-control opts (NOT `-preset/-crf`, which are
   libx264-only). The burn-in font path + filtergraph escaping is already Windows-guarded
   (`fontFile()` + `escFilterPath`) but only compile-verified — confirm the overlay renders.
2. **GStreamer plugin bundle completeness** — deploy.ps1 copies a best-effort LGPL subset
   (`gst*.dll`). If Step 1 shows SOFTWARE decode or `live_pipelines=0` with auth OK, a needed
   plugin is missing; `gst-inspect-1.0 d3d11` on the box (from the GStreamer install) lists what
   exists, and widen the subset in `deploy.ps1`.
3. **Custom manifest extras deferred (W4)** — Qt's manifest gives PerMonitorV2 DPI + Win10/11
   compat + asInvoker; long-path awareness + UTF-8 active code page are not yet re-added.
4. **Camera-IP lockout** — reuse the backend proxy paths; don't hammer cameras directly from a
   new client IP (they lock out on repeated probes — see the project memory).

## W2 exit criteria
Steps 1–3 green on at least one GPU (Intel/NVIDIA/AMD), export STD/HIGH working (compress/burn
tracked as a fix if #1 bites), no GUI-thread stalls over 30 min. File every Windows-specific
defect as a dated `docs/perf/2026-…-win-….md`. Then W3 (parity soaks) + W5 (the GPU matrix).
