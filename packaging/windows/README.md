# Cilex Watchtower — Windows packaging

Scaffold for building and shipping Watchtower on **Windows 10/11**. The app's C++/QML core is
cross-platform; only the files here plus the `if(WIN32)` block in the top-level `CMakeLists.txt`
are Windows-specific. **Nothing here is compiled on Linux/macOS** (the block is inert off-Windows).

## Status — scaffold, not yet a working Windows build
The structure is in place. Items marked **TODO** need a Windows machine and the port work itself
(the decode path + testing). See `docs/DEVELOPMENT.md` → *Build* and the hardware-decode gotcha.

## Files
| File | Purpose |
|---|---|
| `app.manifest` | Win10/11 compat, long-path awareness, per-monitor-v2 DPI, UTF-8, UAC `asInvoker`. |
| `watchtower.rc` | Embeds the manifest + version info (+ the app icon, once added). |
| `watchtower.ico` | **TODO** — generate from `assets/images/cilex-logo.png`, then uncomment in `watchtower.rc`. |
| `fetch-gstreamer-windows.ps1` | Download the GStreamer-for-Windows MSVC runtime. |
| `deploy.ps1` | `windeployqt` (Qt runtime) + the GStreamer LGPL-plugin bundle → a self-contained dist. |
| `installer.nsi` | NSIS installer skeleton (WiX/MSIX are alternatives). |

## Build & package flow (on Windows)
1. **Qt 6.8.3** (same version as Linux):
   `aqt install-qt windows desktop 6.8.3 win64_msvc2022_64 -m qtmultimedia qtshadertools`
2. **GStreamer** — install the MSVC **runtime + development** MSIs (devel is needed to *build*), or run
   `fetch-gstreamer-windows.ps1` for the runtime. Point `PKG_CONFIG_PATH`/CMake at the GStreamer dev
   so the existing `pkg_check_modules(GST ...)` in `CMakeLists.txt` resolves.
3. **Configure + build**:
   ```
   cmake -G Ninja -B build-windows -DCMAKE_PREFIX_PATH=<qt>/6.8.3/msvc2022_64
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
- Qt ≥ 6.11 auto-generates the Windows manifest; on 6.8.3 we embed our own (`app.manifest`). When you
  move to the 6.12 LTS you can either keep ours (explicit control) or drop it and let Qt generate one.
