# Generic installation: simpler commands and visible prompts

Verified on 2026-10-13. No application deployment, service change, policy change or reboot was performed for this task.

## Changes

The [README](../../../packaging/windows/generic/README.md) leads with local and remote installation. All 46 script parameters have an explanation, default/required condition and example in its expandable reference. The [advanced guide](../../../packaging/windows/generic/ADVANCED.md) retains packaging and troubleshooting details.

The remote shorthand derives the mode, host and transport from its network staging path. Explicit conflicting targets are rejected. Git source acquisition tries saved access, then offers one hidden token prompt on an access failure. Target warnings are reviewed locally; accepting a warning on the build computer does not silently accept the same warning on the destination.

Interactive local installation shows its helper questions directly. An approved elevated retry is visible. Automated helpers keep captured logs. Interactive dialogue is not captured; the installation log states this and the structured result remains saved.

## Automated checks

Run from the repository root using Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -NonInteractive -File packaging\windows\generic\tests\run-tests.ps1
```

Exit code: **0**. **490 checks passed**:

| Suite | Passed |
| --- | ---: |
| Requirements | 27 |
| Dependencies | 115 |
| Common helpers and source | 45 |
| Entry point | 48 |
| Installation | 127 |
| Remote installation | 94 |
| Build/package fixtures | 34 |

[Captured fixture output](fixtures.log), with the temporary-directory prefix normalized to `%TEMP%`. README option coverage was checked against the script's PowerShell syntax tree: 46/46 documented, no missing options. Local README links and `git diff --check` passed.

## Real terminal check

```powershell
powershell.exe -NoProfile -File packaging\windows\generic\tests\test-interactive-process.ps1
```

Executed in a ConPTY terminal. The child's `Read-Host` prompt appeared before input was supplied. Entering the harmless `fixture-approved` answer produced `Child received the reply.`, then PASS and exit 0. The child exited and the log explicitly recorded that interactive output was not captured.

An earlier pipe-only attempt failed with child exit 7 because a consoleless parent did not provide the intended terminal input/output. Both processes exited; that attempt is not treated as successful console evidence. The retained console-only test rejects redirected input/output.

## Limits

No live local/remote installation, real GitHub-token entry, UAC approval or reboot was exercised in this task. The optional Python, compiled installer and native launcher suites were not rerun; their implementations were unchanged. Fresh-machine/offline and unattended-reboot acceptance remains open as recorded in the [earlier deployment evidence](../2026-10-13-generic-deployment/README.md).
