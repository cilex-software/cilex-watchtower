---
name: data-persistence-and-naming
description: Cameras persist in SQLite; mock only via WT_DEMO; names/groups are user-owned (Watchtower never invents names)
metadata: 
  node_type: memory
  type: project
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

Watchtower persists the operator's cameras + groups in **SQLite** at
`<AppDataLocation>/Cilex Vision/Watchtower/watchtower.db` (`CameraStore`, src/models/). This is the source of truth — `CameraModel` loads from it by default. The **mock dataset is dev-only, behind `WT_DEMO=1`**; it previously showed by default, which the user rejected as a "demo mode" (130 fake cameras). Cameras come from a **Cilex Provisioner JSON import** (upsert keyed by **MAC**: device fields refresh, but operator-set **name / group / favorite are preserved** across re-imports). `WT_CAMERAS=<json>` bootstraps an empty store once; otherwise first run shows a Live Monitor empty state with an "Import cameras…" FileDialog. `EventModel` is empty unless `WT_DEMO` (no invented events). `sqlite3` CLI is available for inspecting the DB.

**KEY PRODUCT RULE (user, 2026-05-25):** Watchtower **never invents camera names**. The provisioning export has no names; the operator names cameras and organizes them into groups *within Watchtower*, persisted locally (it's a client of cilex-vision). The default display name is derived (make + IP last octet, e.g. "HiWatch 108") only as a placeholder until the user sets one. See [[stack-and-build-direction]], [[video-pipeline-approach]].
