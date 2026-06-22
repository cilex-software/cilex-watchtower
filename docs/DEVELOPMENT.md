# Cilex Watchtower — Development & Implementation Notes

_Durable implementation reference. Pairs with [PROJECT_STATUS.md](PROJECT_STATUS.md)._

## Stack (locked)

- **UI**: Qt 6.4.2 + Qt Quick / QML (GPU scene-graph compositing). The React prototype in `designs/` is recreated **visually** in QML — JSX is not reused.
- **Core**: C++17.
- **Video**: QtMultimedia `MediaPlayer` + `VideoOutput` (QML), GStreamer backend, **VA-API HW decode** (confirmed on Intel Alder Lake-S iGPU, iHD driver). See "qml6glsink" gotcha below.
- **Persistence**: two stores — `QSettings` (INI) for small operator state (prefs, event acks, saved views), and **SQLite** via `CameraStore` for the local camera inventory at `<AppDataLocation>/Cilex Vision/Watchtower/watchtower.db`. Groups, events, and footage are not persisted locally — they come live from cilex-vision.
- **Network**: `QNetworkAccessManager` (Qt6::Network) for cilex-vision auth + APIs.
- **Build**: CMake + Ninja.

## Build / run / verify

```bash
cmake -G Ninja -B build -S . && cmake --build build   # -> build/watchtower
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
| `WT_PLAYBACK_IP=<ip>` | Boot into Playback for that camera. |
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
- **Namespaced attached properties**: with `import QtQuick.Controls.Basic as QC`, use `QC.ScrollBar.vertical`, not `ScrollBar.vertical` (else "Non-existent attached object").
- **Camera IP lockout**: HiWatch/Hikvision lock an IP ~30 min after failed logins. Do **not** run the full live wall against all cameras during dev (per-camera creds incomplete) — use `WT_TEST_IP`. A tile streams only when its `videoActive` is true (Live Monitor visible); a hidden Live Monitor that keeps players open hammers cameras.
- **Live status polls every 15s**: `CameraModel::pollStatuses()` GETs `/streams` and patches rows **in place** (`dataChanged` per row), never `beginResetModel()` — a reset would tear down every tile's RTSP pipeline each tick. (`WT_NO_POLL=1` disables it.)
- **Green wall = video tiles being recreated.** A restarted pipeline shows a fresh VA-API surface (NV12 0,0,0 ≈ RGB 0,135,0) green until its first decoded frame. So tearing down + recreating a `CameraTile` (→ `VideoSurface` → `MediaPlayer`) flashes it green. The Live Monitor grid **must not** rebuild delegates on data/layout changes. It used to bind `model: pagedCameras` (a `cameraModel.page()` **array**); any new array reference made the `Repeater` destroy+recreate **every** delegate — so a layout switch, page turn, or `countsChanged` greened the whole wall. Now the grid binds a persistent, camId-keyed `ListModel` (`gridModel`) reconciled in place by `syncGrid()` (`onPagedCamerasChanged`): cameras present before and after keep their delegate/pipeline; only genuine enters/leaves create/destroy a tile. When changing this, re-verify tiles are **reused** (instrument the delegate's `Component.onCompleted`/`onDestruction` across a layout switch — persisting cameras must log neither).
  - **Second line of defense (so green never shows even when a pipeline _does_ get recreated, or stalls):** `VideoSurface` keys its `playing` off **actual frame flow** (`_hasRecentFrame`, set on `videoOut.videoSink.videoFrameChanged`, cleared by a 2.5 s stall `Timer`) and lays an opaque `#0a0d11` cover over the `VideoOutput` whenever `!playing`. So the raw green VA-API surface — shown before the first decoded frame **and on a silent stall** (RtspVideoSource flips `playing=false` only on EOS/error/teardown, never on a freeze) — is always hidden behind the cover; consumers show "Connecting…" on top, and it self-heals when frames resume. This is what fixed a single camera (e.g. a stalled substream) showing a frozen green tile + green single-cam view.
- **Keep `countsChanged` off hot paths anyway**: it re-runs every `page()`/`countFiltered()` binding. `pollStatuses()` recomputes counts only on a genuine live/recording flip, **not** on a `last_segment_at` advance (which ticks every poll) — see b5345dd.

## Verification convention

Every change: (1) `cmake --build build` clean; (2) offscreen smoke → zero QML warnings; (3) `WT_SCREENSHOT` PNG for any UI change (use `WT_SECTION`/`WT_DEMO` to reach the screen; a temporary auto-select scaffold is OK for detail panels, but revert it before committing).
