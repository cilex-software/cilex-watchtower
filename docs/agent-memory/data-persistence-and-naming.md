---
name: data-persistence-and-naming
description: Camera inventory persists in SQLite (groups are backend-owned, not local); mock only via WT_DEMO; camera names are user-owned (Watchtower never invents names)
metadata: 
  node_type: memory
  type: project
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

Watchtower persists the operator's **camera inventory** in **SQLite** at
`<AppDataLocation>/Cilex Vision/Watchtower/watchtower.db` (`CameraStore`, src/models/). This is the local source of truth for cameras — `CameraModel` loads from it by default. **Groups are NOT in SQLite**: groups + membership are owned by cilex-vision (fetched from the backend on auth; membership applied from `/streams`), and the DB `group_id` column is vestigial (`CameraModel.cpp` ~63-93). The **mock dataset is dev-only, behind `WT_DEMO=1`**; it previously showed by default, which the user rejected as a "demo mode" (130 fake cameras). Cameras come from a **Cilex Provisioner JSON import** (upsert keyed by **MAC**: device fields refresh, but operator-set **name / favorite / order are preserved** across re-imports). `WT_CAMERAS=<json>` bootstraps an empty store once; otherwise first run shows a Live Monitor empty state with an "Import cameras…" FileDialog. `EventModel` is empty unless `WT_DEMO` (no invented events). `sqlite3` CLI is available for inspecting the DB.

**KEY PRODUCT RULE (user, 2026-05-25):** Watchtower **never invents camera names**. The provisioning export has no names; the operator names cameras *within Watchtower* (persisted locally). (Grouping is now **backend-owned** — cilex-vision's `/groups` + `/streams` — not organized locally; this superseded the earlier local-groups design.) The default display name is derived (make + IP last octet, e.g. "HiWatch 108") only as a placeholder until the user sets one. See [[stack-and-build-direction]], [[video-pipeline-approach]].
