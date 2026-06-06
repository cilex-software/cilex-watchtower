# Camera Groups API — live + now manageable from the Cilex Vision web admin

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision (backend)
**Date:** 2026-06-07
**Re:** Camera grouping — backend is now the source of truth (replaces your local SQLite groups); standing item [D §205](./watchtower-to-cilex-vision-api-requests.md) "build the wall from `/streams` (id/name/status/group)"
**Status:** ✅ **SHIPPED + VERIFIED LIVE.** Full CRUD + camera assignment, plus a backend admin UI at `/admin/groups` so groups can be created without going through your client. Round-tripped end-to-end against the live DB on 2026-06-07.

---

## TL;DR

Camera groups are **backend-owned** now. Everything you need is live:

- **`GET /groups`** — list groups with live `camera_count`. Open to any authenticated user. This is what you render the wall's group rail from.
- **`/streams`** already carries **`group_id` + `group_name`** per camera (the denormalized join). Drive the grid from this — you do **not** need to call `/groups` per camera.
- **Mutations** (`POST`/`PATCH`/`DELETE /groups`, `PUT`/`DELETE …/cameras/…`) are **admin+operator**. Your operator login can create/rename/delete groups and (un)assign cameras directly.
- A camera belongs to **at most one group** (single membership). Assigning it elsewhere moves it.
- You can now **drop your local SQLite groups table** — the backend is authoritative and the list is cheap to refetch.

If all you want is to *display* existing groups: call `GET /groups` once for the names/order, then bucket your `/streams` cameras by `group_id`. Done.

---

## Auth (same as everything else)

Cookie `access_token` (JWT), `credentials: include`. No new scheme.

| Operation | Role required |
|---|---|
| `GET /groups` | any authenticated user (incl. read-only / scoped) |
| all mutations below | **admin OR operator** → `403` otherwise |

⚠️ **Scope caveat (brutally honest):** `GET /groups` is **not** camera-scoped — it returns **all** groups for the site, with a `camera_count` over the **whole** fleet. The cameras *inside* a group (which you get from `/streams`) **are** per-user scoped. So a scoped operator can legitimately see `camera_count: 6` on a group while only 2 of those cameras appear on their wall. Don't treat `camera_count` as "cameras I can see" — it's "cameras assigned, fleet-wide." Render your tiles from `/streams`, use `/groups` only for the group's existence/name/ordering.

---

## Endpoints

Base path `/groups` (through your existing proxy → query-api). `camera_id` is the **MAC-keyed stable id** (`{vendor}-{machex}`) exactly as it appears on `/streams` — **not** a UUID; pass it verbatim. `group_id`/`site_id` **are** UUIDs.

### `GET /groups` — list
Any authenticated user. Ordered by `name`.
```json
{
  "groups": [
    { "group_id": "48308261-…", "site_id": "00000000-0000-0000-0000-000000000001",
      "name": "First floor", "camera_count": 4 }
  ]
}
```
`camera_count` = cameras currently assigned (fleet-wide; see caveat above).

### `POST /groups` — create  · admin/operator · `201`
```jsonc
// body
{ "name": "Parking lot", "site_id": "…optional…" }
```
- `name`: required, trimmed, 1–255 chars.
- `site_id`: optional → defaults to the single-site UUID `00000000-0000-0000-0000-000000000001` (same default the cameras/users admin pages use). You almost certainly omit it.
- **`201`** → the new `GroupRead` (`camera_count: 0`).
- **`409`** `{"detail":"A group with this name already exists"}` — names are unique **per site**. This is your "name taken" signal.

### `PATCH /groups/{group_id}` — rename · admin/operator · `200`
```jsonc
{ "name": "Parking — North" }
```
→ `GroupRead` with live `camera_count`. **`409`** on duplicate name, **`404`** if the group doesn't exist (or `group_id` isn't a valid UUID).

### `DELETE /groups/{group_id}` — delete · admin/operator · `204`
Members are **auto-unassigned** (`cameras.group_id` is `ON DELETE SET NULL`) — the cameras survive, they just become ungrouped. **`404`** if the group doesn't exist. No body.

### `PUT /groups/{group_id}/cameras/{camera_id}` — assign / move · admin/operator · `200`
Idempotent. Because membership is single, this **moves** the camera out of any previous group into this one.
```json
{ "camera_id": "hiwatch-083bc1df3a4b", "group_id": "48308261-…" }
```
**`404`** `"Group not found"` or `"Camera not found"` if either side is missing.

### `DELETE /groups/{group_id}/cameras/{camera_id}` — unassign · admin/operator · `204`
Clears the assignment **only if the camera is currently in *this* group** (safe no-op otherwise, so a stale call can't yank a camera out of a group it was since moved to). Idempotent. No body.

---

## Membership is already on `/streams`

Each `/streams` entry carries:

```jsonc
{
  "camera_id": "hiwatch-083bc1df3a4b",
  "name": "Lobby",
  "ip": "192.168.1.106",
  "group_id":   "48308261-…" | null,   // FK, null = ungrouped
  "group_name": "First floor"  | null,  // denormalized, null = ungrouped
  …
}
```

This is the same `group` field referenced in your standing D-section migration note — now formalized as the explicit `group_id` (stable key) + `group_name` (display). **Bucket the wall by `group_id`** (rename-safe); use `group_name` for the label, or cross-reference `GET /groups` for canonical name + ordering. Cameras with `group_id: null` are the "Ungrouped" bucket.

---

## Source of truth + suggested client flow

The backend is now authoritative for grouping (your old local SQLite groups can go). Both your client **and** the new Cilex Vision web admin (`/admin/groups`) write to the same tables, so a group an admin creates in the web UI shows up for you and vice-versa.

- **Display-only:** `GET /streams` (already in your wall loop) gives you everything — group the tiles by `group_id`. Call `GET /groups` if you also want empty groups (zero cameras) to appear as headers, or a canonical name-sorted order.
- **Managing from your UI:** `POST` to create, `PATCH` to rename, `PUT …/cameras/…` to drag a tile into a group, `DELETE …/cameras/…` to pull it out, `DELETE /groups/{id}` to remove the group. After any mutation, refetch `/groups` (+ your next `/streams` poll reflects new `group_id`/`group_name`) — no local cache to reconcile.
- Don't cache group membership long-term; it's cheap and an admin may change it out from under you.

No breaking changes to anything you already consume — `/streams` is unchanged, this just documents the `/groups` surface and confirms the membership fields are stable.

Ping back if you want empty-group semantics tweaked (e.g. suppressing zero-camera groups server-side) or a `member camera_ids[]` array added to `GET /groups` to save the `/streams` cross-reference — both are small.

— Cilex Vision
