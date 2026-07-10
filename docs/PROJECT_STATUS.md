# Cilex Watchtower — Project Status

_Last updated: 2026-07-08. This file is the durable, crash-recoverable snapshot of
where the build is. Implementation details live in [DEVELOPMENT.md](DEVELOPMENT.md);
the design spec is `designs/design_handoff_watchtower/README.md`._

## Current status (2026-07-08 evening) — outage resolved; review-UX burst (filmstrip frame mode, ARMED freshness, calendar refresh, VIEW ISSUE fix)

- **Frame-by-frame FILMSTRIP MODE** (`c8d7023`): `F` in playback swaps the toolbar row for a
  big-thumbnail strip (current frame centered/accented, per-frame `.mmm` labels; thumbs served from
  the decoded-frame cache via `image://fcache`, store now mutex-guarded); `←/→` tap = 1 frame, HELD =
  slow→fast shuttle ramp (400→66 ms); thumb click jumps; veiled ~0.7 s warmup pre-fills; F/Esc exits.
  `WT_FRAME_MODE` dev hook. Verified live on `.201`'s same-hour footage; Windows CI green.
- **ARMED badge shows motion-event freshness** (`190176f`): `ARMED · 4m/2h/3d/now`, dot pulses on a
  fresh event, amber after >24 h eventless — the "visible movement but no events" mismatch is now
  glanceable. Per-camera last-motion tracked in EventModel (motionRev counter binding — deliberately
  no row re-paging, which restarts tile RTSP). Visual proof pending a motion-armed camera.
- **Footage calendar refreshes while open** (`e7a8cd7`): 60 s quiet re-fetch (both calendars) — the
  "recording resumed but the calendar still says Jul 1" report; verified live with today's dot.
- **VIEW ISSUE tile link fixed** (`f725784`): the signal was emitted but handled nowhere; now lands on
  Health with the camera's detail panel open; hover underline + padded hit area; strip z-raised.
- **Recording outage FULLY CLOSED (07-10)** — after the clock fix (Provisioner) a 5th fault surfaced:
  `motion/arm` without `sensitivity` had left the camera at 0 (armed-but-inert; letter UPDATE 4);
  re-armed with 50 → motion chain live within seconds (event → pre-rolled recording). **Overnight
  alert-stream survival CONFIRMED 07-10** (first office entry 10:12:55Z → event + clip after ~16 idle
  hours; recorder readiness `vmd_confirmed: true`). Also shipped: **filmstrip v2** (hidden harvester
  decoder — steps are 0 ms cache repaints both ways) and the **live MOTION tile badge** (pulsing amber
  while events register; ~5 s poll latency, SSE push = CV ask). CV closed the functions thread
  (reply3): mosaic wall gated on `playback` — wired same day (`WallPlayback` calm overlay + auto-retry).
- Windows session-2 prompt for the laptop: `docs/plans/windows-port/2026-07-08-w2w3-session2.prompt.md`.

## Current status (2026-07-07/08) — RU i18n shipped; W2 core gates green on real GPU; frame-step planned

- **Russian language support shipped** (`b452783`) — EN/RU, OS-language default (`QLocale::system()`),
  live in-profile switch (Preferences → Time & language, `QQmlApplicationEngine::retranslate()`),
  `.qm` embedded via `qt_add_translations` (LinguistTools ships in BASE Qt — not an aqt module).
  ~65 chrome strings translated; remaining screens extend incrementally (`update_translations`).
  Verified: Linux screenshots both locales + Windows CI green.
- **Windows W2/W3 advanced on the laptop session** — W2 core gates GREEN on GTX 1070 (launch, d3d11
  HW decode, live pipelines, RSS bounded; `4fd72b4`); export re-encode switched to libopenh264
  (`53b6e28`); gstd3d11 decode closure bundled (`fb15f72`); W3 soak supervisor ported to PowerShell +
  smoke-green (`91a0a0f`, `56078c2`).
- **Windows session-2 (2026-07-08) on the fresh `f725784` artifact** — W2 core gates re-baselined
  GREEN; **HW decode double-confirmed at the GPU-counter level** (Video-Decode engine busy, not just
  the log). **Frame-stepping verified on d3d11** (HEVC 1440p, `[STEPT] wrongWay=0 fails=0 back
  p50=0ms` — PTS valid, hot back-cache, VA-API parity). **RU i18n verified on Windows** (EN OS-default;
  RU `.qm` loads/renders/persists on the MSVC build). **Found + fixed a real export regression**: the
  CI bundle moved to FFmpeg 7.1.3, whose filtergraph parser rejects the single-`\:` drive-letter escape
  `ClipTranscoder::escFilterPath` emitted → every compress/burn overlay export silently failed;
  fixed to the canonical `\\:` (`bacfe48`, measured before/after on-box, CI green; a drawer re-test on
  the rebuilt artifact is still owed). **W3 overnight soak GREEN** — two clean supervised runs (7 h +
  8 h, 0 crashes / 0 hangs, RSS bounded, procdump never fired; matches the Linux bar). **Filmstrip
  mode (`F`, `c8d7023`) functionally verified** on `.201`'s fresh 07-08 HEVC 1440p footage (frame mode
  enters, FrameStepper + FrameCache step the footage; clean strip screenshot blocked only by
  remote-session input/Tailscale-veil, not a defect). **Soak tooling fix** (`b70d1e0`): the export
  sidecar re-logged undeletable 0-byte exports every sweep (474 k lines for ~520 clips) — now logs each
  clip once, on actual removal. Results: `docs/perf/2026-07-08-win-w2w3-session2-results.md`,
  `-frame-step-windows.md`, `-win-export-drawtext-ffmpeg71.md`. Remaining: export drawer re-test
  post-rebuild, Win11 box + mixed-DPI/sleep-resume eyes-on, W5 matrix.
- **`/streams` `functions.playback` split wired same-day** (CV migration 0052): playback/timeline/export
  now gate on the new `playback` key (`playbackEnabled`, fail-safe true); live tiles stay on `live_view`.
  Reply letter `docs/letters/2026-06-16-request-function-state-in-streams.reply2.md`. Verified + Windows CI green.
- **Frame-by-frame stepping researched + planned** — deep-research (25 sources, 23 verified claims):
  [`docs/research/2026-07-07-frame-by-frame-playback-vms.md`](research/2026-07-07-frame-by-frame-playback-vms.md);
  implementation plan (P0 spike → P4, ~3–4 days, on the existing QMediaPlayer stack — key constraint:
  paused seeks render nothing → play-flush primitive; TS seek imprecision → verify-after-step):
  [`docs/plans/2026-07-08-frame-step-plan.md`](plans/2026-07-08-frame-step-plan.md). **P0 spike DONE
  same day (GO):** PTS 100% valid; **paused seeks RENDER on Qt 6.12** (EvHeroPlayer's "render nothing"
  note is stale) → backward step = paused seek + PTS verify, no play/pause cycle; no keyframe snapping;
  GOP 30–60f; cameras are TRUE VFR (25/50/100 ms deltas) so PTS-exact targets are the main path.
  Findings: [`docs/perf/2026-07-08-frame-step-spike.md`](perf/2026-07-08-frame-step-spike.md).
  **P1 DONE** (`3985458`): FrameStepper + |◀ ▶| transport buttons + keys (,/./arrows/Space) + RU
  i18n; forward 100/100 exact. **P2 DONE**: FrameCache decoded-frame cache (hot back-step
  ~3400→~0 ms, ≥95 % cache hits), window-edge/disc fallbacks, alternating soaks green on both
  codecs (0 wrong-way in 260 steps) — [`docs/perf/2026-07-08-frame-step-p2-soak.md`](perf/2026-07-08-frame-step-p2-soak.md).
  **P3 DONE** (¼×/½× speeds, Shift+arrows ±5f, .mmm paused readout, freeze-frame veil). **P4 DONE**
  (stepper on the events hero; playback soak regression green). Feature CODE-COMPLETE; manual passes
  open: veil eyes-on, 5-min paused session, hero step on real footage (blocked by the recording outage).
- **🟢 RESOLVED 07-08 ~14:03 UTC — the 7-day recording outage is OVER; both cameras recording**
  (`.67` H.264 1080p continuous, `.201` HEVC 1440p via fail-safe). Four stacked faults, all identified
  (letter UPDATE 2+3: [`docs/letters/2026-07-08-recording-outage-fleetwide-since-jul-1.md`](letters/2026-07-08-recording-outage-fleetwide-since-jul-1.md)):
  (1) `.67` registry password was wrong → operator factory-reset + re-activated with `Qwerty12!`;
  (2) recorder's continuous engine only reconciles at STARTUP → `docker restart recorder-service`
  engaged `.67`; (3) `.201` motion control vetoed by `camera_clock_drift` (~3 s, camera-side; server
  NTP-true) — silent except a 3/sec log flood; (4) the fail-safe-continuous path excluded `.201`
  *because* it was armed → we disarmed it (workaround; CV API backup saved) → fail-safe records.
  **Pending: operator fixes `.201`'s clock (camera web UI) → re-arm motion (one API call).**
  CV asks filed: runtime continuous reconcile, clock-drift as health state, fail-safe for vetoed
  cameras, inventory hygiene (31 ghost cameras spawn No-route ffmpeg storms on every recorder boot).
- Open with CV: go2rtc ask-4 reply (needs product steer: `[MEMTEL]` exposure + demand-history UI);
  optional letter on CV's `/live` page black-tiles-with-valid-go2rtc-frames finding; `.67` camera
  still needs its operator power-cycle (login lockout).

## Current status (2026-07-06) — Linux client hardened; **Windows port in progress (W0/W1/W4 done, W2/W3 need a Windows GPU box)**

**Windows 10/11 port — same repo, Qt 6.12 msvc2022_64 (MANDATORY; 6.8.3 is Linux-only fallback).**
Canonical plan + phase prompts: [`docs/plans/2026-07-04-windows-port-plan.md`](plans/2026-07-04-windows-port-plan.md)
and `docs/plans/windows-port/W0..W5`. **To continue on a Windows laptop, start with
[`docs/plans/windows-port/START-HERE-WINDOWS.md`](plans/windows-port/START-HERE-WINDOWS.md).**
- **W0 done** — source made MSVC-compilable (`src/main.cpp`, `src/models/MemTelemetry.cpp` `Q_OS_*`-guarded;
  PSAPI RSS + SEH crash filter; `windows` CMake preset; `watchtower.ico`).
- **W1 done** — **`.github/workflows/windows.yml` builds `watchtower.exe` + NSIS installer on every push**
  (`windows-2022`, Qt 6.12 + GStreamer 1.26.11), artifacts `watchtower-portable` + `watchtower-setup`.
  Proved the MSVC compile/link. (4 CI fixes: aqt git-master for Qt 6.12 layout; GStreamer `/a` extract;
  Qt-owns-manifest; `gst*.dll` plugin names.)
- **W4 done** — per-user installer + LGPL notices/SOURCES + CI compliance check; **signing = unsigned
  (internal)**, `packaging/windows/SIGNING.md`.
- **W2 + W3 PENDING — need a physical Win10/11 GPU box on the LAN.** Prep done: runtime audit (decode is
  decodebin-rank-based → auto d3d11, no code change; fixed ClipTranscoder Linux fonts+escaping; FLAGGED:
  compress/burn uses `libx264`, absent from the LGPL ffmpeg → switch to `h264_mf`/`libopenh264` on-box),
  turnkey `packaging/windows/w2-bringup.ps1` + `docs/plans/windows-port/W2-RUNBOOK.md`. W5 = GPU matrix (last).

**Linux client hardening (2026-07-02–03) — shipped on Qt 6.12 (now primary, `build/`; 6.8.3 fallback `build68/`).**
- **HANG #1 root-caused + fixed** (`d81d887`): the rare "GUI wedge" was a **minutes-long QML GC on the GUI
  thread** (Qt ≥6.10), triggered by marshalling thousands of per-fragment QVariantMaps in `PlaybackClient::
  sessionReady`; fixed by shipping fragments as positional primitive rows. Validated 2.5 h, 0 wedges.
- **Far-seek coalescing** (same commit) — chaotic scrubber clicks no longer storm session re-opens
  (one in-flight open, last click wins); after-burst dead-video p90 5.8 s→0.9 s.
- **Transient-empty-manifest retry** — a fresh day-open that returns 0 fragments (backend blip) retries once
  before the "No footage" error. Backend letters: `docs/letters/2026-07-03-*`. Full write-up:
  `docs/perf/2026-07-03-night-soak-gui-wedge.prompt.md`. Earlier crash + TTFF fixes: `docs/perf/2026-07-02-*`.

## Current status (2026-06-25) — 🔴→🟢 P0 RESOLVED: the recurring "Terminated" crash was a Qt 6.4.2 VideoOutput memory leak; fixed by building on Qt 6.8.3 (verified leak-free)

**P0 — live-video memory leak / OOM crash (RESOLVED via Qt upgrade).** The operator's repeated
"Terminated" was earlyoom SIGTERM-ing watchtower at ~9 GB RSS — a per-frame leak in Qt 6.4.2's
QtMultimedia `VideoOutput` (~260 MB/s on a 9-tile wall → OOM in ~30 s). Bisected and proven to be Qt,
not our code (leaks on all RHIs + both video sources; no client render path avoids it on 6.4.2).
**Fix: build/run on Qt 6.8.3** (installed user-space at `~/Qt/6.8.3`, launched via `./run-watchtower.sh`)
— app source unchanged; **verified leak-free** (cap-9 wall, 90 s, RSS flat ~950 MB). 6.8.3 also fixes
the earlier Qt 6.4.2 GridLayout maximize/minimize SIGSEGV. See DEVELOPMENT.md → Build / Gotchas.

## Earlier (2026-06-25) — Q-CV6 FIXED (CV `b002010`, verified both sides); 3 dead-sub cameras flagged (likely == our green-tile/snapshot symptoms)

All P1–P6 complete; this section is the live edge. **Relaunch `./build/watchtower` to run HEAD.**

**Export quality + client-side compression — shipped + verified; one open backend bug (aged-window Standard export still delivers 1080p — Q-CV6, CV's court).**
- Export drawer: **Quality** (High = HEVC 1440p main original / Standard = H.264 sub) with
  grey-out+tooltip when the original has aged out; a **Compression** ladder (Original/1080p/720p/480p,
  ≥-source greyed); functional **overlay burn-in** (default off = pristine).
- CV (migration `0045`): `CreateExportRequest` takes `hevc_capable`; fragments carry `stream_type`
  (`main`/`sub`) = authoritative rendition (orthogonal to `tier`). Verified: High→2560×1440,
  Standard→1920×1080 (720p sub at the 1080p profile). High over an aged span → 422 (surfaced).
- **`ClipTranscoder`** (`src/models/ClipTranscoder.{h,cpp}`): local ffmpeg/libx264 — downscale ladder +
  burned-in camera caption and **per-frame footage wall-clock** (`drawtext %{pts:localtime:…}`). Wired
  via `PlaybackClient::createExport(…, hevcCapable, post{height,timestamp,name,label,startEpochMs,durationMs})`.
  **A2 (server overlay burn-in) retired** — overlays are client-side now.
- **DONE (2026-06-21):** CV shipped the native-720p Standard rendition (`h264-main-720p`; reply5,
  Q-CV5/Q-W1/Q-W2 all yes). Client label flipped — drawer reads **"Standard · 720p"** (`sourceHeight`
  1080→720), no-upscale ladder now offers Original + 480p. **Verified live from our side:** a
  fresh-window Standard export reports `resolution 1280x720` (~747 KB/8 s), and the playback manifest
  shows `delivery_profile h264-main-720p` for every sub fragment. **Q-CV6 — FIXED (CV `b002010`, reply9; verified
  both sides 2026-06-25).** Root cause was *not* a stale rendition or window age: that 1080p "clip" was a
  **black-fill** — cam `…ff9a`'s **sub-stream stopped recording 06-11**, so a Standard (sub-only) export of a
  06-18 window had an all-`no_recording` manifest, and the export worker black-filled the whole window at a
  hardcoded `h264-main-1080p` default → an 8.8 KB black clip mislabeled `ready`. CV now **fails honestly** when a
  window has zero footage in the selected quality. Verified from our side: Standard over `…ff9a` →
  `state=failed` (`error_msg` = "…try a High export"), no artifact; High over the same window → `ready
  2560×1440 1.18 MB`. The `error_msg` field is what our poller reads, so it surfaces verbatim.
  **Client (option 1) shipped:** the failure toast offers one-click **"Export as High instead"**
  (`PlaybackClient.retryLastExportAsHigh()` + a ToastHost callback action). Option 2 (backend
  Standard-from-main) declined — our local `ClipTranscoder` ladder already does small-720p-from-main.

  **NEW open thread — 3 dead-sub cameras (recording-side, CV investigating; likely == our green-tile/snapshot
  symptoms):** CV found `…ff9a` (sub last 06-11), `…3a0d` (06-19), `…3a4b` (06-24) recording **main but not
  sub**. `…3a0d` is the camera whose go2rtc `frame.jpeg` snapshot throws "Unsupported image format" in our
  picker, and dead subs are exactly what produce the green/stalled live tiles we've been patching. **Open
  question to CV (Q-W4): camera-side (affects our live wall + picker, which stream the sub) or recorder-side
  (recording only)?** Plus Q-W5 (ETA to restore subs) and Q-W6 (a structured `failure_reason` code so our
  option-1 trigger isn't prose-matched). Thread:
  `docs/letters/2026-06-20-export-quality-and-client-side-compression.reply{9,10}.md`.

**Other this arc:** green-wall fixes (reconciled camId-keyed `gridModel` → no tile rebuild on
poll/relayout; see DEVELOPMENT.md gotcha); brighter scrubber ruler + dated playhead watermark;
**removed the dead camera-tile bookmark** (cameras = ★ only; bookmarks are Events-only); a **layout
preset now exits the transient map-selection scope** (+ a "✕ Clear selection" chip).

**Relayout/OOM freeze — FIX SHIPPED `51f528d` (2026-06-22), awaiting live confirm.** The host froze
~20 s and the app was OOM-killed during camera-change churn (Arrange → Tap-to-change → Esc, repeated):
the shared Intel `i915` iGPU wedged on a burst of ~16 simultaneous VA-API decode-context creations,
on a box already swap-thrashing (6.9 GiB). Fix is load-spreading: a **global pipeline-build rate
limiter** (`PipelineBuildPump`, ≤1 build/120 ms; `rebuild()` no longer builds inline), **keeping grid
pipelines alive in Arrange** (no teardown/rebuild churn), and **gating the picker thumbnails** on the
picker being open. Teardown stays capped at 8 concurrent. Build-stagger verified offscreen; the freeze
itself only reproduces on the real iGPU, so **needs a live test** (Arrange/Tap cycling, layout
changes, page turns) — recommend a reboot first to clear swap. Diagnostic scripts remain on the host
(`~/freeze-watch.sh`, `~/freeze-snapshot.sh`); `sudo dmesg | grep -iE 'oom|i915|gpu hang'` would
confirm OOM vs GPU-hang. Backend asks open: only the non-blocking [Q-CV6 aged-export bug](letters/2026-06-20-export-quality-and-client-side-compression.reply8.md) (CV's court).

## What this is

A **native Ubuntu Qt6/QML/C++ surveillance VMS operator client** (not a browser app),
a client of the **cilex-vision** platform. The hard requirement is smooth GPU
decode/compositing of up to 16 live RTSP H.264/H.265 streams plus playback scrubbing.
Cameras have **no on-camera storage**; recorded footage and events come from cilex-vision.

## Phase status

| Phase | Scope | State | Key commit(s) |
|-------|-------|-------|---------------|
| P1 | Foundation + Live Monitor (16-stream wall, app shell, models) | ✅ done | (early history) |
| P2 | Single Camera Detail (S05) | ✅ done | `04abd30` |
| P3 | Playback + timeline (S06) | ✅ done | `e340c30` |
| P4 | Export + snapshots (export drawer + confirm modal) | ✅ done | `a3b567e` |
| P5 | Events + Health | ✅ done | `d1ad10f` (Health), `9d22db6` (Events) |
| P6 | Saved Views / Clips / Prefs / polish | ✅ done | all four pieces shipped |

## Done — highlights

- **Live Monitor**: 1/4/9/16 grids, paging, filters, status-first sort, tile hover actions, fullscreen. Real HW-decoded video via QtMultimedia (VA-API).
- **Single Camera Detail (S05)**, **Camera Groups (S03)**, **Preferences (snapshot folder, default stream quality)**.
- **Playback (S06)**: `PlaybackClient` + `HlsProxy` + `PlaybackScreen.qml`. Real recorded HLS from cilex-vision plays through a local auth proxy; manifest-driven timeline (footage/gap coverage), transport, zoom presets.
- **Export (P4)**: full `ExportDrawer.qml` (440px drawer + centered confirm modal) — preview, KV facts, `HH:MM:SS.mmm` range editors, options, required Purpose, gap-warning ribbon.
- **Health (P5)**: `HealthScreen.qml` — 6 stat cards over `CameraModel` counts + filtered camera table + 380px detail panel, plus a storage-subsystem status strip (`StorageHealth` → `GET /health/storage`).
- **Events (P5)**: `EventsScreen.qml` (filter pills + table + detail panel) + `EventModel` wired to the live `GET /events` feed; locally-persisted acknowledge.

## Open backlog

Prioritized — with blocked-status, owners, and what unblocks each — in
**[BACKLOG.md](BACKLOG.md)**. Backend contracts (our asks + Cilex Vision's
point-by-point responses) are in the API-requests letter. In short: every **P1**
item is backend-gated (Events pipeline B2, real export/clips metadata A1/A3/A6,
shared ack B1); the **🟢 actionable-now** items are client-side polish (theme
switching, same-group playback switch, `compact` mode toggle, event-drawer
export/filters).

## P6 progress

- ✅ **Saved Views** — `SavedViewsScreen.qml` (3-col card grid + filter pills) + `SaveViewModal.qml`. `SavedViewModel` now persists views in QSettings (restorable layout/filter/group), with `saveCurrent`/`remove`/`touch`/`toggleFavorite`; mock gated behind `WT_DEMO` (was unconditional). Card counts computed live via `CameraModel.countFiltered`. "Save current view" wired from Live Monitor + the screen; Open applies a view to the Live Monitor.
- ✅ **Preferences completion** (§9) — Workspace (Default landing: Live / saved view / group, applied on boot), Time & language (24h/12h, wired to the now-live top-bar clock + playback), Alerts (sound + desktop-notification toggles, persisted; alert-firing pipeline deferred). Settings gained `defaultLanding`/`time24h`/`alertSound`/`desktopNotifications` + a `clock()` formatter. Light/Dark theme switching deferred (`Theme` is a static singleton). Also fixed the static "17:42" top-bar clock → live + real tz.
- ✅ **Command palette (Ctrl+K)** (§10) — `CommandPalette.qml`: center-top 680px overlay searching cameras / groups / saved views / events over the existing models; grouped results with thumbs + live/rec badges, keyboard nav (↑↓/↵/Esc), footer count. Opens via Ctrl+K and the top-bar search. Activating navigates (camera→detail, group→filtered live, view→apply, event→events). Clips omitted (no enumerable source yet).
- ✅ **Clips & Snapshots library** (§296–304) — `ClipsScreen.qml` + `SnapshotModel` over the local Artifacts dir; artifact table + detail panel (real image preview) + Open / Reveal-in-folder; reached via the command palette (nav rail has no Clips item, per design). Server-exported clips pending the backend list endpoint (letter §A6).

**P1–P6 are all complete.** Remaining work is backend-gated (the API-requests letter) + optional polish/deferred items below.

## Events screen redesign (events-v2) — done (design port, behind `WT_DEMO`)

A faithful Qt6/QML 1:1 port of the `designs/events-v2` HTML/React prototype — the
re-imagined Events area as **four views over one shared store**, built to the four
spec files (`triage-queue-spec.md`, `verify-screen-spec.md`, `timeline-screen-spec.md`,
`map-screen-spec.md`). Commits `7df90aa` → `d09e397`.

- **Shared store** `EventsStore.qml` (singleton): the events-v2 mock domain (20
  events, cameras/types/dispositions) + the only mutators every view uses —
  `ack` / `bookmark` / `dispose` — so OPEN/CRITICAL/CLEARED counts and the same
  event update across all views live. Procedural `EvSnapshot` (CCTV still: AI box,
  tod scene, tamper/offline, OSD) is the only "video"; all icons/glyphs via Qt Quick
  Shapes (no SVG plugin). Primitives: EvIcon/Sev/TypePill/StateTag/EvButton.
- **EventsArea** shell: 01–04 mode switcher + rationale + live status strip; stage
  hosts the views via a Loader.
- **01 Triage** (`EvTriage` + `EvPlayer`): 384px priority list + detail pane that
  plays the clip inline (transport + seekable scrubber w/ event window), facts grid,
  per-type SOP checklist, disposition note, action bar.
- **02 Verify** (`EvVerify`/`EvWall`/`EvSessions`): Wall (S/M/L card grid, hover
  preview, Threat/Dismiss) ⇄ Smart Sessions (zone-grouped, bulk bar), contextual
  toolbar.
- **03 Timeline** (`EvTimeline`): per-camera swimlanes, duration bars, markers,
  click-popover, dashed "now" line, 90m/3.5h/8h windows.
- **04 Map** (`EvMap`): schematic site plan + pulsing camera pins + count badges +
  legend; live-feed rail ⇄ per-camera detail (Verify/Dispatch/Clear).
- **Integration / data source:** `EventsStore` has two sources — `loadMock()` (the
  showcase) and `ingestReal(rows, camLookup)` (live `/events`). **The redesign is now the
  DEFAULT Events screen** (cutover done `d4490d6`). Flags (`src/main.cpp`): **`WT_DEMO`** →
  redesign on the mock showcase; **`WT_EVENTS_LEGACY`** → the old table-style `EventsScreen`
  (instant fallback). Inline hero playback, real frames, real Map, Assign/Export all live.
  Stable task tracker: `docs/events-redesign-tasks.md`.
- **Real-data foundation (done 06-18, `614148d`):** real `/events` mapped honestly via
  `EventsStore.ingestReal`; `EventModel` exposes `durationMs` + `recordingId`.
- **Backend contract shipped + wired (done 06-18, `233229b`):** Cilex Vision shipped all
  five asks (their `…-events-redesign-shipped.md`, backend `44f7bd8`/migration 0042).
  `EventModel.parseRow` now reads `severity`, `triage_state` (NOT `state`), `disposition`,
  `disposition_note`, `bookmarked`, `zone_restricted`, `detection{class,confidence,bbox}`,
  `camera_name`, `zone`; `acknowledge/disposition/bookmark` POST to `/events/{id}/…` and
  swap in the returned row (WT_DEMO keeps a local fallback). `ingestReal` maps real
  severity→priority, triage_state→status, etc.; `actionsPending` is now **false** (actions
  live). Today all events are `severity:low` / `detection:null` (motion-only) — critical/high
  + AI box light up with no rework when smart events/AI land.
- **Follow-up asks shipped + consumed (done 06-18, `2ced7d8`):** Cilex Vision shipped §1–§3
  (their `…-followups-shipped.md`, backend `76dd398`/migrations 0042+0043). (1) **in_progress**
  mapping fixed — `verified`/`dispatched`→`in_progress`; no client change (`_triageToStatus`
  already maps it). (2) **Assign** — `EventModel.assignEvent` + `fetchOperators`
  (`GET /operators`); the Triage "Assign" button is now a real operator picker; events read
  in_progress when assigned. (3) **`PATCH /cameras/{id} {restricted}`** shipped admin-only —
  we accepted admin-only (it's camera policy; redesign only reads `zone_restricted`).
  - **§4 Camera Map** (their `maps`/`map_objects`, migration 0040) is the real per-camera
    site-plan source — we'll **consume it** (dropping the grid-fallback / our own store).
    Asked for the `GET /maps/entities/cameras/{camera_id}/placement` reverse-lookup; will
    grid-fallback the ~28 unplaced cameras; default to the active plan. See reply
    `…-followups-shipped.reply.md`.
- **Imagery part 1 — real event frames (done 06-18, `52114e1`):** `CvImageProvider`
  (authenticated async image provider, `image://cvframe/…`); `EvSnapshot` shows the real
  event-moment frame (`GET /events/{id}/snapshot`) under the OSD in real mode, honest
  "NO FRAME AT EVENT TIME" on 404; mock keeps the procedural still.
- **Situation Map on the real Camera Map (done 06-18, `9bf148d`):** `SiteMapModel` fetches
  CV's active plan + placements (`/maps?status=active`→`/maps/{id}`→`/maps/{id}/objects`);
  `EvMap` real mode draws the real floor plan (pre-signed `background_url`) + camera pins at
  `(x_norm·W, y_norm·H)` with an "N of M placed" note (2/31 today). Mock keeps the schematic.
  CV closed the Events **backend** workstream (their `…-unassign-and-placement.md`; unassign
  now reverts to `acknowledged` — no client change needed).
- **Next (not built):**
  - **Imagery part 2** — real HLS playback in the Triage hero (reuse `/review/sessions`;
    isolated `PlaybackClient`; the *stable* QtMultimedia path). Needs interactive verification
    (offscreen can't screenshot live video).
  - Wire the **Export clip** toolrow button; then **production cutover**.

## Recovery pointers

- Build/run/verify, dev hooks, architecture, API contract, gotchas → [DEVELOPMENT.md](DEVELOPMENT.md).
- Each commit message is written as a context-restoration anchor (`git log` reads like a build journal).
- Design spec of record: `designs/design_handoff_watchtower/README.md` + `design/watchtower.html`.
