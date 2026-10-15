# Darwin Warden verification

Source base `199a8998c4a4b20d8ebffdec87b5bc053adb473b`, plus the uncommitted
Darwin implementation identified by hashes in `checks.json`. No publication or
production deployment occurred as part of these Warden checks.

Measured on macOS 26.6.2 (25G83), native arm64, using `/usr/bin/python3` 3.9.6:

| Check | Result | Evidence |
| --- | --- | --- |
| 23 unit/native integration tests | Passed | `native-startup-cleanup-corrected-tests.log` |
| Existing app-version regression (5 cases) | Passed | `app-version.log` |
| Native PID/UID/birth/path/session, Mach CPU/memory, hardware identity APIs | Passed on this Mac | native suite |
| Literal Unicode/space paths and native spawn gate | Passed | native suite |
| New machine identity, preserved legacy enrollment/token refresh/preferences path | Passed in isolated fixtures | native suite |
| Missing logs, wall-clock jumps, wake and scheduler-gap grace | Passed with injected clocks | native suite; physical sleep not tested |
| Guard EOF after parent SIGKILL, including observed detached-session descendant | Passed, 0.121 s | final native suite |
| Guardian SIGKILL detected by Warden, child stopped, Warden exits for recovery | Passed, 1.119 s | final native suite |
| Isolated child crash restart | Passed, 5.135 s | final native suite |
| Duplicate refusal, reused PID mismatch, installation mismatch, maintenance pause/resume | Passed | native suite |
| Private records and bounded logs reject escaping symlinks | Passed | native suite |
| Actual temporary Aqua LaunchAgent parentage | Passed: launchd → Warden → fixture executable | `launchd-result.json` |
| Actual launchd restart after Warden SIGKILL | Passed, 4.919 s; no overlap | `launchd-result.json` |
| Temporary LaunchAgent and child cleanup | Passed | `launchd-result.json` |
| First packaged PyInstaller native suite | Failed: 2 initial guardian ACK timeouts out of 22 tests | `packaged-warden-tests.log` |
| First packaged actual launchd restart after Warden SIGKILL | Passed, 0.840 s; no overlap | `packaged-launchd-first/result.json` |
| Updated frozen runtime after startup fix (23 cases) | Passed | `packaged-warden-corrected-tests.log` |
| Updated frozen actual launchd recovery | Passed, 4.872 s; no overlap; temporary job cleanup verified | `packaged-launchd-corrected/result.json` |
| Clean Mac, offline installer | Unverified here | artifact workflow must establish separately |
| Read-only runtime verifier (24 cases) | Passed; includes native process/window APIs | `runtime-tests.log` |
| Authenticated local HTTPS fixture (5) and source-integrity cases (3) | Passed; no external network or real credentials | `source-https-tests-final.log` |
| Real-application crash-harness safety logic (12 mocked cases) | Passed; no real signals sent | `recovery-harness-unit-tests.log` |
| Native dotted Qt backend key plus slash compatibility | Passed: 24-case source suite and executable status fixture | `native-dotted-qt-preferences-tests.log`, `native-dotted-qt-status-test.log` |
| Existing native backend preference presence | Present; preference file unchanged; values not exposed | `native-preferences-presence.json` |
| Source Warden through env -i LaunchAgent | Passed; contamination removed, direct parentage, recovery 8.860 s, no overlap | `native-clean-env-launchd/result.json` |
| Updated packaged Warden with native Qt preference fix (25 cases) | Passed; includes packaged executable backend-resolution fixture | `packaged-warden-dotted-qt-tests.log` |
| Updated packaged env -i LaunchAgent | Passed; direct parentage, contamination removed, recovery 7.916 s, no overlap, cleanup verified | `packaged-clean-env-launchd/result.json` |
| Legitimate 1.56 MiB installed receipt | Initial frozen verifier failed; corrected read-only verifier passes receipt validation and correctly reports stopped app | `installed-stopped-receipt-verifier-regression.json` |
| Receipt/guardian size separation (26 runtime cases) | Passed; receipt 32 MiB bound, guardian unchanged at 1 MiB | `runtime-receipt-size-tests.log` |
| Initial installed restart cause | Explained by normal exit 0 plus operator-quit marker and existing kiosk policy; not a measured crash | `installed-restart-and-shutdown-diagnosis.json` |
| Initial installed shutdown cleanup | Failed native identity read in guardian; original errors retained; underlying transient cause not established | `installed-restart-and-shutdown-diagnosis.json` |
| Bounded native identity retry and explicit shutdown classification (31 source cases) | Passed; includes persistent denial refusal and 12 rapid child-exit cleanup races | `shutdown-corrected-native-tests.log` |
| Revised source env -i LaunchAgent | Passed; recovery 9.971 s, no overlap, detached descendant and temporary job cleanup verified | `shutdown-corrected-launchd/result.json` |
| Per-source VIDTEL parsing/progress (38 runtime cases) | Passed; strict schema, duplicate rejection, stale/stalled/reset source failure and external-vs-initial identity basis | `runtime-vidtel-corrected-tests.log` |
| Revised signed packaged Warden (31 cases) | Passed; runtime-tree and binary hashes unchanged; no fixture processes remain | `checks-packaged-readiness.json`, `packaged-readiness-warden-tests.log` |
| Revised packaged env -i LaunchAgent | Passed; recovery 9.842 s, no overlap, cleanup verified; no identity/ACK/cleanup errors | `packaged-readiness-launchd/result.json` |
| Actual rebuilt Warden intentional shutdown | Passed once: explicit shutdown/final heartbeat; no new cleanup errors; root verified zero selected processes | `actual-rebuilt-warden-stop-classification.json` |
| First real crash-harness preflight | Failed before signals: retained historical telemetry exhausted reader row limit | original protected run retained; `retained-log-session-reader-regression.json` |
| Final RTSP-reconnect package Warden suite | Passed 31 cases in 31.951 s; full runtime inventory unchanged | `checks-packaged-rtsp-reconnect.json` |
| Final RTSP-reconnect package isolated env-i LaunchAgent | Passed; Warden crash recovery 9.861 s, direct parentage, detached descendant cleanup, no overlap; temporary job removed and zero selected fixture processes | `packaged-rtsp-reconnect-launchd/result.json` |
| Final user-requested stopped state | Read-only recheck passed at 00:46:31 UTC: selected job unloaded, zero selected processes and no live recorded owner/guardian identities; intentional stop at 00:40:23 UTC, no new cleanup errors | `final-stopped-state-recheck.json` |
| Current-session bounded log reader (42 runtime tests) | Passed; history isolation, preserved latest start, bounded tail/line/bytes and actual retained-log replay | `runtime-session-tail-tests.log` |
| Real Watchtower GUI, backend, video150 s, playback/export | Unverified here | fixture only |
| Real sleep/wake, locking, user switching, network reconnection | Unverified | no settings changed |
| Login/reboot/power loss, oldest claimed macOS | Unverified | temporary job registration does not prove startup |

Commands:

```sh
/usr/bin/python3 tools/tests/warden-darwin.py
/usr/bin/python3 tools/tests/warden-app-version.py
/usr/bin/python3 tools/tests/warden-darwin-launchd.py \
  --allow-launchd --evidence-dir "$EVIDENCE_DIR"
```

The user explicitly designated this Mac for controlled installation/crash tests
before the launchd drill. It used only a unique temporary job and compiled C
fixture, temporary home/state/configuration, empty backend/token, and a literal
fixture executable path. The real application and its existing startup jobs,
station credentials, Qt preferences and unrelated worker/guard state were not
touched. The test fixture creates a descendant with `setsid()`; observing it in
the guardian record before the failure proves this case exceeds inherited
process-group cleanup alone. Arbitrary helpers that detach entirely between
snapshots remain outside the established coverage.

A genuine failed intermediate run is retained in `native-system-python.log`.
A stricter process-permission check initially misclassified already-dead Darwin
zombies: libproc returned ESRCH while `kill(pid, 0)` still succeeded. The fix
uses a bounded native `ps` status read to confirm zombies; unreadable live
identities remain failures. `native-system-python-corrected.log` records the
passing correction. An earlier test-only assertion also needed `/var` to
`/private/var` canonical path normalization; it did not reflect an execution
failure. Successful later runs do not erase these earlier findings.

The first frozen runtime suite exposed a separate real failure: initial guardian
startup exceeded the original 10-second acknowledgement budget in two cases.
The temporary packaged LaunchAgent measured about 15.2 seconds between its Warden
and guardian process creation. The initial handshake now allows 30 seconds;
operational acknowledgements retain their 10-second bound. Constructor failure
now closes its pipe and reaps the guardian before returning failure. A new forced
stall test initially exposed Apple's Python launcher changing executable path
when it enters its framework runtime. Cleanup now matches the unreaped direct
child's PID, birth, UID, session and parent, then binds the current exact path
before signalling. The failed regression is retained in
`native-startup-cleanup-tests.log`; all 23 source tests then passed in
`native-startup-cleanup-corrected-tests.log`. The rebuilt frozen runtime subsequently passed all 23 cases and the actual
temporary LaunchAgent test (`packaged-warden-corrected-tests.log` and
`packaged-launchd-corrected/result.json`). The executable, full runtime tree
digest and source hashes are recorded in `checks-packaged-final.json`. This
uses PyInstaller 6.16.0 and Python 3.13.0; the fixture driver uses system Python
3.9.6. It does not establish clean-Mac, offline-DMG, real-camera or login/reboot
acceptance.

A later native-preference check found Qt stores the backend under
`auth.baseUrl` in the macOS plist. Warden now reads that native key and accepts
the older slash form only when the native key is absent; an empty native value
does not revive a stale fallback. Real preferences were read only, with only
presence and unchanged-file booleans recorded. The executable status fixture
first had a test-only source-description assertion mismatch, retained in
`native-status-fixture-first.json`; backend resolution itself was correct.
The subsequent frozen rebuild passed all 25 tests and the env -i LaunchAgent
fixture. `checks-packaged-dotted-qt.json` records the updated source hashes,
binary hashes (unchanged before/after testing), runtime-tree digest, and measured
recovery. Earlier frozen binary hashes do not cover this preference fix.

The final recorded source hashes cover only the Warden/test files. The eventual
signed installer must separately freeze, hash and validate the exact helpers and
application artifacts it contains.

The separate `tools/tests/macos-deployment-recovery.py` harness is prepared for
the explicitly designated test Mac. Preparing it and passing its mocked tests
does not constitute a real-application crash test. It requires explicit
`--install-dir`, `--desktop-user`, `--test-mac-id` (the deployment machine hash),
`--expected-cameras`, `--evidence-dir`, and `--crash-app` and/or `--crash-warden`.
It refuses root, a different console account, an altered installed inventory,
an inactive/disabled selected LaunchAgent, or an unstable native process graph.
It sends one SIGKILL to the exact revalidated selected process, observes an
application recovery budget of 45 seconds or Warden budget of 60 seconds, and
requires fresh 150-second per-source video evidence from the same recovered
process generation, matching the visible pre-crash source hash set. It does not retry failed drills, repair startup, clear
backend holds, or reboot. Each attempt is retained in a new private evidence
directory, including incomplete/failed outcomes.

The explicit test-only `--process-only` option retains the failed video baseline
and tests process recovery without claiming video acceptance. All inventory,
receipt, native identity, LaunchAgent and visible-window checks remain required
before each signal. Available initial source hashes are pinned; before/after
instantaneous video results remain in the evidence. After process recovery, GUI
readiness is bounded separately at 30 seconds. A completed drill reports
`PassedProcessRecovery_VideoAcceptanceFailed`, `full_acceptance: false` and exit
21; it never becomes a successful 150-second video test. Nineteen mocked safety
tests passed (`recovery-process-only-tests.log`); this does not prove actual
process recovery. The invoking controller must stop both products afterward and
record their absence. The harness does not stop them itself.

During the later actual installation, the original frozen verifier rejected a
legitimate 1,562,588-byte artifact inventory receipt using the guardian's 1 MiB
record limit. The receipt reader now has its own 32 MiB bound, enforced both
against file metadata and bytes read; the guardian retains its 1 MiB bound.
The corrected read-only verifier accepted the same installed receipt, reported
the deliberately stopped application, and created no evidence files or changed
receipt/support entries. This does not establish video or startup acceptance.

The earlier observed application restart was initially unexplained. A later
bounded, read-only inspection resolved it: the app exited with code 0 after
196 seconds and a fresh operator-quit marker; the existing kiosk policy
restarted it after one second. This observation is not an application crash
test, and the policy was left unchanged. The original user-requested shutdown
did expose a separate failure: native identity reads failed inside guardian
descendant cleanup, then the owner reported an invalid guardian acknowledgement
and retained a secondary cleanup error. Only numeric events, classifications
and log hashes were saved; no raw installed logs or credentials were copied.

Known-process identity reads now retry for a bounded 0.5 seconds and still fail
closed for a persistently unreadable live process. Tests inject transient
failures and persistent denial, and run 12 real temporary child exits against
guardian cleanup. The first added assertion expected `/tmp` instead of macOS's
canonical `/private/tmp`; its failed output is retained in
`identity-retry-tests.log`, and corrected tests passed. Explicit Darwin shutdown
or maintenance now also takes precedence when child wait completion races the
intent flag, without changing normal kiosk closure. These mitigations passed
31 source tests and the isolated LaunchAgent drill. They do not prove the
underlying reason for the installed native read failure or replace a packaged,
real-application shutdown retest. The user's required final state is **both
Warden and Watchtower stopped**; root coordinates any actual-app lifecycle tests.

The readiness verifier now accepts the explicit schema-1 `[VIDTEL]` signal
emitted alongside each aggregate sample. It keeps only hashed source IDs and
numeric/boolean delivery state, rejects malformed/duplicate fields and source
IDs, and requires every source to remain decoder-bound, error-free, recently
delivered (at most 5 seconds) and strictly advancing for the full observation.
The set must retain its expected count and identity. An initially observed set
is distinguished from externally supplied expected hashes; neither by itself
maps hashes to camera names or validates playback/export. Adjacent telemetry
writes get a bounded 2-second join window so a concurrent read cannot mistake
an incomplete write pair for a source loss. The source evidence has a 256 KiB
JSON and 1,024-entry bound. An older aggregate-only log remains explicitly
aggregate evidence. These parser tests do not establish actual camera behavior;
the rebuilt application and frozen helper still need the live 150-second run.
An initial fixture incorrectly expected a just-deferred sample to be returned;
`runtime-vidtel-tests.log` retains that failed expectation, and the corrected
38-case suite passed. The separate crash harness pins the initial visible source
hashes across recovery and still leaves final stopping to the invoking controller.

The rebuilt signed Warden then passed all 31 cases in 31.152 seconds and the
isolated env -i LaunchAgent drill recovered in 9.842 seconds with direct parentage,
no overlap and observed detached-descendant cleanup. Its executable hash
`2d54b3528640f02cbdcd0ee8e414e5cf366ea9f35b424c3df003922ed4ab7b48`,
gate hash and complete 65-entry runtime tree were unchanged before/after tests.
No fixture Warden remained, and its retained logs contained none of the earlier
native-identity, invalid-acknowledgement or cleanup failures. These frozen tests
exercise isolated fixture applications, not the installed camera application.

The first real crash-harness preflight failed before sending any signal because
three retained flight-recorder files (30,051,980 bytes) contained 16,912 matching
historical rows and 299 start markers, exceeding the reader's old total-row cap.
The active session contained only ten matching rows at diagnosis. The reader
now keeps the latest start boundary separately and a bounded 2,048-row tail of
that session; history cannot consume its evidence budget. File reads retain the
16 MiB per-file and 64 MiB total limits, enforce the total on actual bytes read,
and cap individual reads/lines at 260 KiB. Malformed latest boundaries still
invalidate earlier success. All 42 runtime tests passed. Replaying the same
retained logs at the failed observation time now identifies 31 sources, but only
one sample existed then, so the result correctly remains insufficient for a
video-progress claim. The original failed result is unchanged. The corrected
frozen helper and a fresh 150-second live observation remain necessary.

Root stopped the rebuilt installed application after this preflight failure.
Read-only classification confirmed Warden recorded an intentional supervisor
stop and its final intended-stop heartbeat, with no new cleanup failure. The
launchd error log was byte-for-byte unchanged from the original failed shutdown,
so its old identity/acknowledgement errors were not mistaken for new errors.
This is one verified clean shutdown, not a general reliability guarantee.
