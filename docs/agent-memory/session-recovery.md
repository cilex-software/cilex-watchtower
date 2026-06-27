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

## Latest session (2026-06-21–25) — READ THIS FIRST (supersedes all blocks below)
HEAD **`f99504a`** on `main`, **pushed, working tree clean.** This arc's commits (newest→oldest):
**ACTION-LIST OUTCOMES from the 3 stress tests (worked through with operator):**
`fb9efa8` **A1 FIXED — playback far-seek freeze.** `seekToWall()` now detects a far target (>20s from the
current compact pos) and calls new `seekFar()`, which re-opens a short ~30min session STARTING ~15s before
the target + seeks on load (mirrors EvHeroPlayer event-open) — target lands near the start of a fresh short
HLS, no cross-discontinuity seek, renders. Verified: before = ≥30s jumps all TIMEOUT; after = ok=32/0,
far jumps render 3-391ms. **Trade-off (prototype): a far jump re-centres the scrubber to ~30min; polish
follow-up = decouple the scrubber timeline from the player's loaded window.** Added `WT_SEEK_SPAN` knob;
seek harness now routes through `seekToWall`. · `f99504a` **A3 DONE — backend letter**
`docs/letters/2026-06-27-playback-seek-discontinuities-and-session-span.md` (asks: continuous-timeline HLS
so seeks don't need the workaround; + the ~24-36h session-span cap). · **A2 NOT FIXED — events leak
(~+100 MB/min browsing).** Operator-chosen experiment (recreate the hero MediaPlayer per event via a Loader)
**FAILED: reuse +104 MB/min vs recreate +140 MB/min** → the leak is NOT the player-object lifecycle; it's
deeper in the per-HLS-source-open path (QtMultimedia FFmpeg shared context / `HlsProxy` / un-closed backend
sessions — PlaybackClient never sends `DELETE /review/sessions/<id>`). Experiment reverted. **Logged as
known P2; next directions: audit HlsProxy per-session teardown, or revisit when a profiler works / Qt
upgrade.** heaptrack still crashes this stack. Also: produced a 6-page PDF exec report (reportlab in a
`/tmp/pdfvenv`; `/tmp/make_report.py`). ·
`52af1b0` **test(harness): 3 env-gated UI-driver stress tests + an external /proc CPU/RSS sampler
(`/tmp/sampler.py`) + matplotlib graphers (`/tmp/graph_test{1,2,3}.py`, `/tmp/run_test*.sh`).** Drivers
(inert unless env set): `WT_RESIZE_TEST` (Main.qml, logs `[RT]`), `WT_SEEK_TEST`+`WT_SEEK_ITERS`
(PlaybackScreen.qml, opened via `WT_PLAYBACK_IP` @ 24h session, logs `[SK]`), `WT_EVENTS_TEST`
(EventsArea.qml via `WT_SECTION=events`, logs `[EV]`). **FINDINGS (2 real bugs to fix):**
**(1) ▸RESIZE = CLEAN** — 600 resizes incl. 1×1/3840×2160, no crash, no leak (RSS floor flat ~160MB),
only transient framebuffer spikes at 3-4K sizes that return. **(2) ▸PLAYBACK SEEK = BUG** — in-buffer
jumps render fast (1s≈36ms, 10s≈101ms, n=100) but **EVERY jump ≥30s FREEZES** (position moves, player
says Playing/Buffered, 0 frames for 45s). Real: scrubber-click + event-click both → `seekToWall`→
`player.position`. Cause = FFmpeg HLS demuxer stalling across the 24h session's ~2879 fragment
**discontinuities**. Day-scale jumps untestable: **backend caps a review session span at ~24-36h** (24h
ok / 36h+ returns empty; footage itself exists ≥4d). Playback mem plateaus ~780MB (HEVC 2560×1440, no
leak). **(3) ▸EVENTS = LEAK** — 15min browsing (cycling tabs + selecting events) climbs RSS **+642MB
(582→1223, sawtooth, NO plateau)**, driven by event-select→hero-recording-open; click→playback-open
latency median 67ms/mean 143ms/max 1157ms (n=295), no crash. (Backend playback contract: `POST
/review/sessions {camera_id,wall_start,wall_end,hevc_capable}` cookie-auth → `{session_id,manifest:{
wall_start,wall_end,fragments[]}}`; `frame.startTime` is unavailable on the HLS QVideoFrames.) ·
`d1f2a8c` **perf: decode snapshot tiles at display size — MEASURED ~224 MB (-33%) wall saving (the
biggest memory win yet).** Ran the videoscale + LiveThumb.sourceSize sweep the operator asked for, with
real stats (offscreen, N=5/config, Welch t-test, MALLOC_ARENA_MAX=2, cap-9). **Finding inverted my
guess: the SNAPSHOT tiles, not the live decode, are the sink.** LiveThumb's two Images (imgA/imgB
no-blank refresh) had NO sourceSize → each non-live tile decoded a full-res JPEG → QImage+texture, ×2.
Results vs 558.8±11.7 MB baseline: snapshots→tile-size **−223.8 MB [209,239] t=42 p<.001**; live
videoscale 480×270 only −47.8 MB [33,62]; live 160×90 ceiling −55.8 MB (⇒ **row-4 zero-copy ceiling is
≤56 MB — NOT worth building**); both −261 MB. **On-screen N=3 confirmed transfer: wall 677→421 MB
(−38%).** Screenshot-verified all 16 tiles render (no visual change). SHIPPED: LiveThumb sourceSize
defaults to tile size. Kept env knobs (inert unless set): **`WT_DECODE_SCALE=WxH`** (videoscale live
decode — optional, costs live res, NOT default) + **`WT_THUMB_SCALE=<px>`** (A/B test). Sweep harness:
`/tmp/sweep.sh` + `/tmp/analyze.py`. Wall = 16 tiles (9 live + 7 snapshot ≈ 32 MB/snap full-res). ·
`40d09a1` **fix: `WT_CV_AUTOLOGIN` without `WT_CV_URL` wiped the base URL → empty wall (0 cameras/0
pipelines on cold launch).** `loginWithPassword("")` overwrote m_baseUrl; now falls back to
`auth->baseUrl()`. **THIS is why cold-launch profiling runs showed `live_pipelines=0` — NOT a decode
bug.** With it fixed, `WT_CV_AUTOLOGIN=1` alone loads the wall. (Backend `/streams` needs the
`access_token` **cookie**, not Bearer; login = `POST /auth/login` JSON {admin,admin} → 200 + cookie.)
**heaptrack (the "tomorrow" task) is UNUSABLE on this VA-API/GStreamer/Qt stack — do not re-attempt:**
on-screen it freezes the Qt event loop (2 timer fires in 82 s → never builds pipelines); offscreen AND
standalone gst-launch both SIGSEGV (139) — heaptrack captured only ~2.8 MB of gst-init before crashing.
So heap MICRO-attribution isn't feasible; the smaps MACRO-breakdown (entry below: ~460 MB shell +
per-tile ~55 MB, ~800 MB anon = glibc arenas) stands as the answer. **Confirmed live wall HW-decodes:
`[WT-DEC] using vah264dec (hardware)` ×9** (settles the WT_HW_ONLY question — it IS hardware). Run with
WT_TRACE: `QT_QPA_PLATFORM=offscreen … WT_CV_AUTOLOGIN=1 WT_TRACE=1 build68/watchtower` decodes 9 @ ~550 MB. ·
`9b192de` **Windows-port scaffold — `packaging/windows/` + `if(WIN32)` CMake skeleton.** Decided (after
a `/deep-research` run): **same repo, not separate** (98 shared cross-platform files; Windows = the same
app + conditionals + packaging; runtime binaries fetched not committed). Created app.manifest (Win10/11,
long-path, PerMonitorV2 DPI, UTF-8, UAC asInvoker), watchtower.rc (manifest+version; .ico TODO),
fetch-gstreamer-windows.ps1, deploy.ps1 (windeployqt + GStreamer LGPL subset — copy step is TODO),
installer.nsi, README. CMake `if(WIN32)`: RC + WIN32_EXECUTABLE + /MANIFEST:NO + a `deploy-windows`
target. **Inert on Linux — verified Linux still builds clean + the target is absent off-Windows.**
`a038b41` **HW-decode instrumentation + enforcement (`WT_HW_ONLY`).** Decode is rank-based + silently
falls back to software: Linux `va` plugin `vah264dec`/`vah265dec` (rank 257, klass `…/Hardware`) edge
out software `avdec_*` (256); Windows = `d3d11h264dec` (DXVA) vs `avdec`. `WT_TRACE`→`[WT-DEC]` logs
codec+decoder+HW/SW (via `decodebin` autoplug-select/deep-element-added); `WT_HW_ONLY=1` refuses
software video decoders → guarantees no software H.26x decode (perf + codec-patent: OS/GPU decoder
carries the patent licence). Qt's QMediaPlayer backend here = **FFmpeg 7.1 LGPL** (same on Windows).
Mechanism validated standalone; full-app `[WT-DEC]` live-check pending (the wall built 0 pipelines — a
backend/streaming/login state, NOT this code: pipeline parses, hooks are inside startPipelineNow).
**Qt-version decision (deep-research): SHIP WINDOWS ON 6.8.3 LTS; 6.12 is Beta 1 (final ~22 Sep 2026,
next LTS) — revisit then. The GStreamerVideoSource 6.12 feature is Linux-only + we don't use Qt's
source API anyway.** Licensing: LGPL is satisfiable (dynamic-link + notices) or buy commercial; the
real cost is H.264/H.265 codec PATENTS (mitigated by OS/HW decode). Legal/NOTICE work parked per operator. ·
`0e1cdf0` **memory profiling + NV12 optimization (steady-state ~958→~825 MB).** Operator asked why the
9-tile wall uses ~958 MB ("just broadcasting video"). Profiled (NOT a leak — flat): smaps = 81% (~800 MB)
anonymous heap, only ~170 MB libs. **Key finding: cap-1 ≈ cap-9 RSS (~960 MB)** → cost is per-TILE
(snapshot ≈ live), ×16 tiles, + ~460 MB Qt/Mesa/GStreamer shell; the decode CAP doesn't cut steady mem.
73 threads → glibc arena bloat: `MALLOC_ARENA_MAX=2` in run-watchtower.sh trims ~30-50 MB (`f9123e4`).
Streams decode 1280×720. **Option (c) DONE (`0e1cdf0`): pipeline now pulls native NV12 (1.5 B/px) not
RGBA (4 B/px) — Qt's shader does NV12→RGB on the GPU; frame buffers 2.7× smaller, no videoconvert RGBA
pool, no CPU convert. Colour space/range carried from caps; new isEmptyGreenNV12 (Y≈0 AND chroma≈0).
Verified: renders correctly (colours right, empty-green drop works), RSS flat ~825 MB / 9,200 frames, no
leak.** Builds on both Qt 6.4.2 + 6.8.3. **NEXT (operator: "do a tomorrow"): heaptrack (`sudo apt install
heaptrack`, their terminal) for exact allocation-site attribution. Deferred bigger wins: true zero-copy
(VA surface → DMABuf/GL texture, no GPU→CPU download) + rendering tiles at DISPLAY res (~480×270 vs 720p
⇒ ~7× smaller per-tile buffers).** ·
`0d68a2b` **🟢 P0 RESOLVED — the live-video OOM crash is fixed by building on Qt 6.8.3 (verified
leak-free).** The Qt 6.4.2 VideoOutput leak (below) has no client-side workaround, so upgraded Qt:
installed **6.8.3 user-space via aqtinstall at `/home/cilex-vision/Qt/6.8.3/gcc_64`**, built watchtower
against it with **ZERO source changes** (`cmake -B build68 -DCMAKE_PREFIX_PATH=…/6.8.3/gcc_64`), run via
**`./run-watchtower.sh`** (launcher sets lib/plugin/QML paths → `build68/watchtower`). **VERIFIED on real
Wayland: cap-9 wall, 90 s, 10,608 frames, RSS FLAT ~950 MB** (was 8.5 GB → OOM in 30 s on 6.4.2). 6.8.3
ALSO fixes the GridLayout SIGSEGV. System Qt 6.4.2 (`build/`) = offscreen checks only now. Docs:
DEVELOPMENT.md Build/Gotchas, PROJECT_STATUS.md. The VideoFrameItem custom-item attempt was reverted
(all client render paths leak on 6.4.2). ·
`aa5aebe` **🔴 P0 — the recurring "Terminated" is earlyoom OOM-killing us for a Qt 6.4.2 VideoOutput
LEAK (not a code crash).** "Terminated"=SIGTERM; earlyoom's log: `SIGTERM … "watchtower" … VmRSS
9025 MiB`. Instrumented + traced: a steady **per-frame leak** — pipeline count flat at 9, RSS climbs
~3.4 MB per delivered frame (~260 MB/s at 9 decodes) → 8 GB in ~30 s → earlyoom. Bisected to
`m_sink->setVideoFrame()` (the VideoOutput path). **EXHAUSTIVELY proven it's Qt 6.4.2, not us:** leaks
identically on OpenGL+Vulkan+software RHIs, AND with the legacy QMediaPlayer source into the same
VideoOutput. Tried 3 client render paths — VideoOutput (3.4 MB/f), custom QSGSimpleTextureNode+
createTextureFromImage (6.8), QQuickPaintedItem/FBO (6.4) — **ALL leak** (reverted; no simple client
fix exists on 6.4.2). **KEPT (committed): a fatal-signal handler (prints signal+RSS at death →
self-classifies OOM-SIGTERM vs code-SIGSEGV) + `WT_TRACE=1` → `[WT-MEM] rss/live_pipelines/frames`
every 2 s + RtspVideoSource::livePipelineCount()/totalFramesDelivered().** Decision (operator: "both"):
**Qt upgrade is the ONLY fix (also kills the GridLayout bug)** → done + verified in `0d68a2b` (above).
`41dbef6` **finished the minimize SIGSEGV fix — converted the last 3 GridLayouts to `Grid`.** Follow-up
to 63aa381: `EvTriage.qml` (Events facts grid — the confirmed Events crash, 158px matched the log),
`PlaybackCalendar.qml` (7-col day grid, Playback+Wall), `OpsSidebar.qml` (Live 2×2 stats — survived
testing but same bug, converted for completeness). All → `Grid` positioner (no `QGridLayoutEngine`),
cells given explicit equal width. **NO `GridLayout {` left in qml/.** Verified real-iGPU: Live, Events,
AND Wall each survive 40 maximize/windowed/minimize cycles (all were segfaults); screenshots confirm
calendar/stats/facts render correctly. ·
`63aa381` **maximize/MINIMIZE SIGSEGV fixed — camera grid positioned manually, not GridLayout.**
Operator's "crashed on maximize/minimize" ("Terminated" = shell reporting a crashed window) is a
**Qt 6.4.2 Quick Layouts bug**: minimize→restore corrupts a `QQuickGridLayout` engine state, the next
rearrange derefs a dangling attached-Layout (`QQuickGridLayoutBase::rearrange`→`qmlAttachedPropertiesObject`).
Repro: cycle `win.visibility` Maximized/Windowed/**Minimized**; maximize-ONLY survives 40, +minimize
crashes in ~4. Ruled OUT: memory, hang, the responsive toolbar (crashes with it off), window size
(stays 1440×900), render loop (basic crashes too). FIX: the Live camera grid is now a plain `Item`
with cells placed by computed x/y/w/h (`gridArea` gCols/gRows/gSpace/cellW/cellH; handles auto-fit
1×1 + feature spans cw/ch + fillers) — no layout engine to corrupt. **Verified: Live survives 40
cycles (was segfault).** Toolbar collapse also deferred (0ms timer) to avoid re-entrant visible-toggle.
(EvTriage/PlaybackCalendar/OpsSidebar GridLayouts NOW converted in `41dbef6` — see above; no
GridLayout left. Long-term still: Qt upgrade past 6.4.2 to fix the root QQuickGridLayout bug.) ·
`79b58c8` **Q-CV6 FIXED (CV reply9, `b002010`) + one-click "Export as High"** — the "aged 1080p export"
was a BLACK clip: cam `…ff9a`'s SUB stopped recording 06-11, so a Standard (sub-only) export of a
main-only window got an all-`no_recording` manifest and the worker black-filled it at a hardcoded
1080p default. CV now fails honestly (`state=failed`, `error_msg` — the field our poller already
reads). Shipped option 1: `PlaybackClient.retryLastExportAsHigh()` + a ToastHost callback action
(`actionId`/`actionInvoked`) → the failure toast offers one-click **"Export as High instead"**.
Declined option 2 (backend Standard-from-main — our `ClipTranscoder` ladder already does small-720p).
Verified live (jobs `53421c72` failed / `a79594ea` High `2560×1440`). **⚠️ DEAD-SUB FINDING: CV flags
`…ff9a`/`…3a0d`/`…3a4b` recording main-but-not-sub — almost certainly == this session's green-tile +
`…3a0d` "Unsupported image format" snapshot symptoms (our live wall + picker stream the SUB). Reply10
asks Q-W4: camera-side (affects our live) vs recorder-side?** Letters: `…reply9.md` (CV), `…reply10.md` (us). ·
`ab57554` **responsive Live controls row** — when too narrow (unmaximized / low-res / side panel open)
the right-hand action buttons collapse MS-Office-style into a right-edge **`»` overflow menu**
(`overflowBtn` + popup with Go-back/Save/Arrange/Reset/Full-screen + Sort options). `_tbCollapsed`
compares `toolbarSpacer.x` (stable left-content width) + the right group's STABLE implicitWidths vs
`headerRow.width` — loop-free (hidden buttons keep their implicit size). Collapses the WHOLE right
group so only the ~38px `»` remains (stays reachable even with the panel eating width). Verified
collapsed + expanded on real iGPU. ·
`88950ca` **"back in time" icon** — the wall-playback button used `clip` (filmstrip); added a `history`
icon to Icon.qml (the CCW replay ring + CLOCK HANDS instead of a play triangle) and used it. ·
`49ca167` **Toggle Side Panel button** — shows/hides the Live right-hand panel (`OpsSidebar`, a
Main.qml sibling of LiveMonitor, Live-only). State `win.opsSidebarOpen` (default open) gates
`OpsSidebar.visible`. Button lives in **`TopBar`** right cluster (NOT the LiveMonitor toolbar — it
overflows its right controls at 1440 px), gated `showSidePanelToggle` (live wall only). Two-state
glyph per spec: window outline + vertical divider INSET from right (+ faint panel-region fill) = open,
divider hard against the edge = closed. `Accessible.name`/`checkable`/`checked` + Show/Hide tooltip.
Verified both glyph states + wall expands full-width when closed. ·
`22bde7d` **wall playback timer in lock-step with the picture on seek** — scrubber-click set
`player.position` instantly → `onPositionChanged` snapped `_smoothMs`/`playheadMs` to the target while
HLS buffered up to ~10 s → time chips + playhead lied about what's on screen. Fix: a `_settling` freeze
(`seekToWall` raises it BEFORE moving position) stops the 60 fps clock + guards
`onPositionChanged`/`onPlaybackStateChanged` so `_smoothMs` HOLDS; a `vout.videoSink.videoFrameChanged`
Connections (`enabled: _settling`) snaps it the instant the seeked frame renders; `settleGuard` (8 s)
fail-safe; loading bar shows during settle. Verified via `WT_WALLPERF` (held 1520 ms→snap, settles
107 ms–10.3 s). ·
`844d61f` **wall-wide loading bar on the "Go back in time" play wall** (`WallPlayback`, id `wallLoadBar`)
— play-wall analogue of `CameraTile.loadBar`: one indeterminate accent sweep (dim `#141a22` track),
anchored at the top of the transport (full width, directly below the camera grid + above the
seek/scrubber), `visible: (loading||pending) && errorText===""`. Verified via force-show screenshot. ·
`6ac4857` **Arrange tap opens the picker, never full-view** — `CameraTile.opened()` fires only from
`TapHandler{onTapped}`, whose PASSIVE grab let it fire alongside the arrange overlay's MouseArea →
tapping a cell (esp. the delegate recreated by the post-assign reconcile) popped the camera full-screen
instead of the picker. Fix: `CameraTile.tapToOpen` (default true) gates the TapHandler `enabled`;
LiveMonitor sets `tapToOpen: !arrangeMode`. Picker path (separate MouseArea) untouched. ·
`0288a96` **picker opens INSTANTLY** — profiled the "Tap to change"/right-click picker: structure was
always instant (cells pre-exist), but all ~32 go2rtc frame.jpeg thumbs RE-FETCHED on every open
(~2.7 s; `cache:true` useless — go2rtc serves fresh frames; raising the cap barely helped → go2rtc-
bound, not client). Fix: **pre-warm on entering Arrange** (tiles fetch when `arrangeMode` turns on, not
only on picker-open) + **keep-alive once loaded** (camId-keyed `_thumbLoaded`, survives delegate
recreation, not cleared on reset → every open after the 1st, Arrange or right-click, reloads 0) +
`_thumbMax` 3→6. Verified real-iGPU: pre-warm 31 thumbs in ~3 s, reopen = 0 reloads. ·
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

⚠️ **RELAUNCH the app** — running `./build/watchtower` predates HEAD; just restart it for `f99504a` (run `./run-watchtower.sh`, NOT build/watchtower — that is the leaky Qt 6.4.2 build).

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
