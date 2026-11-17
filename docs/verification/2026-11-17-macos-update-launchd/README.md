# Startup failure after DMG update; protected recovery

## Observations

The owner supplied the failed update record
`b7872864-16f9-4bd7-8346-74be61c18a31.json` for installation
`af0bae32067f6a466ead3770` on 2026-11-17.

- The transaction stopped the previous running job (PID 70767) and replaced
  `/Applications/Cilex Watchtower.app` with **1.1.814**.
- The old **1.1.803** app remains in the protected adjacent transaction folder.
  Its fingerprint matches `previous_app_sha256` and native strict/deep signature
  verification passes. The installed replacement matches its recorded new
  fingerprint. The startup plist bytes match the recorded previous backup.
- Warden's lifecycle log records a clean SIGTERM stop at **02:50:23**, including
  its expected-stop heartbeat. There is no newly started Warden in that log.
- The original error identifies `launchctl`; this transaction's code places its
  failure at replacement bootstrap. The old command wrapper discarded its exit
  code/stderr, so the exact launchd rejection cannot be recovered from this record.
- Rollback stopped before changing the replacement because the loaded job's
  reported PID did not match a verified Warden process. The record remains
  `rollback_failed`; the old backup was preserved.
- The owner's subsequent native Terminal check reports that the selected job no
  longer exists in `gui/501`, with no matching explicit disabled entry. That is
  consistent with a transient launchd teardown/startup window. It does **not**
  prove the original error was EIO or establish a unique root cause.
- This execution context cannot inspect the user's GUI launchd domain: native
  `launchctl` returns **141, Reentrancy avoided**. Such failure must not be
  interpreted as an absent service.

Raw station logs, preferences and journals are not copied into Git.

## Changes in helper 1.0.7

1. Failed local commands retain the operation, exit status and bounded/redacted
   macOS error text, including structured primary/rollback diagnostics in the
   transaction record. The previous nonexistent “protected diagnostics” pointer
   is replaced by the actual diagnostic.
2. A stop waits both for process exit and for the selected launchd job to be
   removed before swapping bundles. GUI-domain/policy query failures are errors,
   never an assumed unloaded or enabled state.
3. Recovery waits for stale exiting PIDs or the owned `/usr/bin/env` launcher to
   settle. A foreign PID/account/path still fails without being signalled.
4. Bootstrap retries are bounded to 30 seconds and only the transient status
   set 5/36/37. An already registered job must pass the owned process checks;
   no global launchd reset, sudo, arbitrary process killing or disabled-policy
   override is added.
5. A new DMG recognizes the original protected incomplete transaction before
   allowing another replacement. **Restore Previous Version** requires consent,
   verifies the old fingerprint/signature and original options, reconstructs
   the exact recorded replacement, then delegates to the existing bound resume
   engine. It retains the failed version and original failure evidence.
6. A separate `recovery.py` entry uses that same GUI recovery flow without
   requiring a client rebuild. `build.freeze_setup` accepts only the normal
   deployment entry or this recovery entry; the recovery app has its own bundle
   identifier. Both use the existing frozen Python runtime and native dialogs.

## Verification

- Fourteen new lifecycle tests cover stale registrations/PIDs, launcher exec,
  bounded retries/timeouts, permanent errors, inaccessible domains, preserved
  disabled-policy uncertainty and redacted diagnostics.
- Seven recovery fixtures cover actual old-bundle restoration using the existing
  engine, retention of the failed new app, cancellation, altered backups,
  foreign records, changed options/records and completed-record no-op behavior.
  Four standalone entry/build checks and a new update ordering case cover the
  recovery app's delegation and recovery-before-new-update behavior.
- Generic test run: **391 cases, 390 pass and one case-insensitive APFS skip**.
  As in the previous installer verification, this context requires a current-UID
  fixture account because Directory Services is unavailable. The separate native
  CFPreferences integration test is excluded; actual recovery/cache restoration
  still needs native acceptance.
- Both real PyInstaller entry points compile. Normal Setup reports `1.0.7`.
  Nested ad-hoc signing and strict/deep verification pass for both helpers.
  The standalone recovery app's arm64 runtime closure audit passes.
- The standalone app was opened through native Finder. Its real dialog correctly
  offers **1.1.803**, the Applications destination and retention of the failed
  replacement. **Cancel was clicked**, leaving the failed journal, current new
  app and old backup unchanged. [Native confirmation](restore-confirmation.jpg).
- Read-only preflight of the real failed transaction confirms its original
  options hash, previous/new fingerprints and previous native signature.

## Recovery artifact and limits

The compiled app is at:

`/Users/romayankin/Downloads/CilexInstallers/Recovery-1.0.7/Cilex Watchtower Recovery.app`

It was built from the repository's frozen helper sources using
`freeze_setup(..., entry='recovery.py')`, the existing Python/PyInstaller toolchain,
the repository's `watchtower.icns`, and nested ad-hoc signing. The binary and raw
build logs stay outside Git; maintained source/build code and this UI evidence
are committed. The normal installer README describes recovery in a new DMG.

No **Restore** was clicked by the agent. No installed app, startup service or
station setting was changed during this task's verification. Native restoration,
camera/video acceptance and a successful update to a fresh client remain pending.
No fresh client/DMG or passed VideoToolbox build gate is claimed. The standalone
maintenance helper is not a replacement DMG and contains no rebuilt client.
