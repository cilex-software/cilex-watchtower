# macOS DMG update flow

The owner selected: **double-click the app inside the DMG → Update**, stopping
Warden as a service, replacing Watchtower, then restarting it. Fresh installs
retain the two-icon drag-to-Applications layout.

## Implementation

- The existing `src/main.cpp` Finder bridge already invokes the app's frozen
  Setup helper before starting Qt. No client C++ change was necessary.
- `first_launch.py` now routes a disk-image launch to `finder_update.py` and
  shares its Finder-launch lock with the updater. Normal launches from
  Applications retain their existing behavior.
- The updater requires the exact read-only mounted disk image, or Apple's
  original-path mapping with matching app and helper executables. It does not
  scan Downloads for a newer installer. A private package reconstruction retains
  the complete inventory/closure and native signature checks in `install.run`.
- One installed copy is selected by canonical Applications paths and protected,
  exact installation LaunchAgents. Ambiguous copies, unrecognized services,
  foreign ownership and another account using the same bundle stop the update.
- The EN/RU confirmation names both versions, the exact destination, the service
  stop/restart, settings retention and unsigned internal-build status. Cancel
  performs no copying, app replacement or service operation.
- Replacement reuses the existing transactional installer: stage and verify,
  `launchctl bootout` the selected job, wait for its processes to exit, swap
  bundles, write the owned startup entry, bootstrap and verify process startup.
  Failure inside that transaction attempts to restore the old bundle, startup
  entry, preferences and prior service state, retaining the recovery evidence.
- A narrow internal update permission permits an **existing user-owned app**
  inside the stock root:admin `/Applications` directory, only with actual write
  access. No elevation, machine installation, fresh-install exception, broad
  process killing or security bypass was introduced. Scripted installation keeps
  its existing stricter destination policy.
- Existing backend URL and preferences are retained. After successful replacement,
  the explicit Update consent authorizes starting a previously disabled/unloaded
  user job too. If that final start fails, the dialog says the app was updated
  but could not be opened; it does not report success or claim rollback.
- Helper version is **1.0.5**. The artwork and simple installer README explain
  the double-click update step. The SVG and regenerated dual-resolution TIFF
  retain the existing icon positions and window dimensions.

## Verification on this Mac

- 20 new inert updater tests cover cancellation, success ordering, transaction
  failure, final activation failure, first-install guidance, backend preservation
  (current and legacy startup forms), literal localized native-dialog arguments,
  frozen-helper binding, read-only image identity, symlinks, translocation
  mismatches, package reconstruction, ambiguous destinations and ownership rules.
- Three new transaction fixtures verify the exact
  `bootout → old processes gone → replacement → bootstrap` sequence, unchanged
  preferences/backend, rollback to the running old app after new startup failure,
  and no service stop if the authorization recheck fails after staging.
- The complete generic test collection, excluding the unavailable native
  preferences integration test, runs **357 cases: 356 pass, one case-sensitive
  filesystem test skips on this case-insensitive APFS volume**.
  This execution context cannot resolve its own UID through Directory Services;
  the run uses an in-memory fixture account for current-UID/name lookups only.
  Production account resolution is unchanged. The native CFPreferences test
  failed to synchronize here and was excluded from that isolated fixture run.
- Actual PyInstaller compilation with the project's cached Python environment
  succeeds. The frozen executable prints `1.0.5`; recursive archive inspection
  confirms `finder_update` and `first_launch` are included. Nested ad-hoc signing
  and `codesign --verify --deep --strict` pass for the frozen helper.
- A read-only call to `source_volume` successfully identifies the already-mounted
  `/Volumes/Cilex Watchtower` image. It does not execute its app or install it.
- The regenerated background was inspected at 760×480, including its update hint.
  `git diff --check` passes.

## Delivery and acceptance limits

No installed Watchtower app, LaunchAgent, Warden service, live camera or backend
setting was changed for verification. A complete real update through Finder,
including Launch Services behavior while the production app is running, remains
to be accepted on a disposable Mac/account. The fixture tests do not establish
that native end-to-end acceptance.

**No new DMG was produced.** The approved FFmpeg PNG-overlay/scale/VideoToolbox
export gate fails in this execution context with
`Cannot create compression session: -12908`. The owner's instruction to require
all build checks to pass was retained; no software fallback or validation bypass
was applied. The previously created presentation-only 1.1.810 DMG does not contain
this updater. A fresh successful normal build is required to deliver helper 1.0.5.

Temporary helper bundles, test outputs and raw logs are outside Git under `/tmp`.
The installer README remains the human-facing build/install guide.
