# Office process shutdown and rollback

The operator approved the one-run script exception and reviewed the requirement
warnings. Run `office-20261030-133905-ecc0b48c` returned
`INSTALL_PROCESS_RESPAWNED`. Its saved result reported `rollbackVerified=true`
and `labsStartupRestored=true`. A fresh read-only check confirmed the previous
Watchtower **1.1.779.0**, managed startup Running/enabled, Labs Ready/enabled and
legacy `wt-warden` Disabled. The four installed processes formed the expected
launcher → native parent → native child → Watchtower chain in session 1.
The operator did not separately confirm the current visual wall; the rollback
result records completion of its startup/video verification.

The failure occurred during `BeforeReplace`, before any directory move, inside
the transaction's recovery protection. Successful restoration rethrows the
original error with verified rollback; failed restoration has its own error.
The old application directory stayed in place and the staged payload was retained.

The previous shutdown implementation captured one process list, stopped those
processes and treated any entry in its first recheck as a restart. That result
does not establish a newly launched process. Microsoft's
[process termination contract](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.kill?view=netframework-4.8.1)
documents asynchronous termination and the limits of waiting for descendants.
The exact identity left in Office's failed historical recheck was not recorded.

The correction retains native handles and exact owner/path/session/creation
identities before stopping the verified task. It finishes only admitted
processes and waits a bounded time for the owned chain to become inactive.
Old metadata for a demonstrably exited process can settle; an unknown or newly
live identity, changed ownership/session/path, reused PID or unverified access
still refuses. Newly discovered processes are never killed by name or adopted
as a replacement root. The original identity set survives a failed shutdown
into recovery before replacement starts. Recovery independently checks those
identities even when the provider omits them; it cannot silently adopt a new
process that the first shutdown refused. A separate replacement set is allowed
only after the installer attempts its own verified replacement startup.
The original backup, runtime/video verification and rollback remain required.

The earlier integration fixture removed every process immediately when its
fake task stopped, and replaced the real process shutdown function. The new
coverage exercises the actual shutdown code with a four-process model,
asynchronous exit, stale metadata, new identities and recovery before files move.
All operating-system capabilities are stubbed before entry; no production
task, process, service or security policy is changed by these fixtures.
Final shutdown and managed-update fixtures pass on both Windows PowerShell
5.1 and PowerShell 7: **105 shutdown checks and 89 transaction checks** per
engine. They cover delayed four-process exit, stale and omitted provider rows,
PID reuse, access failure, handle disposal, task-stop failure, timeouts and
recovery before files move. The real-new-process recovery case returns
`INSTALL_FAILED_ROLLBACK_UNVERIFIED` without killing that process, performing
a second task mutation, replacing files or starting another application.
The ordinary exited-process case still verifies restoration successfully.
Logs and source/test hashes are retained in
`C:\wt\office-stop-tests-20261031\owned-drain-managed-final.json`.
Office wrapper **60**, idle analysis startup **166** and consent launcher
**37** regression checks also pass per engine: **457 checks per engine** in
total for the shutdown and Office suites. Their logs share that directory.
Independent review reran the final 105 and 89 checks under both engines and
confirmed the process-identity boundary across installation and recovery.

The broader generic installer fixture passes 127 checks in Windows PowerShell
5.1, which the Office launcher uses. Under PowerShell 7 it stops in an unchanged
cross-desktop window-proof date parser: that engine converts a JSON timestamp
to a date object before the existing parser receives it. Both the parser and
fixture match the preceding committed version. This separate compatibility
issue is not changed here; the full generic suite is not reported as passing
under PowerShell 7.

Delivery preserves every Watchtower 1.1.791 / Warden 1.5.0 application, runtime
and symbol byte from source `799396a3664477c5b8fa809a7bf48ce4c4b1116c`.
The corrected installer helper requires a new manifest checksum and entry/CMD
pins. Its deployment-tool commit is recorded separately from the compiled
application source. The small correction therefore includes both updated
package metadata/helper and the outer update files. The previous manifest
checksum must not be reused for the changed helper.

Office's new installation and current moving video remain acceptance gates.
No reboot, crash probe, Labs job start, hold removal or saved policy change is
part of this correction. Booth's separate recovered October 30 crash remains
unexplained by its retained dump and is not attributed to this shutdown error.
