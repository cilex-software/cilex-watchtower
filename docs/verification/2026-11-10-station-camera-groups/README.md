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

The fixed candidate has not yet completed its build/fixture/deployment checks
at this source checkpoint. Do not describe the production dropdown as repaired
until the compiled fix passes and the Booth menu/video are inspected.

GitHub currently rejects the session's saved access, and the connected branch
read returned 404. Remote-source freshness and publication remain unverified
until access is restored. Local repair work continues against the known source.
No authentication policy, camera configuration or operating-system security
setting is changed by this correction.
