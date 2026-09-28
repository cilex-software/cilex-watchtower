# Cilex Watchtower — Development & Implementation Notes

_Durable implementation reference. Pairs with [PROJECT_STATUS.md](PROJECT_STATUS.md)._

## Stack (locked)

- **UI**: Qt **6.12** (primary) / **6.8.3 LTS** (fallback) + Qt Quick / QML (GPU scene-graph compositing). Ubuntu 24.04's system Qt **6.4.2 is BANNED** — the CMake floor is 6.8, so it can't even configure (it has a QtMultimedia libsoup-SIGSEGV on playback seeks, a VideoOutput memory leak, and a GridLayout SIGSEGV — see Build and Gotchas). The React prototype in `designs/` is recreated **visually** in QML — JSX is not reused.
- **Core**: C++17.
- **Video**: QtMultimedia `MediaPlayer` + `VideoOutput` (QML) on Qt's **FFmpeg** media backend (default ≥6.5; FFmpeg 7.1.x), **VA-API HW decode** (confirmed on Intel Alder Lake-S iGPU, iHD driver). The opt-in low-latency LIVE path (`RtspVideoSource`) drives a custom GStreamer pipeline; recorded PLAYBACK uses the FFmpeg backend. See "qml6glsink" gotcha below.
- **Persistence**: two stores — `QSettings` (the native format, since nothing in `src/` sets another: an INI file on Linux, a CFPreferences plist `com.cilex-vision.Watchtower` on macOS, the registry on Windows) for small operator state (prefs, event acks, saved views), and **SQLite** via `CameraStore` for the local camera inventory at `<AppDataLocation>/Cilex Vision/Watchtower/watchtower.db`. Groups, events, and footage are not persisted locally — they come live from cilex-vision.
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
  **Always add `WT_NO_SCHEME_REG=1` to a test run.** Every instance registers the `cilex://` link handler
  for ITSELF at start: `DeepLink.cpp` rewrites `~/.local/share/applications/cilex-watchtower-url.desktop`
  under `QDir::homePath()`, so `XDG_DATA_HOME` does not stop it. That repoints the operator's links at the
  test binary. Measured 2026-09-28: Labs screenshot runs left it on `build68/watchtower`, which was
  restored to the live app's `build/watchtower`.

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

**…which is how two commits used to end up on one version, so a `pre-push` hook now
refuses it** (operator decision 2026-09-26). `git pull --rebase` replays a local commit
onto a remote one that made the SAME bump (N → N+1); git merges the identical change
cleanly, the replayed commit carries no bump of its own, and pre-commit does not run
during a rebase. Measured on `main` that day: of the last 300 first-parent commits, 12
version numbers were each shared by two or more commits that changed code (28 counting
docs-only commits) — among them 854cb4c/efa1561, both 1.1.626, the build blocked on the
booth. The hook refuses any pushed commit whose version is not strictly greater than its
parent's and prints the fix, which renumbers the whole chain in one pass:

```
git rebase -x tools/renumber-version.sh <base printed by the hook>
```

Each replayed commit becomes its parent + 1 (idempotent; a commit already there is left
alone). `WT_ALLOW_SAME_VERSION=1 git push` skips the check — emergencies only. Pinned by
`tools/tests/version-push-check.sh` in pre-commit, on a real collision made in throwaway
repositories.

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
| `WT_STATION_TOKEN=<token> WT_CV_URL=<url>` | Headless station mode (2026-09-08): opens a display session with the station token (`X-Cilex-Display-Session`, scope `station:live`) instead of the sign-in screen — `/streams` and snapshots work; review/mosaic answer 403 `display_session_out_of_scope` BY DESIGN, so playback measurements need an operator credential. Read the token from `warden.conf` in a script; never paste it into a chat or a letter. |
| `WT_FOCUS_DELAY_MS=<ms>` / `WT_FOCUS_CLOSE_MS=<ms>` | With `WT_FOCUS_IP`: wait that long after the roster lands before the click (so the wall is lit — otherwise the hook measures a cold open the instant `/streams` returns), and close the view that long after it opened (so one run also measures the return path; the hook then re-opens within 500 ms). `WT_TRACE=1` prints `[LIVETIME] open / pipeline_playing / first_sample / first_deliver / adopted / playing dt= / hd_promoted / close` and `gui_stall` for GUI-thread gaps > 150 ms. |
| `WT_PARK_MS=<ms>` / `WT_PARK_MAX=<n>` | Pipeline parking (defaults 2500 / 4; `WT_PARK_MS=0` = the old destroy-and-rebuild): a lit decode pipeline whose owner goes away is held for adoption by the next source wanting the same URL — wall→detail opens in ~160 ms instead of a 0–3.3 s keyframe wait. `[WT-PARK] parked/expired` under `WT_TRACE`, `parked=` on the `[WT-MEM]` line. See the mid-GOP gotcha below and `docs/perf/2026-09-08-live-ttff/`. |
| `tools/ttff-soak.sh` (`WT_TTFF_CAM`, `WT_SOAK_WALL_TIMEOUT`, `WT_SOAK_KEEP_ALL`) | The operator's open-latency soak (2026-09-08): per cycle one single-camera playback open (`[TTFF]`), one 16-cell wall open (`[WALLTIME]`), one live open from a lit wall (`[LIVETIME]`), one JSON row each, stamped with the git rev + binary time. Needs the operator-created `soak` account in `~/.config/watchtower-warden/ttff-soak.cred` (0600). Logs of runs that MISS their target are kept next to the rows (`<out>-logs/`); `WT_SOAK_KEEP_ALL=1` keeps every log; `WT_SOAK_WALL_TIMEOUT` (default 70) bounds the wall stage — today's mosaic needs 150. Launch detached (`systemd-run --user`, see `docs/perf/2026-09-08-ttff-soak/`): the session reaper kills harness-tracked background jobs. |
| `WT_PB_HW_DECODE=1` (software decode is the DEFAULT since 2026-09-09) | Every QMediaPlayer path (recorded playback, wall mosaic, frame mode) decodes in software unless this opts back into hardware; live tiles are GStreamer/VA-API and unaffected. Sets `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=,` before the FFmpeg backend loads — Qt reads that env ONCE into a static (`qffmpeghwaccel.cpp`, `HWAccel::decodingDeviceTypes`), so it is process-wide. Why: the 16-cell mosaic's segments open with two corrupt packets each and the VA-API decode of them killed the process in 6 of 7 wall runs on 2026-09-08 (heap corruption after `vaSyncSurface failed`); the overnight soak with software decode had 0 crashes in 278 logs and no measured first-frame cost on playback (CPU cost of 1440p HEVC software decode NOT measured). `WT_PB_SW_DECODE=1` is still accepted (a no-op now). |
| `WT_FRAME_MODE=1`, `WT_PB_MARK=1`, `WT_PB_LADDER=1` | Playback "One Axis" state hooks — auto-enter frame-by-frame once footage renders; mark an export range; open the speed ladder. They drive the REAL controls, so a verification screenshot shows shipped behaviour. |
| `WT_PB_EXPORT=1\|2\|3\|4` | Filmstrip-blank repro (2026-08-10). Needs `WT_FRAME_MODE=1 WT_PB_MARK=1`. `1` = open the export drawer over a 10 s marked range (**no backend write**); `2` = also confirm it (**ONE real export job**); `3` = force a far-seek session re-open under frame mode; `4` = press play under frame mode. With `WT_TRACE=1` each run prints `[STRIP] lit=n/9 pts=… cache=…f …` three times a second — `lit` is the number of filmstrip slots that resolve, and it is the whole measurement. |
| `WT_TEST_IP=<ip>` | Restrict live streaming to one camera during dev (avoid hammering cameras — see lockout caveat). |
| `WT_CAMERAS=<provisioning.json>` | One-time bootstrap import into an empty camera store. |
| `WT_SCREENSHOT=<path>`, `WT_SCREENSHOT_MS=<ms>` | Screenshot hook (above). |
| `WT_NO_SCHEME_REG=1` | Do not register the `cilex://` link handler. Set it on EVERY test/screenshot run (see above). |
| `WT_LABS_VIEW=stats[:24h\|7d\|all]` | Open the Labs screen on its Statistics view, for that period. Review screenshots; it only picks what is shown. |
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

- **`pgrep -f` / `pkill -f` match YOUR OWN shell.** The pattern you pass is itself in your
  command line, so `pkill -f watchtower` kills the shell running it, and
  `until ! pgrep -f "…/warden.py run"; do sleep 1; done` never exits — it is matching itself.
  This cost a **Warden restart that stopped and did not start** on 2026-09-22: the wall was
  down for about three minutes while the loop span against its own process. It bit five
  times in one session. Either exclude your own pid
  (`for p in $(pgrep -f X); do [ "$p" != "$$" ] && kill "$p"; done`), match on something the
  command line cannot contain, or — for a systemd unit — ask systemd
  (`systemctl --user show wt-warden -p MainPID --value`) instead of scanning processes.
- **Restarting `wt-warden` restarts the WALL.** Warden is the app's parent, so
  `systemctl --user restart wt-warden` kills and respawns Watchtower and generates a crash
  report with a forced-kill trigger. That is normal and the bundle uploads like any other —
  do not read it as a real crash. Manage the wall this way and never with a bare `./run.sh`.
- **Qt 6.4 resource prefix**: `qt_add_qml_module` defaults to `/<URI>`, not `/qt/qml/`. We pin `RESOURCE_PREFIX "/qt/qml"` so `main.cpp` loads `qrc:/qt/qml/Watchtower/qml/Main.qml`. `loadFromModule()` doesn't exist in 6.4 — load by URL.
- **qml6glsink doesn't work** on Ubuntu 24.04's `gstreamer1.0-qt6` 1.24.2 (the `Qt6GLVideoItem` QML type never registers). We use **QtMultimedia** instead (verified VA-API HW decode). Don't reintroduce the direct-qml6glsink path without re-checking.
- **Qt 6.4.2 is BANNED (CMake floor 6.8) — it has three fatal bugs; primary is 6.12, fallback 6.8.3 (see Build).** (0) QtMultimedia's GStreamer backend SIGSEGVs in libsoup-3.0 on recorded-playback seek/day-switch churn (the P0). (1) QtMultimedia `VideoOutput` leaks ~one frame-buffer per rendered frame: bisected to `m_sink->setVideoFrame()`, reproduced on OpenGL/Vulkan/software RHI and with **both** RtspVideoSource and QMediaPlayer, and custom render paths (QSGSimpleTextureNode + `createTextureFromImage`, QQuickPaintedItem/FBO) leak *worse* — there is **no client-side workaround on 6.4.2**. → ~260 MB/s on a 9-tile wall → earlyoom SIGTERM (the "Terminated" the operator saw) in ~30 s. (2) `GridLayout` SIGSEGVs in `QQuickGridLayoutBase::rearrange` after minimize/restore. **6.8.3 fixes both** (verified). The diagnostics that found it stay in `main.cpp`: a **fatal-signal handler** (prints signal + RSS at death → instantly tells OOM-SIGTERM from a code SIGSEGV) and `WT_TRACE=1` (`[WT-MEM] rss/live_pipelines/frames` every 2 s).
- **Video decode is hardware-vs-software by GStreamer *rank* — verify it, especially on Windows.** The live `decodebin` pipeline auto-picks the decoder by rank. On this box the **`va` plugin** provides HW decode: `vah264dec`/`vah265dec` are rank `primary+1` (257), klass `Codec/Decoder/Video/Hardware`, outranking software `avdec_h264`/`avdec_h265` (rank `primary`, 256). So VA-API HW decode is used **when it initialises**, but `decodebin` **silently falls back to software** if it doesn't (and `gstreamer-vaapi`'s `vaapih264dec` is rank `none` here — it's the newer `va` plugin that matters). Diagnostics + policy live in `RtspVideoSource`: **`WT_TRACE`** logs the codec + bound decoder + HW/SW (`[WT-DEC] … (hardware)` / `(SOFTWARE)`); **`WT_HW_ONLY=1`** makes `decodebin` *refuse* any non-hardware video decoder (the tile errors and the reconnect watchdog retries, instead of software-decoding). Use `WT_HW_ONLY` to **guarantee no software H.264/H.265 decode** — it matters for CPU **and** codec-patent exposure (the OS/GPU decoder carries the patent licence; a bundled *software* decoder shifts that burden onto us). **Windows port:** the HW equivalent is `d3d11h264dec`/`d3d11h265dec` (DXVA, from gst-plugins-bad's `d3d11`) — bundle it, run with `WT_HW_ONLY=1`, and confirm `[WT-DEC]` shows `d3d11…(hardware)`, never `avdec…(SOFTWARE)`. The QMediaPlayer/HLS playback path uses Qt's **FFmpeg backend** (FFmpeg 7.1, LGPL 2.1 — logged as `qt.multimedia.ffmpeg`) on both platforms; verify *it* HW-decodes (its own HW-device config) rather than silently software-decoding HEVC.
- **A fresh RTSP consumer joins go2rtc mid-GOP and shows nothing real until the next keyframe — 3.3 s period on `-sub`, 4.0 s on main (measured 2026-09-08, three joins each).** The VA decoder emits empty green surfaces for the P-frames before its first IDR and `RtspVideoSource::onNewSample` drops them (`isEmptyGreenNV12`), so a "first decoded frame" probe built on `avdec_h264` LIES by up to a GOP — it outputs corrupt pre-keyframe frames (+137 ms, vs the parser's first keyframe at +1267 ms on the same join). Measure the first REAL picture (`[LIVETIME] first_deliver`), never the first decoded buffer. A COLD producer (fresh camera session) starts on an IDR, which is why the wall's cold tiles light ~250 ms after PLAY while a warm join waits. Two rules follow: (1) never destroy-and-rebuild a lit pipeline for the same URL when it can be handed over — `ParkingLot` in `RtspVideoSource.cpp` does exactly that, and `reconnect()`/`setLatencyMs` opt out via `m_noPark` because a STALLED pipeline must die, not be re-adopted; (2) anything that must build fresh on a warm producer — HD promotion, snapshot tiles beyond the decode cap, any mobile or remote open — is bounded by the camera GOP until CV shortens it or go2rtc starts consumers at the last keyframe (letter 2026-09-08).
- **The proxy sends streamed segment bodies with proper chunked framing, and a mosaic session id is persisted so the NEXT process can reap it** (`HlsProxy.cpp`, `PlaybackClient.cpp`, 2026-09-08/11). A body with no Content-Length ended by a socket close makes FFmpeg's HTTP reader return EIO, not EOF (`Stream ends prematurely at N, should be 18446744073709551615` → `Error during demuxing: Input/output error`, reproduced standalone against a clean segment; Content-Length or chunked framing decodes silently) — the proxy now chunk-frames and terminates on a clean finish, closes without the terminator on a mid-body failure, and hands over whole 188-byte packets. Separately and NOT ours: every CV mosaic/review segment is an independent TS (PTS restarts at 0, `#EXT-X-DISCONTINUITY` per segment), so FFmpeg's HLS demuxer flushes an unterminated video PES at each joint and flags the segment's last two frames corrupt (mosaic: dts 525000/532500 of a 72-frame, 6 s segment; HEVC review: 6 of 11 joints) — reproduced with ffmpeg alone, no Watchtower in the path. The VA-API decoder died on those slices in 6 of 7 wall runs on 2026-09-08 (backtraces in `docs/perf/2026-09-08-ttff-soak/crashes.md`); software decode swallows them, which is why it is the default. Server-side fix asked (continuous segmentation, letter 2026-09-11). A crashed client cannot DELETE its 6 h mosaic session: `mosaic/lastSession` in QSettings is written (and `sync()`ed) at create, cleared on dispose, and anything found there at the next open is deleted first. Coverage refreshes are DEFERRED behind the first frame on both surfaces when a cache exists.
- **A `QQuickImageResponse` must emit `finished()` EXACTLY ONCE, and never from `cancel()`** (`CvImageProvider`). `QQuickPixmapReader::asyncResponseFinished()` runs `response->deleteLater()` **unconditionally** (qquickpixmapcache.cpp:766) — even for a job it already cancelled — so the first `finished()` hands the response to Qt for deletion and a **second one is delivered to a sender Qt has already deleted**: the reader thread then dereferences it and dies in `QObject::deleteLater` (the 2026-07-25 P0 SIGSEGV, 9.5 h uptime, backtrace `QQuickPixmapReader::run` → `asyncResponseFinished` → `deleteLater`). Two rules follow, both now enforced in `CvImageResponse`: **(1)** every exit path goes through `finish()`, which is a one-shot latch (a suppressed duplicate is logged — if `[EVIMG] duplicate finish suppressed` starts appearing, an exit path has regrown a second completion); **(2)** `cancel()` only raises an **atomic** flag and hops to our own thread. Qt calls `cancel()` on the pixmap-reader thread from inside `processJobs()` **while holding that reader's mutex** (`QT_FEATURE_quick_pixmap_cache_threaded_download` is 1 here, so `PIXMAP_READER_LOCK()` is a real `QMutexLocker`), so emitting `finished()` there re-enters `asyncResponseFinished()` → same non-recursive `QMutex` → deadlock, and touching `m_reply` there races the GUI thread that owns the `QNetworkReply`. Same reason the destructor `disconnect()`s the reply **before** aborting: `abort()` emits `finished()` synchronously, which would otherwise re-enter our own lambda from inside the destructor. Stress it with `tools/`-free churn: `WT_GUARD_SOAK=1 WT_GUARD_LIVE_MS=12000 WT_THUMB_REFRESH_MS=700 WT_TRACE=1` (saturates + cancels the governed `/snapshot` queue).
- **Namespaced attached properties**: with `import QtQuick.Controls.Basic as QC`, use `QC.ScrollBar.vertical`, not `ScrollBar.vertical` (else "Non-existent attached object").
- **Camera IP lockout**: HiWatch/Hikvision lock an IP ~30 min after failed logins. Do **not** run the full live wall against all cameras during dev (per-camera creds incomplete) — use `WT_TEST_IP`. A tile streams only when its `videoActive` is true (Live Monitor visible); a hidden Live Monitor that keeps players open hammers cameras.
- **Live status polls every 15s**: `CameraModel::pollStatuses()` GETs `/streams` and patches rows **in place** (`dataChanged` per row), never `beginResetModel()` — a reset would tear down every tile's RTSP pipeline each tick. (`WT_NO_POLL=1` disables it.)
- **Green wall = video tiles being recreated.** A restarted pipeline shows a fresh VA-API surface (NV12 0,0,0 ≈ RGB 0,135,0) green until its first decoded frame. So tearing down + recreating a `CameraTile` (→ `VideoSurface` → `MediaPlayer`) flashes it green. The Live Monitor grid **must not** rebuild delegates on data/layout changes. It used to bind `model: pagedCameras` (a `cameraModel.page()` **array**); any new array reference made the `Repeater` destroy+recreate **every** delegate — so a layout switch, page turn, or `countsChanged` greened the whole wall. Now the grid binds a persistent, camId-keyed `ListModel` (`gridModel`) reconciled in place by `syncGrid()` (`onPagedCamerasChanged`): cameras present before and after keep their delegate/pipeline; only genuine enters/leaves create/destroy a tile. When changing this, re-verify tiles are **reused** (instrument the delegate's `Component.onCompleted`/`onDestruction` across a layout switch — persisting cameras must log neither).
  - **Second line of defense (so green never shows even when a pipeline _does_ get recreated, or stalls):** `VideoSurface` keys its `playing` off **actual frame flow** (`_hasRecentFrame`, set on `videoOut.videoSink.videoFrameChanged`, cleared by a 2.5 s stall `Timer`) and lays an opaque `#0a0d11` cover over the `VideoOutput` whenever `!playing`. So the raw green VA-API surface — shown before the first decoded frame **and on a silent stall** (RtspVideoSource flips `playing=false` only on EOS/error/teardown, never on a freeze) — is always hidden behind the cover; consumers show "Connecting…" on top, and it self-heals when frames resume. This is what fixed a single camera (e.g. a stalled substream) showing a frozen green tile + green single-cam view.
  - **Auto-reconnect on stall (recovers stalled tiles to live video):** once `playing` is frame-accurate, `VideoSurface` actively rebuilds a stalled pipeline. **Per-tile exponential backoff** (`_backoffMs` 2/5/10/20/30 s, reset on frame recovery; a patient 8 s on a *cold* connect so a slow first frame isn't torn down) calls `RtspVideoSource.reconnect()` (a `Q_INVOKABLE` → `rebuild()`; qtmm path re-sets `source`). **Critically, every attempt is routed through the `ReconnectCoordinator` singleton**, a global serializer that releases at most one reconnect initiation per `minIntervalMs` (700 ms). This is the freeze guard: a fleet-wide stall (16 tiles) recovers one pipeline at a time over ~11 s instead of bursting 16 simultaneous VA-API rebuilds — the decode-context churn we suspect causes the Live-relayout freeze. Only **active** tiles (visible, real url) reconnect; the closure null-guards `root` so a paged-out tile's queued attempt is a no-op. **If you add any other reconnect/rebuild path, route it through `ReconnectCoordinator` too** — never let N pipelines rebuild at once.
- **Relayout-freeze fix — pipeline BUILDS are globally rate-limited; never build inline.** The shared Intel iGPU wedges (20 s freeze, sometimes an OOM kill) when ~16 VA-API decode contexts are created at once — a layout change, page turn, app start, or (formerly) entering/exiting **Arrange**. So `RtspVideoSource::rebuild()` does **not** build inline: it enqueues with the global **`PipelineBuildPump`** (RtspVideoSource.cpp — a GUI-thread, leaked singleton) which calls `startPipelineNow()` **≤1 per `kBuildStaggerMs` (120 ms)**. A lone build still fires immediately; only bursts spread (each tile shows its loading bar until its turn). `teardown()`/dtor `cancel()` a queued build; reconnects ride the same pump. **Teardown** is separately bounded by `kMaxConcurrentTeardowns` (8), so create+destroy churn is capped both ways. Two companion changes: **(a)** Live tiles **stay playing during Arrange** (`videoActive` is `root.visible`, not `&& !arrangeMode`) — the arrange overlay just dims them; tearing 16 down on enter + rebuilding on exit was the crash repro's trigger. **(b)** The "Tap to change" picker thumbnails only fetch when the picker is open (`pickerCell >= 0`) — its GridView delegates exist while hidden and were snapshotting every camera in the background. **RULE: any new code that starts a live pipeline MUST go via `rebuild()` (→ the pump); never call `startPipelineNow()` or `gst_element_set_state(PLAYING)` directly in a loop.** The freeze only reproduces on the real iGPU under load — verify live (Arrange/Tap cycling, layout switches, page turns), not just offscreen.
- **Keep `countsChanged` off hot paths anyway**: it re-runs every `page()`/`countFiltered()` binding. `pollStatuses()` recomputes counts only on a genuine live/recording flip, **not** on a `last_segment_at` advance (which ticks every poll) — see b5345dd.
- **A timestamp we cannot parse must never read as "nothing wrong".** Two sentinels for the
  same answer is the trap: in `qml/GroupsStatus.js` an ABSENT `lastSegmentAt` fell to `-1`,
  which every site handles, while a non-empty UNPARSEABLE one became `NaN` — and `NaN`
  answers **false** to every comparison, `<= 0` included, so both the "no timestamp" branch
  and the "too old" branch were skipped and a camera nothing could be said about classified
  as healthy. It does not throw; it quietly stops being true. Fixed by one narrowing
  predicate, `St.ms(iso)`, which returns `-1` for absent, unparseable and non-positive alike
  — the sentinel the code already handled. `qml/HealthScreen.qml` had a byte-faithful copy of
  the classifier and now delegates, so there is one predicate, not two that must be fixed
  twice. Pinned by `tools/tests/groups-status-ts.qml` (18/18; shown to fail 5 against the
  pre-fix behaviour). Same family in `WatchChip.sinceLabel`, which would have rendered
  **"ON WATCH · <guard> · NaNm"** on the title bar. Found by mirroring a sweep
  cilex-pro-mobile ran on their side (`b436010`); **not observed on our wire** — insurance,
  and labelled as such in the file.
- **ISO timestamps with no timezone are read as LOCAL time — by both our parsers** (measured
  2026-09-22, Qt 6.12): `QDateTime::fromString(s, Qt::ISODate)` on a naive string yields
  `timeSpec=0` (`Qt::LocalTime`), and QV4's `Date.parse` agrees. On this box (MSK) that is a
  silent **3-hour** shift; in a UTC container it is none — so a dev box and the guard booth
  would disagree and neither would say so. A client cannot recover the right INSTANT from
  such a string — but it CAN see that the string is the wrong SHAPE, and
  `src/models/WireTime.h` now warns once per field for any of the seven wire timestamps
  that arrives without an offset (names the field, never the value). **This entry first
  said "nothing client-side can detect it", and this box told cilex-vision and
  cilex-pro-mobile the same. That was wrong — mobile drew the instant-vs-shape
  distinction and shipped their detector first (`7358240`).** What prevents the shift in
  the first place is still server-side: cilex-vision's `iso_ms()` (`services/_common/timefmt.py:35`) emits an
  offset **iff** the datetime it is handed is tz-aware, and the columns behind these fields
  are `TIMESTAMPTZ` (alembic `0053`/`0054`; `0028` for `last_vmd_event_at`). That dependency
  is pinned by no test on either side — CV's route tests assert `wire == iso_ms(input)`,
  which holds just as well if BOTH sides are naive.
  - Same measurement retires an open question in CV's own docstring
    (`timefmt.py:14-17`, *"Whether Qt tolerates six is UNMEASURED by me"*): **Qt 6.12
    `Qt::ISODate` and `Qt::ISODateWithMs` both accept six fractional digits**, truncating to
    ms with rounding (`.873977` → `.874`). So `iso_ms` was never load-bearing for us.
    **Whether it is load-bearing for Hermes is NOT measured by anyone** — this box wrote
    that it was, which overstated a report (CV's docstring paraphrases a failure
    cilex-pro-mobile observed on 2026-08-21) as a measurement. Mobile cannot close it
    either: their repo ships only `hermesc`, and their jest environment is Node/V8, so
    any test there would measure V8. It needs a device build, which is the operator's to
    run. Open, and labelled open. CV has since rewritten their own bullet to say
    the same (their words: *"I had dressed a spec-derived risk as a crash somebody saw"*).
  - **The dependency is now pinned on CV's side, and the pin was mutation-tested.**
    `test_route_level_timestamps_carry_a_utc_offset` goes through `GET /streams` and asserts
    `status_since` / `last_seen_at` / `recording_since` / `last_segment_at` all end in `+00:00`
    or `Z`. CV injected a mutant (`iso_ms` stripping tzinfo) to check it was not another
    tautology: **the old assertions passed 2/2 against the mutant; the new test failed, naming
    all four fields.** That is the diagnosis reproduced, not merely accepted. Uncommitted in
    their tree as of 2026-09-22.
  - **Scope correction from CV, worth keeping:** `decommissioned_at` (`streams.py:577,1496`)
    now goes through `iso_ms` too (their working tree, uncommitted 2026-09-22) — but there are
    **129 raw `.isoformat()` calls across the query-api routers** (review.py 27, storage.py 16,
    storage_tiers.py 13). Those are a PRECISION question, not an offset one, while the columns
    stay `TIMESTAMPTZ` — so nothing there is broken, and `streams.py` is not the whole wire.
    Do not read the finding above as wider than it is.
- **A guard whose predicate cannot reach the state it exists to catch is not a guard.**
  Four window guards read `end <= start` — "I have no usable window, do nothing". Against
  NaN that is **false**, so they failed OPEN and the next line threw on
  `new Date(NaN).toISOString()`. Use **`!(end > start)`**: identical for every finite pair by
  trichotomy, and it fires on NaN, so the rewrite is provably behaviour-preserving for valid
  input — which is why it could ship without a live manifest to test against.
  `WallPlayback.qml:156` already used that form; three later guards did not, and a **fifth**
  (`PlaybackScreen.qml` `_wasFitted`) was found only once the rule was made mechanical.
  **`tools/tests/window-guard-lint.sh` now enforces it** — it found all five known instances
  at the pre-fix commit and zero false positives across `qml/`. Run it with the other tests.
  - **The rule's limit, and it is narrower than first written.** It keys on a NAMING
    CONVENTION, not on types, so it cannot tell an instant from a duration. "Rewrite it
    anyway, the two forms are identical for valid input" is true for **instant vs instant**
    and was overclaimed as universal. For a duration against a threshold (`gapMs >=
    joinGapMs`) neither operand is a wire instant, so `!(a > b)` costs readability and buys
    nothing. It is safe here because, measured, all 22 `*Ms <op> *Ms` comparisons in `qml/`
    are instant-vs-instant and none is a duration — a property of this codebase's naming,
    not of the rule. cilex-pro-mobile ran it against their own code before adopting it, found
    five hits, zero reachable and two of them durations, and correctly declined to build it:
    a rule that starts life with an exception list is one nobody trusts.
  - The general shape, named by cilex-vision the same evening after shipping its twin
    (`if token in _bootstrap_tokens(request) and proj.host:` — where `proj.host` falls back
    to the truthy literal `"unknown"`, so the condition could never be false): *a guard
    written as a positive comparison against a value that can be NaN, None, or a truthy
    placeholder is not a guard.* Mine failed open because NaN makes every comparison false;
    theirs because a fallback made one always true. Neither of us found our own by reading it.
  - And the mechanism, from cilex-pro-mobile, who hit it in their repo the same day: *the
    rule was written once and not made structural, so it held where it was written and
    nowhere else.* That is the argument for the lint over the four fixes.
- **Your own `setTransferTimeout` firing is `TimeoutError` (4), NOT `OperationCanceledError`
  (5).** Measured on **Qt 6.12.0** here 2026-09-22 against a socket that accepts and never
  answers: `error=TimeoutError (4)`, `httpStatus=0`. The macOS session measured the same on
  **Qt 6.11** — so it holds across both toolchains, and a guard that tests only
  `OperationCanceledError` silently never matches. That exact defect shipped in an interim
  cut of `PlaybackClient`'s "do not retry our own timeout" rule and let the retry ladder fire
  three times *with the guard in place*. It surfaced only because their harness counted what
  the SERVER would have seen rather than what the client believed it had done — a client-side
  assertion would have passed. The shipped form tests **both** codes
  (`PlaybackClient.cpp:531-532`), which is right; keep it that way if you bound a request on
  the Windows or Linux side.
- **UPDATE 2026-09-23: metrics ARE being scraped now.** A `prometheus` container started
  **2026-09-22T22:58:12Z**, hours after the finding below was reported, and is healthy: four
  targets up (query-api, recorder, playback, itself) and 18 `query_db_latency_ms` series
  recorded. So the macOS session's "one query that might end this" — the DB-latency delta
  over an incident window — **now works for any FUTURE stall**, though still not for the
  2026-09-22 one, which predates the scrape. The note below was correct when written and is
  kept for the reasoning, not the status.
- **Nothing scraped `:8000/metrics` before 2026-09-22T22:58Z, so no incident before then has metric history.**
  `pilot-prometheus` is *defined* (`cilex-vision/infra/docker-compose.pilot.yml:175`,
  `prom/prometheus:v2.53.1`) but the container **does not exist** on this host, and the
  `infra_prometheus_data` volume's newest TSDB block is **2026-08-22 19:37** — a month stale.
  `alertmanager` runs and its config points at `prometheus/rules/*.yml`, which makes it look
  like monitoring is live when nothing is scraping. Checked 2026-09-22 while trying to answer
  the 111 s API stall from history; the answer is that history does not exist. CV's
  `query_db_latency_ms` **does** already include the `pool.acquire()` wait (their
  `utils/db.py` starts `t0` before the acquire), so the metric is the right one — it is
  simply never recorded. Capture it live with `tools/pilot-stall-capture.sh`.
- **Write commit messages with `git commit -F -` and a heredoc, never `-m "..."`.** A
  backticked phrase inside a double-quoted `-m` string is **command-substituted by the
  shell** and silently deleted from the message. It cost two commits on 2026-09-22 —
  `6586430` lost "the `async with pool.acquire()`" and `37da641` lost
  "`_rec(c) !== REC.Armed -> return false`" — and since `main` is never rewritten here,
  neither can be repaired. The second happened *after* the first was written down, which is
  the argument for the rule rather than the vigilance: quoting code in a commit message is
  normal and the failure is silent, so the only reliable defence is never using the form
  that breaks.
- **A comment asserting how ANOTHER system behaves must say when, or how you know.**
  Enforced on new lines by `tools/tests/cross-system-claim-lint.py`, wired into the
  `pre-commit` hook (`WT_NO_CLAIM_LINT=1` skips it). A date, a source citation
  (`review.py:1430`), a letter reference, or "measured"/"verified" all satisfy it.
  **Diff-scoped on purpose:** cilex-pro-mobile declined a lint of mine on 2026-09-22
  because it would have begun life with an exception list, and they were right — so this
  one judges only the lines a commit ADDS and starts at zero.
  - **Why it exists, measured 2026-09-23.** `qml/ExportDrawer.qml:12`, written 2026-05-27,
    still said cilex-vision's `POST /review/exports` "accepts only `{camera_id, wall_start,
    wall_end, mode}`" and that "Purpose … ha[s] no server field yet". Both went false
    without anyone noticing: CV's model (`review.py:1430-1441`) carries `group_id`,
    `purpose` and `hevc_capable`, and **our own** `PlaybackClient::createExport`
    (`:1150-1151`) sends them. The comment contradicted a change we shipped ourselves
    (`c5b4d98`) and outlived it by four months.
  - **Scope, measured rather than guessed.** A first pass counted 127 offenders; that was
    inflated four-fold. 569 comment lines name another system, but 213 are a bare "backend"
    meaning TLS/media/GStreamer, 243 are architectural rather than behavioural, and 67
    already carry a date. **13 made a behavioural claim with neither a date nor a
    citation** — one false (above), ten now annotated with their `git blame` date, two
    describing our own code and left alone.
  - **Dates come from `git blame`, never invented.** "Written YYYY-MM-DD and not re-checked
    since" is verifiable and is what a reader needs; a date nobody measured would be the
    same defect wearing the fix's clothes.
- **Never `git add -A` in this repo — stage explicitly.** Other agents write letters
  *directly into this checkout's* `docs/letters/`, so at any moment there may be untracked
  work that is not yours. On 2026-09-23 a top-level `git add -A` swept cilex-vision's
  219-line letter into a commit about Warden's heartbeat; the same thing had happened to
  their Labs letter in `fb909a0`. The pre-commit hook has warned about exactly this since
  it was written — *"never `git add -A`, which would sweep unrelated work into someone's
  commit"* — about its own staging, and the warning applies just as much to the human
  running `git commit`.
  **The outcome is not the damage.** `CLAUDE.md` says letters received from another agent
  are committed verbatim, so those files belonged in the repo either way. What breaks is
  the log: a commit whose message describes a Warden change also published somebody else's
  letter, so the letter's arrival is undiscoverable from `git log` and the message is no
  longer a true account of the commit. Stage paths by name; when a received letter turns
  up, commit it deliberately, with its own message.
  - **Now enforced**, not just written down: `tools/tests/received-letter-lint.sh` in the
    `pre-commit` hook refuses a commit that stages a letter whose `From:` is another
    agent alongside any other work. Tested three ways — foreign letter + other work
    fails; foreign letter alone passes; your own letter + other work passes, so the
    normal flow is untouched. cilex-pro-mobile audited their own log after this and
    found `5a95fdd`, a commit titled "полоса кадров ждала ПРОСЬБЫ играть" that also
    published a letter of cilex-vision's. Same shape, same cause, different repo.
  - **`git log --author` cannot tell the agents apart** — all four sessions commit as the
    same operator. The only discriminator is the `Claude-Session:` trailer. Filter on that
    when auditing "what did I actually do".
- **Every figure names the population it was measured on.** A population filter is obvious
  to whoever wrote the query and invisible in the number it produces, which makes it the
  easiest way to publish something true-and-misleading. Four instances on 2026-09-23 alone,
  across two systems:
  - cilex-vision's bandwidth constant — a continuous-cameras figure written down as a fleet
    figure (599 MB/camera-hour; the fleet mix is ~360).
  - their A4-A6 decode estimate — a property of *which stream* stated as a property of the
    analyser (1,750 CPU-h/day against a measured 24.6).
  - their A3 base rate — `tier='hot'` had silently selected the continuous population.
  - **mine**: I re-derived A3 over all cameras, got a 27.96 % base rate against their
    10.72 %, and attributed the gap to a different motion label. It was not the label — we
    both used `motion_events`. Motion-armed cameras only record when motion fires, so ~100 %
    of their segments carry motion by construction. Restricted to continuous cameras the
    rate is 15.88 %, and the top decile falls from 85 % to 52 %.
  **What survived is the instructive part.** The contamination moved every headline number
  and left the decision-relevant one alone: top-30 %-by-normalised-bytes recall was 59.8 %
  contaminated, 58.8 % clean, 57 % on cilex-vision's stricter population. A conclusion that
  is robust to the error is not evidence that the error did not matter — the figures anyone
  would have *quoted* were all wrong.
  So: state the population in the same breath as the number, and when two derivations
  disagree on a rate, suspect the population before the method.
- **Naming the population does not catch a bad step BETWEEN two named numbers.**
  Found by cilex-vision on 2026-09-23, hours after both of us adopted the rule above,
  and it is a different failure from the four instances listed there. They published
  "fetching the top 30 % by normalised bytes is ~199 GB/day while keeping 57 % of the
  motion". Both inputs were correct and correctly labelled. The inference was not:
  30 % of the **segments** is not 30 % of the **bytes**, because the segments the
  ranking puts on top are by construction the large ones. Measured, it is 37.4 % of
  bytes — **~248 GB/day, not 199**. Nothing about naming the population would have
  flagged it; the two factors were already well labelled.
  **What catches it: carry the unit through the arithmetic, on the line.** Written as
  `199 GB/day = 30 % [of segments] × 662 GB/day [of bytes]` the mismatch is visible
  where it is made, rather than in the conclusion. Dimensional analysis, applied to
  prose figures. I have not run this as a habit long enough to claim it works — it is
  a proposal, and I am labelling it as one.
  **What actually caught it was replication BY A DIFFERENT ROUTE, and the
  qualification is the whole point.** I re-derived the result from different SQL and
  produced a 37.4 % they had never computed. Labels catch mis-transcribed
  measurements; only a second derivation catches a wrong step between two right ones.
  **But a second run of the SAME method is not a second measurement — it is the same
  measurement twice**, and it reproduces a wrong number perfectly, forever. Two of
  tonight's errors prove it from both sides: my "24 GB / 93.3 d = 257 MB/day, consistent
  with their 263" was one number derived twice and I presented it as corroboration; and
  re-running my `nspname='public'` denominator would have returned 89.33 % every time
  until the heat death of the universe. Independence of the PATH is what does the work,
  not the fact of a second look.
- **A3's operating table is valid for CONTINUOUS cameras and must be recomputed for a
  mixed fleet** (cilex-vision, 2026-09-23, three populations over 645 k segments). The
  byte-share figures reproduce exactly between their population and mine — top 10/30/50 %
  = 14.1/37.4/58.4 vs 14.2/37.6/58.4 — so `facing` and duration filters do not move the
  segment-size distribution, and our matching 37.4 % was structural, not a shared accident.
  Add motion-armed cameras and the top decile's byte share **halves, 14.1 % → 6.5 %**:
  armed cameras write 4-second segments averaging 0.37 MB against continuous cameras'
  30-second 4.79 MB ones, and a tiny segment can still be large relative to its own
  camera-hour median, so it ranks high on the normalised signal while carrying almost no
  bytes. By the 50 % cut the effect washes out (58.4 vs 58.8), which is why agreement
  there told us nothing.
  Note precisely what this does and does not change: **the signal still works; what moved
  is what a chosen operating point COSTS.** Same population lesson as the entry below,
  arriving through a fourth door — this time not in a base rate but in a price.
- **THE LIMIT ON EVERYTHING ABOVE: none of these disciplines caught the errors that
  were caught. Rereading the output did.** Four checks-that-could-not-fail turned up
  between this box and cilex-vision on 2026-09-23, including one of mine in the
  verification OF one of the others. Every single one was spotted because its output
  looked strange, never because the method was sound — my
  `coalesce((select 'yes, '||count(*) ...), 'no')`, which cannot return `'no'` because
  `count(*)` over an empty set is 0 and never NULL, survived being written and being
  run, and died when "yes, 0 chunks" was odd enough to reread. cilex-vision's
  `MASK IS REAL` on 2 blobs versus 1 went the same way.
  So: **write the check, and then read what it printed as though someone else wrote
  it.** A conventions list is a way of having fewer errors, not a way of catching
  them. The catching is still done by looking.
- **Never divide two values that were already rounded for display.** Mine, 2026-09-23,
  in the same hour as writing the entry above. I read `pg_size_pretty` output — 24 GB
  and 31 GB — divided them, and published "77 %". From exact bytes it is
  25,909,411,840 / 32,763,417,059 = **79.08 %**, and the ratio to the next largest
  table is **9.43x**, not the "9x" I wrote. Both inputs had been rounded to two
  significant figures by a function whose entire purpose is to make numbers readable
  rather than exact, and I reported the quotient to two significant figures as though
  it had that precision.
  I then claimed "a sharper figure exists and I had not looked for it: against the sum
  of all user tables rather than `pg_database_size`, `motion_events` is **89.33 %**".

  **THAT FIGURE IS WRONG AND I PUBLISHED IT TWICE — to the operator, and to
  cilex-vision, who repeated it to theirs. Corrected 2026-09-23.** My denominator was
  `sum(pg_total_relation_size(c.oid)) ... where n.nspname='public' and c.relkind='r'`.
  Hypertable data does not live in `public`; it lives in chunks under
  `_timescaledb_internal`. So the filter silently dropped every hypertable's contents:
  `pg_total_relation_size('video_segments')` reports **64 kB**, the empty parent, while
  `hypertable_size('video_segments')` reports **1,736 MB**. Summed over all relations in
  every non-system schema the denominator is 31 GB, not 27 GB, and `motion_events` is
  **79.13 %** — which converges with the 79.08 % against `pg_database_size`, i.e. with
  cilex-vision's original number.
  **So there was no sharper figure. There was a filter I could see and the number could
  not**, which is verbatim the diagnosis in the entry below — committed by me, hours
  after writing that entry, while correcting someone else's version of it. It is also
  the exact hazard of `pg_total_relation_size` on a TimescaleDB hypertable: it does not
  error, it returns a small plausible number.
  Caught by cilex-vision asking me to re-derive my own figure, having quoted it without
  checking. Re-running my query would have reproduced it perfectly; what caught it was
  computing the denominator a different way.
- **On macOS a second Watchtower instance shares the running one's settings.** There,
  `QSettings` is a CFPreferences plist served by `cfprefsd`, and neither `HOME=` nor
  `CFFIXED_USER_HOME=` redirects it. Measured 2026-09-28 on macOS 26: a probe key written with
  `CFFIXED_USER_HOME` set landed in the real `~/Library/Preferences`. So a test instance started
  beside the operator's (with `WT_TEST_QML`, say) reads the operator's session and can write
  into the live app's settings. For a screen that needs only this module's QML, render it with
  Qt's `qml` tool and a stub model instead:
  - a scratch `qmldir` naming what the screen imports (`singleton Theme 1.0 Theme.qml`, the screen);
  - `QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software qml -I <dir> harness.qml`, the harness
    saving `grabToImage` and quitting;
  - `--translation build-macos/watchtower_ru.qm` for Russian.
  The Labs station strip was verified this way (2026-09-28, `LabsStation.h` `switchable`).

## `motion_events` is 79.1 % of the database — and which denominator, exactly

Three denominators are defensible-looking and one is not. Measured 2026-09-23:

| denominator | size | `motion_events` share |
|---|---|---|
| `pg_database_size` (includes catalogs) | 31 GB | **79.06 %** |
| all relations in non-system schemas (includes hypertable chunks) | 31 GB | **79.13 %** |
| same, but EXCLUDING `_timescaledb_internal` | 27 GB | 89.33 % ← **do not use** |

The first two agree and either is fine. **The third is the one I published**, and it is
not an arithmetic error — it is a correct answer to a question nobody wants: *"what
share of user data, if we exclude the contents of every hypertable?"* The chunks under
`_timescaledb_internal` ARE user data; `video_segments` alone has 1,736 MB there while
`pg_total_relation_size` on its parent reports 64 kB.

**So: quote 79.1 %, and say which denominator.** cilex-vision separately reported
83.9 % against a 28.6 GB denominator; I could not reproduce that figure and do not
repeat it.

## Querying the pilot database: the limit goes INSIDE the SQL

**Every query against the pilot's `timescaledb` sets `statement_timeout` in the SQL
itself.** A timeout on the host does not bound the query.

Measured by cilex-vision on 2026-09-25, and it corrected how this box had been working
all week. `docker exec` does **not** kill the process inside the container when its
client dies. So `timeout 60 docker exec -i timescaledb psql …` — the pattern this box
used for every query — kills only the **host-side client** when it fires; `psql` and
its backend carry on. On 2026-09-23 this box "stopped" a 30-million-row aggregate over
`motion_events` that way and reported it stopped. **It very likely ran to completion on
the live database.** Unprovable after the fact; stated because the mechanism is now
known.

```sql
set statement_timeout = '60s';      -- Postgres cancels it, whatever happens to the client
select …;
```

**And never a forking wrapper or `pkill` INSIDE the container.** There the postmaster
runs as **PID 1** with no init, and Postgres treats any PID-1 child that dies by a
signal as a crashed backend and **restarts every connection on the box**. On
2026-09-25 at 10:49Z a `timeout` + `pkill -f` inside timescaledb crash-restarted the
pilot database three times: 4 API 500s, **15 motion events on 8 cameras never saved**,
2 motion segment-index entries lost, a failed operator-event update and a failed export.
cilex-vision's rule, verbatim: *"Never a wrapper that forks (`timeout`, `nohup`,
`sh -c 'x &'`), and never `pkill` or `killall` inside it. End a session with
`pg_terminate_backend`."* The structural fix — `init: true` on timescaledb in compose —
recreates the database container and is the operator's call.

**And read the database log after anything that touches its processes.** cilex-vision's
own diagnosis of how they missed it: *"I wrote reply8 four minutes after the last of
these and did not read the database log. That one check would have caught it."*

```sh
docker logs timescaledb --since <when> 2>&1 | grep -E "terminated by signal|not properly shut down"
```

## Footage retention is a row in a table — read the row

**Do not quote a retention figure from any document, including this one. Read
`storage_tier_config.retention_days`.** As of 2026-09-23 it is **40 days**, changed
on 2026-09-17; the archive is refilling toward it and holds **6.26 days** right now
(oldest hot/main segment 2026-09-17 12:16). Every "5.5 days" in `docs/perf/*`,
`docs/plans/*` and letters before 2026-09-17 was true when written and is stale now —
those are dated measurement records and are deliberately NOT rewritten.

This constant has now been wrong on both sides of the wire. cilex-vision's
`routers/labs.py` carried `timedelta(days=5, ...)` in three places under a comment
reading "retention on this box runs ~5.5 days"; the claim query therefore refused any
hour older than 5.75 days and was on course to discard 34 days of claimable work while
`queue_remaining` under-reported by the same amount. My own 2026-09-11 letter
"corrected" an operator brief from 35 days to 5.5 — and that correction is now further
from the truth than the thing it corrected.

Same species as the always-false predicate in `EventModel` and cilex-vision's
unreachable `lpr` key: **a constant that was right once, living where the depending
code cannot see the thing that governs it.** It does not error and it does not warn.

- **Run a control that cannot succeed.** A check that has never been shown to produce
  its negative answer has not been shown to work. 2026-09-24, both this box and
  cilex-vision probed camera firmware for which endpoints exist, using the 401-vs-404
  method `CLAUDE.md` endorses. Unauthenticated it returns **401 on every path including
  an impossible one**; authenticated it returns **403 on an impossible path**. Neither
  code discriminates. Without the control this box would have reported four endpoints
  as confirmed present, and cilex-vision would have run three real paths, received three
  200s, and recorded "authenticated probing works".
  This is the same defect as every unfalsifiable check in the entries below — my
  `coalesce((select 'yes, '||count(*) ...), 'no')` that could not return `'no'`, their
  `MASK IS REAL` on 2 blobs versus 1 — but it is the first one where **naming the
  control in advance would have caught it**, because the question "what would this
  print if the thing were absent?" has a cheap, concrete answer: run a path that is
  absent and look.
  **Transferability is the point.** The specific status codes are a fact about one
  firmware and will age out. "Include an input your check must reject" outlives it, and
  is the only part worth writing into a rule.

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
