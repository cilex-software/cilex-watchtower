# Watchtower plan — camera config sourced from Cilex Vision (per-user)

_Added 2026-05-29. Driven by an operator directive: Cilex Vision is the single
source of truth for camera configuration, delivered per individual user's profile.
Backend contract: see `docs/letters/watchtower-to-cilex-vision-api-requests.md` §D
(D1, D2, D5)._

## Goal

Watchtower holds **no local camera provisioning**. On login, each client fetches
its camera configuration — list, identity, status, **and connection details
(stream URLs / credentials)** — from Cilex Vision via `GET /streams`, already
scoped to that user's profile (need-to-know; Admin = all). The live wall plays
from what the API returns.

## Why (access model)

Admin provisions cameras in the Cilex Provisioner and uploads the config to Cilex
Vision. Each user is granted access to specific cameras; Admin sees all. A client
must never see a camera — or its credentials — outside its profile. Putting the
config behind the per-user-scoped API (not in a local file) is what enforces that.

**Precondition:** an Admin must configure each user's camera scope in Cilex Vision
*before* that user can do any work, or they log in and see nothing.

## Current state (Phase D, Track B)

`CameraModel` already lists cameras from `/streams` (id/name/status/group/ip), but
live RTSP URLs still come from a **local provisioning side-table** joined by MAC.
Consequence (observed 2026-05-29): cameras present in `/streams` but absent from
local provisioning (e.g. `192.168.1.111–.120`, where only `.101–.110` were ever
imported) have **no playable URL → blank tile**. This is the Track B limitation.

## Target (Track A) — what changes

1. **`CameraModel`: build everything from `/streams`.** Each entry → `CameraData`
   including stream URLs taken from the response (see transport selection below).
   Delete the MAC-join and the local-store enrichment.
2. **Remove local provisioning entirely** once the backend lands the connection
   fields: `ProvisioningImport`, the import file dialog, and the SQLite `cameras`
   table. Keep only `camera_id`-keyed operator prefs (name override + favorite)
   locally — or migrate those to the backend later.
3. **No "re-import" workflow** — explicitly rejected; config is never local.

## Transport selection (admin-selectable, default go2rtc)

Backend (letter §D5) returns, per scoped camera:
- `rtsp_url` / `rtsp_sub_url` — **go2rtc restream** (default; camera passwords stay
  server-side). For ALL users.
- `direct_rtsp_url` / `direct_rtsp_sub_url` — raw camera RTSP **with credentials**,
  **ADMIN-authenticated requests only**. Never sent to non-admin users.

Client picks the URL from `Settings.liveTransport`:
- `"go2rtc"` (default) → `rtsp_sub_url` (wall = SD substream) / `rtsp_url` (HD).
- `"rtsp"` → `direct_rtsp_sub_url` / `direct_rtsp_url`.

The wall stays SD (substream) regardless; HD remains an on-demand per-tile / focused
override (see existing CameraTile/SingleCameraDetail behavior).

## Admin-only configuration

- `Settings.liveTransport` (string, default `"go2rtc"`), persisted.
- `AuthController.isAdmin` (role claim == "admin", case-insensitive).
- Preferences → Video → "Live video transport" (go2rtc | Direct RTSP) is rendered
  **only when `AuthController.isAdmin`**; non-admins never see it and always use
  go2rtc. (Backend also withholds `direct_rtsp_*` from non-admins, so this is
  enforced on both sides.)

## Status

- **Done now (this change):** `Settings.liveTransport` (default go2rtc),
  `AuthController.isAdmin`, and the admin-gated Preferences toggle. The setting is
  inert until the backend exposes the URL fields.
- **Pending the backend (letter §D1/D2/D5):** wire `CameraModel` to read the
  connection fields from `/streams` and select by `liveTransport`; then delete
  `ProvisioningImport` + import dialog + the SQLite `cameras` table.

## Sequencing

1. Backend lands D1 (go2rtc `rtsp_url`/`rtsp_sub_url`), D2 (metadata), D5 (per-user
   scope + admin `direct_rtsp_*`), D3 (go2rtc passthrough/on-demand config).
2. Watchtower wires URL selection from `/streams` → the missing-video gap closes
   for every scoped camera.
3. Delete local provisioning. The migration becomes a deletion.

## Notes

- Client-side live latency is still bounded by GStreamer `rtspsrc`'s ~2 s jitter
  buffer (QtMultimedia 6.4.2 exposes no knob) — independent of transport; tracked
  separately.
