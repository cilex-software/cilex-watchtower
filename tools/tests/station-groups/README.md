# Station camera-group regression

This loopback fixture uses the actual Watchtower `CameraModel`, `LiveMonitor`,
`CameraGroups` and `GroupSwitcher`. It reproduces a station that can read its
camera roster but cannot read the operator-only `/groups` definitions.

Run against an isolated-capable built application:

```powershell
python tools/tests/station-groups/run-model.py --binary 'D:\Build\watchtower.exe' --qt-prefix 'D:\Qt\6.12.0\msvc2022_64' --runtime-bin 'D:\Runtime\bin' --output 'D:\Checks\station-groups-new'
```

The output directory must be new. `--case station` or `--case operator` selects
one scenario. Additional `--runtime-bin` directories may be supplied. Dependencies
are resolved from the given Qt/runtime paths; no package is installed.

The runner copies the executable to `camera-groups-fixture.exe` before launch,
so station watchdogs that match `watchtower.exe` cannot select it. It removes
inherited `WT_` options, redirects settings and station provisioning, enables
test data locations and disables scheme registration, station enrollment and
real media plugins. Only disposable local credentials and loopback camera
metadata with empty media URLs are used. No real camera or backend is contacted.

Checks cover six deduplicated groups and roster-based counts, read-only station
permissions, real dropdown bindings, rename/removal through the normal 15-second
poll without model reset, scoped-roster reduction, null/empty IDs, plain labels,
missing names, logout cleanup, and operator canonical/empty groups. Station mode
must make no `/groups` request; operator counts ignore fleet-wide metadata.
The station case also signs into an operator account and returns to station
mode in the same process, checking that the dropdown and editing controls
change correctly while an unchanged camera roster does not reset its delegates.

An unchanged 1.1.791 application should fail the initial station group assertions.
The repaired application must pass both scenarios. The runner saves selected
request metadata, QML checks, source/binary hashes and results under its output
directory. This verifies group handling and UI bindings, not real camera video,
physical display rendering, Windows startup or production deployment.
