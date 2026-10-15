# Generic macOS deployment — implementation and verification record

This work is **incomplete**. Passing fixtures establish only the behavior named
in those fixtures. They do not establish production distribution, clean-machine
installation, oldest-system compatibility, or reboot recovery.

The latest development candidate was installed and tested, then **Watchtower and
Warden were both stopped** as requested. Native process recovery, process-only
rollback, owned uninstall/resume/reinstall and representative export checks
passed their stated scope. The required sustained 31-camera video acceptance
failed. See [the final native verification summary](artifacts/final-native-verification.json)
and [current claim matrix](current-validation.json).

The source inspected was `199a8998c4a4b20d8ebffdec87b5bc053adb473b`
(Watchtower 1.1.781). Development artifacts use a separately hashed source
snapshot containing unpublished Darwin Warden changes, with that commit recorded
only as the base. They are not a fresh-main release or an existing Git tag.
Deployment-helper provenance is separate. No deployment command publishes code
or artifacts.

## Authorized test scope and host

The operator explicitly designated this Mac for installation and crash tests and
selected the existing saved Live view for video observation. No reboot or power
loss was authorized. No separate remote Mac or alternative desktop account was
provided. Existing preferences, enrollment, worker pauses and protective holds
must be preserved.

Native test host: Apple M1 Pro, arm64, 32 GiB, macOS 26.6.2 build 25G83.
System Bash is 3.2; the installed Apple Python is 3.9.6. This host already has
developer tools. It is not a clean-machine or oldest-supported-system test.
Current Homebrew Qt/GStreamer components force a macOS 26.0 runtime minimum;
the bootstrap's proposed 14.4 baseline remains unverified on an older Mac.
No x86_64 or universal2 configuration is advertised.

## Evidence groups

- `controller/`: stock-shell entry, localized check/dry-run/verify, controller and
  aggregate unit checks. Read-only incomplete assessments deliberately return a
  nonzero status.
- `transaction/`: package validation, extraction, process scoping, ownership,
  configuration restoration, interrupted transactions, SSH result binding and
  dependency provisioning fixtures. Real remote deployment is not demonstrated.
- `warden/`: native Darwin identity, monotonic timing, process guardian, frozen
  runtime, isolated LaunchAgent recovery and crash-harness safety tests. Fixture
  processes are distinguished from the installed Watchtower application.
- `artifacts/`: dependency closure, native build/packaging attempts and approved
  FFmpeg fixture evidence. Earlier failed attempts are retained alongside repairs.
- `scope.json`: authorized scope and the unchanged legacy build-script hash.

The current external claim matrix is
[`current-validation.json`](current-validation.json). The
[frozen original matrix](../../../packaging/macos/generic/VALIDATION.json) is
retained unchanged inside the distribution for provenance.
The deployment interface and limitations are documented in
[`generic/README.md`](../../../packaging/macos/generic/README.md).

## Known production and acceptance blockers

This Mac reports no valid Developer ID signing identity. Local development
artifacts may be ad-hoc signed for execution, but that does not establish trusted
distribution. Signing/notarization credentials, complete dependency license and
source-offer evidence, and a currently approved packaged Python are still needed
for production acceptance.

Protected machine-scope/alternate-administrator authorization is not implemented;
those paths fail before changes. Automatic provisioning is limited to the
implemented pinned inputs and otherwise requires explicit provision. Offline
production Gatekeeper assessment remains blocked because the workflow cannot
yet prove it makes no network requests. No quarantine, Gatekeeper, SIP, privacy,
automatic-login or power settings are weakened.

Real installed GUI/video, application recovery, playback/export, uninstall and
rollback observations will be recorded separately when performed. Registration
alone remains `StartupUnverified`. Actual sign-in, reboot, cold start, sleep/wake,
locking, user switching and network reconnection are separate unverified claims.

## Actual installation and operator stop — 2026-10-14 local time

The final development DMG was independently rehashed and mounted read-only.
Its bundled helper installed Watchtower 1.1.781 and Warden 1.5.0 per user;
installation run `20261013T210320Z-7b1099a3d4f56f4c` returned21 (incomplete
acceptance). Native process evidence confirmed launchd → Warden → Watchtower.
The GUI displayed the existing Улица view with31 camera images. A requested
150-second observation did **not** complete: the real1,562,588-byte installation
receipt exceeded the runtime reader's1MiB limit. This legitimate receipt was
misclassified as unavailable; its ownership/mode/link count were valid. An
application restart observed before any deliberate crash drill was initially
unexplained. Later retained log analysis found exit 0 and the application's
operator-quit marker; Warden applied its existing kiosk restart policy. A separate
guardian identity-read error during shutdown was reproduced and corrected with
a bounded retry that retains the strict process identity checks. The original
observation, diagnosis and failed tests remain retained.

The operator requested **stop Warden**. The selected LaunchAgent was booted out;
verification found it unloaded and zero selected Warden/Watchtower processes.
No crash drill had been performed against the real installed application at that
point. The operator subsequently authorized further tests, with an explicit
requirement to stop both Warden and Watchtower at completion. The AfterSignIn plist is still present
for future login; no startup settings were otherwise changed. Private native
results are retained under the current user's Application Support directory at
`CilexWatchtower/DeploymentVerification/2026-10-13-native-install/`.

Delivery artifacts are in `~/Downloads/CilexInstallers/1.1.781-development-20261014/`.
They remain development candidates with the known verifier defect; production
acceptance and full runtime verification are incomplete.

## Readiness revision — work in progress

The source verifier now accepts the bounded full inventory receipt, while keeping
the smaller bound for process-guardian records. A read-only check of the stopped
installation accepted its receipt, observed zero selected processes and left the
receipt and state directory unchanged.

The application now emits credential-free source hashes and individual sink-frame
counters. Verification requires the same source set, advancing counters and fresh
delivery for every feed over at least 150 seconds. Crash and rollback tests pin
their pre-failure source set into recovery verification. This does not establish
camera-name mapping, a hardware-decoder capacity, or playback/export behavior.
Native loopback C++ checks exercise actual decoded frames and distinguish cached
parked frames from fresh delivery. The new final artifact and actual installed
recovery observations are recorded separately below when performed.


## Previous corrected artifact and actual feed-freshness failure — 2026-10-14

The previous development artifact is recorded in
[the current-session artifact manifest](artifacts/current-session-final-artifacts.json).
It retains Watchtower **1.1.781** and Warden **1.5.0**. Only the deployment
telemetry-reader source changed; the application source snapshot is unchanged.
The corrected frozen reader selects bounded records for the current process
session, fixing the prior `VIDEO_TELEMETRY_LINE_LIMIT_EXCEEDED` failure. Exact
embedded-code regression tests reproduced the old defect, then accepted the
retained 31-source input with the corrected reader. All **42 runtime tests**
passed. The original failed result and old artifacts remain retained.

That development DMG is
`~/Downloads/CilexInstallers/1.1.781-development-20261014-current-session/CilexWatchtower-1.1.781-arm64-development.dmg`,
SHA-256 `d74c31e64feba38f71052b12c9153064cd8cad28a67b78cc01e9c00ee2973594`.
The sibling bootstrap archive SHA-256 is
`502e0f42b2add2d6e057ee80676ea052c2b6c04af4557c1c6f87fdbb8a9f552e`.
Both remain **DevelopmentOnly**, with ad-hoc signatures and no notarization.
They do not establish production distribution, clean-Mac installation or oldest
macOS acceptance. The current runtime floor is macOS **26.0**; the bootstrap's
proposed 14.4 floor still lacks oldest-system testing.

Actual mounted-DMG upgrade `20261013T230718Z-811e9ce7987c2c3a` installed the
corrected package and preserved `PendingStoppedStartup`; exit 21 and
`full_success=false` correctly retained incomplete runtime acceptance. A
separately authorized start produced the intended native process graph:
launchd → Warden (56285) → Watchtower (56287), with guardian 56286 and no
unexpected duplicates. A screenshot of the preceding readiness candidate showed
the saved **Улица** view with 31 camera images and four empty add-camera cells;
that image alone never proved advancing video.

The corrected reader now exposes a separate **real feed-freshness failure**.
The requested 150-second observation failed after **54.383 seconds** with
`EXPECTED_CAMERA_COUNTS_NOT_MAINTAINED` and exit 18. Eight retained samples from
app uptime 30–240 seconds contained all 31 source hashes and 31 decoders, with
zero reported stream errors, but fresh-feed counts were
**22, 14, 14, 31, 31, 31, 30, 29**. The oldest sampled delivered frame reached
66.592 seconds. Seventeen watchdog reconnects and recovered events were observed
by uptime 120 seconds; later staleness recurred. This does not establish a
sustained recovery, and the cause remains **unverified**. No acceptance thresholds
were relaxed. See [the numeric evidence](warden/actual-initial-source-stalls.json).

**At that stage, no actual application or Warden crash signal had been sent.** A healthy
31-feed baseline is required before those drills and the native rollback test.
At that update, the corrected Warden and Watchtower were **still running** for
read-only diagnostics. The prior stop after the parser failure is historical;
the required final stop of both products had **not yet been performed** for the
continuing test sequence.

The complete generic automated suite at that revision ran under Apple Python **3.9.6**:
**270 tests, 269 passed, one expected skip, no failures/errors**, in 7.842 seconds.
[Exact command, hashes and result](transaction/current-session-final-generic-tests.json)
and [full log](transaction/current-session-final-generic-tests.log) are retained.
No helper/test source bytes changed during that run. Subsequent test-only rollback
harness changes passed their separate 17-test suite; the earlier total of 270 is
not a new aggregate run of the changed test tree. The then-current packaged Warden
also passed 31 checks and isolated LaunchAgent recovery in **9.903 seconds**, with
no overlap and verified fixture cleanup. Those isolated tests do not replace
actual application recovery, representative playback/export, native
uninstall/reinstall, rollback, or the final stopped-state verification.

## RTSP reconnect candidate and native refusal checks — 2026-10-14

The latest assembled development candidate is recorded in
[the RTSP reconnect artifact manifest](artifacts/rtsp-reconnect-final-artifacts.json).
It changes the QML wrapper to forward normal RTSP reconnect requests. In the
actual-QML loopback regression, the prior version stalled without retry; the
corrected wrapper delivered fresh frames on the second connection after
**4.609 seconds**, without a watchdog rebuild. This identifies a reconnect
defect; it does not establish the initiating cause of every real-camera stall.
The deployment helpers are unchanged from the corrected session-reader candidate.

The latest DMG is
`~/Downloads/CilexInstallers/1.1.781-development-20261014-rtsp-reconnect/CilexWatchtower-1.1.781-arm64-development.dmg`,
SHA-256 `e66d3fb53e236f5e2fdc4c3f4f49be3de5d327006e171666e38d057ed90a0501`.
The sibling bootstrap SHA-256 is
`53d47bf7d78bb23140232a0385f6fccfb6488bb08b2a6b9021e5424edced15ec`.
Both remain **DevelopmentOnly**. Generic checks are **269 passed and one
expected skip**; exact embedded verifier checks are **42 passed**. The latest
packaged Warden passed **31 checks**, including isolated launchd recovery in
**9.861 seconds**, no overlap and descendant/fixture cleanup. These results do
not substitute for the ongoing installed-candidate acceptance sequence.

The exact frozen Setup passed two additional native refusal checks in new owned
Unicode/spaced test destinations. A corrupt package copy was rejected with
`package.hash`; a valid package targeting an unwritable directory was rejected
with `authorization.destination` and a Russian explanation. Before/after
snapshots confirmed unchanged selected process identities, launchd state,
application executable, receipt, LaunchAgent, Qt preferences, Warden configuration,
ownership and `cilex://` handler. Neither test created an application, LaunchAgent
or installation record at its isolated destination. See
[the result](transaction/native-frozen-refusals.json) and
[reproducible harness](transaction/native-refusal-checks.py). These tests establish
filesystem permission and integrity refusals; production Gatekeeper, privacy
consent and alternate-administrator denial remain separate unverified cases.

One representative playback/export workflow also passed on the preceding
current-session candidate: recorded playback advanced from **01:16:38.231** to
**01:17:32.052**, and a selected ten-second export produced a **9.90-second,
1280×720 H.264** clip with both Qt overlays. The bundled FFmpeg successfully
decoded and reencoded all **150 frames**. Unsupported diagnostic output muxers
and an unrelated external FFmpeg linkage failure remain retained as diagnostic
failures, not export failures. See [the reduced evidence](transaction/playback-export-current-session.json).

Native upgrade `20261014T000434Z-c1d8f29fce83f4ae` installed the reconnect candidate
and verified its process graph, with exit 21 and incomplete acceptance. The
requested 150-second observation then failed after **49.948 seconds** with
`EXPECTED_CAMERA_COUNTS_NOT_MAINTAINED`. The QML correction therefore does not
establish healthy operation of all 31 real feeds. The earlier failures and
unchanged acceptance thresholds remain recorded in
[the native freshness evidence](warden/actual-reconnect-source-freshness-failure.json).

Two separately authorized real crash tests passed **process and visible-window
recovery**: Watchtower recovered in **2.858 seconds** and Warden in **0.330
seconds**, with no overlap and the old owned processes gone. These tests report
`PassedProcessRecovery_VideoAcceptanceFailed`; full acceptance remains false.
See [the reduced crash evidence](warden/actual-process-recovery-rtsp-reconnect.json).

The test-only rollback harness now offers an explicit `--process-only` mode for
the degraded video baseline. It retains strict target/package/receipt bindings,
requires native process and visible-window evidence, injects one post-replacement
failure, and independently compares restored files, configuration ownership and
startup policy. A successful process-only restoration still returns **exit 18**
and leaves video unverified. All [17 harness fixtures](transaction/process-only-rollback-harness-tests.json)
passed. The full-video mode still requires independent 150-second observations.

The authorized native process-only rollback has now run. One injected failure
after replacement exercised the real transaction recovery path; the original
failure remains recorded and no rollback failure occurred. The previous
application, receipt, configuration hashes/ownership and startup policy matched
their pre-test state. Independent observation confirmed the restored process graph
and visible window. The transaction and rollback took **13.162 seconds** and
returned **exit 18**, `FilesReceiptConfigurationStartupAndProcessesRestored_VideoUnverified`.
The `cilex://` default handler was preserved; broader LaunchServices catalog
restoration remains unverified. See [the native rollback evidence](transaction/actual-process-only-rollback.json).

Owned uninstall and completed same-run resume also passed: the selected app and
LaunchAgent were detached, no selected processes remained, and the owned backup
was retained. Independent before/after hashes, modes and ownership matched for
the existing Qt preferences and unrelated Labs control file. Resume reconciled
the protected uninstall journal and actual absence. Both commands returned zero
for this operation while retaining `full_success=false` and unverified
LaunchServices removal. See [the native uninstall/resume evidence](transaction/actual-owned-uninstall-resume.json).

The exact latest development DMG was reinstalled in run
`20261014T003441Z-3a96257ef2aadfa2`. Installation and the native process graph
passed; exit 21 retained unverified video/startup and DevelopmentOnly admission.
See [the reinstall evidence](transaction/actual-reinstall.json).
The required final stop was verified at **2026-10-14 00:40:23 UTC**. The selected
launchd job is unloaded, its PID is absent, and **zero selected Watchtower,
Warden or guardian processes** remain. The installed application, receipt and
AfterSignIn plist are still present; the job was not disabled. The unrelated
Labs control hash remains unchanged. See [the final stopped-state evidence](transaction/final-stop.json).
The retained AfterSignIn registration does not prove future login or reboot
behavior; both remain `StartupUnverified`.

At **00:46:21 UTC**, all three task-owned installer disk images were ejected
successfully and confirmed unmounted. The native test orchestrator reported no
executable running from those installer mounts. The unrelated simulator disk
image was left untouched; transaction backups and failed-run evidence remain
retained. See [the cleanup evidence](transaction/final-disk-image-cleanup.json).
An independent [read-only recheck](warden/final-stopped-state-recheck.json) at
**00:46:31 UTC** again found zero selected processes or live recorded identities,
the job unloaded and no new cleanup failure. It performed no lifecycle actions.

The result is a tested **development deployment**, with full specification
acceptance incomplete. The 31-feed video requirement failed. Production signing,
protected machine/alternate-administrator installation, complete dependency and
license provisioning, clean/oldest supported Mac testing, actual remote-Mac
deployment, and reboot/cold-start acceptance remain blocked or unverified in the
matrix. No further app changes, security-policy changes, reboot or publication
were performed. Native UI review also reported an off-screen camera Purpose
popup/keyboard-focus issue; its reproduction and cause remain unverified, and no
fix for that separate product issue is included here.
