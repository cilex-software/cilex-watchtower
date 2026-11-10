# Station camera-group dropdown

The Booth ran Watchtower 1.1.791 from `799396a3` with station identity `ST`.
The operator's Mac screenshot used 1.1.781 and an administrator identity.
The Booth's camera roster remained available while its group menu showed only
All Cameras. These screenshots are observations, not installation instructions.

## Cause and real-server evidence

A bounded check using the Booth's own station credential obtained a display
session successfully. With that session, `/streams` returned 200 and 133
cameras; `/groups` returned 403. Only selected non-secret fields were saved in
`C:\wt\camera-groups-readonly-20261110.json`.

The authorized camera roster already contains all six groups:

| Group | Cameras |
| --- | ---: |
| 4стр | 9 |
| Entrances | 21 |
| Внутри | 37 |
| Крыша | 17 |
| Лифты | 18 |
| Улица | 31 |

The model fetched group definitions only from the operator-only `/groups`
route. Its group accessor ignored the group identities and names already in
the station's authorized camera roster. This explains the different sign-in
results without requiring deleted groups or a Windows rendering failure.

## Correction

Station group filters are derived from the currently authorized camera roster,
deduplicated by group ID and counted by the existing roster/filter logic.
Operator group definitions, including genuine empty groups, remain canonical.
Station mode no longer calls `/groups`; editing permissions and the backend
allowlist are unchanged. No administrator password or copied station token is
required.

Group-menu bindings observe group changes independently of camera counts.
Switching station/operator mode while already authenticated refreshes the
applicable definitions after the new identity is applied. Routine token
renewal does not trigger this work. An unchanged camera roster is patched
through the existing poll instead of resetting camera delegates. Late group
responses from an old backend/session are discarded.

## Verification and deployment status

The isolated fixture in `tools/tests/station-groups` uses the actual camera
model and shipping menu components, loopback metadata and disposable settings.
Its copied executable is renamed `camera-groups-fixture.exe`, so it cannot be
mistaken for the guard's running `watchtower.exe` by name.

The old installed executable reproduces the station failure: group definitions
and all six counts fail, while the normal operator scenario passes 13 QML
checks. The retained negative-control result is
`C:\wt\camera-groups-baseline-20261110\result.json`.

Candidate 1.1.799 was built from clean commit
`8ca6fa735c725f67cea73471e9ad883fc097de82`. Its fresh build and embedded commit
checks passed. The executable SHA-256 is
`E3C453EA40479E1F96B8C06393FC700669007ECD696634D04C34EF5D53B44ACC`.
The initial configure attempt failed because a build-tool environment export
misdecoded the Cyrillic user-profile path. Restoring the caller's Unicode
profile paths in the private build process allowed a fresh build to complete.
The first failed run remains recorded separately.

Both candidate scenarios passed with zero failures, totaling 22 runner checks
and 54 real QML checks. They include both group menus, station/operator
transitions, delayed-response loading recovery, group changes through normal
polling and unchanged camera delegates. The earlier negative control predates
the added playback/loading cases. The evidence is retained in
`C:\wt\camera-groups-build-20261110-r2\build-proof.json` and
`C:\wt\camera-groups-fixed-20261110\result.json`. All fixture processes exited.

Deployment remains pending. Two real Booth windows are open under different
sign-ins. The supervised station window shows All Cameras; a separate manual
operator window shows 4стр. The operator has been asked which view to preserve.
Neither window has been closed for this task. Shared video logs contain mixed
samples from both windows, so the updater's single-window/video admission must
pass again after the intended view is confirmed.

The Booth watchdog exports no `RunLevel` XML element while the independent
Windows task API reports the typed `Limited` value. The deployment adapter now
accepts this omitted default only with that independent agreement. Explicit
least privilege remains supported. Conflicting, malformed or ambiguous values
still fail before any task/process change. The function-only disposable suite
passed 67 checks in each of Windows PowerShell 5.1 and PowerShell 7. The task
definition itself was not changed. Deployment-tool provenance is separate from
the frozen 1.1.799 application build.

The existing disposable deployment suite passed 24 cases and the pure video-log
suite passed 46 cases in each PowerShell engine. The process-free startup
monitor suite passed 27 cases. These checks do not replace live acceptance.

An isolated native startup check, protected application replacement, automatic
rollback checks and final production menu/video inspection remain unfinished.
Do not describe the Booth dropdown as repaired before those checks pass.

GitHub currently rejects the session's saved access, and the connected branch
read returned 404. Remote-source freshness and publication remain unverified
until access is restored. Local repair work continues against the known source.
No authentication policy, camera configuration or operating-system security
setting is changed by this correction.
