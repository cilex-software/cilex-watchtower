# QML silent-stall reconnect regression — 2026-10-14

The production RTSP wrapper did not expose `reconnect()`, so the existing QML
coordinator reached the wrapper and performed no native reconnect. Adding the
forwarder is verified here using the real production `VideoSurface.qml`,
`ReconnectCoordinator.qml`, and `RtspVideoSource` against a loopback RTSP server.

| Observation | Original QML | Corrected QML |
| --- | --- | --- |
| Initial red frames | Delivered | 25 delivered |
| Silent server stall | Observed | Observed |
| QML recognized stalled playback | Yes | Yes |
| Actual native reconnects | 0 | 1 |
| Server connections | 1 | 2 |
| Fresh blue frames from replacement connection | 0 over 20 seconds | 15 |
| Time from last red frame to first blue frame | Did not recover | 4.612 seconds |
| C++ watchdog rebuilds | 0 | 0 |

The independent C++ watchdog was disabled for both runs. No test code invoked
reconnect; the production QML timers and coordinator did so. Fixture client and
server processes exited. This demonstrates retry dispatch and fresh decoded
frames, not the cause of the initial production stalls or acceptance of the
31-camera workload.

The final evidence is `isolated-plugin-regression/summary.json`, SHA256
`c6be1640a12394aa8d87517a97d43cd4dbec597f142b177b58ba4b003d40885a`.
It records production code, executable, scanner and plugin hashes. This native
Mac run used Qt6.11.1 and GStreamer1.28.6. The original QML and fixed QML
snapshots, all fixture logs, connection events and pixel measurements are
retained alongside it.

`initial-host-plugin-warnings` retains the earlier passing regression with an
incorrect fixture scanner path and unrelated Homebrew plugin-load warnings.
The runner was corrected to query its scanner and isolate the 15 required
plugins, then repeated successfully. Offscreen NSApplication/CPU-conversion
warnings remain recorded; this fixture does not claim visible GUI rendering or
validation of the bundled production runtime. No installed application,
production cameras, backend or user settings were accessed by the fixture.

Reproduction is documented in `tools/tests/live-stream-reconnect/README.md`.

The runner then pinned the known original revision explicitly, so a later
commit will not silently replace the negative baseline. The otherwise identical
rerun passed: 29 red frames in each case, no original-QML reconnect, and fixed
QML recovery in 4.609 seconds with 15 blue frames and zero watchdog rebuilds.
It is retained in `pinned-original-revision/summary.json`, SHA256
`03a7ec8c89a43f5064672354b5e78f5bc7b3e8ade93e87569b691335b05bf8ed`.
