# Office startup selection correction

The Office operator ran the verified 1.1.791 CMD launcher and explicitly
approved its one-run script exception. The wrapper returned
`OFFICE_STARTUP_OWNERSHIP_AMBIGUOUS`. This refusal occurs before result-file
reservation, `Install-WtgPackage`, task changes or application stops.

## Cause and correction

The successful October 13 generic installation deliberately retained its old
root `wt-warden` task disabled beside the managed
`CilexWatchtower-2C40105CD30C9B6A` task. The wrapper incorrectly treated that
inert native-Warden action as a competing owner of the managed launcher.
An in-memory reproduction with both definitions returned the reported error;
the managed task alone passed.

The wrapper now excludes at most one exact historical definition only when a
validated managed installation marker exists. It requires root `wt-warden`,
boolean disabled state, Task Scheduler `Disabled` state, matching owner SID,
Interactive/Limited principal, one exact installed `warden.exe` action with
literal `run`, and an empty or matching installation working directory.
The definition is preserved unchanged. An enabled, running, unknown, foreign,
nested, duplicated or malformed alternative still blocks installation. The
managed task must still be unique and pass the generic installer's XML checks.

No generic ownership guard was relaxed. Marked updates continue using the
managed launcher/native-Warden process chain and the existing transactional
backup, startup/video checks and rollback. The disabled legacy task is not
adopted or re-enabled.

Historical evidence: [October 13 final inspection](../2026-10-13-generic-deployment/README.md#final-office-inspection-and-cleanup),
`C:/wt/generic-office-approved-postcheck-67b1c67126e6/result.json` and its
`record-and-cleanup-verification.json`. The latter confirms the installation
marker is current using explicit UTF-8. Current Office task data was requested
from the operator; historical evidence is not a fresh station inspection.

## Verification and delivery

The isolated wrapper fixtures passed **60 checks under Windows PowerShell 5.1
and 60 under PowerShell 7**. They cover the exact two-task case, order
independence, preservation, disabled-only setup, duplicate definitions and all
rejected variants above. These fixtures do not execute the installer or touch
real scheduled tasks, processes, services or policies.

The managed-update integration fixtures passed **34 checks per engine**, with
an independent rerun of all 94 wrapper/integration checks per engine. Actual
wrapper selection, owned marker/XML validation, directory backup/swap, config
preservation and rollback run against disposable files and in-memory Windows
capabilities. Success touches only the derived managed task. A forced startup
failure restores the exact prior files, task XML, enabled state, config and
registration; the disabled legacy task/XML remain unchanged in both cases.
No real task, process, registry, ACL, service or prerequisite installer is used.

Reproduce the isolated checks with `test-update-local-package.ps1` and
`test-managed-office-update.ps1` beside the Office wrapper, under each supported
PowerShell engine. These checks do not establish the current Office task state
or successful station deployment.

The correction changes deployment tools only. The existing exact-source
Watchtower **1.1.791** / Warden **1.5.0** application package remains unchanged:
application source `799396a3664477c5b8fa809a7bf48ce4c4b1116c`, manifest SHA-256
`A7B35BD7F2BDD8A93BBB8924741DA0ED5BC466E4C9236ADDF79A4EB89E869D7F`.
Delivery regenerates the CMD pins for the corrected wrapper and supplies a
small fix ZIP for the already-downloaded package, plus a complete revised ZIP.
Application installation, current prerequisites/Labs state and Office moving
video remain separate acceptance gates. Security Booth needs no restart for
this deployment-tool correction.
