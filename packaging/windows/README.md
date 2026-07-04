# Cilex Watchtower — Windows packaging

[![windows](https://github.com/romayankin/cilex-watchtower/actions/workflows/windows.yml/badge.svg)](https://github.com/romayankin/cilex-watchtower/actions/workflows/windows.yml)

Scaffold for building and shipping Watchtower on **Windows 10/11**. The app's C++/QML core is
cross-platform; only the files here plus the `if(WIN32)` block in the top-level `CMakeLists.txt`
are Windows-specific. **Nothing here is compiled on Linux/macOS** (the block is inert off-Windows).

## Status — W0 + W1 done (CI builds a Windows .exe + installer on every push)
- **W0** — source is MSVC-ready: the Linux-only bits in `src/main.cpp` and
  `src/models/MemTelemetry.cpp` are `Q_OS_*`-guarded with Windows counterparts (PSAPI RSS, SEH
  crash filter), the `windows` CMake preset + PSAPI link are in place, `watchtower.ico` generated.
- **W1** — `.github/workflows/windows.yml` builds `watchtower.exe` on `windows-2022` (Qt 6.12
  msvc2022_64, GStreamer 1.26.11) and uploads a portable zip + NSIS installer **on every push**.
  This PROVED the W0 MSVC compile (main.cpp + MemTelemetry.cpp compile + link under cl.exe).
- **Next (W2)** — runtime bring-up on a real GPU box: both video paths + D3D11 hardware decode.
  Full plan: `docs/plans/2026-07-04-windows-port-plan.md` + `docs/plans/windows-port/W0..W5`.

## Getting a Windows build (no Windows machine needed)
Every push to `main` (and every PR) runs the **windows** workflow. To fetch a build:
1. Open the [windows workflow runs](https://github.com/romayankin/cilex-watchtower/actions/workflows/windows.yml)
   and click the latest green run.
2. Download from **Artifacts**: `watchtower-portable` (unzip → run `watchtower.exe`) or
   `watchtower-setup` (the NSIS installer). Artifacts keep for 90 days; a `v*` tag publishes a
   permanent installer on the GitHub Release.

**Caveat (W2):** the login screen renders from the portable zip, but the **GStreamer plugin
subset** for the live wall is still being finalised on-hardware in W2 (deploy.ps1 copies it
best-effort and logs what it bundles). Recorded-playback + live-wall decode are validated in W2.

## Files
| File | Purpose |
|---|---|
| `app.manifest` | Win10/11 compat, long-path awareness, per-monitor-v2 DPI, UTF-8, UAC `asInvoker`. |
| `watchtower.rc` | Embeds the manifest + version info + the app icon. |
| `watchtower.ico` | App icon (7 sizes 16–256), generated from `assets/images/cilex-logo.png` (Pillow ICO). |
| `fetch-gstreamer-windows.ps1` | Download the GStreamer-for-Windows MSVC runtime. |
| `deploy.ps1` | `windeployqt` (Qt runtime) + the GStreamer LGPL-plugin bundle → a self-contained dist. |
| `installer.nsi` | NSIS installer skeleton (WiX/MSIX are alternatives). |

## Build & package flow (on Windows)
1. **Qt 6.12** (same version as the Linux primary — **mandatory**, not 6.8.3):
   `aqt install-qt windows desktop 6.12.0 win64_msvc2022_64 -m qtmultimedia qtshadertools`
   (Use the latest available 6.12.x if 6.12.0 has aged off the mirror — stay on the 6.12 line.)
2. **GStreamer** — install the MSVC **runtime + development** MSIs (devel is needed to *build*), or run
   `fetch-gstreamer-windows.ps1` for the runtime. Point `PKG_CONFIG_PATH`/CMake at the GStreamer dev
   so the existing `pkg_check_modules(GST ...)` in `CMakeLists.txt` resolves.
3. **Configure + build** (the `windows` CMake preset sets generator/paths — needs `QT_ROOT_DIR`
   + `GSTREAMER_ROOT` in the environment):
   ```
   cmake --preset windows       # or: cmake -G Ninja -B build-windows -DCMAKE_PREFIX_PATH=<qt>/6.12.x/msvc2022_64
   cmake --build build-windows
   ```
4. **Deploy**: `cmake --build build-windows --target deploy-windows`  (runs `deploy.ps1`).
5. **Verify hardware decode** (critical — perf + codec-patent exposure): run with
   `WT_TRACE=1` and `WT_HW_ONLY=1` and confirm the log shows `[WT-DEC] ... d3d11h264dec (hardware)` —
   never `avdec_* (SOFTWARE)`. (See `docs/DEVELOPMENT.md`.)
6. **Package**: `makensis installer.nsi`.

## GStreamer plugin subset — LGPL only
Watchtower uses GStreamer directly, so `windeployqt` does **not** bundle it. Ship ONLY the LGPL
plugins our pipeline (`rtspsrc ! decodebin ! videoconvert ! NV12 ! appsink`) needs, and **exclude
`gst-plugins-ugly` (GPL)** + unused codecs:
core/base/good (`coreelements`, `playback`, `typefindfunctions`, `videoconvertscale`, `app`, `rtp`,
`rtsp`) + **`d3d11`** (the DXVA hardware decoder — the Windows equivalent of VA-API). The H.264/H.265
*patent* obligation rides on the OS/GPU decoder when you use `d3d11`; a bundled *software* decoder
would shift it onto us — hence `WT_HW_ONLY=1`.

## C++ runtime
`deploy.ps1`’s `--compiler-runtime` ships the VC++ Redistributable DLLs. Alternatively, build with the
**Hybrid CRT** (`static_compiler_runtime`, Qt 6.12+) to drop that dependency entirely — then omit
`--compiler-runtime`.

## Notes
- The build directory (`build-windows/`) is already covered by the root `.gitignore` (`/build-*/`).
- The fetched GStreamer runtime, MSIs and the generated `*-setup.exe` are ignored by this dir's `.gitignore`.
- Qt ≥ 6.11 auto-generates a Windows manifest; on our target (**6.12**) we deliberately embed our own
  (`app.manifest` via `watchtower.rc`, with `/MANIFEST:NO` so the linker doesn't add a second) — it
  declares long-path awareness, PerMonitorV2 DPI, UTF-8 and UAC asInvoker explicitly. Keep ours.
