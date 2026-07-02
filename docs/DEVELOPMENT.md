# Cilex Watchtower — Development & Implementation Notes

_Durable implementation reference. Pairs with [PROJECT_STATUS.md](PROJECT_STATUS.md)._

## Stack (locked)

- **UI**: Qt **6.8.3** + Qt Quick / QML (GPU scene-graph compositing) — build against 6.8.3, **NOT** Ubuntu 24.04's system Qt 6.4.2, which has two fatal bugs (a QtMultimedia VideoOutput memory leak and a GridLayout SIGSEGV — see Build and Gotchas). The React prototype in `designs/` is recreated **visually** in QML — JSX is not reused.
- **Core**: C++17.
- **Video**: QtMultimedia `MediaPlayer` + `VideoOutput` (QML), GStreamer backend, **VA-API HW decode** (confirmed on Intel Alder Lake-S iGPU, iHD driver). See "qml6glsink" gotcha below.
- **Persistence**: two stores — `QSettings` (INI) for small operator state (prefs, event acks, saved views), and **SQLite** via `CameraStore` for the local camera inventory at `<AppDataLocation>/Cilex Vision/Watchtower/watchtower.db`. Groups, events, and footage are not persisted locally — they come live from cilex-vision.
- **Network**: `QNetworkAccessManager` (Qt6::Network) for cilex-vision auth + APIs.
- **Build**: CMake + Ninja.

## Build / run / verify

> **Build and run against Qt 6.8.3 — the system Qt 6.4.2 leaks/crashes in live use.** Ubuntu 24.04's
> Qt 6.4.2 has a QtMultimedia **VideoOutput memory leak** (live video retains ~one frame-buffer per
> rendered frame → ~260 MB/s on a 9-tile wall → ~9 GB → earlyoom SIGTERMs the app in ~30 s) and a
> QtQuick.Layouts **GridLayout SIGSEGV** on maximize/minimize. Both are fixed in 6.8.3, which the app
> builds and runs on **unmodified**. Install it user-space once and build against it:
>
> ```bash
> python3 -m venv /tmp/aqtenv && /tmp/aqtenv/bin/pip install aqtinstall
> /tmp/aqtenv/bin/aqt install-qt linux desktop 6.8.3 linux_gcc_64 \
>     -m qtmultimedia qtshadertools -O "$HOME/Qt"        # ~2 GB; pulls the wayland plugins too
> cmake -G Ninja -B build68 -DCMAKE_PREFIX_PATH="$HOME/Qt/6.8.3/gcc_64" -S . && cmake --build build68
> ./run-watchtower.sh        # launcher: points lib/plugin/QML paths at 6.8.3, runs build68/watchtower
> ```
>
> Verified leak-free on real Wayland: cap-9 live wall, 90 s / 10,608 frames, RSS flat at ~950 MB (vs
> 8.5 GB → OOM in 30 s on 6.4.2). The GridLayout workarounds (manual camera grid, `Grid` positioners)
> are harmless on 6.8.3 and can be reverted later if desired.

The system-Qt 6.4.2 build still compiles and is fine for **offscreen** smoke/screenshot checks (no
video), but leaks/crashes in live use — don't ship or live-test on it:

```bash
cmake -G Ninja -B build -S . && cmake --build build   # system Qt 6.4.2 — offscreen checks only
```

- **Headless smoke test** (no display): `QT_QPA_PLATFORM=offscreen timeout 6 ./build/watchtower`
  — exit **124** (timeout killed it) = QML loaded fine; exit **255** = a load/QML error was printed to stderr. Grep stderr for `.qml:` / `warning` / `Unable to assign` / `Non-existent`.
- **Screenshot to PNG** (env-gated hook in `main.cpp`, no display needed):
  `WT_SCREENSHOT=/tmp/x.png WT_SCREENSHOT_MS=1500 QT_QPA_PLATFORM=offscreen timeout 12 ./build/watchtower`
  — renders the window then quits; read the PNG back to inspect the UI. This is the standard visual-verification path. A real Wayland session also exists (`WAYLAND_DISPLAY=wayland-0`).

## Dev hooks (environment variables)

| Var | Effect |
|-----|--------|
| `WT_DEMO=1` | Use the mock dataset (cameras + events). **Off by default** — real persisted data is the source of truth. Mock is dev-only. |
| `WT_SECTION=live\|groups\|events\|health\|…` | Boot directly into a nav section. |
| `WT_FOCUS_IP=<ip>` | Boot into Single Camera Detail for that camera. |
| `WT_PLAYBACK_IP=<ip>` | Boot into Playback for that camera. (`WT_PLAYBACK_DAY=yyyy-MM-dd[Thh:mm:ss]` opens a specific day / instant.) |
| `WT_TTFF_DAYS=d1,d2,…` | Playback open-latency harness: opens each day in turn, logs `[TTFF]` (calendar-click → first rendered frame) + `[PBTIME]` stage breakdowns, quits. Pair with `WT_PLAYBACK_IP`. `WT_TRACE=1` alone also enables the `[PBTIME]` logs. |
| `WT_TEST_IP=<ip>` | Restrict live streaming to one camera during dev (avoid hammering cameras — see lockout caveat). |
| `WT_CAMERAS=<provisioning.json>` | One-time bootstrap import into an empty camera store. |
| `WT_SCREENSHOT=<path>`, `WT_SCREENSHOT_MS=<ms>` | Screenshot hook (above). |
| `WT_CV_URL`, `WT_CV_USER`, `WT_CV_PASS` | cilex-vision backend base URL + credentials (dev defaults baked in source; override via env). |

## Architecture

- **`src/models/`** — C++ models exposed to QML:
  - `CameraStore` — SQLite-backed camera inventory; upserts by **MAC** (device fields refresh, operator-set name/favorite/order preserved across re-imports). The `group_id` column is vestigial — group membership comes from the cilex-vision `/streams` API at runtime, not SQLite. `ProvisioningImport` parses a Cilex Provisioner JSON export.
  - `CameraModel` — `QAbstractListModel` over the store; live status counts (`onlineCount`/`offlineCount`/`degradedCount`/`notRecordingCount`/`recordingGapCount`), `page(group,statusFilter,sort,…)`, `cameraByBackendId(camera_id)` (resolve cilex-vision id → local camera by MAC). Status filters: `online/offline/degraded/recording/notrec/gap/favorites/issues/recent`.
  - `EventModel` — events feed: live `GET /events` (own authenticated session) or `WT_DEMO` mock; roles for the ops sidebar; `all()` (maps for the Events screen); acknowledge persisted locally in `QSettings["eventAcks"]`.
  - `PlaybackClient` + `HlsProxy` — cilex-vision recorded playback (see below).
  - `GroupModel`, `SavedViewModel` (persisted views), `SnapshotModel` (lists the local snapshot dir for the Clips library), `StorageHealth` (authenticated poll of `GET /health/storage`), `Settings`, `Artifacts` (snapshot dir), `MockData` (WT_DEMO).
- **`qml/`** — screens (`Main`, `LiveMonitor`, `SingleCameraDetail`, `PlaybackScreen`, `ExportDrawer`, `HealthScreen`, `EventsScreen`, `PreferencesScreen`, `CameraGroups`) + components (`Theme` singleton tokens, `Icon`, `IconButton`, status badges, `PlaceholderVid`, `VideoSurface`, `Toast`/`ToastHost`).
- **`Theme.qml`** — design tokens (warm graphite palette, amber accent, Space Grotesk + JetBrains Mono, 4px spacing, 0-radius geometry). Match the handoff exactly.

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
- **Qt 6.4.2 has two fatal bugs — build on 6.8.3 (see Build).** (1) QtMultimedia `VideoOutput` leaks ~one frame-buffer per rendered frame: bisected to `m_sink->setVideoFrame()`, reproduced on OpenGL/Vulkan/software RHI and with **both** RtspVideoSource and QMediaPlayer, and custom render paths (QSGSimpleTextureNode + `createTextureFromImage`, QQuickPaintedItem/FBO) leak *worse* — there is **no client-side workaround on 6.4.2**. → ~260 MB/s on a 9-tile wall → earlyoom SIGTERM (the "Terminated" the operator saw) in ~30 s. (2) `GridLayout` SIGSEGVs in `QQuickGridLayoutBase::rearrange` after minimize/restore. **6.8.3 fixes both** (verified). The diagnostics that found it stay in `main.cpp`: a **fatal-signal handler** (prints signal + RSS at death → instantly tells OOM-SIGTERM from a code SIGSEGV) and `WT_TRACE=1` (`[WT-MEM] rss/live_pipelines/frames` every 2 s).
- **Video decode is hardware-vs-software by GStreamer *rank* — verify it, especially on Windows.** The live `decodebin` pipeline auto-picks the decoder by rank. On this box the **`va` plugin** provides HW decode: `vah264dec`/`vah265dec` are rank `primary+1` (257), klass `Codec/Decoder/Video/Hardware`, outranking software `avdec_h264`/`avdec_h265` (rank `primary`, 256). So VA-API HW decode is used **when it initialises**, but `decodebin` **silently falls back to software** if it doesn't (and `gstreamer-vaapi`'s `vaapih264dec` is rank `none` here — it's the newer `va` plugin that matters). Diagnostics + policy live in `RtspVideoSource`: **`WT_TRACE`** logs the codec + bound decoder + HW/SW (`[WT-DEC] … (hardware)` / `(SOFTWARE)`); **`WT_HW_ONLY=1`** makes `decodebin` *refuse* any non-hardware video decoder (the tile errors and the reconnect watchdog retries, instead of software-decoding). Use `WT_HW_ONLY` to **guarantee no software H.264/H.265 decode** — it matters for CPU **and** codec-patent exposure (the OS/GPU decoder carries the patent licence; a bundled *software* decoder shifts that burden onto us). **Windows port:** the HW equivalent is `d3d11h264dec`/`d3d11h265dec` (DXVA, from gst-plugins-bad's `d3d11`) — bundle it, run with `WT_HW_ONLY=1`, and confirm `[WT-DEC]` shows `d3d11…(hardware)`, never `avdec…(SOFTWARE)`. The QMediaPlayer/HLS playback path uses Qt's **FFmpeg backend** (FFmpeg 7.1, LGPL 2.1 — logged as `qt.multimedia.ffmpeg`) on both platforms; verify *it* HW-decodes (its own HW-device config) rather than silently software-decoding HEVC.
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
