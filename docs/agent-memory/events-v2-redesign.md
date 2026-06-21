---
name: events-v2-redesign
description: "Events screen redesign — faithful QML port of designs/events-v2 (4 views over one mock store), shipped behind WT_DEMO"
metadata: 
  node_type: memory
  type: project
  originSessionId: 057dd61f-f06d-42c8-ac7c-9035085a07c1
---

Events screen **redesign** = a faithful Qt6/QML 1:1 port of the `designs/events-v2`
HTML/React prototype (4 specs: triage/verify/timeline/map). **Done + pushed**
(commits `7df90aa`→`d09e397`, 2026-06-18). Durable detail in `docs/PROJECT_STATUS.md`
(§"Events screen redesign").

- **One shared store** `qml/EventsStore.qml` (singleton): events-v2 mock domain +
  the ONLY mutators every view uses — `ack`/`bookmark`/`dispose` — reassigns
  `events` wholesale so counts + all views update live. `EvSnapshot` (procedural
  CCTV still) is the only "video"; all icons via Qt Quick Shapes (no SVG plugin).
- **Views** under `qml/Ev*.qml`: `EventsArea` (shell: 01–04 switcher + status
  strip + Loader stage) → `EvTriage`+`EvPlayer` · `EvVerify`/`EvWall`/`EvSessions`
  · `EvTimeline` · `EvMap`. Primitives: EvIcon/Sev/TypePill/StateTag/EvButton/
  EvPersonGlyph/EvVehicleGlyph.
- **Two data sources** in `EventsStore`: `loadMock()` (the rich showcase) and
  `ingestReal(rows, camLookup)` (live `/events` via `EventModel.all()`), picked by
  `EventsArea` (demo/no-model → mock; else real). `now` + `cams` follow the source.
- **Flags** (`src/main.cpp`): `WT_DEMO` → redesign on the mock showcase; `WT_EVENTS2`
  → redesign on the **live feed**; neither → the backend-wired `EventsScreen` (still the
  default until cutover). `Main.qml` mounts `EventsArea` for `(wtDemo||wtEvents2)`.
- **Backend contract shipped + WIRED** (done 06-18, `233229b`): Cilex Vision shipped all
  five asks (`docs/letters/2026-06-18-events-redesign-shipped.md`, backend `44f7bd8`/mig
  0042). `EventModel.parseRow` reads `severity` / `triage_state` (**NOT `state`**) /
  `disposition` / `disposition_note` / `bookmarked` / `zone_restricted` /
  `detection{class,confidence,bbox}` / `camera_name` / `zone`; ack/disposition/bookmark
  **POST** to `/events/{id}/…` and swap the returned row (WT_DEMO = local fallback).
  `ingestReal` maps them; `actionsPending` now **false** (actions live, not disabled).
  Today every event is `severity:low` + `detection:null` (motion-only) — critical/high + AI
  light up with no rework later. `EventModel` also exposes `durationMs`+`recordingId`.
- **Follow-ups shipped + consumed** (done 06-18, `2ced7d8`; backend `76dd398`/migs 0042+0043,
  their `…-followups-shipped.md`): §1 in_progress fixed (verified/dispatched→in_progress; no
  client change — `_triageToStatus` already maps it). §2 **Assign WIRED** — `EventModel.assignEvent`
  + `fetchOperators` (`GET /operators`); Triage "Assign" button is now a real operator picker.
  §3 `PATCH /cameras/{id} {restricted}` shipped admin-only (we accepted admin-only). §4 = their
  **Camera Map** (`/maps`, `/maps/{id}/objects`, mig 0040) — we'll consume it (asked for a
  `…/{camera_id}/placement` reverse-lookup; grid-fallback unplaced; default active plan).
- **Imagery part 1 — real event frames DONE** (06-18, `52114e1`): `CvImageProvider`
  (authenticated async image provider `image://cvframe/<path>` → GET `<baseUrl>/<path>`, moved
  to GUI thread); `EvSnapshot` real mode shows `GET /events/{id}/snapshot` under the OSD,
  honest "NO FRAME" on 404; mock procedural unchanged.
- **Situation Map on the real Camera Map DONE** (06-18, `9bf148d`): `SiteMapModel` (C++) fetches
  CV's active plan + placements (`/maps?status=active`→`/maps/{id}`→`/maps/{id}/objects`);
  `EvMap` real mode draws the floor plan (pre-signed `background_url`, loaded directly) + pins at
  `(x_norm·W, y_norm·H)`; 2/31 placed, rest in the feed. Shared `MapPin` inline component.
  Gotcha: load fires on realMode **AND** auth ready (ingestReal flips realMode before autologin).
  CV closed the Events backend workstream; unassign now reverts (no client change).
- **Imagery part 2 + Export + CUTOVER DONE** (06-18): `EvHeroPlayer` = real inline HLS in the
  Triage hero (own `heroClient` PlaybackClient, QtMultimedia, wall↔compact seek, real frame as
  poster; EvTriage swaps mock EvPlayer / real EvHeroPlayer via a Loader). Export-clip button
  bubbles `exportClip` → Main's `createExport`. **The redesign is now the DEFAULT Events
  screen** — flags flipped: `WT_DEMO`=mock showcase, **`WT_EVENTS_LEGACY`**=old table screen
  (was the opt-in `WT_EVENTS2`, now removed). Live video needs an on-screen eyeball (offscreen
  can't composite it). **Stable task tracker: `docs/events-redesign-tasks.md`** — maintain row
  status there; rows are fixed.
- **Remaining = optional polish + operational only** (tracker #12–#16): live-frame 404 fallback,
  map-pin rotation, keyboard; + CV-deployment (severity/AI data, camera placement 2/31). Nothing
  on the critical path. See [[handling-design-backend-gaps]].

Verify a single view standalone: `QT_QPA_PLATFORM=offscreen WT_TEST_QML=/tmp/x.qml
WT_SCREENSHOT=/tmp/y.png WT_SCREENSHOT_MS=900 ./build/watchtower` mounting e.g.
`EvVerify{layoutMode:"sessions"}`. See [[build-roadmap]], [[toolchain-setup]].
