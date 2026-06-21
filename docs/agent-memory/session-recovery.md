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

## Latest session (2026-06-21) — READ THIS FIRST (supersedes all blocks below)
HEAD **`d7a8ef6`** on `main`, **pushed, working tree clean.** This arc's commits (newest→oldest):
`d7a8ef6` flip Standard label 1080p→720p (CV shipped native-720p; verified live 1280×720) ·
`9b43253` recovery snapshot · `e49f116` simplify camera marks + un-stick map-selection ·
`999a9fe`/`306a660` export letters · `a21da42` client-side compression + overlay burn-in ·
`808f75f` wire High/Standard export · `3e6d689` brighter ruler digits · `9e50713` export quality UI ·
`b7c7705`/`b5345dd` green-wall fixes.

⚠️ **RELAUNCH the app** — the running `./build/watchtower` predates HEAD; rebuild is on disk,
just restart it to get `d7a8ef6`. (QML is byte-compiled in; no hot reload.)

**EXPORT QUALITY + CLIENT COMPRESSION — shipped both sides; one CV item open.**
- Single-cam **Export drawer** now has: **Quality** (High = HEVC 1440p main original; Standard =
  H.264 sub) with grey-out+tooltip when the original has aged out; a **Compression** ladder
  (Original/1080p/720p/480p, sizes ≥ source greyed); and functional **overlay toggles**
  (default OFF = pristine, no re-encode).
- Backend (CV, migration **0045**): `CreateExportRequest` takes **`hevc_capable`** (true=High,
  false=Standard); fragments carry **`stream_type` ("main"|"sub")** = the authoritative
  "is the high-res original retained here" (orthogonal to `tier`, which is retention age).
  Verified live: High→**2560×1440 H.264**, Standard→**1920×1080** (the 720p sub upscaled to the
  1080p delivery profile; visual detail ≈720p). A High request over an aged span → **422** (string
  `detail`), surfaced as an export error; our grey-out prevents the normal case.
- **Client-side compression/overlays are OURS now — `ClipTranscoder` (`src/models/ClipTranscoder.{h,cpp}`):**
  ffmpeg via QProcess, **software libx264** (never contends with the live wall on the shared iGPU),
  scale + 2 `drawtext` overlays — camera caption via `textfile=` (no escaping), per-frame **footage
  wall-clock** via `text='%{pts\:localtime\:<clip_start_epoch>\:%Y-%m-%d %H\\\:%M\\\:%S}'` (verified).
  Wired through `PlaybackClient::createExport(..., hevcCapable, post)` where `post` =
  `{height,timestamp,name,label,startEpochMs,durationMs}`; downloads the clean export then transcodes
  to the final path (keeps the original on failure). **A2 (server overlay burn-in) is RETIRED.**
  ffmpeg 6.1.1 + DejaVuSans present on the box.
- **DONE (2026-06-21, `d7a8ef6`):** CV shipped native-720p Standard (`h264-main-720p`; reply5 —
  Q-CV5/Q-W1/Q-W2 all yes). Flipped the ExportDrawer label **"Standard · 1080p" → "720p"**
  (`sourceHeight` standard 1080→720; ladder now Original+480p; confirm-modal "(720p)"). **Verified
  live end-to-end** (drove the real backend, not just CV's word): a fresh-window Standard export →
  `resolution 1280x720` (~747 KB/8 s); playback manifest → `delivery_profile h264-main-720p` on every
  sub fragment. **One non-blocking open item — Q-W3 (reply6):** a re-export of a *pre-deploy-rendered*
  window still serves cached **1080p** (byte-identical 8848 B) → asked CV whether the rendered-fragment
  cache is keyed by `(segment, hevc_capable)` not `delivery_profile` (so old windows serve 1080p until
  they orphan out; fresh exports are correctly 720p). Created 2 dev-backend test exports
  (`wt-720p-verify`/`wt-720p-fresh`). Thread: `…export-quality-and-client-side-compression.reply6.md`.

**ALSO shipped this arc:** green-wall fixes (the live grid binds a camId-keyed reconciled `gridModel`
so a poll/relayout never rebuilds tiles → no green flash — see DEVELOPMENT.md gotcha); brighter/larger
scrubber ruler digits + full date on the playhead watermark; **removed the dead camera-tile bookmark
button** (it was a no-op — cameras keep the ★ star/favourite; bookmarks are Events-only); a **layout
preset now exits the transient map-selection scope** to All cameras (+ a "✕ Clear selection" toolbar
chip shown only in that scope).

**PAUSED — freeze diagnosis (in progress, not finished):** user reports the host appears to freeze
(over RDP) immediately on Live **"Change layout"**. Likely the **shared Intel AlderLake iGPU (`i915`)**
— one chip does the app's VA-API decode + Mutter + GNOME-Remote-Desktop encode + go2rtc QSV — wedging
under VA-API decode-context churn on relayout (would freeze app+desktop+RDP together), and/or
**memory/swap/OOM** (15 GiB, ~1.2 free, 6.5 swap; documented Docker `ffmpeg`/`h264_qsv` cgroup OOM
history). **Recording is in Docker → killing the app is SAFE.** Diagnostic scripts left on the host:
**`~/freeze-watch.sh`** (1 s continuous monitor) + **`~/freeze-snapshot.sh`** (deep capture, run with
`sudo` — gdb needs root, ptrace_scope=1). **Not yet run** — awaiting the user to reproduce + paste
logs. Decision matrix + recovery order are in this session's transcript (least-disruptive: capture,
then `kill -TERM $(pidof watchtower)`; never reboot first; never `docker stop`).

**OFFERED, not started:** (a) broader view-scope simplification (a 2nd "favourite" exists on Saved
Views; possible Groups/Saved-Views/Favourites consolidation); (b) a live end-to-end export→download→
transcode verification pass.

**Platform note:** this was a ~7-day **resumed Remote** session; its Background-tasks panel accumulated
**9 phantom "Running" `run_in_background` entries** (processes long dead — a Claude Code bug; likely a
sandbox time-namespace/clock skew). Reported via `/feedback`; full write-up at
`/home/cilex-vision/claude-code-bug-report-background-tasks.md`. **A NEW session clears them.** Going
forward, **avoid `run_in_background` for verify/perf — use foreground bounded runs.** (The freeze
scripts + bug report live in `/home/cilex-vision/`, NOT the repo — local-only.)

## Latest session (2026-06-18) — earlier (supersedes the 06-02 block below)
Latest commit **`147ed50`** on `main` (pushed). The **Events redesign** (faithful QML port of
`designs/events-v2`: 01 Triage / 02 Verify / 03 Timeline / 04 Situation Map) is now the
**DEFAULT** Events screen, fully on real `/events` + `/maps`. Canonical task state lives in
**`docs/events-redesign-tasks.md`** (rows #1–#14, #17 ✅ done; only **#15 severity/AI data** +
**#16 camera placement** remain — both *operational/config on Cilex Vision's side*, not code).
Backend Events workstream is **closed**. This session's two features: **(#13) FOV coverage cones**
on Situation-Map pins (translucent wedge + outline via `rotation_deg`, tinted by pin state) and
**(#17) a camera-group switcher** in the Events mode bar (`groupFilter` scopes queue / wall /
timeline / map pins to All / a named group / Ungrouped; placed pins follow the group too).
New dev hook **`WT_EVENTS_VIEW=triage|review|timeline|map`** opens an Events sub-view directly
(for offscreen screenshots). Flags: `WT_DEMO` → mock showcase; `WT_EVENTS_LEGACY` → old table
screen. Verify offscreen via PIL crop of `WT_SCREENSHOT` PNGs (no ImageMagick on the box).
Letters exchanged this arc are under `docs/letters/2026-06-18-*`. Earlier blocks below are history.

## Latest session (2026-06-02)
Latest commit **`c18b5fa`** on `main` (pushed). The E1 wall is live; this session landed a
large client-feature batch and **closed BOTH backend threads** (recorder stall + E2 export) —
**no open backend asks** right now. For current truth read `docs/PROJECT_STATUS.md`,
`docs/BACKLOG.md`, the `docs/letters/` thread, and [[multicam-review-architecture]].

**✅ E1 16-cam synchronized wall DELIVERED + verified live.** (Earlier this arc it was blocked
at scale; CV fixed it in `51c7b4d` — `pids_limit` 256→1024, `-threads 1`/input, render semaphore,
seek-3s-early for 0-byte boundary segs — and I drove the real 4×4 wall on the iGPU: composites +
plays, populated cells synced, empties black-filled, cold seg ~1s.) Full thread:
`docs/letters/2026-05-31-disk-healthy-path-to-live.{md,reply…reply4}.md`. **Client facts:** wall
entry = the LiveMonitor **"Go back in time"** button (the only entry; reactive — no gate, "pending"
only on a 404); shipped an **18s render watchdog** (`WallPlayback.qml`, honest-fail a stuck composite)
+ a permanent **`WT_WALL_DAY=<YYYY-MM-DD|live>`** dev hook. Wall screenshots need the real **Wayland
display + VA-API** (`/dev/dri/renderD128`). Coverage A7+E4 ✅ — both calls send `?tz=<system IANA tz>`.

**Both backend threads CLOSED:**
- **Recorder per-stream stall — FIXED + WIRED.** CV `0ab548f` (thread closed via
  `…recorder-per-stream-stall.reply2.md`): per-stream **watchdog + auto-restart** (silent
  "ffmpeg-alive-no-frames" stall → restart in ~50s) + **`/streams.recording` is now mode-aware**
  (`recording`|`stalled`|`armed`|`disabled`|`offline`) + a new **`last_segment_at`**. *Correction:*
  `.106`/`.120` weren't dead — they were switched to **motion-triggered** recording (so `armed`, not
  stalled; `.106` reads ARMED live). **Wired client-side** (`10fffe1` + `1245699`): `CameraStatus::RecState`
  gained **Stalled/Armed/Disabled**; `recStateFrom()` parses the vocab on full fetch + 15s poll;
  `last_segment_at` → `CameraData` + a model role. **Counts: stalled→NOT REC, armed→recording, disabled→neutral.**
  UI: red **STALLED** badge + "RECORDING STALLED · since <last_segment_at>" tile strip + fault edge;
  neutral **ARMED** badge; **"Last recording"** row in single-cam + Health detail. Closes the old
  **"NOT REC 0 looked green"** gap. (Verify recording from the state/`last_segment_at`, or segment
  timestamps — NOT a bare `/streams` count.)
- **Combined-grid export E2 + I7 + A6 — SHIPPED + WIRED.** CV `d724a20` (thread closed via
  `…mosaic-export-e2.reply2.md`). E2 = `POST /review/mosaic-sessions/{id}/exports {wall_start,wall_end,mode}`
  → `{job_id}` on the shared `export_jobs` flow. **Wired client-side** (`fec0374`): `createExport`/
  `createMosaicExport` send optional **group_id+purpose**; `WallPlayback.exportSelection()` sends one
  group_id across N per-cam + 1 mosaic (I7 dual-archive); **`PlaybackClient.fetchExports()`** consumes
  **`GET /review/exports`** (A6); the **Clips & Snapshots library** (`ClipsScreen.qml`) now lists server
  exports (per-cam = `clip` icon; mosaic = `layers` icon "Grid · <group_id>") merged with local
  snapshots — purpose/state/resolution/group + Open via the proxied token download + a Refresh button.
  Verified live (4 exports incl. the `grid-verify-1` single+mosaic set).

**Other client features this session:**
- **Events screen** (`EventsScreen.qml`): fixed Camera-column alignment (`b7b3ab7`); **per-column sort +
  Excel-style autofilter on EVERY column** (`759d300`) — clickable headers (funnel + ▲▼), dropdown with
  Sort↑/↓ + search + Select-all/Clear + a distinct-value checklist; **Enter-to-apply** + **drag-resizable
  columns** (grips on Camera/Group/Time/Status; Event flexes) (`73f5ad2`). Added `EventData.tsMs` (epoch)
  for chronological Time sort. **NOTE: the `/events` feed is LIVE now** (motion events flowing; was empty).
- **Live Monitor**: **★ Favorites filter pill** (`a1080ae`) — camera-favorites filter was plumbed in the
  model but had no UI; now the first pill shows only starred cameras. Tile **hover-action fixes** (`6e41c3a`):
  unclipped dense grids (vertical Column → bottom-right Row), new **playback** icon (`Icon.qml` gained a
  **`pf`** filled-overlay channel), wired the dead Open-Playback + Favorite buttons, toggle active states.
  **bookmark stays visual-only (not persisted).**

**NEXT (all optional — nothing backend-gated):** (1) wire the single-camera **ExportDrawer Purpose** onto
`/review/exports` (A1 now accepts it; ~one line). (2) Latent: **fix the `availability !== "ready"` filter**
(PlaybackScreen) that drops hydrating/cold fragments. (3) Optional UI: persist **bookmark**; a
nav/command-palette entry for the wall (only entry today = "Go back in time").

**Durable backend/disk facts (this machine):** WD Purple disk was re-cabled + host
rebooted **21:09 MSK 2026-05-31** and is **solid** — `/health/storage` ok, `sda`
(WDC WD43PURZ, fs_uuid `07fa7c7d…`, managed_id `f437216b…`) `assigned`/`role=video`,
**zero `ata5`/`sda` resets even under full recording load**. The dev box **IS**
`192.168.1.79` (backend + recorder run locally; shutting it down takes them offline).
**Backend auth is COOKIE-based** (`-b "access_token=$T"` from `POST /auth/login`
admin/admin), NOT a Bearer header — `/storage/*` 401s on a bearer header. Footage
lives in **SeaweedFS** (`.dat`/`.idx` volumes under the mount); `/recording/segments`
+ `/admin/recordings` look empty without filters. **`/streams` lists 31 cameras**
(192.168.1.101–.131, was 4). **Recorder** was undersized for the 31-cam fleet (a 768 MB cap → restart-loop); CV
raised it to **2 GB / 512 pids** (`ad96216`) and later added a **per-stream watchdog**
(`0ab548f`). `/streams.recording` is **mode-aware** now (recording/stalled/armed/disabled)
+ carries **`last_segment_at`** — judge recording health from those (or actual segment
timestamps), NOT a bare `/streams` count. ("disk healthy" ≠ "recorder writing segments".)

**Two heads-ups:** (1) `sda1` is **double-mounted** — canonical `/mnt/cilex-vision/disks/07fa7c7d…`
*and* `/mnt/cilex-storage` — but CV confirmed this is an **intentional** reboot-persistent
bind from their storage-recovery runbook, not a stray automount; migration `0029` (pure
DDL) was unaffected. (2) **OS disk `/` ~91% (23 GB free as of 2026-06-02; was 97%/9 GB)** —
watch it; build churn fills it.

**Build reminder:** QML is byte-compiled into the binary — *no hot reload*; every QML edit
needs rebuild (`cmake --build build`) + relaunch. (A7 coverage is deployed; the 2026-05-31
IP-dedup fix is committed `0d04757`.) Offscreen smoke: `QT_QPA_PLATFORM=offscreen timeout 6
./build/watchtower` (exit 124 = ok). Screenshots: `WT_CV_AUTOLOGIN=1 [WT_SECTION=… | WT_FOCUS_IP=…
| WT_WALL_DAY=…] WT_SCREENSHOT=/tmp/x.png WT_SCREENSHOT_MS=… [WT_DEMO=1]`.

## Where we are (2026-05-30, earlier — for current status see PROJECT_STATUS.md + BACKLOG.md)
**P1–P6 are ALL COMPLETE** (Foundation+Live, Single-Camera, Playback, Export,
Events+Health, Saved Views/Clips/Prefs/palette). Latest commit **`4170cb5`** on
`main`, pushed to the **private** GitHub remote `origin`
(github.com/romayankin/cilex-watchtower).

**Since 2026-05-28 (post `623d660`):** Phase D landed (backend = camera source of
truth via `/streams`: go2rtc rtsp urls D1/D2/D5, recording-state D6, §D3 main HD
passthrough). A **live-streaming stability incident** drove RTSP-teardown fixes
(staggered/bounded teardown, worker-thread GStreamer teardown, green-frame-reset
fixes), low-latency RTSP path is now the **default** (`WT_LEGACY=1` opts out),
`WT_NO_POLL=1` disables `/streams` polling. A **go2rtc OOM incident (§D3)** —
clip-service's 20-camera rolling buffer opened 20 per-consumer VA-API transcodes —
was fixed backend-side by making the main stream **dual-source** (raw RTSP H.265
passthrough first, ffmpeg:vaapi only for browser HLS).

**HD snapshot capture — DONE, committed `df5576e`.**
`Artifacts::captureMainStreamSnapshot()` async-pulls a full-res JPEG from go2rtc
`http://<host>:1984/api/frame.jpeg?src=<stream>` (derived from the MAIN rtsp url,
not the substream the wall renders), saves `.jpg`, emits `snapshotCaptured`/
`snapshotCaptureFailed`; `CameraTile.qml` prefers it, falls back to
`captureFromTile()` on failure. Verified live: real 2560×1440 JPEG, pulls the raw
H.265 passthrough producer (NOT the 1280 ffmpeg transcode), transient one-shot —
no §D3 OOM risk. Open follow-up: port 1984 hard-coded (code TODO → backend ask to
expose the frame url on `/streams` + per-user auth). Working tree clean.

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
**(2026-05-31: see "Latest session" at the top for current next steps + the WD Purple
disk context. The list below is earlier background and may be partly stale.)**

Read `docs/PROJECT_STATUS.md` then `docs/BACKLOG.md`. Nothing is broken or
half-done. Next actionable (🟢, no blocker), quickest first: the `compact`
export-mode toggle, "−15s" seek, same-group playback switch, event-drawer
export/filters, then theme switching (a `Theme`-singleton refactor). Every P1
(Events pipeline B2, export/clips metadata A1/A3/A6, shared ack B1) waits on
cilex-vision's first batch — the one thing worth pinging them for is the
**synthesized multi-day mixed timeline** to verify the mixed-codec playback switch.

Related memories: [[build-roadmap]] · [[cilex-vision-playback-api]] · [[s06-playback-gaps]] · [[product-rules]] · [[handling-design-backend-gaps]] · [[stack-and-build-direction]] · [[toolchain-setup]] · [[video-pipeline-approach]] · [[data-persistence-and-naming]]
