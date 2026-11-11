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

Two real Booth windows initially used different sign-ins. Shared video logs
contained mixed samples, so the updater correctly required one supervised wall
and fresh video samples. The operator subsequently chose 4стр with operator
sign-in. The original station window was closed cleanly through the UI while
the manual operator wall stayed open. Its supervised replacement was observed
before the extra manual window was closed. A fresh single-process baseline
verified seven advancing feeds with zero stream errors. Evidence is retained in
`C:\wt\camera-groups-operator-handover-20261111.json`.

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

## Booth installation and final acceptance

The isolated native startup check passed for 40.078 seconds with private settings,
zero second-chance faults and termination of its own child. Source and packaged
Warden status checks passed for the unchanged 1.5.0 files. Installed Warden source
uses CRLF while the repository uses LF; ordinal text comparison confirms that
line endings are the only difference. Exact installed byte hashes remain pinned
throughout preparation and installation. The first preparation attempt refused
that byte difference before creating a run directory. A private helper parameter
was also renamed to avoid PowerShell's reserved HOME variable before execution.

The reviewed Booth adapter installed the application and symbols, retaining the
same Warden files. Its result is Success after 152 seconds of supervised startup
and advancing video. Backup files remain in the run directory. Rollback was not
exercised during this successful installation.

The helper-launched app opened station sign-in with a stale saved view. It did
show all six groups, including their expected station counts. This established
the live station fix, but did not satisfy the requested operator view. No saved
operator credentials were extracted or copied. Repeating startup through the original verified
watchdog task restored the operator session. The 4стр dropdown selection then
restored the original nine-cell arrangement with seven live feeds and the same
two offline cells. The operator menu also shows all six groups, with its scoped
counts. The earlier restart check did not establish final sign-in continuity.

The final normal-task chain is watchdog 14580, Python Warden 3536 and Watchtower
17248 in guard session 1. The final check passed for 152 seconds. Its last
30-second sample advanced by 2,465 frames with seven decoders, seven lit cells
and zero stream errors. The task is enabled and Running. Application hash and
version match the admitted 1.1.799 build. Warden files, Warden configuration and
Labs control retain their original hashes. The normal-task handover used the
verified original seven-feed baseline for the requested view, and separately
verified active video immediately before its scoped stop.

Evidence is under `C:\wt\camera-groups-rollout-20261110-nov11`.

- `preflight.json` and `native-startup.json` record isolated admission.
- `deployment-result.json` records the protected installation and task restoration.
- `normal-startup.json` records the task-owned startup and final moving video.
- `acceptance.json` records final ancestry, hashes and visual menu/view acceptance.
- `backup` retains the prior application, symbols and unchanged Warden files.

The helper and original task saw different saved session/view state despite the
same observed user, session and ordinary profile paths. No settings override or
package identity was found. HKCU and direct guard-hive reads from the inspection
context agreed with each other but did not explain the task-launched operator
session. The cause remains unresolved. Future Booth updates must verify the
original task's startup and the actual sign-in/view, beyond a helper's process
and frame checks. Reboot startup, extended endurance and a full fresh package or
exporter installation were not tested. No reboot or security-policy change was
performed.

GitHub rejected a fresh noninteractive access check on November 12 Moscow time;
the earlier connected branch read also returned 404. Remote-source freshness and
publication remain unverified until access is restored. The compiled application
remains tied to its recorded source commit; later tools/documentation versions
do not relabel that binary.
No authentication policy, camera configuration or operating-system security
setting is changed by this correction.
