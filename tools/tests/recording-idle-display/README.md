# Recording idle display regression

This fixture loads the actual `RecordingStatusBadge.qml` and `HealthScreen.qml`
with the production `CameraStatus` enums and `RecordingHealth.h` normalizer.
Only the roster and badge-timer settings are synthetic. It does not start
Watchtower, read operator settings, connect to a server/camera, or register a
URL handler.

With an existing Qt 6.8+ kit:

```sh
cmake -S tools/tests/recording-idle-display -B build-recording-idle \
  -DCMAKE_PREFIX_PATH="$HOME/Qt/6.8.3/gcc_64"
cmake --build build-recording-idle --parallel 1
ctest --test-dir build-recording-idle --output-on-failure
```

On the recording host, use its existing normal admission and capped runner.
The test writes `health-idle.png` in its build directory. This is a synthetic
offscreen screen, not native station or real-video acceptance.

The cases cover fresh idle against stale legacy Recording/Stalled/Disabled,
real stopped/delayed/unknown observations, expiry, motion readiness, canonical
selection refresh even when the row signature is unchanged, removal with an
identically named replacement, filter changes and missing identity/model.

For a preserved-source comparison, `WT_RECORDING_TEST_QML_DIR` may point to a
separate QML directory; the checked source is not rewritten. The regression
must fail against the original idle/selection behavior as well as pass against
the repair. Keep both results rather than interpreting any nonzero baseline
exit as proof of the intended defect.
