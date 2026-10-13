# Build and update Security Booth and Office

Run `build-and-update.ps1` from the Security Booth, signed in as the guard.
It builds the latest GitHub source, checks it, then updates Watchtower and
Warden on the Booth and Office. Each camera window briefly restarts.

The script keeps backups and restores the previous files if the new app
does not start correctly. It checks that the same supervised app stays up
for 150 seconds on each machine, including a check that camera frames advance. This is a startup and recovery check, not
a guarantee that every feature or future network condition is fault-free.

## Current purpose and limits

This is a maintenance updater for the already configured Security Booth and
Office stations. It requires an existing repository checkout, provisioned
build tools, installed Watchtower/Warden, working startup tasks, a signed-in
operator and healthy camera video. Its build checks use an existing station's
runtime files.

It is not a first-install or general Windows provisioning script. Changing
hostnames or paths does not make it suitable for a fresh machine. It does not
clone the initial repository, install missing build tools, assemble a complete
new-machine installer, enroll a new station or configure unattended sign-in.

The separate generic deployment script is currently a specification, not an
implemented feature. See the [technical specification](../../../docs/plans/2026-10-13-generic-windows-deployment-specification.md).
This maintenance script and its behavior remain unchanged.

## Quick start

Open PowerShell 7 in the repository folder. Preview the action first:

```powershell
pwsh -NoProfile -File .\packaging\windows\deploy\build-and-update.ps1 -WhatIf
```

Build and test without replacing either installation:

```powershell
pwsh -NoProfile -File .\packaging\windows\deploy\build-and-update.ps1 -BuildOnly
```

Build, test and update both machines:

```powershell
pwsh -NoProfile -File .\packaging\windows\deploy\build-and-update.ps1
```

The default targets are `WT-SM-VNUTRI-01` and Office `192.168.1.5`
(`WT-OFFICE-01`). The default source is the freshly fetched `origin/main`.
The script records the exact revision before building; a later GitHub
change does not alter an update already in progress.
Older source revisions without the private-startup-settings test hook are
refused before an app probe can run.

## Before running

- Both machines need their existing Watchtower/Warden installations and a
  signed-in desktop user. Run from the guard's normal Booth session.
- Camera video and its diagnostic log must already be working. Keep the
  selected camera view unchanged during the update. Missing, stale or stalled
  video is refused before the script stops an app.
- The Booth uses Python Warden and `wt-warden-guard`; Office uses the
  packaged Warden and its existing `wt-warden` task. These startup methods
  must already be working. The guard needs permission to control its own
  watchdog task.
- Booth Labs must be stopped, with no Labs startup task. Existing pause
  files are preserved. Office analysis must be paused/stopped and drained
  through its normal admin controls before updating. The script refuses
  active or claim-enabled analysis work.
- Office administrator access must already work through its `C$` share
  and Service Control Manager. No password belongs in a script or command.
- The Booth needs its provisioned tools: PowerShell 7.2+, Git, MSVC 2022,
  CMake/Ninja, Qt 6.12, GStreamer development files, and Python with
  PyInstaller and `pefile`. The script does not install or upgrade SDKs.

Default tool locations are the existing Booth paths under `C:\wt`.
`-QtRoot`, `-GStreamerRoot`, `-PkgConfig` and `-PythonPath` can select other
already provisioned tools.

If Office needs a fresh login, use PowerShell's protected credential prompt:

```powershell
$officeLogin = Get-Credential -UserName wtcopy
.\packaging\windows\deploy\build-and-update.ps1 -OfficeCredential $officeLogin
```

The credential stays in memory. It is not passed to process command lines,
saved to files, logged, or committed. The temporary Windows network
connection may remain for the current login session; existing connections
are never disconnected automatically.

## Useful options

```powershell
# Update only the Booth.
.\packaging\windows\deploy\build-and-update.ps1 -Targets Booth

# Update only Office; the build still runs on the Booth.
.\packaging\windows\deploy\build-and-update.ps1 -Targets Office
```

| Option | Purpose |
|---|---|
| `-BuildOnly` | Build and run checks; leave application files alone. |
| `-WhatIf` | Show the action without fetching, building or contacting stations. |
| `-SourceRef` | Select a branch or exact Git revision instead of `origin/main`. |
| `-WorkRoot` | Store runs outside the repository; default `C:\wt\station-updates`. |
| `-BuildJobs` | Use 1-4 compiler jobs; default 4 at reduced priority. |
| `-OfficeAddress` / `-ExpectedOfficeHost` | Select and verify the Office machine. |
| `-OfficeCredential` | Provide a protected PowerShell credential if needed. |
| `-BoothFlightRecorderPath` / `-OfficeFlightRecorderPath` | Set an existing diagnostic log path when it differs from the standard user profile location. |
| `-JobTimeoutSeconds` | Bound station job waiting; default 1,200 seconds. |

## Checks and update behavior

Every run uses a new clean source folder and retains its build files,
symbols, hashes and results. Existing checkout changes are preserved.

The checks include file-recovery failure tests, the available camera
obstruction contract and UI tests, version/symbol checks, and 40 seconds
of monitored app startup. The Windows UI fixture changes only its
temporary screenshot output path; its assertions remain unchanged.
Startup checks use a separate home directory and a private Windows settings
area inside the test process, created before the app runs. They disable
station enrollment and protocol registration. The guard's saved sign-in
is not loaded. Arbitrary app debug output is not saved by the entry script.

Existing Warden executables are reused only when their embedded code
matches the selected source. Otherwise a new package is built and checked.
Each station checks its own new executable before replacing live files.
If a newly required runtime library is detected, the update stops rather
than attempting a partial runtime upgrade. Per-machine startup checks
also reject missing or incompatible existing libraries.

Before stopping a camera wall, the station verifies its user, desktop
session, paths, process creation times and startup task. It backs up and
checks the existing files, replaces files through verified temporary
copies, restores supervision, and watches the new process for 150 seconds.

The video check reads only numeric diagnostics tied to the verified app.
It requires advancing frames, no stream errors, and at least the previous
feed and decoder counts. It checks the final observation window; it cannot
prove each camera's identity or future network conditions. No raw stream
addresses or credentials are saved. HTTP/HLS playback is conservatively
refused because these camera counters cannot verify it.

Shared locks prevent overlapping updates. Office uses a temporary
deployment service; the service is removed after job submission, and
success is reported only after the matching result is received.

The script does not reboot, configure automatic sign-in, relax security
policies, change task actions/accounts, clear operator holds, or publish
Git changes. Office's existing analysis safety guard may pause analysis
after the camera app restarts; it releases only its own hold after its
configured healthy interval. Server/operator pauses remain in place.

## Results and recovery

The last output gives the run's `result.json` path. The default directory is:

```text
C:\wt\station-updates\RUN-ID\
```

It contains the pinned source, build/test logs, checked manifests, station
results and Booth backups. Office retains its files under
`C:\Users\Public\Downloads\WatchtowerDeploy\RUN-ID` and its recovery
data under `C:\ProgramData\CilexWatchtower\CodexDeploy\job-JOB-ID`. The Office
result records the exact backup and test directories.

| Result | Action |
|---|---|
| `BuildVerified` | Checks passed; no deployment was requested. |
| `Success` | All selected station updates completed and were stable. |
| `RolledBack` / `rolledback` in a station result | The previous files were restored. Read the reason before retrying. |
| Completion unknown or recovery incomplete | Leave the recovery job running. Inspect its result and live station before any retry or manual file replacement. |
| Windows refuses a new executable | Keep the existing wall running and report the refusal. Do not bypass policy or repeatedly relink to evade it. |

Keep backups until the new version has been accepted. Do not delete a
source worktree as an ordinary folder; remove it through Git only after
the retained source and symbols are no longer needed. Logs and temporary
services are not evidence of success on their own; use the result files.
If the controller stops after one station reports success, check that station
and its saved result before retrying. Update only the unfinished station with
`-Targets Booth` or `-Targets Office`; avoid repeating a completed restart.

## Safe local script checks

These checks use temporary files and invalid inputs; they do not contact
Office or stop applications:

```powershell
pwsh -NoProfile -File .\packaging\windows\deploy\tests\test-station-deployment.ps1
```

The test records remain separate from live application data. They cover
failed/partial copies, wrong hashes, restored files, introduced symbols,
unknown-file refusal, locked files, invalid paths/manifests and preview
mode. A live deployment run is still required to validate real startup
and supervision on the two stations.

The additional process-free startup-monitor checks run automatically in
each build. They check private marker ownership/paths, refused older
executables, clean test environments and safe output directories.

Validated on Windows on 13 October 2026: 24 recovery/refusal checks, 46
video-health checks, 27
startup-monitor checks, 9 interface checks, the camera-obstruction contract,
and a full new app startup lasting 40 seconds with private settings and no
fatal faults. A controller regression also checks that a completed updater
returns while its supervised child stays running.

Watchtower 1.1.778 and the source-matched Warden 1.4.10 were verified running
on both stations. Office needed one controlled app recovery after a stream
stall; its sixteen feeds then advanced for four minutes without errors.
Booth video and supervision also passed independent checks. Reboot and
automatic sign-in were not tested.
