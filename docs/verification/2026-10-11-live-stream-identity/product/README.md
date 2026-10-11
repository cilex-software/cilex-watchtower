# Fixed-binary product integration verification

This directory preserves the **fixed-binary** Product.Main integration run. The
original temporary directory happened to end in `qml-before`; that name does not
indicate a baseline run. Raw logs and original result JSON retain their original
paths unchanged. `execution.json` maps every copied image to its original path
and measured SHA-256 and records the command, environment, actual exit code and
binary identity.

The executed command recorded in `execution.json` exited **0**. Its raw
`app.log` records **45 assertions, zero failures, ten navigation legs and 18
rendered images**. The image verifier command in `verify-command.json` exited
**0**, checking actual pixel colour rather than merely URL/tab labels; see
`pixel-verification-recheck.json`, `verify.stdout` and `verify.stderr`.

The regression opens red, returns to the wall, opens green, revisits red,
returns to the wall, opens blue, revisits green/red and returns to the wall
(`tools/tests/live-stream-identity.qml:28`, navigation at line 147).
The test uses the shipping Main, LiveMonitor, SingleCameraDetail and VideoSurface
components through `tools/tests/live-stream-identity.qml:13`. The camera roster and
authenticated-shell visibility are test fixtures, so this verifies the product
navigation/rendering path with synthetic local streams. It does not exercise
production authentication, backend camera metadata or physical cameras
(fixture substitution and visibility override: `tools/tests/live-stream-identity.qml:125`).

Startup warnings remain visible in `app.log`: GStreamer's plugin scanner emits
`_dma_fmt_to_dma_drm_fmts` assertion output, and a QQuickRectangle member overrides
`enabled`. Neither prevented this run's recorded assertions or pixel verification.

## Reproduce in an isolated test instance

Dependencies: the repository's normal Watchtower build/runtime, an X11 display,
Python Pillow for PNG verification, Python GI bindings, the GstRtspServer 1.0
typelib/library, and GStreamer's `x264enc` plugin. The fixture only listens on
loopback and produces 160×96 synthetic colour streams at five frames/second
(`tools/tests/live-stream-identity/rtsp_fixture.py:25`). For this run the missing
RTSP-server packages were extracted under `/tmp/watchtower-live-identity-deps`
without a system installation; the C++ regression's fixture evidence records
that setup.

Start the local fixture in one terminal (omit these two dependency overrides if
GstRtspServer is installed normally):

```sh
GI_TYPELIB_PATH=/tmp/watchtower-live-identity-deps/usr/lib/x86_64-linux-gnu/girepository-1.0 \
LD_LIBRARY_PATH=/tmp/watchtower-live-identity-deps/usr/lib/x86_64-linux-gnu \
nice -n 10 taskset -c 0,2 /usr/bin/python3 \
  tools/tests/live-stream-identity/rtsp_fixture.py \
  --port 18554 --ready /tmp/watchtower-identity-fixture.json
```

In a second terminal, create disposable config/data/cache/shots directories and
run the command in `execution.json`, adjusting those temporary paths if desired.
Use `./run.sh` so the app loads its matching Qt runtime; keep
`WT_NO_SCHEME_REG=1`, `WT_DEMO=1`, the isolated XDG directories, and the explicit
removal of credential/autologin environment variables. Stop only the fixture
process you started after the test finishes.

The preserved PNGs can be verified without any running app or fixture:

```sh
python3 tools/tests/live-stream-identity/verify_qml_captures.py \
  docs/verification/2026-10-11-live-stream-identity/product/app.log \
  --capture-dir docs/verification/2026-10-11-live-stream-identity/product/shots \
  --output /tmp/live-stream-identity-copied-pixels.json
```

This regression intentionally has two gates: the app's exit code and the pixel
verifier's exit code must both be zero. A passing URL/title check alone is
insufficient.
