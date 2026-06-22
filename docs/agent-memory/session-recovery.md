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

## Latest session (2026-06-21–22) — READ THIS FIRST (supersedes all blocks below)
HEAD **`dcc61d3`** on `main`, **pushed, working tree clean.** This arc's commits (newest→oldest):
`dcc61d3` **cap concurrent VA-API decodes (default 9; `WT_MAX_DECODES` override)** — `LiveMonitor.
maxLiveDecodes`; only the first N tiles by grid position run a live pipeline (`liveDecodeAllowed`),
the rest show a periodic go2rtc snapshot via `LiveThumb` (all cameras stay visible). The residual
~5.8 GB scales with concurrent decode count, so this bounds it. **Verified real-iGPU: 4×-reassign
8.6→5.8→~3.3 GB (cap 9); screenshot shows a 4×4 all-populated (9 live + 7 snapshots).** Tune lower on
a weak box, raise (16) for an all-live wall. ·
`e2c870b` **stop decoding during Arrange + decode picker thumbs small (sourceSize 480)** —
re-assign scenario (Arrange→pick-and-assign ×4) balloon **8.6 GB → 5.8 GB**. Reverts the earlier
"keep alive in arrange"(Part2) + "pause during picker"(6390eb9) experiments (both kept/churned 16
VA-API decodes → balloon). Arrange just identifies cameras; build-stagger defuses the on-exit
rebuild. ·
`7bcabc9` **bound live-frame delivery to a 1-frame mailbox** (RtspVideoSource: onNewSample → single
`m_pendingFrame` + `m_frameMutex`, post ≤1 `deliver()`; newer frames replace the unconsumed one).
The low-latency path was posting EVERY decoded frame to the GUI thread via an **unbounded
QueuedConnection** (16×15fps×3.7MB ≈ 888 MB/s); when the GUI thread fell behind, the event queue
piled up and RSS ballooned. **Verified on the real iGPU (RSS heartbeat): steady-state 16-cam wall
now flat at ~457 MB (was unbounded).** ·
`6390eb9` **pause the live wall while the picker is open** (`videoActive: … && pickerCell < 0`) —
frees the 16 live decode contexts during the picker; rebuild staggered on close. (Marginal vs the
balloon below — keep for the single-open case.) ·
`2bc7c21` **picker-table crash fix** — hard-cap the "Tap to change" thumbnail fetches to **≤3
concurrent** (load limiter on LiveMonitor root: `_thumbWant`/`_thumbPump`/`_thumbRelease`, reset on
open). **SELF-TESTED offscreen (drove the picker open, instrumented): cap provably holds at ≤3** —
admit 3 → strict release→admit → drains all 32, inflight never >3. So the 32-fetch burst is GONE.
The picker built ALL ~32 go2rtc frame.jpeg thumbs (= iGPU frame-grabs) AT ONCE → OOM (4th crash;
operator correctly fingered "the table of cameras"). ·
`51f528d` **RELAYOUT-FREEZE FIX** — global pipeline-build rate limiter (PipelineBuildPump, ≤1 gst
build / 120 ms) + keep tiles alive in Arrange + gate picker thumbs on picker-open ·
`7bfcbfb` **drop the decoder "empty surface" green frame at the source** (RtspVideoSource onNewSample
samples the RGBA frame; uniform+green-dominant = the all-zero-NV12→RGB(0,135,0) signature → don't
deliver, don't mark playing → cover/reconnect take over). This is what finally kills the green that
survived the cover — the wedged sub-stream was *delivering* green frames, so frame-flow gating saw
"playing". · `f04861d` snapshot console-spam fix · `85525d3` loading bar + wall per-cell ms clock ·
`3769878` auto-reconnect (throttled) · `09130b8` green cover + frame-flow gating · `fc81bba` export
letters (Q-CV6) · `d7a8ef6` Standard label→720p · `a21da42` client compression.

⚠️ **RELAUNCH the app** — running `./build/watchtower` predates HEAD; just restart it for `dcc61d3`.

🧠 **ROOT CAUSE — VA-API decode-memory watermark (now bounded by the decode cap `dcc61d3` → ~3.3 GB at cap 9; lower the cap for more headroom).**
Replicated both scenarios on the REAL iGPU with an RSS heartbeat + a `WT_TEST_PICKER` self-drive hook.
Findings: mailbox bounds *steady-state* (457 MB); the **picker / 4×-reassign churn balloons RSS to
~8.6 GB** (~530 MB **per live tile**), now cut to a **flat ~5.8 GB watermark** by `e2c870b`
(stop-decode-in-arrange + small thumbs). Ruled OUT as causes: thumbnail burst (capped ≤3, proven),
unbounded frame queue (mailboxed), reconnect cascade (disabling changed nothing), thumbnails
(sourceSize didn't move the 5.8 GB), glibc arenas (MALLOC_ARENA_MAX=2 only trims ~750 MB). So the
residual ~5.8 GB is **VA-API/i915 decode memory held after tearing down the 16 pipelines** — a flat
watermark below the Qt/frame layer; client code can't free it. **On a healthy box (~10 GB free) 5.8 GB
SURVIVES; on a swap-loaded box it OOMs.** → Keep the box rebooted / low-swap. **Real elimination needs
fewer concurrent VA-API decodes (smaller default wall, or a "freeze last frame, no live pipeline"
path) or a driver/gst fix** — a system-level look (`intel_gpu_top`, `LIBVA_*`/`GST_DEBUG`) at why each
decode holds ~360–530 MB. Optional cheap tweak: launch with `MALLOC_ARENA_MAX=2` (~750 MB). Re-add the
`WT_TEST_PICKER`
self-drive hook + an RSS heartbeat (added & reverted this session; re-add from git if needed).
🖥️ **THE BOX IS STARVED + NOT REBOOTED (2026-06-22 15:42): 7-day uptime, swap 6.1 GiB used, 1.6 GiB
free RAM, load avg 7.7.** Three crashes happened in this state. The code fixes remove the demand
bursts, but **strongly push a REBOOT** (or `~/safe-swap-clean.sh` / the `swap-clean.timer` from this
session — see `/home/cilex-vision/`) before/after testing. If crashes persist post-reboot, suspect a
steady memory leak (Docker backend OOM history), not Watchtower.

🔥 **CRASH (2026-06-22): app OOM-killed + 20 s system freeze during camera-change churn.** Repro:
Arrange → "Tap to change" → Esc → "Tap to change" again. Mechanism: `videoActive: visible &&
!arrangeMode` (LiveMonitor:916) ⇒ entering Arrange tears down all 16 video pipelines and exiting
**rebuilds 16 at once** (UNTHROTTLED gst PLAYING = 16 simultaneous VA-API decode contexts); the
"Tap to change" picker (GridView of go2rtc snapshot thumbs) piles on. On a box at **6.9 GiB swap**,
that wedged the shared iGPU (20 s freeze) and the OOM-killer SIGKILL'd it ("Killed"). **The
auto-reconnect did NOT cause it** (inactive arrange tiles don't reconnect; coordinator throttles).
**FREEZE FIX SHIPPED (`51f528d`, awaiting LIVE confirm)** — load-spreading, all three parts: (1)
**global pipeline-build rate limiter** `PipelineBuildPump` (RtspVideoSource.cpp, GUI-thread, leaked
singleton): `rebuild()` no longer builds inline — it enqueues + the pump calls `startPipelineNow()`
≤1 per **120 ms**, so a 16-tile burst (layout change / page turn / app start) comes up gradually
(loading bar covers it) instead of 16 simultaneous VA-API decode contexts. teardown()/dtor cancel a
queued build; reconnects ride the same pump. **RULE: any pipeline build MUST go through `rebuild()`
→ PipelineBuildPump — never build inline.** Verified offscreen (builds at 120/126/125 ms intervals,
queue draining 1 at a time). (2) **Keep grid pipelines alive in Arrange** (videoActive dropped
`&& !arrangeMode`) — no teardown-on-enter / rebuild-on-exit churn; overlay just dims. (3) **Picker
thumbs gated on `pickerCell >= 0`** — GridView delegates existed while hidden and fetched go2rtc
snapshots for every camera in the background (also the frame.jpeg spam source). Teardown still
capped by kMaxConcurrentTeardowns(8). **Can't repro the freeze offscreen → NEEDS LIVE TEST**
(Arrange/Tap cycling, layout changes, page turns); recommend a reboot first to clear 6.9 GiB swap.
Still worth `sudo dmesg | grep -iE 'oom|killed process|i915|gpu hang'` to confirm OOM vs GPU-hang.

🩺 **DIAGNOSTIC LESSON (2026-06-22):** the operator reported green STILL showing after the
green fix — but it was the **stale running binary**. Always confirm what's actually running:
`ps -o lstart,etimes -C watchtower` (process start) vs `stat -c %y build/watchtower` (build time).
The process had started 10:35; the fix was built 13:21 → 3 h of testing old code. When a "fix
didn't work," **check the running process age FIRST** before re-diagnosing the code.

**This session also added (`85525d3`, awaiting live confirm):** (1) an indeterminate **loading
bar** along the bottom of a connecting/reconnecting tile (honest sweep, no fake %; clears when
frames flow). (2) **Per-cell wall-clock (ms) on the playback wall** — `WallPlayback` is ONE
server-composited HLS stream (one decode/timeline → ms-synced BY CONSTRUCTION; no client sync to
do), so each cell now prints the identical `playheadMs` via `fmtWallMs()`, making the sync visible.

**GREEN-SURFACE FIX (`09130b8`) — shipped, awaiting live confirm.** A single camera (.120, a stalled
substream) showed a frozen green tile in the 4×4 AND a fully green single-cam view, while the backend
was fine (motion events flowing). Root cause: `VideoSurface.playing` meant "pipeline up", not "frames
decoding" — `RtspVideoSource` flips `playing=false` only on EOS/error/teardown, never on a *silent*
stall, so a green/frozen surface kept `playing=true` and showed through. Fix (`qml/VideoSurface.qml`):
`playing` now = real frame flow (`_hasRecentFrame`, set on `videoOut.videoSink.videoFrameChanged`,
cleared by a 2.5 s stall `Timer`) + an opaque `#0a0d11` cover over the `VideoOutput` whenever
`!playing`. Green never shows; a stall degrades to "Connecting…" and self-heals when frames resume.
Verified: build/smoke clean + a WT_TEST_QML harness renders 100 % `#0a0d11` (not green). **Auto-reconnect
SHIPPED (`3769878`):** stalled tiles now actively recover — `VideoSurface` rebuilds the pipeline with
per-tile exponential backoff (2/5/10/20/30 s; patient 8 s on a cold connect) via
`RtspVideoSource.reconnect()` (`Q_INVOKABLE`→`rebuild()`; qtmm re-sets source), and **every attempt is
serialized through the `ReconnectCoordinator` singleton** (≤1 initiation / 700 ms app-wide) so a
fleet-wide stall recovers one pipeline at a time, NOT a 16-pipeline burst — the freeze guard. Throttle
verified (6 requests released exactly 700 ms apart). **RULE: any other rebuild/reconnect path must also
route through `ReconnectCoordinator`.** Likely original cause for .120: opening the single view tears
down the grid tile's pipeline + opens a 2nd .120 sub pipeline; the open/close churn wedges go2rtc's .120
sub producer — now self-heals. A genuinely-wedged sub is a backend/go2rtc item. **Both the green-fix and
auto-reconnect await live confirm on .120 (relaunch needed).**

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
  sub fragment. **Open (non-blocking, CV's court) — Q-W3 → Q-CV6:** re-exports of *pre-deploy / aged*
  windows still deliver **1080p** (byte-identical 8848 B across **3** fresh post-deploy jobs). CV
  (reply7) says the warm-path rendition cache is keyed by `(segment_id, delivery_profile)` → "no fix
  needed"; our Q-CV6 re-test (reply8) disproves that for the **export worker's aged/cold path** — it
  serves the old 1080p rendition even though the window's live session now reports `no_recording`.
  Recent-footage exports are correctly 720p (the common path), so non-blocking. Created 3 dev test
  exports (`wt-720p-verify`/`wt-720p-fresh`/`wt-cv6-retest`; the failing-1080p jobs `62588e85` +
  `bdb5237b` are for CV to inspect). reply8 also carries a **bitrate correction** (the sub is
  ≈1 Mbit/s / 1024 Kbps-configured, not "~0.1"). Thread: `…compression.reply8.md` (reply7 = CV's).

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
