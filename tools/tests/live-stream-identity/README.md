# Live-stream identity regression

This standalone harness compiles the production `RtspVideoSource` directly and
checks actual decoded `QVideoSink` pixels. It connects only to a loopback RTSP
fixture: red, green and blue H.264 streams at 160×96, 5 fps. It does not open
real cameras, access recording services, or change camera configuration.

The checks cover retargeting A → B → A → C, same-URL pipeline adoption when a
detail view yields to a wall, concurrent independent sources, warm-only mode
transitions, and two rapid A → B → C cycles. Every valid delivered frame is
checked against the expected colour, including synchronous parked-frame
delivery inside `setUrl()`. A previous image retained by `QVideoSink` without a
new frame callback is outside this harness's boundary; the product QML check
covers rendered navigation separately.

The fixture requires Python PyGObject, the `GstRtspServer` typelib/library, and
GStreamer `videotestsrc`, `x264enc`, `rtph264pay`, H.264 decode and conversion
plugins. The C++ harness requires CMake, Qt Core/Gui/Qml/Multimedia and GStreamer
development packages. `--port` changes the loopback listener.

Start the fixture in a separate terminal:

```sh
nice -n 10 taskset -c 0,2 /usr/bin/python3 tools/tests/live-stream-identity/rtsp_fixture.py --port 18554
```

Build and run (adjust the Qt prefix and affinity for the host):

```sh
cmake -S tools/tests/live-stream-identity -B /tmp/watchtower-live-identity \
  -DCMAKE_PREFIX_PATH=/home/cilex-vision/Qt/6.8.3/gcc_64
nice -n 10 taskset -c 0,2 cmake --build /tmp/watchtower-live-identity --parallel 2
env QT_QPA_PLATFORM=offscreen WT_RTSP_TCP=1 WT_PARK_MS=10000 WT_PARK_MAX=8 \
  WT_STREAM_WATCHDOG_OFF=1 OMP_NUM_THREADS=2 OPENBLAS_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  nice -n 10 taskset -c 0,2 /tmp/watchtower-live-identity/live-stream-identity \
  rtsp://127.0.0.1:18554
```

Unset `WT_WALL_BADURL`, `WT_DECODE_SCALE`, `WT_WALL_CHURN`, and `WT_HW_ONLY` for
this test. Standard output is a JSON report; standard error contains lifecycle
logs and per-check results. Exit 0 means every pixel check passed; exit 1 means
at least one failed; exit 2 means invalid command arguments. The longer parking
grace prevents test-machine timing from prematurely expiring adoption fixtures.

For a preserved before/after comparison, pass
`-DWATCHTOWER_SOURCE_DIR=/absolute/directory/with/RtspVideoSource.cpp-and-header`
to a separate build directory. No production changes or private-field hooks
are needed for the comparison.

On the 2026-10-11 host, the missing RTSP server runtime and typelib were fetched
as Debian packages and extracted under `/tmp/watchtower-live-identity-deps`,
without a system installation:

```sh
cd /tmp
apt-get download libgstrtspserver-1.0-0 gir1.2-gst-rtsp-server-1.0
dpkg-deb -x libgstrtspserver-1.0-0_1.24.2-1_amd64.deb /tmp/watchtower-live-identity-deps
dpkg-deb -x gir1.2-gst-rtsp-server-1.0_1.24.2-1_amd64.deb /tmp/watchtower-live-identity-deps
```

The fixture process then used
`GI_TYPELIB_PATH=/tmp/watchtower-live-identity-deps/usr/lib/x86_64-linux-gnu/girepository-1.0`
and `LD_LIBRARY_PATH=/tmp/watchtower-live-identity-deps/usr/lib/x86_64-linux-gnu`.
The actual run arguments, environment overrides, source hashes, child exit
codes and decoded-pixel results are preserved under
`docs/verification/2026-10-11-live-stream-identity/`.
