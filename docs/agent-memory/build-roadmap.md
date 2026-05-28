---
name: build-roadmap
description: Cilex Watchtower P1–P6 build phases and current position (P4 Export+snapshots is next)
metadata: 
  node_type: memory
  type: project
  originSessionId: 07da05e9-981a-465b-aad6-7f1cc1e8c07c
---

Cilex Watchtower is a native Ubuntu Qt6/QML/C++ surveillance VMS (not a browser app), client of the cilex-vision platform. Locked stack: Qt 6.4.2 + QML, C++ core, QtMultimedia (VideoOutput+MediaPlayer) with VA-API HW decode confirmed working. Build: `cmake -G Ninja -B build -S . && cmake --build build`.

Phased build order and status (as of HEAD e340c30, clean tree):
- ✅ P1 Foundation + Live Monitor (16-stream wall proven)
- ✅ P2 Single Camera Detail (S05)
- ✅ P3 Playback + timeline (S06) — see [[s06-playback-gaps]]
- 🟡 **P4 Export + snapshots — client UI done (2026-05-27, uncommitted), backend follow-up pending.** Full Export drawer + confirm modal built (`qml/ExportDrawer.qml`); snapshots already worked. cilex-vision's export API only accepts 4 fields, so purpose/overlays/audio are "pending backend" — spec letter in `docs/letters/`. The Clips & Snapshots library (§296–304) was deliberately left to P6. See [[s06-playback-gaps]].
- ✅ **P5 Events + Health — DONE.** Health (commit d1ad10f): `qml/HealthScreen.qml` — 6 stat cards over CameraModel counts + filtered table + 380px detail panel; added a `gap` statusFilter; default card = Visible (real fleets mostly online). Events (2026-05-28): `qml/EventsScreen.qml` (filter pills + table + detail panel) + `EventModel` wired to live `GET /events` (own auth; **feed is empty today, total 0** → honest empty state; full table verified via WT_DEMO mock); added `CameraModel.cameraByBackendId` (resolve backend camera_id→local camera by MAC). **Acknowledge is client-side + persisted in QSettings** (no backend ack endpoint — requested in `docs/letters/2026-05-28-watchtower-to-cilex-vision-events-api.md`, which also reports the empty feed + a /detections 500). **Deferred (not backend-blocked, just more client work):** Today/All-cameras/+Filter pills, Bookmark/Export actions in the event drawer, "−15s" precise seek; server-side shared ack pending the letter.
- ⬜ P6 Saved Views / Clips / Prefs / polish

Screens map to S-numbers (Live, S05 Single Camera Detail, S06 Playback…). Product invariants in [[product-rules]]; backend contract in [[cilex-vision-playback-api]].
