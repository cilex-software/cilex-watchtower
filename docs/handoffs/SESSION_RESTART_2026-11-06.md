# Session restart handoff — Cilex Watchtower, 6 November 2026

This is the detailed restart record requested by the operator before restarting
this Codex session. Read this document first, then the linked canonical records.
It describes several workstreams with different completion states. Saving or
publishing this document does not complete their outstanding implementation,
release, deployment or acceptance gates.

**Time boundary:** preparation is 6 November in Europe/Moscow; the clock read
`2026-11-05 21:45:16 UTC` during writing. Git/checkout observations below were
repeated during this save. Production memory/recorder observations are dated
31 October. Recognition evidence is principally 5–10 October. No fresh camera,
archive, obstruction-detector or analyser-process health measurement was made
while saving this document. An unfinished analyser task is not evidence that a
training or inference job is currently running.

## 1. First actions after restart

1. Read `AGENTS.md`, `CLAUDE.md`, `docs/PROJECT_STATUS.md` and this handoff.
   For backend work also read its `AGENTS.md`, `CONVENTIONS.md`, exact
   operator-approved memory/storage queue in `PROJECT-STATUS.md`,
   `.agents/manifest.yaml` and the relevant handoffs. Preserve all existing
   task IDs, attribution and dependencies.
2. Check branch, HEAD, upstream, dirty files and remote URLs before changing
   anything. The primary checkout contains substantial uncommitted analyser
   work and evidence; it is deliberately not a clean release checkout.
3. For the immediate Git state, use the private checkpoint and main-update
   receipts in section 3. For archive remediation use section 4 and freshly
   reconcile the backend owner's current state. Do not replay old issued
   operator commands or assume an old process/container identity is current.
4. For original recognition, resume at **Task 04B: spatial grouping and the
   withheld development release**. Read the exact Task 04 report before
   training, scoring or selecting more footage. The next planned experiment
   has not been authorised by a ready release.
5. Keep production capture ahead of background experimentation. The last
   archive work recorded a problematic NTFS data volume; do not scan or decode
   from it merely to refresh context. Establish current storage health first.

There is no request to build, deploy, restart services, train or run inference
as part of this context-save operation. A documentation-only publication has
no runtime deployment or feature activation to perform.

## 2. Working agreement and operator preferences

- The operator expects action and completion, not repeated generic permission
  questions. Their standing 21 October direction is: verify task-owned changes,
  commit, integrate into `main`, non-force push, deploy to the intended
  environment, enable and verify. Report engineering, publication, deployment,
  enablement and operational acceptance separately. Preserve specific safety,
  access, ownership and destructive-plan gates; the standing instruction does
  not waive them. See `AGENTS.md:1` and the operator instructions in this session.
- Preserve dirty primary checkouts. Use an isolated worktree for new task-owned
  changes. Do not sweep unrelated drafts into a commit, reset/stash their work,
  force-push shared history or build an outdated shared checkout. The specific
  request to update primary `main` was completed with a backup and reviewed
  integration, described below.
- Every factual code statement needs `file:line`; measured behaviour needs a
  command/run/evidence reference. Distinguish reported, independently measured,
  expected and not measured. Missing measurements in comparison tables say
  `not measured`. Passing schema validation or unit tests is not production or
  visual acceptance. Preserve failed attempts and correct previous claims openly.
- If a letter is referenced without its full text having been read, ask for the
  full letter and say exactly what was read. Do not imply a summary is the letter.
- **Original recognition is ChatGPT/Codex only from 19 October.** Do not give new
  recognition work to DeepSeek, Gemini/Antigravity, Qwen, Kimi or another provider.
  Preserve their historical submissions and attribution. The local ChatGPT
  subagents used for read-only review are not new external-provider assignments.
  Source: `AGENTS.md:34`,
  `docs/benchmarks/original-detector-expansion-2026-10-09/TASK_PLAN.md:15`.
- Nontechnical explanations and operator reports are often requested in Russian.
  Technical implementation prompts can be English. Server-procurement PDFs must
  be clean Russian documents with company/VAT prices, not individual/discount
  prices silently substituted. Current supplier prices require new verification.
- Never print passwords/tokens, authenticated camera URLs or full container
  environments. Root authentication belongs in a secure local dialog/terminal,
  never in chat. Do not treat an unanswered password dialog as authenticated sudo.

## 3. Git, authentication and primary-checkout update — completed

### Repository migration and authentication

The canonical Watchtower remote is now:

```text
https://github.com/cilex-software/cilex-watchtower.git
```

Both `origin` fetch and explicit push URLs were corrected from the old
`romayankin` owner. `gh repo set-default cilex-software/cilex-watchtower` set
the local GitHub CLI default; `gh repo view` resolved the same repository.
No global repository override was present in the inspected environment.

The operator said the launching terminal had `GH_TOKEN`; **this Codex command
environment did not inherit it**, in both login and non-login checks. Authentication
nevertheless succeeded through the saved GitHub keyring login `romayankin`.
`gh auth status --hostname github.com` exited 0; the repository API exited 0
and reported read/push permissions. No credentials were displayed or saved in
these receipts. No token was copied out of another process/terminal.

Evidence:

```text
/home/cilex-vision/.local/state/cilex-watchtower/github-access-verification/
  20261105T205505Z-0hhceq1i/
    remote-configuration.json
    git-read-access.json
    push-dry-run.json
    summary.json
```

The first explicit dry-run
`git push --dry-run --porcelain origin HEAD:refs/heads/main` exited 1 with
`[rejected] (non-fast-forward)`: local main was behind, not an authentication
failure. The error was reported before any further push attempt. No real push
was made during that verification.

### Updating local main while preserving the analyser work

The operator then explicitly requested: **"update main to the latest version"**.
Completed in `/home/cilex-vision/projects/cilex-watchtower`:

| Observation | Before update | After update |
|---|---|---|
| Branch | measured: main | measured: main |
| HEAD | measured: `4c8fd989d67a606bfd372d4a48a56ff48787691f` | measured: `8d5ff2b636d66d0b430df76402f64765e627730e` |
| Upstream | measured: origin/main | measured: origin/main |
| Ahead / behind | measured: 0 / 20 | measured: 0 / 0 |
| Staged work | measured: none | measured: none |
| Push dry-run | measured: exit 1, non-fast-forward | measured: exit 0, up to date |

The pre-update published project version was 1.1.797 at `8d5ff2b`
(`CMakeLists.txt:4`). That is a source version, not a new measurement of the
running Ubuntu/Windows/macOS client. The normal hook may advance the source
version when this handoff is committed; use Git history/receipt for that
documentation publication rather than assuming a deployed client changed.

There were 15 dirty tracked files before updating; five overlapped incoming
changes: `AGENTS.md`, `CMakeLists.txt`, `docs/PROJECT_STATUS.md`, and EN/RU TS.
All originals, a binary patch and the index were copied before mutation.
Three-way outputs were prepared outside the checkout and independently reviewed.
Two status-document insertion conflicts retained the upstream additions plus
surrounding local text. The English translation conflict retained the local
semantic-search contexts and the new upstream AvailabilityHistory context, with
valid XML and unique context names. Both languages parsed successfully.

Only the five backed-up overlap paths were temporarily restored to their old
base bytes; native `git merge --ff-only --no-edit <pinned-target>` then updated
the checkout, and the reviewed combined local edits were restored atomically.
**No stash, reset or branch switch was used.** All ten other dirty-file hashes
and all fifteen modes matched originals; all 15,333 original untracked paths'
device/inode/mode/size/mtime metadata were unchanged. Untracked content was not
fully rehashed. `AGENTS.md` became clean because the preserved text was already
identical to upstream; the other fourteen tracked files stayed dirty.

Exact recovery package and commands:

```text
/home/cilex-vision/.local/state/cilex-watchtower/main-update/
  20261105T210821Z-zb9ghh3y/
    preparation.json
    reviewed-plan.json
    originals/                 # old dirty bytes for all 15 paths
    three-way/                 # base/local/upstream/reviewed output
    working.patch
    index.before
    untracked-metadata-before.json
    transaction-intent.json
    fast-forward-command.json
    result.json
    final-verification.json
```

`final-verification.json` records live `ls-remote` confirming `8d5ff2b`, successful
dry-run and `rev-list` 0/0. No actual push was necessary for a fast-forward to
already published commits. No application build or deployment was performed.

### Dirty work that must survive restart

Immediately before saving this handoff, main was `8d5ff2b` and these fourteen
tracked files were dirty:

```text
CMakeLists.txt
docs/PROJECT_STATUS.md
docs/agent-memory/MEMORY.md
docs/agent-memory/kimi-qwen-labs-benchmark.md
docs/agent-memory/session-recovery.md
i18n/watchtower_en.ts
i18n/watchtower_ru.ts
qml/EvHeroPlayer.qml
qml/EvTriage.qml
qml/LabsNames.qml
qml/LabsScreen.qml
tools/labs/plugins.py
tools/labs/run_worker.py
tools/labs/worker.py
```

Untracked work includes benchmark packages/reports/evidence, original-dataset
tools, Stage4 synthesis, semantic-search UI/models, semantic_objects worker and
tests. Important paths include `docs/benchmarks/`, `tools/benchmarks/`,
`tools/labs/original_dataset/`, `tools/labs/stage4_synthesis/`,
`qml/LabsSemanticSearch.qml`, `src/models/LabsSemanticSearchModel.{h,cpp}`,
`tools/labs/semantic_objects.py`, and the associated `tools/tests/` files.
Many of these files are **not in the published main tree**. A clean worktree
does not contain this whole ongoing analyser effort. Do not interpret their
absence there as loss or safely delete them as build clutter.

A separate private checkpoint was made for this save, with current working/staged
patches, index, dirty-file hashes, all untracked path names and copies of key
analyser text reports:

```text
/home/cilex-vision/.local/state/cilex-watchtower/session-restart/
  2026-11-06-ngvgq1_u/
    snapshot.json
    working-tree.patch
    staged.patch
    index.before
    untracked-paths.json
    context-source-copies/
```

This protects restart context locally; it is not a complete backup of ignored
weights, videos, extracted images or untracked bulk data. Original sources and
the designated data archives remain authoritative. Do not publish this entire
dirty tree just because the operator asked to save context.

## 4. Archive publication lag and truthful recording-health work

### Original problem and evidence limits

The operator reported street-camera warnings `Recording stalled` / `NOT REC 56`
while live video was visible. The original 27 October investigation measured
56 catalogue-stale online cameras at its observation time. Files grew for the
tested main/sub streams of .102 and .105, but this did not establish health of
all affected cameras, decoded freshness, fsync durability or continuous coverage.
The historic UI's "since" used the last catalogue fragment time, not proven
failure onset. The original limiting stage was not isolated by that first audit.

Historical incident evidence, **do not reread the problematic volume just to
restore context**:

```text
/media/cilex-vision/86761555761546F9/CilexLab/
  recording-stalled-review-20261027-1613-v1/
    DIAGNOSIS.ru.txt
    root-evidence/summary.json
    recorder-current/FINDINGS.txt
  recording-stalled-remediation-planning-20261028/published-context/
  archive-lag-remediation-20261028/
```

The broader assignment is `REC-ARCHIVE-20261028`: repair the demonstrated
publication bottleneck AND report independent connectivity/capture/archive/
unknown dimensions, publish, deploy, enable and verify usable current and delayed
recordings. Tests, advancing newest timestamps or a warning-label change alone
do not complete it.

### Implemented/published client and backend work

- Watchtower capture/archive health implementation is published in
  `cddf4ab296722f5b422f7610805cef662691ba09` and is contained by `8d5ff2b`.
  Read `docs/verification/2026-10-28-recording-health/README.md:1` for the exact
  source references, Linux fixture commands and limits.
- The API contract separates capture progress from catalogue freshness;
  stale/missing telemetry becomes unknown. Main/sub requirements aggregate
  conservatively. The UI distinguishes stopped capture, archive delay and
  unverified status; it does not invent a failure onset from a catalogue time.
  Sources: `src/models/RecordingHealth.h:21`,
  `src/models/CameraModel.cpp:896`, `qml/RecordingStatusBadge.qml:28` and `:54`.
- Historical client verification recorded 18 contract checks, 24 Groups checks,
  31 EN and 31 RU shipping-shell checks, 16 obstruction checks and a Linux Qt6.8.3
  Release build. These are saved fixture/build results, not new runs during this
  save or evidence of native guard-station deployment. The before fixture really
  reproduced one catalogue-only stalled camera incorrectly counted as a capture
  stop; after it was one archive warning plus unverified capture, zero confirmed
  stops. Evidence is indexed in the same README:57.
- Backend retry identity, recorder progress instrumentation, source expiry and
  publication observations were implemented/published. The saved backend handoff
  reports the health API deployed, while the new recorder profile/telemetry
  rollout remained incomplete; do not equate API deployment with recorder
  enablement. Backend source references and actual audit boundaries are in
  `.agents/handoff/REC-ARCHIVE-20261028.md:9` and `:148` in the backend worktrees.
- The fresh-vs-history scheduling repair is published in backend commit
  `3c532050b6d90d7d3329d93d7a17b7bd063a7b04` (1.0.288). It advances a moving
  current-publication frontier and keeps bounded historical service. Earlier
  baseline regression failures and subsequent checks are preserved in
  `~/.cache/cilex-vision/current-frontier-*` and
  `~/.local/share/cilex-vision/archive-remediation-state/`.
  The historical source map was main.py
  `914f4359b7e2e388011d3afbaa569564419a8ed02a03f332205e171f470a4645`,
  segment_schedule.py
  `7688283c87d557609b40141615f20d1fc047d1aec3efd1a504fa33d543eee458`.
  These are old build pins, not permission to launch an old capsule now.

The source-level failure reproduced by the later audit was a fixed startup
cutoff: a worker classified footage as "current" against a boundary calculated
once, then repeatedly selected the oldest prefix above it while new footage
kept arriving. The moving frontier repairs that demonstrated starvation mode.
This does **not** isolate every physical production bottleneck or prove full
backlog drain capacity; directory enumeration still scales with directory size.
See backend archive handoff:1946, :1972 and :2022. Its saved final affected suite
had133passes and scoped checks, while full configured Ruff still exited1 with
baseline findings; do not call the whole lint run clean.

**Correct explanation of "Архив недоступен · запись не проверена":** no catalogue
segment was confirmed in the checked window, and fresh capture confirmation is
missing. It does not prove all historical footage is lost or that capture has
definitely stopped. `qml/RecordingStatusBadge.qml:28` preserves that uncertainty.
The operator has explicitly been told the complete archive problem is not yet
verified fixed. Do not reverse that statement just because memory was raised.

### Confirmed memory increase — completed runtime action, 31 October

The operator requested: **"Add memory to the container that OOMed"**.
Kernel evidence attributed the historical OOM to the original recorder b500 at
30 October 14:46:29 UTC /17:46 Moscow with a 5GiB limit. Its safe active replacement
was the held recorder d362. The live action targeted that replacement, not the
stopped forensic predecessor.

Published backend source:

- `ea3241a3cc0dca25eec3985966b33a48ad6d4782`, 1.0.294: only recorder Compose
  `mem_limit`/`memswap_limit` 5g→6g; reservation2g retained.
- `a904c97d567661ff13beab8e3dea6da7466bc9df`, 1.0.297: final verified runtime
  result/status. Both were confirmed on published backend main at the time.
  Later backend remote/runtime state was not re-fetched for this save.

At **31 October 04:17:21 UTC**, one guarded Docker update exited0 and raised
Memory/MemorySwap to6442450944 bytes. Kernel memory.max agreed; swap.max stayed0
(no additional cgroup swap), reservation2147483648 remained. Same PID2135834,
StartedAt01:29:12.679951464Z, restart count0 and cgroup inode2424811 before/after.
Only the two memory fields changed; full spec and observed mounts were checked.
Independent readbacks at04:17:55 and04:28:10 UTC showed6GiB/healthy with unchanged
epoch/restarts and OOM counters0. These are **dated short-window observations**,
not a current reading, representative workload acceptance or a guarantee against
future OOMs. No recorder restart occurred for the memory increase.

Evidence root, on rootfs:

```text
/home/cilex-vision/.local/share/cilex-vision/archive-remediation-state/
  oom-memory-increase-20261031-v1/
    baseline.json
    recorder-oom-kernel.json
    raise_memory.py                 # historical one-shot; DO NOT execute again
    action-plan.v4.json
    update-intent.json
    update-result.json
    independent-readback.json
    short-followup.json
    final-publication-readback.json
```

Useful receipt hashes:

| File | Saved SHA-256 |
|---|---|
| update-result.json | `9636489ebf6721675ef0dc36a75e2d111a30c96bebe5ccc650f9ac06e67ddc98` |
| independent-readback.json | `0665b2696804740b58fdf931bf9d858eb4e0001699acd1d217f94c8ac3af2165` |
| raise_memory.py | `69e3841dca9bc6470582427da2dd9487cca996aa70a62f9e36d9a7cbb0914e4c` |
| action-plan.v4.json | `7dca4a14a83dcedba28187bac1763b6ef8dadb5b9c8f35642376acc0d978d5c3` |

The immutable scope is backend
`.agents/prompts/REC-ARCHIVE-20261028-RECORDER-MEMORY-6G.md`, hash
`b0c10cca3c793b7c1d98245df4bc7113dac016bd0b3278c0cf09209cb762747c`.
Detailed source-bound result:
`/home/cilex-vision/projects/cilex-vision-recorder-memory-20261031/.agents/handoff/REC-ARCHIVE-20261028-RECORDER-MEMORY-6G.md:1`.

The guard was respected: initial preflight refused while compaction owned its
lock. The task waited; it did not kill/clear/bypass compaction. That maintenance
closed naturally at04:14:39 UTC with `deadline_missed`,8operations,0errors, which
is partial maintenance, not full storage recovery. The eventual action freshly
passed the existing admission model (2GiB reserve+1GiB increase+512MiB margin,
plus pressure checks), persisted intent and made one finite update. No memory
borrowing controller, forced shrink, cleanup reset or expired-job renewal occurred.
This contributes to MEM-R03/MEM-R04 without completing them.

### Last-known runtime and safety/ownership — recheck before using

The following identities were observed on31October, **not checked live on6November**:

```text
Active held replacement:
 CID d362f11b0ce8bb9669b7d6b06c378688165018246baf4012660c7adf9c536312
 name recorder-held-emergency-3849a2c9b6394adb8ce3efc2505b430b
 image sha256:57aa99c5f6d430fcc0286321bea298dc8381bcfcd18c904e8059c68c61266fc0
 full-spec hash after6GiB:
 a509fb419732d558f78c850b6f6d7c4388526eedf5671e83aa76166631d2c7f0

Stopped forensic original, do not restart:
 b5004f0c72dc483bffe87c7ab8d44acb643eccd4fa857cdba4d8568084404f41

Prepared new recorder image, never-started at last reconciliation:
 sha256:f0e66770e20e362c3e98846dac198294d55c1e9c5bfc4d10cb02d856c867ce09
```

Earlier held-recorder restoration did start the replacement, but its helper
exited1afterSTART and produced no004success receipt. Independent read-only
reconciliation did not erase that failure. Rotation-aware samples later showed
positive output on112/112fixed lanes, not continuous or playable archive proof.
The measured container interruption remains disclosed in backend archive
handoff:2260; its timestamps are not exact per-camera recording-gap lengths.

The backend Codex thread `01a0fd02-d0f4-7961-93b7-1e5f9f692d70`
(`cilex-vision-main`) owns ROOT, boot overrides, guarded V18 rollout and all other
runtime controls. This session owns the completed memory-only action and its
records. Do not run a second overlapping rollout or cap change. Read the backend
owner's latest messages/artifacts first; its state may have changed since this
handoff's historical observation boundary.

Historical relevant worktrees:

```text
/home/cilex-vision/projects/cilex-vision                  # dirty/shared, preserve
/home/cilex-vision/projects/cilex-vision-archive-goal-20261030
/home/cilex-vision/projects/cilex-vision-archive-current-priority-20261031
/home/cilex-vision/projects/cilex-vision-archive-publish-20261031
/home/cilex-vision/projects/cilex-vision-recorder-memory-20261031
/home/cilex-vision/projects/cilex-watchtower-archive-health-20261028
```

V18's design preserves the exact held original for rollback and keeps watchdog
ownership inhibited until the guarded closure. Old V17/other issued attempts
remain forensic evidence, not resumable jobs. No second writer, old raw-image
startup, rename/delete/commit of held originals, arbitrary watchdog CAS, renewed
old lease or cleared ambiguous ownership is allowed. Existing admission rules
and full source/config/mount/cgroup identities must be reconciled freshly.

V18's ROOT entry, loader and bridge are **implemented**, superseding older
statements that the privileged entry code was still missing. The saved component
publication is `7993cce2e8f8765c84b74b325caddea3c2d06d74`,1.0.292, and bridge
publication is `620505f26b2585fc4289706532cfc8742117bfc6`,1.0.295. Separate
component cohorts passed; they are not one complete privileged production
acceptance result. Read backend archive handoff:2390 and :2436 and manifest:121
before reconciling new capsules. Later remote/runtime state was not reverified.

At last check, private boot override access was denied to UID1000; secure ROOT
authentication had not been verified. The source default and live container were
6GiB, but the effective systemd/Compose boot chain was **not verified/promoted**.
Do not claim persistence through a future Compose recreation or host boot from
the Docker update alone. Do not bypass ROOT by mounting host files into a
privileged container. The backend owner retains this task.

The observer contribution was implemented and passed46isolated checks in the
last saved R6 run, plus lint/seal checks. Its final historical file hashes were
`2616624235361f162d8379b07ade160a391b13e97a703776a73ea4861ad8bde2`
for `tools/storage/recorder_preserved_observer.py` and
`b635b581bdebe2d8d61074ee7635c449ba8e4b850bb4aee49069dd735f9fc823`
for its test. These were contributed to the backend owner's worktree; their
later publication status was not re-audited during this save. It is a read-only
metadata observer with bound source/permit/scope, not a proof of decoded-media
coverage, effective cgroup OOM telemetry or full ROOT lifecycle safety. A fake-
clock hour is not an actual hour of production acceptance. Preserve all failed
observer fixture generations and the separate structured JSON approval versus
Markdown scope/admission hashes.

### Still pending for archive remediation

1. Fresh owner-controlled reconciliation after the memory change: actual running
   source/images/config, caps/cgroups, recording roots, pending media and guards.
2. ROOT boot-chain readback/promotion so future recreation will not revert the cap
   or start an unsafe older implementation. Rebuild any unissued capsule against
   fresh6GiB/current source; never rewrite an issued capsule.
3. Authenticated protected-predecessor receipts, private policy/capsule sealing
   and a complete isolated ROOT/USER/supervision fixture must pass before the
   production canary. Separate component/unit results do not establish this gate.
4. Safe enabling of the new scheduling/telemetry profile under V18's current
   ownership, rollback and admission checks. Earlier prepared/passing source
   fixtures do not establish that the new profile is running.
5. Fixed-cohort operational proof: capture, publication queue age/rates, current
   and delayed media retrieval and actual playback, coverage holes/recovery,
   resource/OOM/restart deltas. Keep segment capture/upload/catalogue/playback
   times distinct. Preserve current120second policy, not a relaxed pass threshold.
6. A representative real observation window (proposed minimum60minutes), including
   normal live viewing, archive playback, export and stated background workload.
   Metadata collection alone cannot claim complete recording recovery.
7. Native guard-station client rollout/verification, with real UI/video/export.
   Linux offscreen checks cannot establish Windows deployment or playback.

The operator said to provide instructions for the existing Codex CLI on
**WT-SM-VNUTRI-01**, rather than ask again for an IP/password. Prepared private
handoff: `~/.local/share/cilex-vision/archive-remediation-state/WINDOWS_CODEX_HANDOFF-8d5ff2b.md`
(older `-c3fab3e` and `-5a3d60b` versions are historical). Use the verified local
Windows deployment workflow, fresh source pins and rollback; preserve the saved
guard view, Warden and Labs startup. Do not assume rolling GitHub Windows assets
are current. This session has not verified the final native deployment.

**Queue discipline:** preserve MEM-R01–MEM-R09 and
STOR-CLEANUP-ENABLE-20261021 exactly. MEM-R06 is not STOR-R06. Do not make the
independent storage rollout wait for future memory sharing, silently complete
the queue, reset the cleanup guard or execute an unreviewed destructive plan.

## 5. Analyser and original-recognition work — detailed resume map

### Purpose, ownership and critical instruction distinctions

The operator wants useful original recognition of humans, cars and animals,
then apparent size, colour and colour location, evaluated inside Watchtower's
Labs/Findings/Playback workflow. False positives, misses and alignment matter;
falling training loss or helper tests do not demonstrate improvement.

Historical Stage3/Stage4 participant assignments remain evidence only. All new
original-recognition preparation, annotation/review, implementation, training,
scoring and adoption belong to ChatGPT. Stage3's earlier wait-for-four gate was
explicitly superseded; do not wait for Kimi to resume. Old Stage4 pretrained-B
instructions are historical; **the current original-expansion plan prohibits
YOLO, torchvision, third-party pretrained weights/detectors and new external
labelling APIs**. Generic PyTorch/NumPy/OpenCV/ONNX Runtime are allowed under the
current task. Read the exact active protocol rather than combining incompatible
old prompts. Sources: original TASK_PLAN:15 and :140; Stage3 coordinator:315;
Stage4 START_HERE:13 documents the older rule, not current permission.

### Stage1/2 tracking comparison — historical, no adoption decision

The saved5October comparison records assessed points Kimi95/95,
DeepSeek95/95, Gemini92.75/95, Qwen89.58/95; five controlled-resource points were
deferred, not zeros. Kimi's then-submitted revision lacked Stage2. Integrated
submissions failed independently reproduced evidence/recording identity cases;
there was no adoption winner or deployment. These are historical assessed scores,
not current measurements or a basis for claiming a statistically strong ranking.
Read `docs/benchmarks/labs-tracking/evaluation-2026-10-05/RESULTS.md` and
`docs/agent-memory/kimi-qwen-labs-benchmark.md` for evaluator corrections, exposure
disclosure and quota/spending observation limits. Do not convert account-wide
quota/token counters into task-exclusive cost or elapsed work time.

### Stage3 semantic comparison and local integration — done locally, not activated

Canonical report:
`docs/benchmarks/labs-detection-stage3/evaluation/COMPARISON.md` and `.html`.
Coordinator provenance:
`docs/agent-memory/labs-detection-stage3-coordinator.md:363`.
Implementation/acceptance evidence:
`docs/verification/2026-10-06-semantic-production/README.md`.

The6October record says Qwen/Gemini/DeepSeek each completed20native and20common-
frame new-clip runs plus8original common-frame runs. Kimi remains ungraded.
Qwen had a narrow descriptive F1 lead, not a universal win. The optional combined
implementation was evaluated on28public development clips; it did not win every
metric and colour remained weak.

Local source integration includes an optional `semantic_objects` worker,
source-bound PostgreSQL ingestion in the sibling backend, typed same-object
search, default-off optional NLP, and Labs Search footage with authenticated
crops/playback. The historical isolated H016 ingestion check recorded29rows and
29crops and successful main search/playback. No production activation, live
findings writes or publication was claimed by that checkpoint. Current dirty/
untracked paths in section3 preserve this work; a clean published checkout does
not prove it has been integrated or enabled.

Unsupported/weak outcomes to preserve: reliable clothing/coat colour, complex
gender/garment/action/relation queries, scooter/sedan specificity. Do not turn
detector attributes or unobserved motion into confident labels. The received
DeepSeek current files later differed in5paths from its frozen receipt; the51
saved run manifests matched the preserved version. The comparison grades that
preserved version, not unknown later edits. Qwen/Gemini matched their receipts.
Source: Stage3 coordinator:369.

Useful local implementation paths to audit before any future scoped publication:

```text
tools/labs/semantic_objects.py
tools/labs/plugins.py
tools/labs/worker.py
tools/labs/run_worker.py
qml/LabsSemanticSearch.qml
src/models/LabsSemanticSearchModel.h
src/models/LabsSemanticSearchModel.cpp
qml/LabsScreen.qml
qml/LabsNames.qml
qml/EvTriage.qml
qml/EvHeroPlayer.qml
docs/reference/labs-semantic-worker.md
tools/tests/labs-semantic-objects.py
tools/tests/labs-semantic-search.qmlbody
tools/tests/labs-semantic-playback.qmlbody
```

Backend counterparts must be reconciled from their current dirty/published and
deployed state separately. No new live analyser registration is implied by this
handoff. The directory `~/.local/share/watchtower-stage3-coordinator/` preserves
coordinator receipts, frozen submissions and annotation/evaluation material.

### Stage4 compact detection and synthesis — evaluated, no adoptable detector

Read:

```text
docs/benchmarks/labs-detection-stage4/README.md
docs/benchmarks/labs-detection-stage4/EVALUATION.md
docs/benchmarks/labs-detection-stage4/evaluation/intake/
docs/benchmarks/labs-detection-stage4/synthesis-2026-10-09/
  Cilex-Watchtower-Stage4-Final-and-Synthesis-2026-10-09.ru.md
  Cilex-Watchtower-Stage4-Final-and-Synthesis-2026-10-09.ru.pdf
  Cilex-Watchtower-Stage4-Final-and-Synthesis-2026-10-09.ru.xlsx
```

Saved common90 diagnostics report GeminiB47TP/692FP, DeepSeekB3TP/36FP,
CilexF0TP/91FP and CilexS10TP/184FP. These are the report's historical common-frame
counts, not new runs, not one interchangeable performance score and not a blind
test. Read the denominators/matching definitions and evidence at synthesis:187.
The report recommends retaining defensible engineering components while
withholding detector adoption; original public common90 material is development,
not unseen-camera acceptance (synthesis:304 and :376).

R1 bounded resource runs used different clips/native schedules. The saved report
records DeepSeek A/B206.24/213.69MiB and Gemini A/B592.39/818.52MiB process-tree
peaks. These are different-run diagnostics, not a fair speed ratio or fleet
capacity measurement. Earlier geometry bugs, stale default selections and
provenance issues remain disclosed in the intake reports. The CPU analyser
target in the historical Stage4 contract was512MiB, maximum1GiB including decode;
training resources were separate. No new model evaluation was run for this save.

The original own-weight400-update pilot and fixed tiling failed to establish
useful improvement. Preserve the negative result, not just training-loss plots.
See `docs/benchmarks/original-detector-expansion-2026-10-09/RECOGNITION_PROGRESS_2026-10-10.md`.

### Original-detector expansion — current canonical task table

Canonical plan:
`docs/benchmarks/original-detector-expansion-2026-10-09/TASK_PLAN.md:24`.
Statuses below are **read from saved records**, not freshly rerun experiments.

| ID | Work | Saved outcome / remaining dependency |
|---|---|---|
|01|Acquire/verify first200clips|Complete; recorded200source hashes checked.|
|02|Enrich car/dog/small-person/difficult-background candidates|Partial acceptance; inventory useful as hints, semantic triage defects remain.|
|03|Annotate/review selected frames|First24frame canary accepted; broader coverage still partial.|
|04|Grouping and development release|Partial; release withheld at sealed spatial boundary.|
|04A|Package/identity/lineage|Complete and coordinator-audited,260frames54clips.|
|04B|Adjudicate grouping and issue exact-byte release|Review performed; staged217frames43clips,149train68validation; NOT ISSUED.|
|05|Freeze recipe/run unchanged baseline|Pending, requires issued04B release; distinguish historical exposure.|
|06|Balanced training, architecture unchanged|Pending, requires05.|
|07|Higher-resolution small-object crops|Pending, requires05 and comparable budgets.|
|08|Independent scoring/error review|Pending, requires06–07.|
|09|Combine demonstrated gains; justified architecture trials|Conditional on08.|
|10|Before/after report/adoption decision|Pending.|

#### Task03: accepted canary contribution and exact deduplication

`TASK03_COORDINATOR_REVIEW.md:3` records all24source frames and corrected overlays
viewed,13training/11validation;18corrected and6unchanged against the Gemini
draft.36object observations:19human,10car,7animal. Three empty negatives were
confirmed;3scoped ignore regions and19unknown colour regions remain explicit.
Added2omitted objects; removed0; changed25existing boxes and one existing flag
of each kind. Counts refer to repeated frame observations, not distinct people.
The labels are AI-assisted and fallible, not human-verified ground truth.

Accepted data-volume contribution:

```text
/media/cilex-vision/86761555761546F9/CilexLab/
  original-detector-expansion-20261009/task03-coordinator-review-v1/
    references-coordinator-adjudicated-v1.jsonl
    review-notes-coordinator.jsonl
    adjudication.jsonl
    review-ledger.jsonl
    unresolved-work.jsonl
    integrity/final-audit.json
```

It adds15new stable identities and replaces9previously reviewed identities:
245prior+24contribution−9replacement=260unique frames across54clips,
provisionally192train/68validation. **Never add all24to245 and report269.**
Task04A's combined object totals are161human/34car/19animal observations, with
only1validation animal. Its lineage236retained/15added/9superseded is preserved.

Difficult-case decisions retained in the report: CE-000010's left-edge human is
positive, not empty; CE-000045's green dog covering is not natural coat colour;
CE-000065 is a truncated car with visible-extent box; CE-000066's night clothing
colours remain unknown; CE-000144 is the only validation animal observation.
Some prior triage assertions were wrong even though the existing reference was
already correct. Do not confuse triage-vs-reference revisions with new labels.

A further bounded24-frame annotation batch belongs to ChatGPT after an explicit
allowlist is issued; it has **not started** by this ownership change. Prioritise
additional animal/camera coverage, independent car scenes, small humans and
training empty scenes. Use source-first rendered pixels and native crops;
support colour labels with owner-owned source pixels and documented median RGB.
Validation/schema success is not pixel review. Do not rerun completed Task03
reviews without a concrete reason or scale to the full queue automatically.

#### Task04B: decisions made, release withheld

Canonical report `TASK04_COORDINATOR_RELEASE.md:3` and plan:49 state no ready
declaration was issued. Candidate directory:

```text
/media/cilex-vision/86761555761546F9/CilexLab/
  original-detector-expansion-20261009/task04b-coordinator-release-v1/
```

Historical DeepSeek04A package:
`.../task04a-deepseek-release-candidate-v1/`; originals/submissions are immutable.
The coordinator accepted conservative hint vocabulary normalization in a new
manifest, preserving old qualifications in a sidecar. The independently compared
candidate manifest had38affected candidate rows; do not conflate that denominator
with the submission's wider160row inventory/144hint-status claim.

Administrative `camera_group`/`inventory_group_id` UUIDs were not automatically
equated with leakage `camera_group_id`; broad categories such as street/site
do not prove identical viewpoints. Development image review created conservative
view/adjacency groups and quarantined11training clips43frames on7cameras, with
no split transfer and no accepted-annotation rewrite. Excluded IDs:

```text
CE-000003 CE-000007 CE-000020 CE-000022 CE-000030 CE-000031
CE-000045 CE-000055 CE-000082 CE-000215 CE-000218
```

The staged subset has43clips/217frames:30train clips149frames,13validation
clips68frames;17train cameras/5validation cameras;7train viewpoint groups and
2validation groups. Staged observations:108train/32validation humans,
21/8cars,14/1animals. One animal observation and only2validation viewpoint
components are serious limits on any generalisation claim. These exclusions
change proposed release membership, not the accepted260frame annotation archive.
Source: Task04 report:17–41 and its saved coverage command/evidence.

The metadata-only sealed check recorded no direct source/camera/event/same-camera
interval overlap, but there was no authoritative placement/topology evidence for
sealed viewpoints. **No known edge is not proof of no overlap.** Sealed pixels,
labels/predictions/video were not opened. Keep sealed identities/paths/mappings
private; shared handoffs contain sanitized conclusions only.

Shared CLI validation was valid/integrity-verified, yet release_verified and
ready_for_training remained false. Candidate hashes recorded by the report:

```text
manifest 1042c3507146ea405f945f1de224988097bb2c8db126d423d3c6a6b43645a325
labels   0787a9161ed924ece4051d2fa3777c79120cabb3fc3798dc90913835f9cf988e
```

These bind staged bytes, not a ready release. An older immutable pilot release
exists and was preserved; do not mistake that for approval of this new candidate.

Historical replay exposed the viewpoint of one current validation camera; a
different day does not make it unseen. Some current validation frames were used
for pilot evaluation/diagnostics. Task05 must freeze scratch-only versus
warm-start/replay boundaries and call old-checkpoint validation a development
diagnostic where appropriate. Source: Task04 report:43–47; do not invent a clean
final-test claim.

**Exact next input:** authoritative viewpoint/adjacency metadata or dated,
attributable operator-confirmed topology covering the sealed boundary and
possible development neighbours. Distinguish overlap/shared-event paths,
non-overlap and unknown. Keep the exact sealed camera list private. User offered
help with street-camera topology; a live-tab stream-identity bug interrupted
that process. The screenshots alone do not certify all camera relationships.

Once the input exists: adjudicate connected groups, change membership explicitly
if necessary, preserve annotation bytes/lineage, rerun identity and shared
validation, then issue a new exact-byte-bound coordinator development release
only when its gates pass. Do not invent timestamps or mark provisional rows
released. No new training or inference is permitted from this withheld04B
candidate. More generic tooling tests cannot resolve missing spatial evidence.

#### Recognition job and data protection rules

- Preserve all participant originals, submitted checkpoints, prior releases,
  failed experiments, extraction receipts and annotation provenance.
- No sealed pixels, predictions or labels for model selection. Coordinator-only
  minimum metadata is distinct from sealed visual access. Do not distribute
  private sealed mappings to implementation participants or shared reports.
- One bounded heavy decode/train job at a time under
  `~/.local/share/watchtower-original-expansion-20261009/heavy-job.lock`,
  `nice -n 10`, CPU affinity0,2 and two computation threads per active protocol.
  Recording gets priority; no blind parallel training or mass exports.
- Bulk images/data belong on the designated data volume when it is healthy;
  current save does not certify its health. Do not decode to refresh context.
- Existing acquisition receipts establish recorded extraction identity; do not
  claim independent video-to-frame correspondence without actually decoding
  and checking it. No invented historical viewing timestamps.
- Freeze recipe, data membership and evaluation before experiment comparisons.
  Measure per-class precision/recall, small objects, empty-scene false alarms,
  coverage and resources. No recognition improvement is established by current
  annotation/release preparation or helper tests.

## 6. Other product work retained from this session

### Camera obstruction/tamper pilot

The urgent incident was paper covering **4.1.6 Холл /192.168.1.109** while the
camera still appeared online. Operator supplied2blocking-activity clips and a
paper-obstructed clip under `~/Videos/Watchtower/`. This is image-visibility
monitoring, separate from the original human/car/animal training programme.

Historical12October pilot: continuously running backend monitor for this one
camera, reviewed clear reference and protected previous clear views, sustained
scene deterioration checks. Watchtower central alert links to live camera review;
false alarm gives6hour snooze, confirmed incident acknowledgement, and after
3distinct consecutive false incidents an explicit7day suppression with
confirmation. False-alarm reporting uses the existing crash-report ingestion
channel and a labelled30second1fps decision-frame proxy, not an unqualified
full-frame-rate incident clip. The operator chose designated security/admin
recipients, but asked to defer mobile notification testing until the detector
works reliably. **Mobile push is not implemented/verified by these results.**

Canonical evidence:

```text
docs/verification/2026-10-12-camera-obstruction/README.md
docs/verification/2026-10-13-camera-obstruction-preview/README.md
docs/verification/2026-10-13-camera-obstruction-design/README.md
tools/preview-camera-obstruction.sh
```

The design was revised to a compact graphite review strip consistent with the
product, restrained alert edge and themed accessible controls. Historical replay
of the supplied paper clip triggered at6.04seconds, not measured end-to-end
physical-cover-to-native-warning latency. Isolated ingestion, regression and
clear-scene checks passed at their dated checkpoints. Real cover/recovery/UI
drill, long-duration false-alarm rate and wider-camera acceptance remain open.
The pilot's current running state was not queried during this save.

Some early memory entries still say "no commit/push" or "reopen1.1.773"; these
describe the implementation checkpoint. The operator later authorised publication
and backend redeployment; read the dated deploy/README records rather than
treating those old lines as the current permission or installed version.

### Live-tab stream identity, availability and platform deployment

The operator's reproduced Live bug showed earlier camera tabs and wall cells
displaying the most recently opened camera's stream. The preserved fix evidence
is `docs/verification/2026-10-11-live-stream-identity/`; do not confuse stream
identity with the separate recording/archive health dimensions. No new native
retest of that bug was performed for this context save.

Camera-availability persistence/sync was separately developed/published; read
`docs/features/camera-availability.md`,
`docs/reference/camera-availability-v1.md` and
`docs/verification/2026-10-29-camera-availability/README.md`. Published status
records real Booth uploads/retries and later Office updater fixes, but current
station health and native archive-remediation acceptance are not established by
those older runs. Do not overwrite native setup/startup/rollback ownership.

The published main now contains Windows build/update tooling, Office lessons,
macOS installer work, sparse independent live-camera views and health/availability
changes that were absent from the old primary4c8checkout. Being on latest source
does not mean it has been built or installed on each machine. Homebrew uses
`qtmultimedia`, not `qt-multimedia`; Mac build instructions were corrected earlier.
Use the actual platform's current deployment docs and preserve settings/Warden.

## 7. Storage, hardware and procurement context

### Existing host / disks and OOM caution

The user supplied29October SMART output for two Seagate Exos22TB disks:

```text
model ST22000NM001E-3HM103
/dev/sda serial ZX26SFM3, WWN 0x5000c500e8f75e69
/dev/sdb serial ZX26R3CE, WWN 0x5000c500e8f70691
system NVMe Samsung SSD980500GB, serial S78GNL0X819488P
```

Both reported SMART PASSED and zero reallocated/pending/offline-uncorrectable/CRC
sector counts at that time; this is user-supplied historical output, **not proof
of present filesystem/I/O health or absence of latency/command timeouts**.
Do not interpret Seagate raw read/seek counters as ordinary error counts without
vendor-aware interpretation. No new SMART/benchmark scan was run for this save.

The late archive work recorded NTFS kernel BUG/D-state problems on the bulk data
volume. Keep new small evidence and helper files on rootfs EXT4 until a fresh
bounded health reconciliation authorises otherwise. Do not unmount/fsck/reboot,
kill unrelated tasks or scan the whole data volume under this context-save task.
The earlier instruction "save cleanup logs to data disk" must be reconciled with
this later failure boundary, not followed blindly.

### Saved root cleanup procedure

`docs/agent-memory/MEMORY.md:17` preserves the12October exact cleanup audit:
pip/npm download caches and106audited generated Qt PCH files; net root recovery
40.50GiB at that observation. Docker dangling-image prune reclaimed0B and aged
unused build-cache prune reported5.138MB; tagged rollback images were preserved.
These are historical quantities, not expected future savings.

For another low-space incident inspect bounded current usage first. Consider only
actual disposable caches/audited generated PCH under exact guards. No blanket
`/tmp`, `.cache`, build-tree, model/evidence/recording, volume, container or
`docker image prune -a` cleanup. Do not delete checkpoints or recovery artifacts
because they appear untracked or unused. Preserve active tools, runtimes and
rollback images. Cleanup admission and explicit destructive-plan requirements
remain in force.

### Procurement / PDFs — historical, prices not current

The session also researched an experiment/training workstation, later a distinct
120camera Cilex Vision recording server. The operator explicitly separates these:
the latter is not for model training. For the recording-server proposal they
rejected RAID and an expensive Micron enterprise SSD, limited storage to at most
two HDDs comparable to the present host, and wanted UPS marked optional.
Reports require separate Regard/Citilink/DNS tables with company/VAT prices;
DNS/Citilink screenshots supplied by the operator were evidence when sites blocked
access. Do not reuse old prices as today's quote or infer company price from a
retail/club price.

Experiment-build history included Ryzen9950X,64GB DDR5,RTX5080GamingPro16GB,
Samsung990PRO2TB,DeepCoolCH560 andLE360V2; MSI board/RAM choices changed through
later variants. The operator also has an RTX A2000 and requested a simple visual
comparison to the5080. Exact final component choices and compatibility decisions
must be taken from the corresponding saved PDF/source, not this abbreviated
history. GPU A/OC/V1 part numbers were intentionally distinguished.

Existing document directories observed locally during this save:

```text
~/Documents/Watchtower-Server-Comparison-R2.ru.pdf
~/Documents/Watchtower-Server-Final-2026-10-13/
~/Documents/Watchtower-Server-Final-2026-10-13-RAM-R2/
~/Documents/Watchtower-Server-Company-2026-10-20-R2/
~/Documents/Watchtower-Server-Company-v2-2026-10-23/
~/Documents/Watchtower-GPU-A2000-vs-RTX5080-2026-10-23/
~/Documents/Watchtower-Server-Citilink-DNS-2026-10-23/
~/Documents/Watchtower-Server-Replacements-B2B-2026-10-24/
~/Documents/Watchtower-Three-Retailers-2026-10-24-R3/
~/Documents/Watchtower-CH560-LE360V2-Fit-2026-10-26/
```

Only directory/file presence was checked for this save, not PDF content, latest
prices or present stock. The context also contains user requests about32GB RAM
replacement and exact existing DIMM models; no fresh DIMM identification is
claimed by this handoff. Reinspect actual hardware before recommending parts.

## 8. Publication and what this save does not claim

This save uses isolated worktree
`/home/cilex-vision/projects/cilex-watchtower-session-save-20261106`, initially
`8d5ff2b`, branch `codex/session-restart-20261106`. It publishes only this
restart document and a pointer in the existing memory-directory README, plus
normal hook-owned version metadata. It must not stage the primary's fourteen
dirty analyser files or15,333untracked files. Publication receipt, final remote
SHA and preservation checks are saved separately in
`~/.local/state/cilex-watchtower/session-restart/2026-11-06-ngvgq1_u/`.

The final publication commit cannot be embedded in its own content. Find it with:

```bash
git log -1 --format='%H %s' -- docs/handoffs/SESSION_RESTART_2026-11-06.md
git remote get-url origin
git remote get-url --push origin
git status --short --branch
```

The private checkpoint is local state, not a substitute for published Git history
or a complete recording/model backup. A new session should read the published
handoff AND the preserved dirty local analyser records; older memory has stale
statuses and must be interpreted chronologically.

**Completed by this session:** migrated/verified Watchtower origin/default/auth,
updated primary main while preserving dirty work, previously published archive-
health/scheduling and6GiB memory changes, applied and verified the dated live
memory increase, and saved this detailed context.

**Not complete:** end-to-end archive recovery and native acceptance, boot-chain
6GiB persistence verification, original-detector04Brelease, further bounded
annotation, new controlled training/scoring/adoption, production semantic-analyser
activation, real obstruction-to-native-alert accuracy/drill and mobile push.
Do not claim that any of these became complete by restarting, publishing docs,
passing helpers or merely being on latest main.
