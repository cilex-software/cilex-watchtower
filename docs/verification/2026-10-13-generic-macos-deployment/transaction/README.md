# Installation and SSH fixture evidence

## October 14 transaction follow-up

[New fixture evidence](checks-2026-10-14-transaction-recovery.json) records **95
installer tests** and **241 generic tests (one expected skip)** passing on the
same Mac. The older records below remain intact. These additions did not start,
stop or replace a live application.

[Final installer/harness fixture evidence](checks-2026-10-14-rollback-harness.json)
records 98 installer tests and nine native-harness fixtures passing after the
additional readiness changes. The full-suite count above predates those changes;
the packaging workstream records the final aggregate suite separately.

An existing unloaded LaunchAgent now remains unloaded during upgrade, with
`PendingStoppedStartup`. An existing loaded job with no Warden PID is rejected
before replacement, because retry and intentional successful shutdown cannot be
safely distinguished. An interrupted transaction whose prior job had this state
returns unknown without automatically restarting it. Requesting video observation does not authorize an
implicit start: that combination fails before replacement. Disabled startup
continues to remain disabled, and missing graphical sessions remain pending.

Uninstall has a private run-bound journal and snapshots of its owned receipt,
application inventory and LaunchAgent. Interruption before or after the app rename
can be resumed only with matching files, account, installation and startup policy.
A new run cannot bypass an incomplete uninstall. Completed resume checks actual
absence and refuses to remove a later reinstallation. Only the selected job is
stopped; user configuration, credentials and unrelated holds remain untouched.
The complete application is retained in an adjacent private
`.cilex-uninstall-*/application.backup` directory for recovery, with its path in
the result. It is not recursively deleted, and automatic backup disposal is not
implemented. This retention is reported separately from removal of the active
application and startup components.

The installer snapshots the default `cilex://` bundle identifier and resolved
application path before replacement. A preexisting default is preserved after
registration and restored/read back during rollback through public Launch
Services APIs. A native read-only snapshot resolved the installed application on
this Mac; all restoration/setting tests used fixtures. The code never opens a
`cilex://` URL during these checks. Apple documents
[default-handler setting](https://developer.apple.com/documentation/coreservices/1447760-lssetdefaulthandlerforurlscheme)
and [resolved application lookup](https://developer.apple.com/documentation/coreservices/1448824-lscopydefaultapplicationurlforur).
These APIs are deprecated but remain declared in the baseline-compatible SDK.
No documented general unregister/clear API was identified: restoration of prior
absence and the complete Launch Services registration catalog remain explicitly
unverified. A denied setter or mismatched path does not count as recovery.

The native rollback acceptance approach is to inject one test-process exception
at the post-replacement observation callback after a separately confirmed healthy
baseline. Real staging, scoped stop, replacement and rollback then run normally;
a separate unpatched 150-second observation must establish actual recovery of
the same source-hash set observed during the healthy baseline.
The test-only harness is
[`native_rollback.py`](../../../../packaging/macos/generic/tests/native_rollback.py).
It requires explicit machine ID, current receipt SHA, trusted package SHA,
installation path/account, camera count and a new evidence directory. Its default
is read-only preflight; `--execute-authorized-test` enables the requested native
test only on an already healthy loaded job. Nine fixture tests validate target
binding, stopped-job refusal, process-generation changes, unchanged request
binding and retention of failures. The harness has not been executed on the live
installation by this workstream. The parent agent controls live acceptance and
the requested final stopped state.

Requested installation observation and this harness now require
`VisibleAndPerSourceVideoObserved`; aggregate-only evidence cannot satisfy the
per-camera acceptance requirement. The installer has 98 passing fixtures
(including aggregate-only rejection and loaded/no-PID preservation). The historical October 13
aggregate-only result below remains a record of the earlier implementation.

## October 13 evidence

`checks.json` and the logs record 79 installer tests, 18 SSH fixtures and 23
dependency tests passing on this Mac. The complete generic suite ran 195 tests
with one documented skip. The initial 59-test record is retained separately.
All installation/remote suite
launchd, Launch Services mutation, application starts and SSH/SFTP operations
were fixtures. Native tests also exercised Darwin quarantine propagation on an
owned temporary archive, statfs64 filesystem assessment and CoreFoundation
preference-cache replacement in a unique owned test domain. A separate read-only
call to `install.process_snapshot()` used Darwin libproc successfully. This does not establish application health,
remote deployment, GUI visibility or camera playback.

The installation fixtures exercise archive traversal and link rejection,
case/Unicode collisions, protected locks, pre-stop package corruption, disabled
startup preservation, no-GUI pending state, selected process identity,
configuration preservation, rollback and distinct original/rollback failures.
The LaunchAgent uses system `/usr/bin/env -i` with an explicit whitelist before
executing the absolute Warden path. Ownership checks require the exact generated
launcher and permit only the exact previous direct-Warden format for upgrades;
injected DYLD values, extra arguments, duplicate assignments and Program
overrides are rejected by fixture tests. Native parentage/environment/crash
testing is recorded separately by the Darwin Warden workstream.
Read-only startup assessment records FileVault status and a boolean match
between the automatic-login setting and intended desktop account. It never
records that account name or reads automatic-login secrets. Native evidence in
`startup-assessment-native.json` observed FileVault enabled and no configured
automatic-login account on this Mac, so unattended reboot remains blocked.
[Apple documents these automatic-login restrictions](https://support.apple.com/en-au/102316).
Even matching settings leave restart and cold-start recovery unverified until
separately authorized runtime tests provide matching post-boot evidence.
Private configuration snapshots cover both Watchtower preference domains,
the legacy user Warden config and DATA/warden.conf. They bind bytes, ownership and
permissions to a transaction and restore the native preference cache before a
prior app is restarted. The tests reject corrupt snapshots and redirected paths,
preserve unrelated pause/hold files and verify atomic replacement failure.
No real station credentials or settings are copied into these evidence files.

When `--observe-seconds` requests an explicit interval, observation runs inside
the transaction before the installed receipt is committed. Failed or incomplete
video evidence rolls back the application and configuration; the numeric runtime
result and its evidence file remain available. Resume cannot skip an observation
bound to the original request. Aggregate video evidence still does not establish
individual camera identity, playback/export, backend enrollment or startup.
Storage checks include the exact sum of configuration, LaunchAgent and receipt
restoration writes plus a 64 MiB reserve on each affected filesystem.

Interrupted local transactions bind the original run, installation, account,
package, requested options and private backup hashes. Resume can finish a proven
healthy or intentionally pending replacement, restore a known prior state, or
replay a staged transaction only when its durable record proves stopping had not
begun. Missing backups, changed operator startup choices, newer installation
receipts or unknown file/process state leave the outcome unknown. The fixtures
test each case without stopping actual applications. Actual restart recovery
after SIGKILL or power loss still requires separate runtime evidence.
A new installation run ID cannot bypass a prior incomplete transaction: the
installation lock protects a scan of this installation's private records before
any process inspection or replacement. Completed installs and restored rollbacks
permit normal upgrades; incomplete records for other installations are outside
this check. Original failure evidence remains unchanged when a new run is refused.
Uninstall applies the same guard while holding the installation lock, before
stopping processes or removing owned files. Its successful fixture preserves
user data and unrelated operator holds.
The SSH fixtures exercise explicit authentication, verified host keys, identity
mismatch, Unicode paths, secret exclusion and uncertain-outcome reconciliation
without executing installation again.

Three development failures were explained and corrected before this final run:

- Python on Darwin did not provide `os.getxattr`; quarantine propagation now uses
  the system libc getxattr/setxattr APIs and explicitly never removes attributes.
- Fixture temporary paths passed through macOS's `/var` symlink. Fixtures now use
  their canonical `/private/var` paths; production continues to reject redirected
  destination/state paths.
- Resume protection initially depended on a journal phase. It now also records a
  persistent execution-requested flag, so an outer controller's phase update
  cannot cause an uncertain remote installation to be launched a second time.

Production offline Gatekeeper admission remains blocked: Apple's public/open
source SecAssessment flags provide no documented no-network assessment switch.
The installer never substitutes a made-up flag, removes quarantine or changes
security policy. Machine scope and native protected elevation for a different administrator are also
blocked. A development package requires explicit development authorization and
still undergoes hash, Mach-O closure and signature validation.

Actual launchd install/upgrade/uninstall, clean-machine/offline installation,
remote transfer interruption, permission dialogs, sleep/wake, GUI/video,
backend, hardware decoding, recovery and reboot acceptance remain unverified by
these fixtures. Restoring files and observed process parentage is reported as
runtime-unverified rollback, never as full recovery.

The install destination must use local APFS or journaled HFS+ with execution and
ownership enabled. Only APFS was observed on this Mac; HFS+ acceptance is based
on fixture flags and remains experimentally unverified. File fsync, atomic
replacement and directory fsync are used for transaction records and settings;
no claim of cold power-loss durability is made without that test.

Remaining transaction requirements: production offline security admission,
protected native elevation, real alternate-administrator ownership validation,
oldest supported macOS and HFS+ testing, remote target execution/uncertain-outcome
recovery, and complete GUI/backend/recovery acceptance. Rollback cannot undo
backend-side enrollment or token rotation; its resulting backend/session health
must be independently verified. Shared worker/guard hold records are deliberately
outside configuration snapshots and are never cleared by this transaction.
