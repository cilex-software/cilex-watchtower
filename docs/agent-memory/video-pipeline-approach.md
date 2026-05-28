---
name: video-pipeline-approach
description: "Video uses QtMultimedia (VideoOutput+MediaPlayer); qml6glsink's QML item won't register on Ubuntu 24.04"
metadata: 
  node_type: memory
  type: project
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

Phase-1 video decision (2026-05-25): the direct-GStreamer path via **`qml6glsink` → `Qt6GLVideoItem` QML item does NOT work on Ubuntu 24.04's `gstreamer1.0-qt6` 1.24.2**. Diagnosed thoroughly: the plugin `.so` (`libgstqml6.so`) loads into the process (confirmed in `/proc/<pid>/maps`), `QQuickWindow::setGraphicsApi(OpenGL)` is set, `gst_init` order tried both before/after `QGuiApplication`, the element was driven to `READY` — yet `qmlTypeId("org.freedesktop.gstreamer.Qt6GLVideoItem", *, 0, "Qt6GLVideoItem"|"GstGLVideoItem")` stays **-1** for all versions 0–12. The `QQmlPrivate::qmlregister` call exists in the (stripped) `.so` but its registration function never runs at plugin load, and `gstreamer1.0-qt6` ships **no dev headers** to call it manually. (Note: in 1.24.2 the QML type name is `Qt6GLVideoItem`, not `GstGLVideoItem`.)

**Pivot (VERIFIED WORKING):** use Qt's **QtMultimedia** `MediaPlayer` + `VideoOutput` (QML) — `qml/VideoSurface.qml`. Real RTSP **H.265** from a provisioned HiWatch camera plays in the Live Monitor grid, and **VA-API HW decode is confirmed**: a 1440p HEVC main stream runs at ~1–11% of one core (20-core box) → software decode would peg a core, so the GPU is doing it. 16 substreams are clearly viable. `src/video/CameraStream.{h,cpp}` (the qml6glsink path) was deleted. Trade-off vs [[stack-and-build-direction]]'s "direct GStreamer for max control": higher-level — revisit appsink+custom-GL only if needed.

**Credentials reality (2026-05-25):** the provisioning export's password `Qwerty12!` authenticates on **only `.108`**; the other 9 cameras (`.101`–`.107`, `.109`, `.110`) return **401** on it — consistent with the export's `"password_included": false` (per-camera passwords weren't captured). Do NOT run the full wall against all cameras until correct per-camera creds exist: each failed login locks that camera's IP ~30 min. The full 10-up live wall is a credentials/data blocker, not a code one. Milestone 1's technical question is already answered (real HW-decoded H.265 plays; ~0.1 core per 1440p stream → 16 substreams trivial). Use `.108` (substream by default) as the live demo camera; placeholders for the rest.

**Implementation notes:** tiles use a `Loader` so a `MediaPlayer` exists only while `videoActive` (paged-out/offline tiles stay cheap); the grid uses the **Hikvision substream** (rtsp path `/Streaming/Channels/102`) derived from the main `/101` URL; focused views can use the main stream. `WT_TEST_IP` gates which camera streams during dev (avoids hitting cameras with possibly-wrong passwords — HiWatch/Hikvision lock an IP ~30 min after failed logins; `.106` got locked during testing). `WT_CAMERAS=<provisioning.json>` loads real cameras at startup.

**Critical (do not regress):** a tile streams ONLY when its `videoActive` is true, which requires the Live Monitor to be the **visible section** (`root.visible`). Otherwise a hidden Live Monitor keeps every player open — hammering cameras (HiWatch lock after failed logins) and crashing GStreamer's teardown on exit. `VideoSurface` also calls `player.stop()` in `Component.onDestruction`. Don't run the full wall against all cameras during dev (use `WT_TEST_IP=<ip>` to stream one). `WT_SECTION=<live|groups>` boots a section (dev).
