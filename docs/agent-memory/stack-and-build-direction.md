---
name: stack-and-build-direction
description: "Watchtower is a native Ubuntu Qt6/QML/C++ VMS — locked stack, scope, and phase build order"
metadata: 
  node_type: memory
  type: project
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

Watchtower is a **native Ubuntu 24.04/26.04 operator-workstation surveillance VMS, NOT a browser app**. The user explicitly overrode the product briefing's "browser-based desktop UI" framing on 2026-05-25. The decisive requirement is smooth decode/compositing of up to **16 live RTSP H.264/H.265 streams** plus playback scrubbing — that, not the screen count, is the hard part.

**Locked stack (user-approved 2026-05-25):**
- UI: Qt 6 + Qt Quick / QML (GPU scene-graph compositing). Recreate the React prototype *visually* in QML — do NOT reuse React/JSX code.
- Core language: C++ (chosen over PySide6 for max control of the multi-stream HW-decode pipeline).
- Video ingest/playback: GStreamer (`rtspsrc`), VA-API (Intel/AMD) or NVDEC (NVIDIA) HW decode, zero-copy to GL / Qt Quick scene graph (`qml6glsink` from `gstreamer1.0-qt6`).
- Clip export: FFmpeg/libav (MP4, optional timestamp + camera-name overlay burn-in). Snapshots: frame-grab to JPG/PNG.
- Data: C++ `QAbstractListModel` exposed to QML, fed by a mock-data layer first (mirrors prototype `CAMERAS`/`GROUPS`/`EVENTS`/`CLIPS`/`SAVED_VIEWS`), swappable for real ONVIF/NVR later.
- Persistence: SQLite (prefs, saved views, favorites, acknowledgements).
- Build: CMake + Ninja. Packaging: Flatpak primary, .deb/AppImage secondary. Display: Wayland-native + X11 fallback.

**Build order (user-approved):** Phase 1 = Foundation + Live Monitor (scaffold; design tokens; self-hosted fonts Space Grotesk + JetBrains Mono; icon set; app shell = nav rail + top bar + status strip; mock-data models; full Live Monitor: 1/4/9/16 grids, manual paging for 100–500 cams, filters, status-first sort, tile hover actions, fullscreen variant; then GStreamer video proof 1→4→9→16 with CPU/GPU/mem measurement). **Milestone 1:** 4×4 grid of 16 tiles, HW decode used, smooth UI. Then P2 Single Camera Live, P3 Playback+timeline, P4 Export+snapshots, P5 Events+Health, P6 Saved Views/Clips/Prefs/polish. Do NOT build all 10 screens at once — prove the 16-stream wall first.

Dev machine confirmed capable: Intel Alder Lake-S iGPU, VA-API H264/H265 VLD decode working (vainfo, iHD 24.1.0). See [[toolchain-setup]] for the install state of the build toolchain.

Design reference lives in-repo: `designs/design_handoff_watchtower/` — `README.md` (full spec + design tokens) and `design/watchtower.html` (pixel-precise React prototype + mock-data shapes).
