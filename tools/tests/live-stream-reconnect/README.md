# Production QML reconnect regression

This native test loads the actual `VideoSurface.qml` and
`ReconnectCoordinator.qml`, with the actual C++ `RtspVideoSource`, through a
QQmlEngine. The loopback-only RTSP fixture sends red H264 frames on its first
connection, then silently drops raw buffers after 30 frames (about two seconds).
It sends no EOS or error. A second connection sends blue frames continuously.

The test observes decoded sink pixels and the QML `playing` property. Passing
requires initial red video, a real stall, a QML reconnect, at least 15 blue
frames, recovery within 15 seconds of the last red frame, and zero C++ watchdog
rebuilds. `WT_STREAM_WATCHDOG_OFF=1` prevents the independent 75-second backstop
from concealing the broken QML path. It never invokes `reconnect()` itself.

The runner preserves a negative baseline using QML from the known original
commit `199a8998c4a4b20d8ebffdec87b5bc053adb473b` and compares it with a snapshot
of the working QML. `--before-revision` accepts another full local commit hash;
the runner never fetches. Each gets its own server, HOME and
GStreamer registry in a new evidence directory. Fixture cleanup only targets
the child processes started by the test. No production camera, backend,
installed application, launchd registration or user preferences are used.

On the macOS build host with Qt6, GStreamer and its RTSP-server development
package already available:

```sh
cmake -S tools/tests/live-stream-reconnect -B /tmp/cilex-qml-reconnect-build \
  -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt
cmake --build /tmp/cilex-qml-reconnect-build --parallel 2
python3 -B tools/tests/live-stream-reconnect/run.py \
  --build-dir /tmp/cilex-qml-reconnect-build \
  --evidence-dir /tmp/cilex-qml-reconnect-new-run
```

The macOS fixture runner explicitly selects `/opt/homebrew` build dependencies;
it is not the generic installer bootstrap. Its host dependencies and offscreen
QML result do not establish packaged-runtime or production-network acceptance.
Evidence contains code/binary hashes, initial and recovered frame counts,
transition timings, connection generations and all logs, including failures.

The buffer-drop fixture follows GStreamer's
[pad-probe contract](https://gstreamer.freedesktop.org/documentation/additional/design/probes.html).
The production QML singleton is registered using Qt's
[QQml type registration API](https://doc.qt.io/qt-6/qqml-h.html).
