# Generic Windows deployment: verification on 2026-10-13

The source build, packaging and revised automated checks passed: 487 checks
through Windows PowerShell 5.1 plus eight Python checks. The revised Office
update installed Watchtower 1.1.779 and Warden 1.4.10. Its visible window,
supervision and 31 advancing feeds passed the 150-second startup check with zero
stream errors. Both authorized recovery drills also passed. The earlier failed attempt and
controlled recovery remain documented below.
Microsoft Autologon setup was not completed for Office's existing account without
a password. The tool/task have been cleaned up; account and security settings
are unchanged. No reboot has been performed. The guard's existing
Watchtower was kept running throughout these checks.

Use the [deployment guide](../../../packaging/windows/generic/README.md) for
commands and the [specification](../../plans/2026-10-13-generic-windows-deployment-specification.md)
for the intended acceptance criteria. Passing the checks below does not establish
complete acceptance of that specification.

## Acceptance matrix

| Area | Result | What the evidence establishes |
| --- | --- | --- |
| Windows PowerShell 5.1 compatibility and fixtures | PASS | The final full run passed 487 checks, including 34 native-launcher checks, through an actual PowerShell 7 parent launching native 5.1 children. Fixtures do not establish live recovery. |
| PowerShell 7 starting Windows PowerShell 5.1 tools | PASS, limited | Common/source passed 36 checks on each host after resetting the native child module path after environment overrides. |
| Runtime dependency scanner fixtures | PASS | Eight Python checks passed. |
| Latest main source acquisition and compilation | PASS | Freshly fetched source `820823ccf88179f8b0ed286f9622149637ca9828` built Watchtower 1.1.779 and Warden 1.4.10. |
| Exact tag and missing tag behavior | PASS | `windows-latest` resolved to its exact commit; an invalid tag was refused without fetching main. |
| Packaged DLL imports | PASS, limited | The original static scan checked 162 executable/library files; the current package with its native launcher passed the 163-file scan. Dynamic library loading still requires runtime testing. |
| Export component | PASS, limited | A generated fixture was encoded and decoded with the packaged FFmpeg. This is not a real camera export test. |
| Isolated Watchtower startup | PASS, limited | The private test process remained alive for 40.015 seconds with no recorded second-chance fault. Its settings were isolated from the guard's station. |
| Native Warden package | PASS, limited | Source/version matching, isolated status checks, installed Office launcher/Warden/Watchtower chain and both authorized recovery drills passed. |
| Self-contained EXE construction and extraction | PASS, limited | The final EXE extracted successfully; 1,752 payload files and seven helpers passed their manifest checks. Clean offline installation remains unverified. |
| Standalone bootstrap bundle | PASS, limited | The final ZIP was extracted, source hashes matched, and its bundled suites passed 487 checks plus eight Python tests. A clean-machine provisioning run remains unverified. |
| New computer build-tool bootstrap | UNVERIFIED | The real build reused available tools; a clean computer starting without those tools was not tested. |
| Clean offline installation | UNVERIFIED | No clean Windows/VM installation was performed. Extraction alone does not prove installation. |
| Qt Multimedia playback | UNVERIFIED | Static imports, live camera rendering and FFmpeg tests do not prove representative Qt playback. |
| Office new-version installation and live cameras | PASS, limited | Revised run `office-test-2f6baf3bf7cf` installed 1.1.779/1.4.10 and verified the visible window, correct supervision and 31 advancing feeds after 150 seconds, with zero stream errors. Startup after reboot and enrollment remain deferred. |
| Office recovery | PASS, limited | A separate controlled recovery restored the previous version. The visible window/16 feeds were confirmed initially; the later 18:27 UTC baseline showed 31 feeds, advancing frames and zero errors at 1,890 seconds of uninterrupted runtime. This does not make the original automatic rollback a pass. |
| Office automatic application/supervisor recovery | PASS | Application recovery took 4.2 seconds. After supervisor failure, the old group was gone in 1.4 seconds and exactly one replacement returned in 57.8 seconds. Each then passed 150 seconds of visible, healthy 31-feed operation. |
| Final Office configuration and test cleanup | PASS | Managed task enabled/running, legacy task disabled, installed binaries match the package, existing non-runtime settings preserved, visible healthy 31 feeds, and temporary test tasks/services removed. |
| Office policy-refusal handling and helper cleanup | PASS, limited | The production launcher reported the policy block and its temporary service was confirmed removed. The test used a read-only dummy helper. |
| Office unattended startup | UNVERIFIED | Microsoft Autologon setup was not completed for the existing account without a password. Its task was removed without account/security changes. Public `AutoAdminLogon` was `0` at the last check; the existing Windows sign-in behavior still needs the authorized reboot test. |
| Security Booth service continuity | OBSERVED | Root recorded the existing Watchtower PID 18672 with Warden parent PID 23776 unchanged. No Booth deployment or reboot was performed. |
| Hardware/camera capacity | UNVERIFIED | Requirements remain provisional; no capacity benchmark was run. |

## Automated checks actually run

The final `packaging/windows/generic/tests/run-tests.ps1` run used a PowerShell
7.6.5 parent and native Windows PowerShell 5.1 children. It passed, with the
following counts confirmed in the saved log:

| Suite | Passing checks |
| --- | ---: |
| Requirements | 27 |
| Dependencies | 115 |
| Common/source | 36 |
| Entry point | 30 |
| Installation/recovery fixtures | 127 |
| Remote transport fixtures | 69 |
| Build/installer fixtures | 49 |
| Native launcher lifecycle checks | 34 |
| **Checks through Windows PowerShell 5.1** | **487** |
| Python runtime-closure fixtures, separate | 8 |

The final saved records are
`C:\wt\generic-final-fixtures-20261013-ps7-child-fixed\checks.log` and
`result.json`; both were independently read. These counts describe that executed
source snapshot, not live machine acceptance or any later repair.
Missing/disabled tasks and wrong task account/action are
refused before startup verification. Cross-session read-only verification defers
visibility; installation can use a bounded target-user observation task and
verify its cleanup.

Development exposed inherited module-path incompatibility when a
PowerShell 7 host launched inbox Windows PowerShell 5.1. `Invoke-WtgProcess` now
resets the native child module path after applying environment overrides.
The revised common/source suite passed 36 checks on native 5.1 and on the actual
PowerShell 7 host. The final full run includes that repaired path.

A later full-run native fixture failed to become ready; its evidence is retained
at `C:\wt\generic-final-fixtures-20261013-1825`. The cause of that readiness
failure is unproven. A bounded explicit readiness handshake and exit diagnostics
were added; the revised native fixture then passed 34 checks in the final full
run. Use `run-tests.ps1 -VsDevCmdPath ...`
to include native compilation/lifecycle checks, together with `-PythonPath` and
`-MakensisPath` for their corresponding optional suites.

The earlier native run at
`C:\wt\generic-final-fixtures-20261013-1739` passed 369 checks plus eight Python
checks between `17:40:01.7933174 UTC` and `17:40:26.5359554 UTC`. It is retained
as development evidence and superseded for current validation by the final run;
the two totals must not be added together.

Read-only Booth tool discovery also passed. Requirement inspection did not
create its proposed cache directory or install anything.

## Actual source build

Build run:
`C:\wt\generic-deployment-final-runs\20261013-163830-94f44076`

The real `BuildInstaller` run started at `2026-10-13T16:38:30.9403003Z` and
completed at `2026-10-13T16:46:55.5612022Z`, with status `InstallerBuilt` and exit
code 0. Source was freshly fetched main, pinned to:

```text
820823ccf88179f8b0ed286f9622149637ca9828
Watchtower 1.1.779
Warden 1.4.10
```

The build used Qt 6.12.0 and Python 3.12.10. Results and supporting records are in:

- `result.json`: source, versions, requirements, accepted findings and build checks.
- `source.json`: acquired source identity.
- `runtime-closure.json`: 162 files checked, static imports only.
- `startup-result.json`: isolated process lifetime and fault observations.
- `export-fixture.mp4`, `export-fixture.log`, `decode-fixture.log`: export fixture.
- `build.log`, `configure.log`, `build-warden.log`: build output.

The private startup process was PID 24284, created at
`2026-10-13T16:42:31.712495+00:00`. The check terminated only its own test child
after observation (`TerminatedOwnChild=true`). It did not install the new build
over the guard's running application. The test ran on the existing build machine,
so it is not evidence of clean-machine compatibility.

## Current sealed package and installer

The next Office attempt uses the package sealed after the final 487-check run:

```text
C:\wt\generic-deployment-final-runs\packaging-20261013-183756-3a288623\package
Manifest SHA256: 8ddf0a7ce93f605f7d0ad66a334ce6470e441c2bf1da646a25d4ae1b826dca9a
Payload files: 1752
Helper files: 7
```

Its manifest was independently read and hashed. It retains Watchtower 1.1.779,
Warden 1.4.10 and source commit `820823ccf88179f8b0ed286f9622149637ca9828`, and adds
deployment launcher 1.0.0. The launcher source SHA-256 is
`fadec0cea5e0da6b10ff5ce4df909b48e309dd2133b6a3019f71641d466d204b`;
the included binary SHA-256 is
`16728af0c3dd2f7c30e1f2d5b529874150089d6c9fd1ec54554ec9783a8de9ff`.
The current runtime closure check covers 163 executable/library files. The final
EXE was built and actually extracted; all 1,752 payload files and seven helpers
passed verification. Its SHA-256 was independently recalculated:

```text
C:\wt\generic-deployment-final-output\packaging-20261013-183756-3a288623\CilexWatchtower-1.1.779-820823cc-windows-x64-setup.exe
Size:   131073659 bytes
SHA256: 0ded7f9c05b72379d56ef2342d01a28ead076401133f42eb2a64b8d80d400934
```

The installer is unsigned. Clean offline installation remains unverified.
Packaging evidence is
`C:\wt\generic-deployment-final-runs\packaging-20261013-183756-3a288623\result.json`
with status `PackagedAndExtracted`. The separate revised Office installation
passed current-session checks as recorded below; clean offline installation
must not be inferred from package extraction.

## Earlier tested installer, superseded

The runtime from the verified build was repackaged with updated installation
helpers and dependency provenance. Runtime binary bytes remained unchanged.
This earlier tested EXE superseded the original build's installer. It is now
superseded by the package above and is retained only as evidence of the failed
Office attempt:

```text
C:\wt\generic-deployment-final-output\packaging-20261013-173924-c6f36f65\CilexWatchtower-1.1.779-820823cc-windows-x64-setup.exe
Size:   131041909 bytes
SHA256: 41543911a40800225eefd29645dc1e992cd37f99b010881d6136117c31dd1743
```

The EXE is **unsigned**. It was actually extracted and the extracted payload and
helpers were checked against the manifest; extracted helpers also matched the
source used for packaging. The same verified raw package was used for the
subsequent Office attempt described below.

Packaging evidence:

```text
C:\wt\generic-deployment-final-runs\packaging-20261013-173924-c6f36f65\result.json
C:\wt\generic-deployment-final-runs\packaging-20261013-173924-c6f36f65\package\manifest.json
C:\wt\generic-deployment-final-runs\packaging-20261013-173924-c6f36f65\extracted
```

## Final standalone bootstrap

```text
C:\wt\generic-deployment-final-output\packaging-20261013-183756-3a288623\CilexWatchtower-bootstrap-20261013-183756-3a288623-final.zip
Size:   159955 bytes
SHA256: d25926e554d024c02a47a3114f08c6de57e2d2f85fddd50e9737920ee69b8ef3
Entry:  packaging/windows/deploy-watchtower.ps1
```

The ZIP hash was independently recalculated. The builder extracted it and
verified all 32 manifest-listed source files against the frozen source. Its bundled full suite passed the same
487 checks plus eight Python tests; this is a repeated validation of the actual
distribution, not additional distinct coverage to add to the test total.
The saved log was independently read at
`C:\wt\generic-deployment-final-runs\packaging-20261013-183756-3a288623\bootstrap-final\bundled-tests.log`.
The `Bootstrap` and `BootstrapVerification` records are in the parent packaging
run's `result.json`, not a separate `bootstrap-final\result.json`.

The guide inside this ZIP is frozen. Later cleanup and reboot evidence belongs
in this external record. The bootstrap contains deployment tools, not the
application runtime, and clean-machine provisioning is still unverified.

## Exact-tag and invalid-tag acquisition

Evidence directory:
`C:\wt\generic-source-acceptance-20261013-164001-69ecccfc`

The read-only repository acquisition checks ran from
`2026-10-13T16:40:01.9653759Z` to `2026-10-13T16:40:19.8722467Z` using existing
authorized Git credentials. No credential was placed in the result record.

- Remote tag `windows-latest` resolved to
  `73ef50c7419aeec59faa48453df80857289998fe`; detached HEAD matched that commit.
  Its source reports Watchtower 1.1.44 and `FetchedMain=false`.
- A unique nonexistent tag was refused. The failed acquisition had neither a
  checked-out HEAD nor fetched refs, proving it did not silently choose main.
- The tagged historical source was not built; this verifies exact acquisition,
  not compatibility of every historical version with the current toolchain.

## Evidence hashes

These SHA-256 values were read from the named non-secret JSON files. Paths under
the build run are relative to
`C:\wt\generic-deployment-final-runs\20261013-163830-94f44076`.

| Record | SHA-256 |
| --- | --- |
| Build `result.json` | `231cb8bbb6734f62509ad0634a830bc57f29f020dfa0e109a5b209b26fac494b` |
| Build `source.json` | `3dfe24945b5fc96616cc513f750cb79ead601b5e53b34963d9d0bb6354804e84` |
| Build `startup-result.json` | `192d0640fb328c9147b8bf0194bc0e0e70cff78c8308fa69192a5037a197f284` |
| Build `runtime-closure.json` | `4db44e2d09191b16e95200878eebb23e467c2fabf08e67287e7fd769af035cd7` |
| Source acceptance `results.json` | `b300b94488fc068081ad4e64aa2ba8cec7f0639b6123fe48a82b138cbfd2adc4` |
| Superseded 17:39 packaging `result.json` | `1cd16db6e0857801bce10686591439b8175a8ec15329f998698dc6f0d8e9e41e` |
| Superseded 17:39 package `manifest.json` | `15a92ee64391f0d20ccf2b91165fc42e6a5ed551f3fd3b2d2a57022865f95c32` |
| Current 18:37 package `manifest.json` | `8ddf0a7ce93f605f7d0ad66a334ce6470e441c2bf1da646a25d4ae1b826dca9a` |
| Current 18:37 packaging `result.json`, including final bootstrap | `301351107eeb38ae1861919cfccb4253a7559ac9aaab7fa3e5c4bd72d565744e` |
| Final bootstrap `bundled-tests.log` | `659f645885bb6e0ebacc6f59998ccccb574bfb7ed9f6bb0dd0e9383cb5b6b7cb` |
| Earlier 369-check fixture `result.json` | `c9aeb954128efe76462b763168f9c22828184b131eaefb437567b82469e365e2` |
| Earlier 369-check fixture `checks.log` | `6785b1cfcd65d70d24f96f054ddeaffc22c2d7ff863c024292aab1ac9125167d` |
| Final 487-check fixture `result.json` | `e3b6acdfad21680c5085aa706544031bae8f410908f2d0024194a6324d344509` |
| Final 487-check fixture `checks.log` | `07ff0bec2afbc34c6b21c72d885bdb84d9e242f690cbe8ca59d5d18b64b113e9` |
| Revised Office installation `result.json` | `301faec3715eaa12f44aaed03820c011e03d7823d4c67cd8c05bfd5480b83d21` |
| Office application recovery `result.json` | `b35095d66b0006df798d2cfb4327518b18f3db05f9b260e378b6f6191125dcbf` |
| Office supervisor recovery `result.json` | `9a7400807e6ad77df61acfc2471b54aa623475eb7b5125f1d083ff0586b59e3e` |
| Final Office inspection `result.json` | `e1bab87792c43bafb02aab52a21ec800ac58d6214ad6f053c7bd693e4ee78800` |
| Final Office `record-and-cleanup-verification.json` | `c1930e3c8629b0442c791ebb5762485babd6ad4e8d50c7e54c385b99acab8de7` |

The Office read-only effective-policy record is on Office at
`C:\ProgramData\CilexWatchtower\Deploy\preflight-f9ddf43c452c\effective.json`.
It was reported by the root agent; this document does not claim an independently
copied or hashed local record for it. Password values and LSA secrets were not
needed for these checks and are not included here.

The subsequent production-launcher check used the protected default staging root
`C:\CilexWatchtower-Deploy` on Office. It returned
`REMOTE_SCRIPT_POLICY_BLOCKED`; the exact temporary service was confirmed absent
(Windows result 1060). The helper was a read-only fixture. Installed application
files, scheduled tasks and security policies were not changed.

Its local record is
`C:\wt\generic-office-policy-validation-policy-a5efe6e95cdd\verification.json`,
SHA-256
`10dbe867c32ad55ea56e7a3937410c2b5caf63529da97169aaaa7cf971593fb7`.
Remote evidence remains at
`C:\CilexWatchtower-Deploy\policy-a5efe6e95cdd`.

## Revised Office installation

Run `office-test-2f6baf3bf7cf` completed at
`2026-10-13T18:47:25.4326403 UTC`. Its independently read record is
`C:\wt\generic-office-approved-office-test-2f6baf3bf7cf\result.json`:

- Status `InstalledWithDeferredChecks`; Watchtower 1.1.779 and Warden 1.4.10,
  source `820823ccf88179f8b0ed286f9622149637ca9828`.
- Current-session runtime and window verified; the temporary window observer's
  cleanup was verified. Correct target SID and session 1 were confirmed.
- Native launcher PID 16692 → packaged Warden 12036 → supervisor 8852 →
  Watchtower 12564. The application started at `18:44:43.016 UTC` and passed
  the 150-second stable-startup check.
- All 31 expected feeds were present. The final video proof recorded 8,632
  additional frames over 29.986 seconds, with zero errors.
- Startup task: `CilexWatchtower-2C40105CD30C9B6A`.
- Backup retained at
  `C:\Users\Админ\AppData\Local\Programs\.cilex-backup-office-test-2f6baf3bf7cf`.

Labs' task remained unchanged and its server stop/zero-unit state was preserved.
The existing Labs guard set its own protective hold during replacement; the
deployment did not clear or overwrite that hold. Both subsequent automatic
recovery drills passed, as recorded below.

Startup remains `UnattendedSetupRequired` and `RebootVerified=false`. No account
or security setting was changed. The authorized reboot is waiting for the user
to confirm whether open terminal work needs saving; no reboot has occurred.

## Authorized Office recovery drills

These tests ran only on the newly installed, healthy Office station. Each test
bound its deliberate process termination to the exact installed file, hash,
owner SID, session and process creation time. Automatic recovery was observed
before any manual rescue; neither passing test required rescue. Both then used
the same 150-second startup, window and video verification.

| Test | Recorded outcome | Evidence |
| --- | --- | --- |
| Watchtower process failure | Automatic recovery in 4.2 seconds; the original Warden and launcher remained unchanged. Visible application, all 31 feeds and zero errors passed the health check. | `C:\wt\generic-office-approved-recoverydrill-6e4cdf558c8c\result.json` |
| Inner Warden supervisor failure | Original group gone within 1.4 seconds; exactly one replacement group returned automatically in 57.8 seconds, without overlap. Visible application, all 31 feeds and zero errors passed the health check. | `C:\wt\generic-office-approved-recoverydrill-192d7e52c474\result.json` |

Both records were independently read and hashed. The application test ran from
`18:48:43.3409567 UTC` to `18:51:33.5330321 UTC`; its final sample gained 8,755
frames in 30.029 seconds. The supervisor test ran from `18:52:40.4648 UTC` to
`18:56:23.9446223 UTC`; its final sample gained 10,155 frames in 29.999 seconds.
The latter ended with Watchtower PID 9256 under supervisor 14272, packaged Warden
8916 and launcher 3576 in the intended desktop session.

Labs control and task hashes matched before/after each test. Its protective hold
was preserved. The Security Booth application was not used for either test.
A reboot/sign-in test remains separate and unperformed.

## Final Office inspection and cleanup

The final read-only inspection at `18:57:07.8644501 UTC` is saved in
`C:\wt\generic-office-approved-postcheck-67b1c67126e6\result.json`.
Its installed process group and three executable hashes matched the package.
The managed task was enabled/running with one-minute recovery; legacy
`wt-warden` was disabled. The application window was verified, and the latest
sample showed all 31 feeds, advancing video and zero errors. Existing non-runtime
Warden settings were preserved. Labs remained held, server-stopped and at zero
units, with its task unchanged.

The first one-use observer omitted explicit UTF-8 when reading the marker and
therefore reported a record mismatch. The companion
`record-and-cleanup-verification.json`, at `18:58:56.3607714 UTC`, used native
Windows PowerShell 5.1 and explicit UTF-8 and confirmed `ManagedRecordState=Current`.
The product reader already specifies UTF-8; no product repair was needed for
this observer error. Both records are retained so the correction is traceable.

All temporary test/observation tasks were absent. The inspection's stopped
transport service was then removed and confirmed absent by the companion
record. No helper remained running. Evidence files, the installer/bootstrap and
the installation backup were intentionally retained. No reboot, account change
or persistent security-policy change occurred.

## Earlier failed Office attempt and controlled recovery

After the policy-refusal test, the operator explicitly approved a temporary
script-execution exception for the Office test. This separate permission did
not change the generic script's default behavior or authorize persistent policy
weakening. Target-user visibility/adoption preflight passed; its final record is
`C:\wt\generic-office-approved-preflight-d2117e166ef9\result.json`.

Run `office-test-b35aaa1e4923` then attempted the Office update using the package
manifest hash recorded above. Its saved result is `Failed` with
`INSTALL_FAILED_ROLLBACK_UNVERIFIED`. Evidence is retained at:

```text
C:\wt\generic-office-approved-office-test-b35aaa1e4923
Office: C:\CilexWatchtower-Deploy\office-test-b35aaa1e4923\install-result.json
```

The installation agent separately restored the prior application and startup
task. The early recovery snapshot is
`C:\wt\generic-office-approved-recovery-12f20c3cdec5\result.json`: Watchtower
1.1.778.0 was running as PID 5860 under Warden PID 13108 in the intended user's
session 1. That immediate snapshot preceded fresh video telemetry. A later
check confirmed the window, and samples at 150, 180 and 210 seconds of application
runtime showed all 16 feeds, advancing frames and zero stream errors. Its record is
`C:\wt\generic-office-approved-rollbackdiag-eaf04bb0907f\result.json`
(sample `17:59:12.759 UTC`, record `17:59:18.4357182 UTC`), SHA-256
`fed333d0d46a92f27c6dc15d2943d2ce801664c3d70054346a4d1d22b5cd1652`.
This establishes the observed recovery, not successful automatic
rollback of the original failed run.

The update exposed a Windows PowerShell 5.1 `String.Split` overload error while
reading the existing `APP_ENV` setting. The parser was repaired, and the
installation agent reports 127 passing installation fixtures after subsequent repairs.
The final 487-check run includes those fixtures. The later installation above
passed current-session health checks; this does not retroactively make the
earlier automatic rollback a pass.

Labs safety state was inspected without changing it. Before the update there
was no local hold and the server state was `stopped_by_server`. At 17:47:45 UTC,
the existing `wall-guard` recorded a hold because no wall application was running.
The held state matched that reason. This explains the changed control file hash;
the deployment did not need to write or clear Labs state. The guard later cleared
its own hold through its normal release rule; no manual release was performed.
The fresh baseline at `18:27:13.1473527 UTC` is
`C:\wt\generic-office-approved-preflight-706a39f62011\result.json`.
Its video sample at `18:27:12.771 UTC` shows PID 5860 still running at 1,890 seconds
uptime, 31 lit feeds/decoders, advancing frames and zero errors. Labs has no local
hold, remains `stopped_by_server`, and has zero units. The server's stop was
preserved.

Separate code inspection found a Warden recovery risk. Its lock is held while
the supervisor lives (`warden/warden.py`, lines 192–217); Windows GUI launch uses
`CREATE_NEW_PROCESS_GROUP` without a Windows job or parent-death cleanup (lines
1383–1391), and a new supervisor launches a fresh GUI without adopting an
existing one (lines 1625–1628). No application-level Windows singleton was found;
`src/models/DeepLink.h` describes single-instance routing as packaging work.
The inference was that loss of the inner supervisor could leave an unsupervised
GUI and a replacement could create another one. **This is not a proven cause of
the Office failure.** The new native launcher owns the process group and startup
now uses a one-minute recovery trigger. Its isolated lifecycle suite passed 34
checks across six modes. An Office comparison using disposable fixture processes
confirmed the old group was gone within five seconds and exactly one replacement
was running by 65 seconds; fixture processes/tasks were cleaned up. These tests
did not crash the live application. Evidence:

```text
C:\wt\generic-supervisor-fixture-20261013\native-launcher-tests.json
C:\wt\generic-office-approved-launcherfixture-4262cba1d73d\result.json
```

The current sealed package includes the launcher and later installation fixes.
Its Office installation and live recovery drills passed; reboot verification
remains pending.

## Automatic sign-in setup

The operator approved Microsoft Autologon for the Office desktop account.
The tool was downloaded from the link on Microsoft's
[Autologon page](https://learn.microsoft.com/en-us/sysinternals/downloads/autologon),
then its Microsoft Authenticode signature and copied file hash were verified.

```text
Tool: Autologon64.exe, version 3.10
SHA256: 5d96bbc4e5b726d87c7cf547f5fe98f8f05434ec2130bd60cbf5671fd3a7381b
Office path: C:\CilexWatchtower-Deploy\autologon-prep-20261013-173048-de01ca06\Autologon64.exe
Evidence: C:\wt\autologon-prep-20261013-173048-de01ca06
```

The visible tool window was initially confirmed in session 1 under the exact intended
`WT-OFFICE-01\Админ` SID at `17:37:59 UTC` (PID 12448). No password, account or
EULA-acceptance argument was passed to the tool. No GUI field values were read
by the agent.

One authorized public-state check at `17:52:59 UTC` still found
`AutoAdminLogon=0`, the correct target username and no logon banner. The tool was
still open. The operator subsequently clarified that the account has no Windows
password and could not complete the approved tool's setup. No account/password
or security changes were authorized or made. Setup remains incomplete, and the
existing Windows sign-in behavior must be observed during a later authorized
reboot after a healthy update. No password value, whole Winlogon key or LSA
secret was read.

At `18:23:54 UTC`, the tool window was already closed. The exact owned setup task
`CilexAutologonSetup-autologon-prep-20261013-173048-de01ca06` was validated,
removed and confirmed absent. No close request or forced termination was needed.
All three temporary service launchers were removed and their absence verified.
The cleanup did not change sign-in settings or launch another observation task.

| Non-secret setup record | SHA-256 |
| --- | --- |
| `verification.json` | `841f02bdbc3a975e397c036fe45e0f81377664207cdf93262e750598a817afe8` |
| `window-result.json` | `a9abcda6192082966f978798602e6355730db25999fe2d640299508bf236a98f` |
| `public-state-result.json` | `0f483e3cf8ae6ba0f2a5b75d36c8630a224e7fcfc949cec1ce79e65a6e2cadb7` |
| `normal-close-result.json` | `382acf8e705359e87f2278b0774852ad6801580ac1ccfaf451f344c0ddf1aa30` |
| `normal-close-service-cleanup.json` | `9d5170faaade6771f177513a2f0b9e11820c62292a2c8f8bf998b8c3bb48800d` |

## Remaining acceptance work

1. Validate failed-update rollback on a disposable target under the intended
   runtime conditions; retain the earlier failed-run evidence and working backup.
2. Test new-machine build-tool provisioning and a clean offline installation,
   including ordinary-user and alternate-administrator setup.
3. Verify fresh-station backend enrollment, representative Qt playback/export
   workflows and codec coverage, and actual uninstall behavior. Office's live
   31-feed viewing and automatic process recovery have already passed.
4. Once the user confirms whether open terminal work needs saving, perform the
   authorized Office reboot test. Observe the existing Windows sign-in behavior
   without changing account/security settings. A configured task alone is not
   proof of success.
5. Measure hardware/workload limits and publish the tested Windows edition/build
   matrix before describing provisional thresholds as established minima.

Build caches, package directories, extracted installers and source-test
directories above remain as evidence. They should not be removed until the
failed update and pending startup test are reconciled. The Autologon window/task
and temporary setup services no longer need cleanup.
