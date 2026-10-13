# Live view membership and empty cells

Arrange now supports assigning any empty cell, removing an occupied cell, and
adding another page. Choosing a camera already in the view swaps its slot with
the target, including across pages; a camera cannot occur twice. The picker
queries the full accessible roster using the toolbar sort, with independent
group/search filters. Its membership badge and hide toggle cover the whole view.

The first edit captures explicit membership with empty strings for vacant slots.
Removed cameras do not return after sorting, filtering, leaving Arrange or
reloading. A Sort action orders occupied positions while retaining holes;
assignments stay in the clicked cells until another Sort action. Filters hide
members without deleting them. A filter-hidden occupied cell says so and opens
Arrange before editing. Reset arrangement returns to the dynamic group roster.

No camera-group write is involved. New saved views capture their own membership,
including an empty selection. Legacy saved views remain readable. Crash state
captures edits immediately, and playback receives only occupied page entries.

## Implementation

- `qml/LiveMonitor.qml:238`: exact membership and independent picker roster.
- `qml/LiveMonitor.qml:331`: explicit sorting without refilling holes.
- `qml/LiveMonitor.qml:507`: assign/swap, remove and add-page operations.
- `qml/LiveMonitor.qml:738`: camera delegates retain identity while their sparse
  slot positions change.
- `src/models/Settings.cpp:247`: synchronous persistence of sparse cells.
- `src/models/LiveViewCells.h:9`: duplicate IDs become empty slots.
- `src/models/SavedViewModel.cpp:45`: backward-compatible saved-view membership.
- `qml/Main.qml:214`, `qml/Main.qml:700`, `qml/Main.qml:2589`: session capture,
  saved-view restore and saving the full membership.

## Verification on macOS

The English and Russian QtTest runs each passed **20 cases, zero failures**.
These include initialization/cleanup, seven grid layouts, actual cell/picker/
remove-button clicks, adding cameras from another group, empty views, 300 slots
across pages, cross-page duplicate prevention, all five picker sorts, filtered
edits, reload/reset, group independence and camera delegate identity.

```sh
QT_BIN=/opt/homebrew/opt/qt/bin ./tools/tests/live-arrangement/run-ui.sh
/opt/homebrew/opt/qt/bin/lrelease i18n/watchtower_ru.ts -qm /tmp/watchtower-arrange-ru.qm
QT_BIN=/opt/homebrew/opt/qt/bin ./tools/tests/live-arrangement/run-ui.sh \
  -translation /tmp/watchtower-arrange-ru.qm

cmake -S tools/tests/live-view-persistence \
  -B /private/tmp/watchtower-live-view-persistence-native \
  -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt
cmake --build /private/tmp/watchtower-live-view-persistence-native --parallel 4
ctest --test-dir /private/tmp/watchtower-live-view-persistence-native --output-on-failure

cmake -S . -B build-macos -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  '-DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt;/opt/homebrew/opt/qtmultimedia'
cmake --build build-macos --parallel 4
./tools/tests/window-guard-lint.sh
git diff --check
```

The isolated C++ persistence test passed **23 checks**, covering disk reload in a separate process,
duplicate rejection, empty membership, legacy compatibility and independent
same-group saved views and the real QML QStringList slice/map/mutation bridge.
See `persistence.log`. The macOS application builds successfully (`macos-build.log`). Timestamp
guard lint and whitespace checks pass.

The rendered English/Russian PNGs in `en/` and `ru/` were visually inspected,
including the complete last row of the picker. Each folder includes its test
log and source hashes. No production QML warning occurred; Qt reported the
host's missing default Sans Serif font alias.

## Boundaries

The UI harness uses production LiveMonitor and presentation components with a
synthetic roster, in-memory Settings and a CameraTile stub. The separate C++
test exercises real Settings/SavedViewModel in a temporary INI store. Neither
test accesses operator preferences, live cameras or the backend. The full app
was built but not launched over the operator's session. Live video, native
interactive use, end-to-end crash recovery and Windows/Linux runtime behavior
were not measured for this change. No running station was updated or restarted.
