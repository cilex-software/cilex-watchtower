# Operator reboot handoff — 14 November 2026

Written for the operator's planned reboot. This save does **not** reboot the
machine or authorize deletion of footage. Read this document first in the next
session, then the detailed task handoffs linked below. Never treat historical
resource/service/stock observations as current after reboot.

## Immediate continuation

1. Resume Codex normally: `cd ~/projects/cilex-vision && codex resume`, or use
   the Watchtower directory for this coordinating session. A saved local Codex
   configuration workaround is described below. No need to delete sessions.
2. Read current project instructions. Backend: `AGENTS.md`, `CONVENTIONS.md`,
   exact approved memory/storage table in `PROJECT-STATUS.md`, current
   `.agents/manifest.yaml`, and related handoffs. Watchtower: `AGENTS.md`,
   `CLAUDE.md`, `docs/PROJECT_STATUS.md` and the 6 November handoff.
3. Inspect fresh Git status and deployed identities without resetting, stashing,
   switching or building dirty primary checkouts. Fetch actual published sources
   before integrating work. Preserve unrelated changes and recovery overlays.
4. The latest unfinished development task is the emergency **recent footage**
   purge. It remains unsafe to enable. Read its handoff before editing or running
   any plan/start command. The operator asked what publisher coordination meant;
   the answer explained it and confirmed it can be implemented. That exchange
   did not implement coordination, approve a deletion plan or start deletion.
5. Recheck services/resources after reboot through bounded read-only commands.
   Do not rerun historical boot/recovery capsules, start cleanup, remove guards
   or clear ownership merely to obtain a healthy-looking state.

## Emergency purge — exact request and unfinished state

The operator requested a parameterized emergency script and explicitly clarified
that X means **the MOST RECENT X days**, preserving older footage. It must never
silently become an older-than-X retention command. The proposed interval is the
database clock's rolling `[now-X*24h, now)`.

Isolated backend worktree:

```text
/home/cilex-vision/projects/cilex-vision-emergency-purge
branch: codex/emergency-footage-purge-20261113
base HEAD: 6333e9b27d6eece3bf2bcf91b68c84fc84857919
```

At this save, `git status --short --branch` showed that worktree behind cached
`origin/main` by four commits, with task-owned modifications and untracked
files. This is a local cached comparison, **not verification of latest remote
or deployed source**. No purge-task commit, push, install or enablement occurred.

Canonical detailed task record:

```text
/home/cilex-vision/projects/cilex-vision-emergency-purge/
  .agents/handoff/EMERGENCY-RECENT-FOOTAGE-20261113.md
  .agents/prompts/EMERGENCY-RECENT-FOOTAGE-20261113.md
  tools/storage/RECENT-PURGE.md
  tools/storage/purge_recent_footage.py
  tools/storage/recent_footage.py
```

Local implemented portions: CLI plan/status/execute/pause with durable private
intent and exact-digest confirmation (`tools/storage/purge_recent_footage.py:152`);
recent raw main/sub planner (`tools/storage/recent_footage.py:281`), metadata
backup (`:325`), and a worker refusal without publisher exclusion (`:492`).
Only closed indexed raw main/sub video wholly inside the frozen interval is in
the proposed scope. Active/local/pending uploads, boundary-crossing segments,
incident clips, exports and unindexed objects are excluded. Boundary counts are
not measured. Metadata backups are not video backups, and logical S3 deletion
does not promise immediate physical free space.

**Execution is intentionally unavailable.** The host does not advertise recent
start (`services/storage-agent/storage_agent/cleanup_coordinator.py:88`) and
explicitly rejects it (`:600`). The host feature flag defaults off
(`services/storage-agent/storage_agent/cleanup_runtime.py:110`). Do not turn a
flag on or remove a refusal and claim the missing synchronization is solved.

### What "publisher coordination" means and why it remains necessary

Publisher means Cilex Vision's own code that uploads recorded bytes and commits
the archive catalogue entry. Source review found that an existing identity can
be uploaded again (`services/recorder-service/main.py:844`); object upload
precedes the catalogue INSERT (`:962`, `:992`, relative to the isolated base).

Inferred race, **not a reproduced production deletion**: an upload can finish,
purge can delete that object, then the delayed catalogue INSERT can recreate an
entry pointing to missing video. Catalogue table locks alone do not exclude the
physical upload. Coordination must reserve exact selected identities, finish or
refuse uncertain in-flight work, delete consistently and handle retries/restarts.

No real publisher-exclusion implementation has been added. The worker's trusted
`pool.assert_recent_purge_exclusive(plan_digest)` hook is deliberately absent in
the production maintenance pool and refuses before deletion. Do not stub it with
success. A shared advisory lock alone cannot prove that a background S3 transfer
finished after task cancellation, database-session loss or process failure.
All relevant paths need consideration: continuous upload, motion raw indexing,
raw tier migration and their physical-I/O closure. Preserve pending media;
broad interval tombstones must not expand the exact reviewed deletion set.

### Verification evidence and remaining checks

CLI isolated actual Unix-socket fixtures: **24 passed, exit0**; receipt namespace
`/media/cilex-vision/86761555761546F9/CilexLab/emergency-recent-cli-checks-20261113-v2/`,
sealed generation `2917bae5fbbf43019074ab81eebed298`.

Worker synthetic DB/S3 fixtures: **31 passed, exit0**; namespace
`/media/cilex-vision/86761555761546F9/CilexLab/emergency-recent-worker-checks-20261113/`,
sealed generation `b01e8f79a7f948ab8332ad1b44dd4e19`.

Parent scoped Ruff and `git diff --check` passed. Exact commands, source hashes,
UTC times, stdout/stderr and exit codes are in
`/media/cilex-vision/86761555761546F9/CilexLab/emergency-recent-integration-review-20261113/`.
The normal pressure admission returned `memory_pressure`, exit1, so integrated
coordinator/API/type checks and real PostgreSQL/S3 fixtures were **not run**.
Helper tests do not establish full integration, PostgreSQL SQL validity or
operational purging. Earlier failed CLI tests and admission refusals are retained
in the detailed handoff; do not erase or call them passes.

At 2026-11-13T11:46:55Z, saved `systemctl show storage-agent.service` reported
inactive/dead/PID0. That is a **historical observation**, not present health or
an established cause. No service was restarted in this purge task.

Remaining: implement and review real publication exclusion; run integrated and
isolated real-service failure/recovery tests after normal admission permits;
reconcile independent existing cleanup rollout/owners; publish only completed
changes, then install/enable/verify with rollback. Actual deletion still needs
explicit confirmation of a specific finite plan. Never delete footage during
development to manufacture acceptance or space gains.

## Private reboot backups — verified before this save

The new private snapshot directory is:

```text
/home/cilex-vision/.local/state/cilex-vision/session-restart-20261114T152752Z/
  SESSION_RESTART_2026-11-14.md
  snapshot.json
  watchtower.status.txt
  watchtower.tracked.patch
  emergency-purge.status.txt
  emergency-purge.tracked.patch
  emergency-purge-task-files.tar.gz
  emergency-purge-files.sha256.json
```

The archive includes 22 task-owned tracked/untracked purge files; a read-back
hash comparison against its SHA-256 inventory passed. The Watchtower tracked
patch is a backup of pre-existing unrelated changes, not permission to apply or
publish them. Both original worktrees remain in place. Do not blindly extract
or apply backups over newer source; compare current files/HEAD/ownership first.
The exact snapshot timestamp is recorded inside `snapshot.json`; the directory
name is an identifier, not a fabricated approval/reboot timestamp. No reboot
was performed by the save task.

## Codex startup repair — completed local configuration workaround

The operator could not start `codex` or `codex resume` in the backend directory.
On 13 November, read-only inspection found the daemon processes still running
but the `/tmp/codex-daemon-1000` socket directory missing, leaving the control
symlink dangling. Why that directory disappeared was **not established**. The
old MCP cleanup log lines alone were not accepted as the root cause.

Installed CLI help reported version **0.169.0**. An isolated PTY probe with
`codex --disable daemon_auto_start resume --no-alt-screen` reached the picker.
The only saved configuration change was:

```toml
# /home/cilex-vision/.codex/config.toml, [features]
daemon_auto_start = false
```

At this save, a fresh `tomllib` read confirms that value remains false.
Configuration location at inspection: `config.toml:58`.

Private backup and receipts:

```text
/home/cilex-vision/.local/state/codex-daemon-recovery/20261113T183806Z/
  config.toml.before
  change.json
  plain-resume-verification.json
```

The actual `codex resume` PTY check in the backend directory at
2026-11-13T18:38:34Z reached the picker in 1.42 seconds without the daemon
readiness error. The probe selected no session and submitted no prompt, then
deliberately sent SIGINT (child exit -2); that exit is not a startup failure.
This restored new CLI startup by bypassing the shared daemon; it did **not**
repair/restart that daemon. Existing sessions, tokens and project files were
preserved. Do not delete `.codex` databases, sessions, locks or sockets to resume.
After reboot, verify actual behavior again; do not claim reboot acceptance from
the pre-reboot picker test. CLI also advertises `codex resume --no-daemon` as a
one-command fallback if the saved setting is later changed.

## Watchtower and analyser context that must survive

For the detailed original project history and accepted decisions, read
[the 6 November handoff](SESSION_RESTART_2026-11-06.md), especially its archive
remediation, analyser/recognition and procurement sections. This new document
supersedes only the topics explicitly updated here.

At this save the shared Watchtower checkout is on `main` at
`bc739501be9e9feeb963471e69961c96d14f9d54`, with existing dirty analyser/UI/memory
files. Saved `git status` showed modifications to CMakeLists, PROJECT_STATUS,
memory indexes, translations, EvHeroPlayer/EvTriage/Labs QML, and Labs
plugins/run_worker/worker. Preserve all of them; none belongs in this reboot
documentation commit merely because it is dirty.

Correct Watchtower fetch/push URL:
`https://github.com/cilex-software/cilex-watchtower.git`. Do not use the obsolete
`romayankin/cilex-watchtower` remote. Inspect live auth without displaying tokens.
Primary checkout and cached tracking refs do not prove current deployed code.

Recognition work remains **ChatGPT/Codex only** per the operator's 19 October
instruction. Preserve historical participant submissions and attribution, but
make no new DeepSeek/Gemini/Qwen assignments. Do not start training/inference
while saving/restoring context or treat hardware procurement as experiment
authorization. The saved canonical task plan retains partial Task03 annotation
coverage and a withheld Task04B release; verify it before any continuation.

Saved canonical task-plan snapshot (read for this handoff, no experiment rerun):
Tasks01/04A complete; Tasks02/03 partial; Task04 partial/withheld; Task04B
reviewed but **NOT ISSUED**; Tasks05–10 pending/conditional
(`docs/benchmarks/original-detector-expansion-2026-10-09/TASK_PLAN.md:28`).
The staged 04B subset is 217 frames/43 clips, 149 train/68 validation, with eleven
training clips quarantined (`TASK_PLAN.md:33`). These are saved record counts,
not newly recomputed membership. It has one validation animal observation and
two validation viewpoint components; historical replay exposed a current
validation viewpoint, so checkpoint diagnostics are not an unseen final test
(`SESSION_RESTART_2026-11-06.md:712`, `:737`).

Next recognition dependency is authoritative or dated operator-confirmed camera
adjacency covering the sealed boundary (`TASK_PLAN.md:49`, `:61`). Absence of
records does not prove separation. Then resolve grouping, preserve lineage,
recheck identities/shared validator and issue an exact-byte-bound release only
if gates pass. The next bounded annotation batch still needs its explicit
allowlist (`TASK_PLAN.md:94`). No annotation/training/scoring job started here.

Training/analysers PC is separate from the pure recording server. The latest
conversation retained Ryzen9 9950X, MSI PRO X870E-P WIFI, RTX5080 GamingPro OC,
Samsung990PRO2TB, PQ1000G, LE360V2 and CH560. The old XCOM memory sold out. Latest
recommendation was G.Skill Flare X5 F5-6000J3636F32GX2-FX5 at a **historical**
Regard 127410 RUB after Kingston KF560C36BBE2AK2-64 rose to 129990 RUB. These are
saved 11 November observations, **not current prices/stock**. No matching model
training speedup was measured, and dual rank does not establish better analyser
accuracy. Last PDF R8 still used the older XCOM memory and was not regenerated
for that subsequent recommendation:
`~/Documents/Watchtower-Regard-XCOM-2026-11-10-R8/Watchtower-Regard-XCOM-R8.ru.pdf`.
User requires Russian PDFs with purchase URLs embedded in component names.

## Standing safety and reporting rules

- Distinguish measured, reported, inferred and not measured. Code claims require
  file:line; behavior claims require commands/tests/receipts. No invented totals,
  timestamps, acceptance or current health from historical observations.
- Preserve dirty primary worktrees, source/deployed recovery overlays, archives,
  pending uploads, model/dataset evidence and tagged rollback images. No blanket
  `/tmp` cleanup: active Codex socket/runtime data also lives there.
- Backend frozen MEM-R01–MEM-R09 and STOR-CLEANUP-ENABLE-20261021 remain distinct.
  MEM-R06 is not STOR-R06. Never disable/reset cleanup protection, clear ambiguous
  ownership or make independent STOR rollout wait for future memory borrowing.
- After completed and verified task-owned work: commit, integrate main, non-force
  push, then scoped deploy/enable/verify. Unfinished purge changes are not ready
  to publish. Documentation-only context needs no runtime deployment/restart.
- Do not invent generic approval requirements. Exact destructive-plan approval,
  real admission, ownership and rollback requirements still apply.

## Resume message for the operator

Paste this after restarting Codex:

> Read docs/handoffs/SESSION_RESTART_2026-11-14.md and its linked emergency-purge
> handoff. Restore the saved context, inspect post-reboot state read-only, and
> preserve every dirty worktree. The purge means the MOST RECENT X days. It is
> unfinished and no footage deletion is approved. Resume the missing publisher
> coordination implementation and required checks without bypassing guards.
