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

## Separate deployment gates

Passing fixtures establishes implementation behavior, not unattended station
acceptance. The final committed package must separately pass isolated startup,
its own SQLite runtime check, a bounded real backend round trip using genuine
observations, and station startup/advancing-frame checks after replacement.
The 180-minute schedule is tested with an injected clock; a full production
three-hour cycle and reboot recovery are separate observations.

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
