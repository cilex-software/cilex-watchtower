---
name: session-recovery
description: START HERE after a context reset — full state of Cilex Watchtower and how to resume
metadata: 
  node_type: memory
  type: project
  originSessionId: 07da05e9-981a-465b-aad6-7f1cc1e8c07c
---

**Read this first to restore context.** Cilex Watchtower = a native Ubuntu
**Qt6/QML/C++ surveillance VMS operator client** (not a browser app), a client of
the **cilex-vision** platform. Cameras have no storage; footage/events come from
cilex-vision. Repo: `/home/cilex-vision/projects/cilex-watchtower`.

## Where we are (2026-05-28)
**P1–P6 are ALL COMPLETE** (Foundation+Live, Single-Camera, Playback, Export,
Events+Health, Saved Views/Clips/Prefs/palette). Latest commit **`623d660`** on
`main`, pushed to the **private** GitHub remote `origin`
(github.com/romayankin/cilex-watchtower). Working tree clean, nothing in-flight.

## Canonical current state — read these in-repo docs (authoritative)
- `docs/PROJECT_STATUS.md` — phase status + done-highlights.
- `docs/BACKLOG.md` — the prioritized open backlog (priority + 🟢ready/🔴blocked + owner + what unblocks each). **All P1 items are backend-gated; 🟢 items are client polish.**
- `docs/DEVELOPMENT.md` — stack, build/run/verify commands, all `WT_*` dev hooks, architecture (models + QML), API contract, Qt 6.4 gotchas.
- `docs/letters/watchtower-to-cilex-vision-api-requests.md` — the single living backlog of backend asks **and Cilex Vision's point-by-point responses** (BACKEND RESPONSE section). Items coded A#/B#/C#.
- `docs/agent-memory/` — an in-repo MIRROR of this memory dir (so memory survives a full machine loss). Refresh it (`cp ~/.claude/projects/<proj>/memory/*.md docs/agent-memory/`) when committing memory changes.

## Build / verify (full detail in DEVELOPMENT.md)
- Build: `cmake -G Ninja -B build -S . && cmake --build build` → `build/watchtower`.
- Smoke: `QT_QPA_PLATFORM=offscreen timeout 6 ./build/watchtower` (exit **124** = loaded fine; grep stderr for `.qml:`/warning).
- Visual: `WT_SECTION=<live|groups|events|health|views|clips|preferences> WT_SCREENSHOT=/tmp/x.png WT_SCREENSHOT_MS=1500 [WT_DEMO=1] timeout 12 ./build/watchtower` then Read the PNG. Use `WT_DEMO=1` to populate mock data; live (no WT_DEMO) to hit the real backend (allow ~3–5s for login+fetch on first network call).
- Always: build clean + offscreen no-warnings + a screenshot for UI changes; **revert any temp verification scaffold before committing** (grep `TEMP-VERIFY`).

## Backend (cilex-vision) — key facts
`WT_CV_URL` default `http://192.168.1.79:8000`, login `admin/admin`, OpenAPI at
`/openapi.json`; reachable from the dev box. Post-reply contract truths:
- Export `mode` ∈ **{wallclock, compact}** (enum; we send `wallclock` = freeze gaps). `"continuous"` is 400'd.
- EventType vocab: **entered_scene | exited_scene | stopped | loitering | motion_started | motion_ended** (offline/online are NOT events). EventState: new|active|stopped|exited|closed.
- `/events` feed is **EMPTY** — backend pipeline gap (their fix; detections=0 → no events). Keep the honest empty state.
- `/detections` 500 is **fixed**; `/health/storage` is **live + wired** (Health-screen storage strip).
- Full contract + responses: [[cilex-vision-playback-api]] + the letter above.

## How I operate here (working agreements)
- **Commit each completed unit to `main`** with a thorough context-restoration commit message (git log reads like a build journal), then `git push origin main`. The user wants work on `main` + pushed (private repo = crash backup).
- **Product rules**: never invent content (real data or honest empty states; mock only behind `WT_DEMO`); pixel-fidelity to `designs/design_handoff_watchtower/README.md`; footage only from cilex-vision. [[product-rules]]
- **Backend gaps**: build the full UI, transmit only fields the API accepts, mark the rest "pending," and record the ask in the letter. [[handling-design-backend-gaps]]
- Surface real decisions to the user (AskUserQuestion) rather than guessing scope.

## To resume
Read `docs/PROJECT_STATUS.md` then `docs/BACKLOG.md`. Nothing is broken or
half-done. Next actionable (🟢, no blocker), quickest first: the `compact`
export-mode toggle, "−15s" seek, same-group playback switch, event-drawer
export/filters, then theme switching (a `Theme`-singleton refactor). Every P1
(Events pipeline B2, export/clips metadata A1/A3/A6, shared ack B1) waits on
cilex-vision's first batch — the one thing worth pinging them for is the
**synthesized multi-day mixed timeline** to verify the mixed-codec playback switch.

Related memories: [[build-roadmap]] · [[cilex-vision-playback-api]] · [[s06-playback-gaps]] · [[product-rules]] · [[handling-design-backend-gaps]] · [[stack-and-build-direction]] · [[toolchain-setup]] · [[video-pipeline-approach]] · [[data-persistence-and-naming]]
