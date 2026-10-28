# Availability observation checks

These fixtures use synthetic loopback services. They do not disconnect cameras,
change frame rates or stop an installed Watchtower.

## Evidence rules

- Live RTSP evidence uses a valid decoded appsink sample with an arrival age of
  at most **5 seconds**. Repainting an adopted/cached frame is not evidence.
- A missing decoded frame is confirmed after **75 seconds**, matching the
  existing backstop. A shorter UI reconnect is not recorded as a confirmed outage.
- A timer gap greater than **25 seconds**, a backward wall-clock step, or a
  wall/monotonic delta discrepancy greater than **25 seconds**,
  interrupts observation. It does not prove a camera failure.
- Inactive, warm-only and sink-less sources close their own observation session.
- Backend reports expire locally after **45 seconds**. API/authentication failure
  records a station condition/gap; retained camera values are last-known values.
- Recording catalogue evidence uses fresh v1 archive telemetry. Capture stopped,
  motion idle, disabled recording and maintenance do not establish archive loss.
- Snapshot failures require **three consecutive** endpoint/decode failures.
  Authentication, service and network uncertainty do not count as camera outages.
- A snapshot needs an explicit `X-Snapshot-Source: live` and an age no greater
  than **15 seconds** to establish current delivery. The current backend supplies
  no source header and can substitute zero for unknown age; HTTP 200 therefore
  remains unknown. Old snapshots are degraded. Lifecycle fencing drops results
  from hidden, destroyed, retargeted or retired thumbnails.
- QtMultimedia requires an owned player/sink, the current source generation and
  two strictly advancing decoded frame presentation timestamps. Signal-emission
  arrivals are stamped on both clocks before the GUI queue. Repeated cached PTS,
  inactive/warm sources and old generations cannot establish recovery. Missing
  usable timestamps remain explicitly unknown.

## Deterministic rules

Configure with the local Qt prefix, build and run `availability-observer-rules`:

```sh
cmake -S tools/tests/availability-observers -B /tmp/wt-availability-rules \
  -DCMAKE_PREFIX_PATH="$QT_PREFIX"
cmake --build /tmp/wt-availability-rules --parallel 2
/tmp/wt-availability-rules/availability-observer-rules
```

Windows uses the same CMake project in a Visual Studio developer terminal; the
executable is `availability-observer-rules.exe`.

On the provisioned Russian MSVC host, CMake cached a wrongly encoded include
prefix and Ninja recorded no header dependencies. Use a fresh build directory
or `cmake --build <directory> --clean-first --parallel 2` after header changes.
An incremental fixture with mismatched class layouts crashed; its clean rebuild
passed. Do not use an incrementally rebuilt package as deployment evidence on
that host until header dependency tracking is repaired.

## Real video boundaries

The extended `tools/tests/live-stream-identity` fixture checks actual pixels,
canonical identity, observer separation, inactive/warm/sink-less sources, cached
adoption and credential/URL exclusion. Build its C RTSP server when Python GI
is unavailable. Its synthetic encoder uses intra frames to keep identity checks
independent of software-decoder concealment during a mid-GOP join.

For the actual 75-second loss/recovery check, start the loopback server built by
`tools/tests/live-stream-reconnect`, wait for its `ready:true` line, then run:

```sh
env QT_QPA_PLATFORM=offscreen WT_RTSP_TCP=1 WT_STREAM_WATCHDOG_OFF=1 \
  /tmp/wt-live-identity/live-stream-identity \
  rtsp://127.0.0.1:18559 --availability-stall
```

This takes about 80 seconds. It requires one confirmed loss followed by exactly
one fresh-frame recovery. Only after confirmation does the fixture request a
reconnect. The product threshold remains unchanged.

On Windows, the C servers have a 90-second deadline; the controller must also
close only its own child processes. Use a separate GStreamer registry and a
software-only test-plugin directory to avoid unrelated GPU device enumeration.
This does not validate the production hardware decoder.

The existing QML reconnect fixture separately checks the shipping
`VideoSurface.qml` against an approximately two-second source followed by a
silent stall. It verifies bounded automatic reconnection and recovered pixels.
Passing a local clip URL instead of the RTSP URL exercises the actual QML
MediaPlayer binding, fresh decoded delivery, cached-frame rejection and bounded
unknown-timestamp reporting. Its timeout may be set to 5000 milliseconds.

## Actual model, station failure and durable history

After building the application with test-profile isolation support:

```sh
python tools/tests/availability-observers/run-model.py \
  --binary "$WATCHTOWER_BINARY" --qt-prefix "$QT_PREFIX" \
  --output /tmp/wt-availability-model-new
```

On Windows, pass `--runtime-bin` for additional dependency DLL directories.
The output directory must be new. The runner sets `WT_SETTINGS_DIR`, uses a
profile-only database/provisioning file, clears inherited station inputs and
provides no camera URLs. It checks 133 initial reports, repeated API 503 results,
freshness restoration, one explicit camera failure, duplicate polling and its
referenced recovery. SQLite history, request paths, logs, source/binary hashes
and results are retained. No station ingest token is needed for this local test.

These checks do not establish production backend upload, installed-package
SQLite support, real-camera freshness, capacity or Linux/macOS acceptance.
