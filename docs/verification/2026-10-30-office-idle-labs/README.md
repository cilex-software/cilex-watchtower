# Office idle analysis startup barrier

The operator's read-only Office check reported no Labs worker or restart guard,
no current or assigned jobs and no hold. The status was 1,413,731 seconds old;
`wt-labs-start` remained enabled. The existing updater correctly refused before
application stops or installation. Old `stopped_by_server` status does not prove
that the server is still stopped.

The correction permits only the known idle Office startup task to be temporarily
disabled during update, verification and rollback. Its exact owner, action,
triggerless definition, launcher/guard hashes and Ready state are checked.
Any running or queued instance, other enabled Labs startup task, Labs
process in any session, unreadable actor or changed definition stops the update.

A private, flushed recovery record is saved before disabling. The existing
no-worker/no-restart-actor barrier is then checked on fresh data. Finally, only
the original enabled state is restored, without starting the task. Restoration
failure prevents a success report. Task definitions and Labs control files are
never rewritten. A power loss or forced termination can bypass cleanup; retain
the recovery record for a checked restoration in that case.

Local holds are not used: the worker treats a new hold as a reason to abort
assigned work. Starting a worker to refresh old status and accepting stale status
were also ruled out. Running analysis requires a separate safe pause and drain.

The verified Watchtower 1.1.791 / Warden 1.5.0 package remains unchanged, source
`799396a3664477c5b8fa809a7bf48ce4c4b1116c`, manifest SHA-256
`A7B35BD7F2BDD8A93BBB8924741DA0ED5BC466E4C9236ADDF79A4EB89E869D7F`.
Only the pinned outer updater changes. Booth needs no restart.

Isolated checks passed under Windows PowerShell 5.1 and PowerShell 7:

| Check | Passed per engine |
|---|---:|
| Wrapper package, startup selection and Labs barrier | 60 |
| Managed installation transaction and rollback | 34 |
| Idle Labs lifecycle, races and durable recovery | 106 |
| Package-pinned consent launcher | 37 |

The idle lifecycle suite covers success, installer failure, partial disable,
failed recovery writes/restoration, changed task/control/script/process state,
other owners/sessions, unreadable actors and read-only mode. Real disposable
files exercise private-writer capability failure, atomic replacement and the
captured callback through the actual lifecycle. All operating-system task,
process, COM, ACL and policy capabilities are stubbed before entry. No real
production capabilities are exercised. An independent review reran the 106
idle checks and reviewed final wrapper integration under both engines.

Reproduce using `test-update-local-package.ps1`,
`test-managed-office-update.ps1`, `test-idle-office-labs.ps1` and
`test-office-launcher.ps1` in `packaging/windows/deploy/office`. Local run logs:
`C:/wt/office-idle-labs-tests-20261030`.

The real writer tests found and fixed PowerShell's null-to-empty-string binding
for `File.Replace`'s optional backup path. The wrapper captures the writer
scriptblock explicitly because a new closure cannot resolve its caller's local
function by name. Fresh state is revalidated after flushing the initial record,
before the first disable, and immediately before the installer. Empty CIM
triggers represented as null are accepted only with a present property and
verified triggerless XML; missing or contradictory data still refuses.

No Office task has been disabled or application installed by this development run.
Actual Office task validation, installation, startup, moving video and recovery
remain runtime acceptance gates.

## Windows default settings correction

The first idle-startup correction returned `OFFICE_LABS_TASK_UNVERIFIED` on
Office. Its next read-only check confirmed Ready/enabled, the expected Admin
SID, Interactive/Limited, one exact `wscript.exe` action, empty working directory
and zero triggers. Exported XML had one matching principal/action, no triggers,
and omitted both default `RunLevel` and `Enabled`. Read-only Booth task exports
and an isolated reproduction confirmed the same normal representation.

The validator wrongly required an explicit enabled XML element. Microsoft's
[full Task Scheduler schema](https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-schema)
defines that setting as optional with default true. An omitted element now
requires the independently read task API to contain boolean true. Explicit XML
booleans must parse correctly and match the typed API value; duplicate, nested,
invalid or contradictory values still refuse. Principal, action, trigger,
instance, actor, script pin and control-file checks remain in place.

Task Scheduler may omit or materialize default true after re-enabling. Cleanup
therefore requires exact canonical XML for every field except the intentionally
toggled enabled element, plus the original semantic enabled state. It never
registers or rewrites task XML. The recovery record retains the original XML.

New fixtures reproduce the operator's omitted-default export through disable,
installation success/failure and restoration, including both omitted and
materialized true after re-enabling and the inverse serialization change.
They retain the earlier lifecycle cases and reject changes to any other XML
field, invalid/contradictory enabled values, foreign or missing principals,
changed actions and new triggers.

Final checks passed under Windows PowerShell 5.1 and PowerShell 7: wrapper 60,
managed installation/rollback 34, idle/default-state lifecycle 166 and launcher
37, totaling **297 per engine**. Independent review reran all four suites under
both engines. The writer/lifecycle tests use disposable files and in-memory
Windows capabilities; no real task, policy, service or production process was
changed. These fixtures do not establish actual Office installation or moving
video. Application package source and manifest remain unchanged as above.
