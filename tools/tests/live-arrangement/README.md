# Live arrangement regression

Run from any directory:

```sh
./tools/tests/live-arrangement/run-ui.sh
```

Set `QT_BIN` when `qmltestrunner` is not on PATH. Qt Quick, Qt Quick Controls,
Qt Quick Shapes and QtTest are required. The runner copies the shipping
`LiveMonitor.qml` and its presentation primitives into a temporary import module,
then drives real cell, picker and remove-button clicks with QtTest. It also
checks sorting, filters, pagination, explicit empty membership, screen reload,
group independence and camera delegate identity during refresh and swapping.
Seven layouts cover single cells, 100-cell grids and feature layouts; adding
pages is verified beyond 100 positions. Filtered occupied cells and first edits
on a compact filtered wall must preserve all untouched camera memberships.

The module uses an in-memory Settings API fixture, a synthetic roster and a
CameraTile stub with no streams. It cannot read/write operator preferences,
contact the backend, or decode video. This separation is deliberate: on macOS,
changing HOME does **not** isolate the real application's QSettings. Real
Settings serialization and saved-view behavior need the separate C++ regression.

Rendered fixture screenshots are written to
`/tmp/watchtower-live-arrangement-*.png`. They show production arrangement UI
with synthetic camera names and no camera imagery; they do not verify live
playback, production camera access, or remote-station behavior.

To verify the translated UI, compile a catalog and pass QtTest's translation
option (each run replaces the same temporary screenshot files):

```sh
lrelease i18n/watchtower_ru.ts -qm /tmp/watchtower-arrange-ru.qm
./tools/tests/live-arrangement/run-ui.sh -translation /tmp/watchtower-arrange-ru.qm
```
