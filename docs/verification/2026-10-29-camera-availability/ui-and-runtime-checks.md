# History UI and SQLite runtime evidence

The shipping history panel is in `qml/AvailabilityHistory.qml`, reached through
the Health screen. Its sync control uses the service's authorization/busy state;
its history view additionally checks the current camera roster and explicit
station-row permission. The worker/service remain responsible for authorization.

## Observed checks

On 2026-10-29, these isolated commands each passed ten behavioral cases plus
test initialization/cleanup (12 total, zero failures):

```powershell
python tools/tests/camera-availability-ui/run-ui.py --qt-bin C:/wt/Qt/6.12.0/msvc2022_64/bin --output C:/wt/availability-ui-en-r7-20261029
python tools/tests/camera-availability-ui/run-ui.py --qt-bin C:/wt/Qt/6.12.0/msvc2022_64/bin --output C:/wt/availability-ui-ru-r7-20261029 --russian
```

JUnit reports and screenshots remain in those output directories. Both images
were inspected: readable English/Russian, dark product styling, separate
failure/recovery/gap rows, explicit delivery and uncertain-duration labels.
These fixtures use no network and do not establish a deployed station UI.

The compiled `tools/tests/camera-availability-ui/sqlite-smoke.cpp` probe passed
against the existing Booth installation with a restricted PATH containing only
that installation and system directories. It loaded the actual installed
`Qt6Core.dll`, `Qt6Sql.dll` and `sqldrivers/qsqlite.dll`; a separate temporary
database passed WAL/FULL open/commit/close/reopen/read. The application DB and
running Watchtower were not touched. The JSON proof is `sqlite-installed-booth.json`.
Repeat this probe against the final package and final installation after rollout.

Earlier screenshot inspection found missing fixture font loading. The runner
now loads the shipped fonts and requires a JUnit report, count and screenshot;
the results above use that corrected harness. The Health stale-status notice is
also asserted by the shipping recording-health integration fixture; its new
assertion requires the final application build and is not established by the
standalone panel tests.

## Worker HTTP integration and shared schema

The fresh, clean Qt 6.12/MSVC build of `tools/tests/camera-availability-sync`
passed 20 scenario/data cases plus initialization/cleanup (22 total, zero
failures, 9.758 seconds). Reports are:

`C:/wt/availability-sync-clean-r10-20261029/results.{txt,xml}`

The suite uses the actual worker, SQLite journal and Qt HTTP transport with a
loopback protocol fixture. Coverage includes next/resume native cursors, lost
acknowledgements and duplicate retry, partial/malformed/wrong-identity replies,
413 splitting, 422 poison isolation, 401/403 retry pause, 409 identity protection,
429 Retry-After, the injected 180-minute schedule, one in-flight request,
history authorization/logout, destination pinning, station-token rotation and
restart persistence. The locked-database context-change case proves history is
hidden, observations cannot leak into the old context, and a later successful
selection recovers safely. The backend reconnect case imports new native
history between cycles without an early upload or a changed upload deadline;
repeated healthy observations do not create a poll loop. The rate-limit case
also refuses manual retry at zero and
119 seconds and preserves the pause across restart; the 401 case stays paused
after restart until the station credential changes. It does not establish a real Vision/PostgreSQL round trip.

The earlier `results-r3` run had nine failures because its fixture incorrectly
expected a new queue to upload before the initial three-hour interval. The
fixture now requests manual sync after capabilities/feed discovery completes;
the production interval is unchanged. Those failed reports remain retained. A later r6 run had three failures after
protocol/conflict handling was intentionally changed to pause manual retry. Its
cases now assert that pause and verify explicit restart resumes the unchanged
original envelope; the completed run above passed after the central-review
journal and worker changes. A separate build-tool investigation found that
Ninja records zero C++ header dependencies with the installed Russian MSVC
resource and incorrectly decoded include prefix. The completed run used a new
build directory and `--clean-first`, rebuilding every C++ object. Any later
source/header changes require another clean rebuild; incremental results alone
are insufficient on this toolchain.

`tools/tests/camera-availability-sync/validate-wire.py` passed 26 offline checks:
17 shared file SHA-256 hashes, eight positive normative fixtures and a generated
client batch. The final result is:

`C:/wt/availability-wire-validation-20261029-r3.json`

It used jsonschema 4.23.0 with Draft 2020-12 and UUID/timestamp format checking.
Dependencies were installed only under
`C:/wt/availability-schema-validator-20261029`; normal Python packages were not
modified. Structural schema validation does not replace authorization or
semantic protocol tests. `git diff --check` passed for these owned paths.

## Access preflight

The existing Booth station token successfully read the implemented backend
capabilities and native feed; scope is explicitly configured. No synthetic
observations were uploaded during this inspection. The exact shared contract
and all 18 schemas/fixtures were copied byte-for-byte from the backend repository
and verified against their Git blob hashes; see `backend-contract-provenance.json`.

Office answers on its file-sharing port, but the current account cannot open
its administrator share or service manager. No Office credential/session is
stored for reuse. Office installation/version/enablement are unverified until
an authorized connection is established. No authentication guessing or policy
change was performed.
