# Camera availability: implementation and acceptance

Task: **CAM-AVAIL-WT-20261027**. Source began at `cddf4ab2` in the isolated
`codex/camera-availability-20261029` worktree. The unrelated primary checkout
and its untracked handoff were preserved.

## Implemented

- One application-owned worker, SQLite journal/outbox and scheduled/manual sync.
- Durable event/batch identity, exact acknowledgements, native cursor commits,
  retries, poison isolation, destination pinning and scoped history.
- Backend reports, API freshness, actual RTSP and QtMultimedia decoded delivery,
  snapshot freshness, restart/sleep/logging gaps and indefinite retention.
- English/Russian Health history and manual sync; role checks are enforced in C++.
- A local Office update wrapper for the verified generic package, with backup,
  startup/video checks and rollback. It does not grant remote administrator access.

See the [operator guide](../../features/camera-availability.md),
[shared contract](../../reference/camera-availability-v1.md) and
[UI/runtime evidence](ui-and-runtime-checks.md).

## Measured checks

Checks ran on the Windows Booth with MSVC 2022 and Qt 6.12, using isolated
profiles, loopback fixtures and owned child processes. No synthetic incident
was submitted to production by these fixtures.

| Check | Result | Retained local evidence |
|---|---|---|
| Clean SQLite journal build and persistence/failure/relationship tests | 125 passed | `C:/wt/availability-journal-final-clean-20261029/results.txt` |
| Fresh worker/journal HTTP integration | 22 passed | `C:/wt/availability-sync-clean-r10-20261029/results.txt` |
| History UI, each language | 12 passed EN; 12 passed RU | `C:/wt/availability-ui-{en,ru}-r7-20261029` |
| Shared schema/fixture validation | 26 passed | Refer to `ui-and-runtime-checks.md` |
| Clock/evidence rules | 38 passed | `C:/wt/availability-observer-rules-20261029` |
| Actual RTSP identity | 27 passed after a clean rebuild | `C:/wt/availability-live-identity-20261029` |
| QtMultimedia HTTP decode, 75-second loss and recovery | 8 passed | `C:/wt/availability-media-result-20261029-attempt2.json` |
| Local Office wrapper | 27 passed; no installer executed | `packaging/windows/deploy/office/test-update-local-package.ps1` |
| Clean full application and real model workflow | Build passed; 11 model checks | `C:/wt/availability-model-20261029-final-clean` |
| Shipping Health screen, each language | 32 passed EN; 32 passed RU | `C:/wt/availability-recording-health-{en,ru}-20261029-final-clean` |
| Existing installed Booth SQLite runtime | Open/commit/reopen passed | `sqlite-installed-booth.json` |

The earlier RTSP test crash followed an incremental build with a stale caller
object after a class-layout change. Ninja recorded zero include dependencies
because CMake misdecoded the localized MSVC include prefix. Clean compilation
resolved that fixture failure. Final application/package builds must use fresh
objects. Earlier failure records are retained outside the repository.

## Real backend pilot and first rollout

The first exact-source package was Watchtower 1.1.789, commit `2622dd9c`,
with Warden 1.5.0. Its own isolated startup, packaged SQLite WAL/FULL
commit/reopen and packaged QtMultimedia delivery checks passed.

The brief Booth run committed 407 genuine local observations, received an exact
full acknowledgement, and imported 17,626 native server records. Read-only
SQLite inspection found no pending/rejected records and `quick_check=ok`.
Replaying the identical saved batch twice produced zero accepted new records,
407 duplicates each time, and the same original server receipt timestamp.
The database was opened read-only for this replay; no new event identities or
synthetic incidents were created. See [exact replay results](real-backend-duplicate-proof.json).

At that stage, this was a real upload and idempotency check. Operator-authenticated history
read-back, manual sync from the production UI, restart acceptance and a complete
production three-hour cycle remain separate gates.

The rollout restored the earlier Booth binaries because only 16 feeds returned
against the previous 19-feed baseline. The restored old version also showed 16
advancing feeds without playback errors. Its original watchdog task was restored
enabled/running. Both launches rejected a stale saved view; the prior 19 feeds
were subsequently matched to their existing saved camera group. The rollout
result and original backups are retained under
`C:/wt/availability-rollout-20261029-r2`. Installation then remained incomplete until
the intended camera view and the original video acceptance are restored.

### Station sign-in continuity correction

The rollout exposed an existing unattended sign-in defect: a live-only station
display session expired after fifteen minutes without renewal. `AuthController`
now renews it using that station's existing provisioned credential, retains video
during temporary failures, observes bounded retries/Retry-After, and marks expired
live information unavailable. It never grants operator/history/ingest privileges
to the display session. Operator sign-in and logout invalidate old asynchronous
replies, station headers are restricted to the configured origin, and auth error
logs no longer copy server response text. Existing operator refresh remains
separate. No default username/password is tried when service credentials are absent.

The isolated [station-session fixture](../../../tools/tests/station-session/README.md)
uses the actual authentication controller and a local HTTP server; it covers
renewal, expiry, temporary failures, rate limits, redirects, scope changes,
normal operator refresh, logout and delayed-response/cookie races. Production
sign-in continuity must still be checked after installing the corrected build.
New status messages have English/Russian translations.

Fresh native Qt run: **24 passed, zero failures**, 34.221 seconds; evidence
`C:/wt/station-session-final-r2-clean-20261029/results.txt` and `results.xml`.
Both translation catalogs parsed and contain all three new status messages.

## Separate deployment gates

### October 30 follow-up and storage correction

Watchtower 1.1.790 and Warden 1.5.0 were installed successfully on the Booth
in rollout `C:/wt/availability-rollout-20261029-r3`. At the October 30 follow-up,
the running application was a later Warden-owned launch, PID 18264, created
October 29 15:22:17 UTC; Warden PID 18452 was unchanged. Its seven currently
selected feeds were advancing without playback errors. This is the current
operator view, not the earlier 19/21-feed rollout baseline. The cause of the
intervening launch was not established.

Read-only journal inspection proved genuine production ACK waves at October 29
15:23, 18:24 and 21:24 UTC. Last success was 21:24:33 UTC, with the next scheduled
sync at 00:24:37 UTC. There were no rejected/unrecorded events or sync error;
24,382 events and 52 batches were acknowledged and 25,962 native records imported.
Pending observations since the last cycle were expected. This establishes the
production three-hour cadence; reboot, physical sleep and operator manual-sync
acceptance remain unverified. Evidence is retained under
`C:/wt/availability-office-followup-20261030`.

The database plus WAL occupied about 232 MB against the former 256 MiB budget.
The 100 MB WAL allocation contained only about 6.9 MB of current frames; most was
a reusable high-water tail. The corrected journal closes single-row read cursors,
sets a 1 MiB WAL reset limit, reclaims space outside transactions without waiting
for readers, and restores the normal 250 ms write timeout. The default physical
budget is now 2 GiB. Batch-envelope growth also passes the capacity fence. No
automatic history purge or schema migration was added.

Fresh native SQLite checks: **156 passed, zero failures**; the independent rerun
also passed 156. A 4,972,872-byte reusable WAL was reclaimed to zero while saved
history, pending/rejected records, native cursors and active immutable retry
bytes remained unchanged. Both incomplete-backfill and fully-backfilled but
TRUNCATE-busy reader cases refused promptly, then recovered with a durable gap
after the reader released. Evidence:
`C:/wt/availability-storage-tests-20261030/{results.txt,independent-review-results.txt}`.
The fresh worker/journal HTTP integration also passed **22 checks**, zero failures,
using the changed journal under `C:/wt/availability-storage-sync-20261030`.
Before replacement, the live journal was opened read-only and copied with the
SQLite backup API. The copy passed `quick_check`, retaining 52,234 events;
proof and backup are under `C:/wt/availability-storage-backup-20261030`.

The user confirmed Office's display-session check succeeds, but its saved
`APP_ENV` does not configure station-token fallback. This does not establish
unattended app sign-in. Office must show its normal camera wall before updating;
no Booth credential is copied there. Its 1.1.790 PS1 update was blocked by Windows
before execution. The Booth test firewall prompt was closed by the user.

The new Office CMD factory pins the entry script, wrapper and manifest before
consent and again before launch. Only unmanaged effective Restricted policy
offers a clear one-run child-process exception. Managed Restricted refuses;
other policies receive one normal attempt without automatic exception or retry.
No saved policy is changed. Harmless fixture children exercise the actual
generated CMD, Unicode/special paths and output/exit propagation; no production
updater, security policy or remote machine is touched by these tests.
The final launcher suite passed **37 checks under Windows PowerShell 5.1 and
37 under PowerShell 7.6.5**. Each run exercised both parent engines. A discovered
PowerShell 7 module-lookup incompatibility was fixed by using trusted Desktop
module folders inside the launcher's process and its child only. The actual
child imported Security, ScheduledTasks and CimCmdlets, hashed a harmless file,
and preserved its output and exact exit status. Reproduce with
`packaging/windows/deploy/office/test-office-launcher.ps1`; the fixture never
runs the production updater.

The first publication attempt stopped at two existing Labs process-fixture
assertions: concurrent Windows appends lost one decoder PID record. A focused
two-process reproduction lost records in 2,970 of 3,000 rounds. The fixture now
atomically publishes one PID file per camera; 3,000 rounds lost no records.
All lifecycle assertions, real child-process checks and timeouts remain intact;
no Labs product code changed. Evidence: `C:/wt/labs-pid-record-proof-20261030.json`.
The rerun exposed the same shared-append defect in fixture submission JSON.
Each submission now publishes a distinct complete JSON file atomically. Two
concurrent writers retained all 2,000 submissions, including repeat submissions
for the same camera; live reads saw no partial JSON and malformed published JSON
still fails. Evidence: `C:/wt/labs-submission-record-proof-20261030.json`.
The final required pre-commit validation body then passed in full: Labs worker
422 assertions, B1 40, A4-A6 79/79, object profile 40/40, frame-source process/GOP
checks and repository invariants. Version 1.1.791 was retained after the failed
initial attempt; validation was run separately to avoid another version bump.
Evidence: `C:/wt/availability-storage-required-checks-final-20261030.log`.

Passing fixtures establishes implementation behavior, not unattended station
acceptance. The final committed package must separately pass isolated startup,
its own SQLite runtime check, a bounded real backend round trip using genuine
observations, and station startup/advancing-frame checks after replacement.
The 180-minute schedule is tested with an injected clock; the real three-hour
cadence was subsequently measured above. Reboot recovery is unverified.

Office's administrator share and service manager reject this session's account.
The user can run an approved local command as Office administrator. Until that
result is returned, Office installation, Warden update and feature enablement
remain unverified. Do not weaken Windows policies to work around access.

Linux/macOS native builds and physical sleep/resume were not run from this
Windows session. Dual-clock gap rules are covered by deterministic fixtures.
Snapshot source/age and media streams without usable frame timestamps remain
unknown instead of claiming freshness. Native server planning files on the
Ubuntu filesystem were not accessible; the implemented backend contract and all
published schemas/fixtures were retrieved and verified through its repository.
