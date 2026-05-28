---
name: toolchain-setup
description: "Build toolchain install state, build/run/smoke-test commands, and the Qt 6.4 resource-prefix gotcha"
metadata: 
  node_type: memory
  type: project
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

Toolchain installed on the dev machine (Ubuntu 24.04.4) via `scripts/install-deps.sh` (needs sudo, run in the user's own terminal): **Qt 6.4.2** (distro qt6-base/declarative/multimedia + qml6 runtime modules), **CMake 3.28.3**, **Ninja 1.11**, **GStreamer 1.24.2** dev + `gstreamer1.0-qt6` (provides `qml6glsink`) + `gstreamer1.0-vaapi`, **FFmpeg 6.1.1**. VA-API HW decode confirmed: Intel Alder Lake-S iGPU, iHD driver 24.1.0, `vaapih264dec`/`vaapih265dec` present.

Build: `cmake -G Ninja -B build -S . && cmake --build build` → binary at `build/watchtower`.
Headless smoke test (no display needed): `QT_QPA_PLATFORM=offscreen timeout 3 ./build/watchtower` — exit 124 (killed by timeout) means the QML loaded fine; exit 255 means a load error was printed to stderr.

**Visual verification:** `main.cpp` has a screenshot hook — `WT_SCREENSHOT=/tmp/x.png QT_QPA_PLATFORM=offscreen timeout 6 ./build/watchtower` renders the window to a PNG (env-gated, no-op when unset), which can be read back to inspect the UI without a display. Used throughout Phase 1 to verify each screen/component. The dev machine also exposes a real Wayland session (WAYLAND_DISPLAY=wayland-0) if on-display runs are needed; no screenshot CLI (grim/gnome-screenshot) is installed.

**Gotcha (Qt 6.4.2):** `qt_add_qml_module`'s default resource prefix is `/<URI>` (i.e. `qrc:/Watchtower/...`), NOT the `/qt/qml/...` used by Qt 6.5+. We pin `RESOURCE_PREFIX "/qt/qml"` in CMakeLists.txt so `main.cpp` can load `qrc:/qt/qml/Watchtower/qml/Main.qml`. `QQmlApplicationEngine::loadFromModule()` does not exist in 6.4 — load by resource URL. See [[stack-and-build-direction]].
