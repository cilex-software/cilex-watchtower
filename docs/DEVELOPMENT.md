# Cilex Watchtower — Development & Implementation Notes

_Durable implementation reference. Pairs with [PROJECT_STATUS.md](PROJECT_STATUS.md)._

## Stack (locked)

- **UI**: Qt **6.12** (primary) / **6.8.3 LTS** (fallback) + Qt Quick / QML (GPU scene-graph compositing). Ubuntu 24.04's system Qt **6.4.2 is BANNED** — the CMake floor is 6.8, so it can't even configure (it has a QtMultimedia libsoup-SIGSEGV on playback seeks, a VideoOutput memory leak, and a GridLayout SIGSEGV — see Build and Gotchas). The React prototype in `designs/` is recreated **visually** in QML — JSX is not reused.
- **Core**: C++17.
- **Video**: QtMultimedia `MediaPlayer` + `VideoOutput` (QML) on Qt's **FFmpeg** media backend (default ≥6.5; FFmpeg 7.1.x), **VA-API HW decode** (confirmed on Intel Alder Lake-S iGPU, iHD driver). The opt-in low-latency LIVE path (`RtspVideoSource`) drives a custom GStreamer pipeline; recorded PLAYBACK uses the FFmpeg backend. See "qml6glsink" gotcha below.
- **Persistence**: two stores — `QSettings` (INI) for small operator state (prefs, event acks, saved views), and **SQLite** via `CameraStore` for the local camera inventory at `<AppDataLocation>/Cilex Vision/Watchtower/watchtower.db`. Groups, events, and footage are not persisted locally — they come live from cilex-vision.
- **Network**: `QNetworkAccessManager` (Qt6::Network) for cilex-vision auth + APIs.
- **Build**: CMake + Ninja.

## Build / run / verify

> **Windows build/run** lives separately — CI builds `watchtower.exe` + an installer on every push
> (`.github/workflows/windows.yml`); the toolchain + deploy notes are in `packaging/windows/README.md`,
> the port plan in `docs/plans/2026-07-04-windows-port-plan.md`, and the on-hardware session bootstrap
> in `docs/plans/windows-port/START-HERE-WINDOWS.md`. The rest of this section is the Linux build.

> **ALWAYS launch with `./run.sh`** (alias of `./run-watchtower.sh`). It pins the Qt runtime env and
> runs `build/watchtower`, building it first if missing. The primary toolchain is **Qt 6.12**; the
> system Qt **6.4.2 is banned** (CMake floor 6.8 → it hard-fails `find_package`). Even a correct binary
> doesn't pin its own Qt — without the launcher's `LD_LIBRARY_PATH` it loads whatever `libQt6*.so` the
> linker finds — so the launcher is mandatory. A red banner appears on the Playback screen if a <6.5
> runtime is ever detected.
>
> Install Qt user-space once, then build via presets:
> ```bash
> python3 -m venv /tmp/aqtenv && /tmp/aqtenv/bin/pip install aqtinstall
> /tmp/aqtenv/bin/aqt install-qt linux desktop 6.12.0 linux_gcc_64 \
>     -m qtmultimedia qtshadertools qttasktree -O "$HOME/Qt"      # ~2 GB; pulls the wayland plugins
> cmake --preset default && cmake --build build   # Qt 6.12 → build/   (primary)
> ./run.sh
> ```
>
> **Fallback — Qt 6.8.3 LTS** (the 8.8h-soak-validated runtime; kept as a safety net because 6.12
> fixes nothing on the residual per-open decode leak, ~+2 MB/min vs 6.8.3):
> ```bash
> /tmp/aqtenv/bin/aqt install-qt linux desktop 6.8.3 linux_gcc_64 -m qtmultimedia qtshadertools -O "$HOME/Qt"
> cmake --preset qt68 && cmake --build build68           # Qt 6.8.3 → build68/
> WT_QT_PREFIX="$HOME/Qt/6.8.3/gcc_64" WT_BUILD_DIR=build68 ./run.sh
> ```

Both use Qt's FFmpeg media backend (which fixed the 6.4.2 playback crash). Build floor / AOT / offscreen
caveats:
- **CMake floor is 6.8** (`find_package(Qt6 6.8 REQUIRED)` + `qt_standard_project_setup(REQUIRES 6.8)`).
  Configuring against system 6.4.2 fails with *"not compatible with requested version 6.8"* — by design.
- **Qt 6.12's `qmlcachegen` SIGSEGVs in the AOT C++ codegen pass** on `qml/Main.qml` (valid QML — 6.8.3
  compiled it fine; a 6.12 tool regression). CMake auto-sets `--only-bytecode` for Qt ≥6.12 (keeps the
  QML *bytecode* cache — startup stays fast — only AOT binding-compilation is skipped; the app is
  identical). `-DWT_ENABLE_AOT=ON` re-enables it once a fixed Qt ships.
- **Qt 6.12's `offscreen` QPA SIGBUSes** under playback/calendar churn (intermittent; ~1 per 30 actions).
  It is **offscreen-only** — real Wayland ran 77 churn actions clean (6.8.3 offscreen also clean, 168
  actions). So for headless smoke/screenshots on 6.12, either run on **Wayland** (below) or use the
  **6.8.3 `build68`** binary for offscreen checks. Doesn't affect real use.

- **Headless smoke test** (offscreen): `QT_QPA_PLATFORM=offscreen timeout 6 ./build68/watchtower`
  — exit **124** (timeout killed it) = QML loaded fine; exit **255** = a load/QML error on stderr. Grep for `.qml:` / `warning` / `Unable to assign` / `Non-existent`. (Use `build68`, not `build`, to avoid the 6.12 offscreen SIGBUS.)
- **Screenshot to PNG** (env-gated hook in `main.cpp`):
  `WT_SCREENSHOT=/tmp/x.png WT_SCREENSHOT_MS=1500 QT_QPA_PLATFORM=offscreen timeout 12 ./build68/watchtower`
  — renders the window then quits; read the PNG back. The standard visual-verification path. On a real
  Wayland session (`WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000`) the 6.12 `build/` renders fine.

## Versioning — automatic, one version per commit

**Operator decision 2026-08-12: every commit that lands on GitHub gets its own
version.** The PATCH component increments and nothing else: 1.1.1, 1.1.2,
1.1.3 … Major and minor never move on their own — they change only when the
operator explicitly says so.

`project(VERSION x.y.z)` in `CMakeLists.txt` is the ONE source of truth. It
reaches the UI as `WT_VERSION` → the `wtVersion` context property → the number
beside the git hash in the top-left corner. The four Windows spots
(`watchtower.rc` ×4 fields, `installer.nsi`, `app.manifest`) are **derived**,
never hand-edited.

Enforced by a tracked `pre-commit` hook. **Each clone must opt in once** — hooks
are not distributed by git:

```
git config core.hooksPath tools/git-hooks
```

Do that in the Windows checkout too, or commits from that box will reuse a
version number. Verify with `tools/bump-version.sh --print`.

- `tools/bump-version.sh` — bump patch, rewrite all four files, print the new version
- `tools/bump-version.sh --set 1.2.0` — explicit major/minor change
- `WT_NO_BUMP=1 git commit --amend` — **required when amending.** Amend re-runs
  the hook and would otherwise bump twice for one logical change.

Merges, rebases, cherry-picks and reverts are skipped automatically: the version
already travelled with the commit.

**Both agents bumping the same line will conflict** when the Windows agent's
`win/<topic>` branch meets `main`. The conflict is always in
`CMakeLists.txt:4` plus the packaging files, and the resolution is always "take
the higher number, then re-run `tools/bump-version.sh` if the result collides
with a version already pushed."

## Dev hooks (environment variables)

| Var | Effect |
|-----|--------|
| `WT_DEMO=1` | Use the mock dataset (cameras + events). **Off by default** — real persisted data is the source of truth. Mock is dev-only. |
| `WT_SECTION=live\|groups\|events\|health\|…` | Boot directly into a nav section. |
| `WT_FOCUS_IP=<ip>` | Boot into Single Camera Detail for that camera. |
| `WT_TABS=<ip>[,<ip>…]` | Open those cameras as **view tabs** on boot (`WT_TABS_HOME=1` then returns to the main tab — the state that proves tabs outlive going back to the wall). |
| `WT_TABS_TEST=1` | Headless self-test of the view-tab bookkeeping against the shipping functions — logs `[TABTEST]` per assertion, then `PASS`/`FAIL`, and quits. Run it after touching `openCameraHere`/`openCameraTab`/`activateTab`/`closeTab`. |
| `WT_FLIGHTREC_OFF=1`, `WT_FLIGHTREC_DIR`, `WT_FLIGHTREC_BYTES`, `WT_FLIGHTREC_KEEP` | Flight recorder (Warden CW-01): every Qt log line is teed to rotating files in `<AppData>/flightrec/` (default 10 MB × 5) — the raw material Warden bundles after a crash. Console/journald output is untouched (previous handler chained). Off/dir/size/count knobs; lines are flushed to the kernel per write, so they survive SIGKILL (verified). `WT_FLIGHTREC_OFF` also disables the CW-02 module snapshots (`modules.txt`/`maps.txt`, 30 s on-change) but NEVER the crash marker — `<AppData>/crash/marker-<report_id>.json` is armed unconditionally. |
| `WT_HOVERSHOT=1` | Forces the playback scrubber's hover preview at ~62% of the view once the timeline is live — deterministic screenshot verification of its placement (the card must float ABOVE the track, never cover it; operator report 2026-07-28). Pair with `WT_PLAYBACK_IP`+`WT_PLAYBACK_DAY`. |
| `WT_MERGE_TEST=seed\|verify` | Merged-cells self-test (Live wall cell spans): `seed` drives select(1,1→2,2)+merge on a 4×4 and quits; `verify` in a new process asserts persistence (13 slots, region at slot 5), then splits and asserts 16 slots restored. `[MERGETEST] PASS/FAIL`. Run after touching `_spanCells`/`mergeSelection`/`splitAt`/slot math. |
| `WT_RESTORE_OFF=1`, `WT_RESTORE_TEST=seed\|verify` | View-state persistence (Warden CW-05): on a clean operator boot the shell state (section/layout/group/page/sort, open tabs, focused camera) persists debounced+`sync()`ed and restores on launch (≤24 h old; camera ids re-resolved against the roster, playback deliberately NOT resumed). Any boot-shaping dev hook (`WT_SECTION`, `WT_TABS`, soaks…) makes the run ineligible so synthetic states never overwrite the guard's real view. `seed`/`verify` = two-process self-test (`[RESTTEST] PASS`). |
| `WT_PLAYBACK_IP=<ip>` | Boot into Playback for that camera. (`WT_PLAYBACK_DAY=yyyy-MM-dd[Thh:mm:ss]` opens a specific day / instant.) |
| `WT_TTFF_DAYS=d1,d2,…` | Playback open-latency harness: opens each day in turn, logs `[TTFF]` (calendar-click → first rendered frame) + `[PBTIME]` stage breakdowns, quits. Pair with `WT_PLAYBACK_IP`. `WT_TRACE=1` alone also enables the `[PBTIME]` logs. |
| `WT_FRAME_MODE=1`, `WT_PB_MARK=1`, `WT_PB_LADDER=1` | Playback "One Axis" state hooks — auto-enter frame-by-frame once footage renders; mark an export range; open the speed ladder. They drive the REAL controls, so a verification screenshot shows shipped behaviour. |
| `WT_PB_EXPORT=1\|2\|3\|4` | Filmstrip-blank repro (2026-08-10). Needs `WT_FRAME_MODE=1 WT_PB_MARK=1`. `1` = open the export drawer over a 10 s marked range (**no backend write**); `2` = also confirm it (**ONE real export job**); `3` = force a far-seek session re-open under frame mode; `4` = press play under frame mode. With `WT_TRACE=1` each run prints `[STRIP] lit=n/9 pts=… cache=…f …` three times a second — `lit` is the number of filmstrip slots that resolve, and it is the whole measurement. |
| `WT_TEST_IP=<ip>` | Restrict live streaming to one camera during dev (avoid hammering cameras — see lockout caveat). |
| `WT_CAMERAS=<provisioning.json>` | One-time bootstrap import into an empty camera store. |
| `WT_SCREENSHOT=<path>`, `WT_SCREENSHOT_MS=<ms>` | Screenshot hook (above). |
| `WT_CV_URL`, `WT_CV_USER`, `WT_CV_PASS` | cilex-vision backend base URL + credentials (dev defaults baked in source; override via env). |

## Architecture

- **`src/models/`** — C++ models exposed to QML:
  - `CameraStore` — SQLite-backed camera inventory; upserts by **MAC** (device fields refresh, operator-set name/favorite/order preserved across re-imports). The `group_id` column is vestigial — group membership comes from the cilex-vision `/streams` API at runtime, not SQLite. `ProvisioningImport` parses a Cilex Provisioner JSON export.
  - `CameraModel` — `QAbstractListModel` over the store; live status counts (`onlineCount`/`offlineCount`/`degradedCount`/`notRecordingCount`/`recordingGapCount`), `page(group,statusFilter,sort,…)`, `cameraByBackendId(camera_id)` (resolve cilex-vision id → local camera by MAC). Status filters: `online/offline/degraded/recording/notrec/gap/favorites/issues/recent`. Sort modes: `live` (online first, offline last — the Live-wall default), `ip`, `default` (stream order), `status` (problems first), `alpha`. On the Live wall, `live` also floats online cameras ahead of a saved manual arrangement (order preserved within each tier); pick another sort to get the exact manual order back.
  - `EventModel` — events feed: live `GET /events` (own authenticated session) or `WT_DEMO` mock; roles for the ops sidebar; `all()` (maps for the Events screen); acknowledge persisted locally in `QSettings["eventAcks"]`.
  - `PlaybackClient` + `HlsProxy` — cilex-vision recorded playback (see below).
  - `GroupModel`, `SavedViewModel` (persisted views), `SnapshotModel` (lists the local snapshot dir for the Clips library), `StorageHealth` (authenticated poll of `GET /health/storage`), `Settings`, `Artifacts` (snapshot dir), `MockData` (WT_DEMO).
- **`qml/`** — screens (`Main`, `LiveMonitor`, `SingleCameraDetail`, `PlaybackScreen`, `ExportDrawer`, `HealthScreen`, `EventsScreen`, `PreferencesScreen`, `CameraGroups`) + components (`Theme` singleton tokens, `Icon`, `IconButton`, status badges, `PlaceholderVid`, `VideoSurface`, `Toast`/`ToastHost`).
- **`Theme.qml`** — design tokens (warm graphite palette, amber accent, Space Grotesk + JetBrains Mono, 4px spacing, 0-radius geometry). Match the handoff exactly.
- **Window chrome is ours (`TitleBar.qml`, frameless `Window`)** — the handoff's 36px title bar was drawn as "generic OS-style, replaced by host", but the host chrome under GNOME/Wayland is Qt's own `bradient` decoration, which paints a title with **no usable minimize/maximize/close buttons**. So `Main.qml` sets `Qt.FramelessWindowHint` and `TitleBar.qml` draws the designed bar (wordmark · current view · three round buttons). Move/resize are handed back to the compositor with `QWindow::startSystemMove()` / `startSystemResize()` (both are `Q_SLOTS`, so QML can call them): the title bar starts a move past a 3px threshold — starting on press would eat the double-click-to-maximize — and `resizeFrame` in `Main.qml` lays 4px edge / 14px corner grips over the shell. Consequence to keep in mind: the outermost 4px of the window is a resize handle, not content.
- **View tabs (`TabStrip.qml`)** — `Main.qml` owns `tabs` / `activeTab` / `mainTabCamera`. `tabs[0]` is the main tab (the nav-rail section, which may hold a camera opened **in place** — `openCameraHere`); `tabs[1..]` are cameras opened with a tile's "Open in new tab" (`openCameraTab`), which is what makes that action differ from "Open". Only the ACTIVE tab renders, so N tabs never mean N live pipelines — a background tab is a camera reference, and `activateTab` re-resolves it against `CameraModel` so it carries current status/urls. The strip only exists while a camera tab does (and hides during playback). Regression-test the index math with `WT_TABS_TEST=1`.

## cilex-vision integration

Backend at `WT_CV_URL` (FreeText, FastAPI; `/openapi.json` is the schema). `/api` is the
Next.js browser proxy prefix — backend routes are unprefixed (`/review/…`, `/events`, …).

- **Auth**: cookie-only. `POST /auth/login {username,password}` (from `WT_CV_USER`/`WT_CV_PASS`) → session cookie in the shared cookie jar, sent on every request incl. HLS segments.
- **Playback**: `POST /review/sessions {camera_id, wall_start, wall_end, hevc_capable:true}` → inline `manifest` (fragments with wall/compact times, codec/resolution/tier, availability). HLS `playlist.m3u8` + `seg/{idx}.ts`. `camera_id = "hiwatch-" + mac_hex`.
  - **`HlsProxy`**: Qt 6.4 `QMediaPlayer` can't attach auth headers, so a loopback proxy injects the cookie, rewrites `/api/review/`→`/review/`, **strips `#EXT-X-GAP`** placeholder segments (v1 `hlsdemux` 404s on `gap-N.ts`), keeps `#EXT-X-DISCONTINUITY`, and retries `503` (cold fragment remuxing sub-second).
- **Export**: `POST /review/exports {camera_id, wall_start, wall_end, mode}` → poll `GET /review/exports/{id}` → `download_url` (proxied). _Only those 4 fields accepted; no list endpoint — see `docs/letters/watchtower-to-cilex-vision-api-requests.md` (§A)._
- **Events**: `GET /events` (rich filters) → `EventListResponse{events,total,offset,limit}`; `EventResponse{event_id, event_type, camera_id, start_time, state, clip_url, metadata, …}`. _No acknowledge endpoint; feed currently empty — see the API-requests letter (§B)._

## Gotchas & caveats (don't regress)

- **Qt 6.4 resource prefix**: `qt_add_qml_module` defaults to `/<URI>`, not `/qt/qml/`. We pin `RESOURCE_PREFIX "/qt/qml"` so `main.cpp` loads `qrc:/qt/qml/Watchtower/qml/Main.qml`. `loadFromModule()` doesn't exist in 6.4 — load by URL.
- **qml6glsink doesn't work** on Ubuntu 24.04's `gstreamer1.0-qt6` 1.24.2 (the `Qt6GLVideoItem` QML type never registers). We use **QtMultimedia** instead (verified VA-API HW decode). Don't reintroduce the direct-qml6glsink path without re-checking.
- **Qt 6.4.2 is BANNED (CMake floor 6.8) — it has three fatal bugs; primary is 6.12, fallback 6.8.3 (see Build).** (0) QtMultimedia's GStreamer backend SIGSEGVs in libsoup-3.0 on recorded-playback seek/day-switch churn (the P0). (1) QtMultimedia `VideoOutput` leaks ~one frame-buffer per rendered frame: bisected to `m_sink->setVideoFrame()`, reproduced on OpenGL/Vulkan/software RHI and with **both** RtspVideoSource and QMediaPlayer, and custom render paths (QSGSimpleTextureNode + `createTextureFromImage`, QQuickPaintedItem/FBO) leak *worse* — there is **no client-side workaround on 6.4.2**. → ~260 MB/s on a 9-tile wall → earlyoom SIGTERM (the "Terminated" the operator saw) in ~30 s. (2) `GridLayout` SIGSEGVs in `QQuickGridLayoutBase::rearrange` after minimize/restore. **6.8.3 fixes both** (verified). The diagnostics that found it stay in `main.cpp`: a **fatal-signal handler** (prints signal + RSS at death → instantly tells OOM-SIGTERM from a code SIGSEGV) and `WT_TRACE=1` (`[WT-MEM] rss/live_pipelines/frames` every 2 s).
- **Video decode is hardware-vs-software by GStreamer *rank* — verify it, especially on Windows.** The live `decodebin` pipeline auto-picks the decoder by rank. On this box the **`va` plugin** provides HW decode: `vah264dec`/`vah265dec` are rank `primary+1` (257), klass `Codec/Decoder/Video/Hardware`, outranking software `avdec_h264`/`avdec_h265` (rank `primary`, 256). So VA-API HW decode is used **when it initialises**, but `decodebin` **silently falls back to software** if it doesn't (and `gstreamer-vaapi`'s `vaapih264dec` is rank `none` here — it's the newer `va` plugin that matters). Diagnostics + policy live in `RtspVideoSource`: **`WT_TRACE`** logs the codec + bound decoder + HW/SW (`[WT-DEC] … (hardware)` / `(SOFTWARE)`); **`WT_HW_ONLY=1`** makes `decodebin` *refuse* any non-hardware video decoder (the tile errors and the reconnect watchdog retries, instead of software-decoding). Use `WT_HW_ONLY` to **guarantee no software H.264/H.265 decode** — it matters for CPU **and** codec-patent exposure (the OS/GPU decoder carries the patent licence; a bundled *software* decoder shifts that burden onto us). **Windows port:** the HW equivalent is `d3d11h264dec`/`d3d11h265dec` (DXVA, from gst-plugins-bad's `d3d11`) — bundle it, run with `WT_HW_ONLY=1`, and confirm `[WT-DEC]` shows `d3d11…(hardware)`, never `avdec…(SOFTWARE)`. The QMediaPlayer/HLS playback path uses Qt's **FFmpeg backend** (FFmpeg 7.1, LGPL 2.1 — logged as `qt.multimedia.ffmpeg`) on both platforms; verify *it* HW-decodes (its own HW-device config) rather than silently software-decoding HEVC.
- **A `QQuickImageResponse` must emit `finished()` EXACTLY ONCE, and never from `cancel()`** (`CvImageProvider`). `QQuickPixmapReader::asyncResponseFinished()` runs `response->deleteLater()` **unconditionally** (qquickpixmapcache.cpp:766) — even for a job it already cancelled — so the first `finished()` hands the response to Qt for deletion and a **second one is delivered to a sender Qt has already deleted**: the reader thread then dereferences it and dies in `QObject::deleteLater` (the 2026-07-25 P0 SIGSEGV, 9.5 h uptime, backtrace `QQuickPixmapReader::run` → `asyncResponseFinished` → `deleteLater`). Two rules follow, both now enforced in `CvImageResponse`: **(1)** every exit path goes through `finish()`, which is a one-shot latch (a suppressed duplicate is logged — if `[EVIMG] duplicate finish suppressed` starts appearing, an exit path has regrown a second completion); **(2)** `cancel()` only raises an **atomic** flag and hops to our own thread. Qt calls `cancel()` on the pixmap-reader thread from inside `processJobs()` **while holding that reader's mutex** (`QT_FEATURE_quick_pixmap_cache_threaded_download` is 1 here, so `PIXMAP_READER_LOCK()` is a real `QMutexLocker`), so emitting `finished()` there re-enters `asyncResponseFinished()` → same non-recursive `QMutex` → deadlock, and touching `m_reply` there races the GUI thread that owns the `QNetworkReply`. Same reason the destructor `disconnect()`s the reply **before** aborting: `abort()` emits `finished()` synchronously, which would otherwise re-enter our own lambda from inside the destructor. Stress it with `tools/`-free churn: `WT_GUARD_SOAK=1 WT_GUARD_LIVE_MS=12000 WT_THUMB_REFRESH_MS=700 WT_TRACE=1` (saturates + cancels the governed `/snapshot` queue).
- **Namespaced attached properties**: with `import QtQuick.Controls.Basic as QC`, use `QC.ScrollBar.vertical`, not `ScrollBar.vertical` (else "Non-existent attached object").
- **Camera IP lockout**: HiWatch/Hikvision lock an IP ~30 min after failed logins. Do **not** run the full live wall against all cameras during dev (per-camera creds incomplete) — use `WT_TEST_IP`. A tile streams only when its `videoActive` is true (Live Monitor visible); a hidden Live Monitor that keeps players open hammers cameras.
- **Live status polls every 15s**: `CameraModel::pollStatuses()` GETs `/streams` and patches rows **in place** (`dataChanged` per row), never `beginResetModel()` — a reset would tear down every tile's RTSP pipeline each tick. (`WT_NO_POLL=1` disables it.)
- **Green wall = video tiles being recreated.** A restarted pipeline shows a fresh VA-API surface (NV12 0,0,0 ≈ RGB 0,135,0) green until its first decoded frame. So tearing down + recreating a `CameraTile` (→ `VideoSurface` → `MediaPlayer`) flashes it green. The Live Monitor grid **must not** rebuild delegates on data/layout changes. It used to bind `model: pagedCameras` (a `cameraModel.page()` **array**); any new array reference made the `Repeater` destroy+recreate **every** delegate — so a layout switch, page turn, or `countsChanged` greened the whole wall. Now the grid binds a persistent, camId-keyed `ListModel` (`gridModel`) reconciled in place by `syncGrid()` (`onPagedCamerasChanged`): cameras present before and after keep their delegate/pipeline; only genuine enters/leaves create/destroy a tile. When changing this, re-verify tiles are **reused** (instrument the delegate's `Component.onCompleted`/`onDestruction` across a layout switch — persisting cameras must log neither).
  - **Second line of defense (so green never shows even when a pipeline _does_ get recreated, or stalls):** `VideoSurface` keys its `playing` off **actual frame flow** (`_hasRecentFrame`, set on `videoOut.videoSink.videoFrameChanged`, cleared by a 2.5 s stall `Timer`) and lays an opaque `#0a0d11` cover over the `VideoOutput` whenever `!playing`. So the raw green VA-API surface — shown before the first decoded frame **and on a silent stall** (RtspVideoSource flips `playing=false` only on EOS/error/teardown, never on a freeze) — is always hidden behind the cover; consumers show "Connecting…" on top, and it self-heals when frames resume. This is what fixed a single camera (e.g. a stalled substream) showing a frozen green tile + green single-cam view.
  - **Auto-reconnect on stall (recovers stalled tiles to live video):** once `playing` is frame-accurate, `VideoSurface` actively rebuilds a stalled pipeline. **Per-tile exponential backoff** (`_backoffMs` 2/5/10/20/30 s, reset on frame recovery; a patient 8 s on a *cold* connect so a slow first frame isn't torn down) calls `RtspVideoSource.reconnect()` (a `Q_INVOKABLE` → `rebuild()`; qtmm path re-sets `source`). **Critically, every attempt is routed through the `ReconnectCoordinator` singleton**, a global serializer that releases at most one reconnect initiation per `minIntervalMs` (700 ms). This is the freeze guard: a fleet-wide stall (16 tiles) recovers one pipeline at a time over ~11 s instead of bursting 16 simultaneous VA-API rebuilds — the decode-context churn we suspect causes the Live-relayout freeze. Only **active** tiles (visible, real url) reconnect; the closure null-guards `root` so a paged-out tile's queued attempt is a no-op. **If you add any other reconnect/rebuild path, route it through `ReconnectCoordinator` too** — never let N pipelines rebuild at once.
- **Relayout-freeze fix — pipeline BUILDS are globally rate-limited; never build inline.** The shared Intel iGPU wedges (20 s freeze, sometimes an OOM kill) when ~16 VA-API decode contexts are created at once — a layout change, page turn, app start, or (formerly) entering/exiting **Arrange**. So `RtspVideoSource::rebuild()` does **not** build inline: it enqueues with the global **`PipelineBuildPump`** (RtspVideoSource.cpp — a GUI-thread, leaked singleton) which calls `startPipelineNow()` **≤1 per `kBuildStaggerMs` (120 ms)**. A lone build still fires immediately; only bursts spread (each tile shows its loading bar until its turn). `teardown()`/dtor `cancel()` a queued build; reconnects ride the same pump. **Teardown** is separately bounded by `kMaxConcurrentTeardowns` (8), so create+destroy churn is capped both ways. Two companion changes: **(a)** Live tiles **stay playing during Arrange** (`videoActive` is `root.visible`, not `&& !arrangeMode`) — the arrange overlay just dims them; tearing 16 down on enter + rebuilding on exit was the crash repro's trigger. **(b)** The "Tap to change" picker thumbnails only fetch when the picker is open (`pickerCell >= 0`) — its GridView delegates exist while hidden and were snapshotting every camera in the background. **RULE: any new code that starts a live pipeline MUST go via `rebuild()` (→ the pump); never call `startPipelineNow()` or `gst_element_set_state(PLAYING)` directly in a loop.** The freeze only reproduces on the real iGPU under load — verify live (Arrange/Tap cycling, layout switches, page turns), not just offscreen.
- **Keep `countsChanged` off hot paths anyway**: it re-runs every `page()`/`countFiltered()` binding. `pollStatuses()` recomputes counts only on a genuine live/recording flip, **not** on a `last_segment_at` advance (which ticks every poll) — see b5345dd.

## Verification convention

Every change: (1) `cmake --build build` clean; (2) offscreen smoke → zero QML warnings; (3) `WT_SCREENSHOT` PNG for any UI change (use `WT_SECTION`/`WT_DEMO` to reach the screen; a temporary auto-select scaffold is OK for detail panels, but revert it before committing).


## Diagnostic counters name their measurement point (2026-08-16)

Three instruments in one investigation each answered a narrower question than
their name implied, and each cost days: `livePipes` counts pipelines
**constructed** (it kept saying 26 while 5 had no decoder), `playing` is a
**2.5 s gap detector** (tiles at 0.1 fps stayed green), and `frames=` counts
frames **presented** after the GUI-thread mailbox (3.2 fps/tile was read as a
decoder rate; the decoder was never measured). The rule: **a counter's exposed
name states WHERE it measures, not what it is about.**

The `[MEMTEL]` line now carries the whole split: `livePipes` (constructed) ·
`dec` (decodebin bound a decoder) · `lit` (delivered a frame ≤5 s ago) · `err`
(bus-error state) · `framesIn` (appsink → client) · `frames` (presented) ·
`coalesced` (mailbox drops) · `swd` (backstop rebuilds — **nonzero on a healthy
wall means the QML recovery layers failed**) · `recon=ran/refused`.

Stream recovery is three layers, outermost first: CameraTile error-recycle
(6/15/30/60 s, destroys the element), VideoSurface coordinator-serialized
reconnect (8 s cold start), and the C++ backstop watchdog in RtspVideoSource
(45 s first-frame / 30 s stall, ×2 backoff capped 120 s) which shares no
machinery with the QML layers precisely so a wedged singleton cannot take all
three down. Env: `WT_SWD_FIRST_S` / `WT_SWD_STALL_S` (test cadences),
`WT_STREAM_WATCHDOG_OFF`, and `WT_RECON_OFF` (disables both QML layers — the
backstop-isolation harness; never set in production).


## Socket state is not liveness (2026-08-16, the coordinated-restart verdict)

A TCP socket can read `ESTABLISHED` forever on a stream that ended minutes ago:
if our reader stops draining, the kernel advertises a zero window; the server's
send queue pegs (flat byte count, ZERO retransmits — flow control, not loss);
the server times out and close()s — and its FIN queues behind bytes the
zero-window connection will never carry. Server: FIN_WAIT1. Client:
ESTABLISHED, eternally. Measured live: booth 32 ESTABLISHED with ~5.5
delivering, go2rtc 6 ESTABLISHED + 8 FIN_WAIT1 — the same reality from both
ends. Therefore: **liveness = frames received recently, never socket or
pipeline state** — which is exactly what the swd backstop keys on, and why
`lit=` exists on the [MEMTEL] line. Related knob: `WT_BUILD_STAGGER_MS`
(pipeline build pacing — the death burst correlates with build bursts).


## Qt toolchain reality check (2026-08-17, web-verified)

The "Qt 6.12.0" this box has run since 2026-07-02 is a **pre-release** — as of
August 2026 the latest released Qt is **6.11.1**, with 6.12.0 targeted for
September 2026 (`~/Qt/6.12.0-patched-beta1` beside the kit is the tell). Two
consequences: the 6.12 tool crashes we carry workarounds for (qmlcachegen AOT
SIGSEGV, `--dump-aot-stats`, offscreen QPA SIGBUS) are BETA bugs and must be
re-tested against 6.12.0 final when it ships; and the Mac port's Homebrew Qt
6.11.1 is the newest stable in existence — the Mac is not the lagging platform,
this box is the bleeding-edge one.
