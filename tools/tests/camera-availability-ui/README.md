# Availability history and packaged SQLite checks

These isolated fixtures do not read saved sign-in details, contact a production
server, disconnect cameras or change the running station.

## History controls

Run against Qt 6.8 or later, using a new output directory for each run:

```powershell
python tools/tests/camera-availability-ui/run-ui.py `
    --qt-bin C:/wt/Qt/6.12.0/msvc2022_64/bin `
    --output C:/wt/availability-ui-en

python tools/tests/camera-availability-ui/run-ui.py `
    --qt-bin C:/wt/Qt/6.12.0/msvc2022_64/bin `
    --output C:/wt/availability-ui-ru --russian
```

The runner copies the shipping panel/theme into an isolated module and loads the
shipping fonts. It requires successful JUnit results and a rendered screenshot.
Ten cases cover sync permission/single-flight presentation, revoked/empty camera
scope, station-row permission, separate sources/domains/onset times, unknown gap
durations, explained worker failure states, blocked sync controls, bounded time filters and no UI polling. These tests do not establish
backend authorization or real video health; those require service/integration tests.

## Installed or staged SQLite runtime

Build `availability-sqlite-smoke` through the CMake project in this directory.
Use a normal provisioned developer shell with the matching Qt toolchain:

```powershell
cmake -S tools/tests/camera-availability-ui -B C:/wt/availability-sqlite-probe `
    -G Ninja -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_PREFIX_PATH=C:/wt/Qt/6.12.0/msvc2022_64
cmake --build C:/wt/availability-sqlite-probe --parallel 2
```

In a separate PowerShell process, point it at the exact runtime being verified:

```powershell
$runtime = "$env:LOCALAPPDATA/Programs/Cilex Watchtower"
$env:PATH = "$runtime;$env:SystemRoot/System32;$env:SystemRoot"
$env:QT_PLUGIN_PATH = $runtime
& C:/wt/availability-sqlite-probe/availability-sqlite-smoke.exe $runtime
```

The probe selects only that directory for Qt plugins. It creates a separate
temporary SQLite database, commits under WAL/FULL durability, closes, reopens
and verifies the stored row. On this platform it also checks the actual loaded
Qt Core, Qt SQL and SQLite-plugin paths. It never opens the application's DB.
Exit zero plus `passed:true` is required. A development-SDK result is not proof
for the final package; run again against its staged/installed directory.
