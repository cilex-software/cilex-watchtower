# Cilex Watchtower — Project Status

_Last updated: 2026-05-28. This file is the durable, crash-recoverable snapshot of
where the build is. Implementation details live in [DEVELOPMENT.md](DEVELOPMENT.md);
the design spec is `designs/design_handoff_watchtower/README.md`._

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
- **Health (P5)**: `HealthScreen.qml` — 6 stat cards over `CameraModel` counts + filtered camera table + 380px detail panel. Pure view over existing data.
- **Events (P5)**: `EventsScreen.qml` (filter pills + table + detail panel) + `EventModel` wired to the live `GET /events` feed; locally-persisted acknowledge.

## cilex-vision backend gaps (tracked in letters)

The backend is missing fields/endpoints the design needs. We build the full UI, send
only what the API supports, mark the rest "pending," and file functional-spec letters.
See the single living backlog **`docs/letters/watchtower-to-cilex-vision-api-requests.md`** (sections: A Export & Clips, B Events, C misc):

- **Export & Clips** — export accepts only `{camera_id, wall_start, wall_end, mode}`; needs `purpose`, overlay burn-in (a server re-encode path — exports are stream-copy), a typed job response (size/resolution/expiry), documented `mode`, audio, and a **LIST endpoint for the Clips library** (no way to enumerate past exports today).
- **Events** — **no acknowledge endpoint** (ack is client-local for now); the **`/events` feed is empty** (`total: 0` — is the pipeline producing?); `GET /detections` 500s; needs authoritative `event_type`/`state` vocabularies.

## Deferred (not backend-blocked — more client work; no fake controls shipped)

- **Playback**: mid-playback **codec switch** (H.264 720p ↔ H.265 1440p across `#EXT-X-DISCONTINUITY`) is **unverified** — only happens across the 3-day hot→warm boundary; a static GStreamer pipeline broke at the switch; needs the synthesized multi-day mixed timeline cilex offered. Same-group camera switch in the playback aside.
- **Events**: the mock's Today / All-cameras / +Filter pills, Bookmark / Export actions in the event drawer, "−15s" precise seek on Open-playback. Server-side shared ack pending the letter.
- **Latent (don't manifest with today's data)**: `"hydrating"` fragments are dropped (`availability !== "ready"`) — fine while all footage is hot-tier; `resolution` inferred from codec rather than read.

## P6 progress

- ✅ **Saved Views** — `SavedViewsScreen.qml` (3-col card grid + filter pills) + `SaveViewModal.qml`. `SavedViewModel` now persists views in QSettings (restorable layout/filter/group), with `saveCurrent`/`remove`/`touch`/`toggleFavorite`; mock gated behind `WT_DEMO` (was unconditional). Card counts computed live via `CameraModel.countFiltered`. "Save current view" wired from Live Monitor + the screen; Open applies a view to the Live Monitor.
- ✅ **Preferences completion** (§9) — Workspace (Default landing: Live / saved view / group, applied on boot), Time & language (24h/12h, wired to the now-live top-bar clock + playback), Alerts (sound + desktop-notification toggles, persisted; alert-firing pipeline deferred). Settings gained `defaultLanding`/`time24h`/`alertSound`/`desktopNotifications` + a `clock()` formatter. Light/Dark theme switching deferred (`Theme` is a static singleton). Also fixed the static "17:42" top-bar clock → live + real tz.
- ✅ **Command palette (Ctrl+K)** (§10) — `CommandPalette.qml`: center-top 680px overlay searching cameras / groups / saved views / events over the existing models; grouped results with thumbs + live/rec badges, keyboard nav (↑↓/↵/Esc), footer count. Opens via Ctrl+K and the top-bar search. Activating navigates (camera→detail, group→filtered live, view→apply, event→events). Clips omitted (no enumerable source yet).
- ✅ **Clips & Snapshots library** (§296–304) — `ClipsScreen.qml` + `SnapshotModel` over the local Artifacts dir; artifact table + detail panel (real image preview) + Open / Reveal-in-folder; reached via the command palette (nav rail has no Clips item, per design). Server-exported clips pending the backend list endpoint (letter §A6).

**P1–P6 are all complete.** Remaining work is backend-gated (the API-requests letter) + optional polish/deferred items below.

## Recovery pointers

- Build/run/verify, dev hooks, architecture, API contract, gotchas → [DEVELOPMENT.md](DEVELOPMENT.md).
- Each commit message is written as a context-restoration anchor (`git log` reads like a build journal).
- Design spec of record: `designs/design_handoff_watchtower/README.md` + `design/watchtower.html`.
