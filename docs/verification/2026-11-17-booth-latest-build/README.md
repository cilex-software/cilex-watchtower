# Booth rebuild and relaunch — 2026-11-17

The operator authorized rebuilding the latest sources and relaunching the Booth.
Office, macOS, reboot and security-policy changes were outside this task.
These are dated observations, not guarantees about a later session.

## Source and build identity

GitHub authentication was renewed interactively without printing credentials.
The old and new repository URLs returned the same repository ID `1248399685`;
origin now names `https://github.com/cilex-software/cilex-watchtower.git`.

Fetched upstream `29cf289942d1362847f6ea9b368bfe83541b58a0` was **1.1.805**.
Four completed, previously unpublished local fixes were rebased onto it:

| Revision | Version | Change |
| --- | --- | --- |
| `42bc0597` | 1.1.806 | Station camera-group filters |
| `c6573f5e` | 1.1.807 | Loading state across sign-in mode changes |
| `4c93983f` | 1.1.808 | Verified omitted watchdog privilege default |
| `6f0cff76` | 1.1.809 | Prior Booth repair acceptance record |

Product changes merged without conflicts. Version fields and status-entry
placement were reconciled, preserving upstream changes and local repairs.
The old local main remains as `archive/booth-pre-update-20261117`.

The clean, frozen compiled source is
`6f0cff763c36d603192a3ccc68bfb8d2a4e87517`, under
`C:\wt\watchtower-sync-20261117`. Later documentation commits must not be
reported as that executable's compiled provenance.

A fresh Ninja RelWithDebInfo build used the provisioned MSVC/Qt 6.12 toolchain,
two BelowNormal compiler jobs and the existing Unicode child-environment fix.
Configure and compilation exited 0. The executable reports **1.1.809.0**.

| Artifact | SHA-256 |
| --- | --- |
| watchtower.exe | `CCD9E53B6AE82311D6AC57D6F866E7ECC98E3CEBB15F642919EE104DF87124D1` |
| watchtower.pdb | `819975E943D0715368073000B8FC4B8075D0CA25E47E0C6238FAB3AEC0396BDE` |

## Verification and deployment

- The rebased watchdog/deployment/video fixtures passed **67 / 24 / 46** checks
  in both Windows PowerShell 5.1 and PowerShell 7. Version checks and
  `git diff --check` passed.
- The actual new executable passed the isolated station/operator group runner:
  **22 runner checks and 54 QML assertions**, no failures. Its loopback server
  printed one connection-aborted traceback; its exact cause was not established.
  Assertions and both application exits passed.
- All eight English/Russian, 1200/1440-pixel, details-open/closed Health UI
  configurations passed: **128 tests**, no failures/errors or QML warnings.
  Representative images were inspected. Qt emitted its default-font-directory
  notice; bundled fonts rendered. Some existing Russian detail-field labels
  remain English; complete localization is not claimed.
- The exact candidate passed **40.078 seconds** of private native startup, with
  isolated settings, no second-chance faults and termination of its own child.
  Unchanged Warden source and packaged status checks passed. The installed
  runtime was checked against its prior manifest before replacement.
- The reviewed `packaging/windows/deploy/station-booth.ps1` backed up the old
  files, replaced the app/PDB and verified **155 seconds** of stable supervision.
  Its final **29.999-second** sample gained **6,631 frames**, with **20 decoders,
  20 lit feeds and zero stream errors**. It returned `Success` at
  **2026-11-16 21:19:11 UTC / November 17 00:19:11 Moscow**.
- Final native window inspection confirmed **1.1.809 / 6f0cff76**, operator
  sign-in, **Улица**, the same 20-cell alphabetical arrangement and moving video.
  One Watchtower and one Python Warden were present. The original recovery task
  was restored enabled/running. Warden files, configuration and Labs control
  retained their hashes. No additional restart was performed for acceptance.

## Evidence retained on the Booth

| Evidence | Location under `C:\wt` |
| --- | --- |
| Integration and isolated adapter checks | `watchtower-sync-checks-20261117\integration-summary.json` |
| Fresh compile and symbols | `watchtower-latest-20261116-prep\build-20261117-v809\build-proof.json` |
| Actual app group regression | `watchtower-latest-groups-20261117\result.json` |
| Health UI results and images | `watchtower-health-20261117\acceptance.json` |
| Startup, manifest, rollback files, runtime and final acceptance | `camera-groups-rollout-20261110-latest-20261117` |

Preparation used the existing `camera-groups-prepare-rollout-20261110.ps1`
with fresh build/fixture proofs and the frozen source path. The updater used
that run's `manifest.json` and `runtime.json`; submission alone was not treated
as completion. `deployment-result.json` and `acceptance.json` record completion.

## Limits

This was an existing-station application update, not a complete new installer,
runtime upgrade or release upload. Native export, event/archive playback,
fresh-machine installation and reboot acceptance were not exercised.

The executable is **NotSigned**. No certificate was invented or security setting
changed during this task. Successful startup on this station does not establish
Smart App Control acceptance or solve production signing.
