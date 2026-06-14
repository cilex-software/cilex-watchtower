# Camera events are now searchable — new event types on /events (no API change)

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision (backend)
**Date:** 2026-06-14
**Re:** ADR-006 Phase 2 — first-class camera events; backend commit `9603f10`
**Status:** ✅ Shipped + deployed. **No API/contract change** — your existing `/events` filter just gains new `event_type` values. Action on your side is optional (label/iconography).

---

## What changed

In basic (NVR) mode the product records on **motion only**, but the camera also
reports other events over ISAPI (line crossing, intrusion, region enter/exit,
tamper, scene change, video loss, …). Those are now **captured as first-class,
searchable `events` rows** — same table, same `/events` filter you already use
for motion. They do **not** trigger recording (motion is the only trigger).

## What you get

`GET /events/types` now returns these additional values (it auto-discovers from
the data + carries display labels):

| `event_type` | label |
|---|---|
| `line_crossing` | Line crossing |
| `intrusion` | Intrusion |
| `region_entrance` | Region entrance |
| `region_exiting` | Region exiting |
| `tamper` | Tamper |
| `scene_change` | Scene change |
| `video_loss` | Video loss |
| `face_detected` | Face detected |
| `defocus` | Defocus |
| `pir` | PIR |
| `camera_event` | Camera event (other) — catch-all for an unmapped vendor type |

These are **in addition to** the existing motion types (`motion_started`,
`motion_ended`, `motion_detected`, …). Filtering is unchanged: pass any of them
in your existing `event_types[]` query param to `GET /events`.

Each row carries the usual `camera_id`, `start_time`, optional `end_time`
(stateful events like `video_loss`/`intrusion` get a duration; instantaneous
ones like `line_crossing` are point events), and `metadata_jsonb` with:
- `subtype` — the raw vendor `eventType` (e.g. `regionExiting`) for display/forensics,
- `channel`, `trigger_type: "camera_event"`.

## Two things worth knowing

1. **Capture rides the motion alertStream**, so a camera produces these only
   while it's motion-supervised (enrolled/armed) — the same cameras that do
   motion recording. As you arm more cameras, their camera events start flowing.
2. **The camera must actually emit the event.** Most of our HiWatch units only
   have VMD enabled today; line-crossing/intrusion/etc. only appear if those
   detectors are configured on the camera (a camera-config step, not a code
   gate). So expect the new types to populate gradually as cameras are
   configured. `video_loss` will appear whenever a camera genuinely drops video.
   (We also stopped persisting the camera's `videoloss/inactive` keepalive — it
   was ~99.5% of raw events and never a real event.)

## Ask

If you want, add labels/icons for the new `event_type` values in the events-screen
filter. Nothing else is required — your filter already accepts them. Ping back if
you'd like a `metadata.subtype` filter or any other shaping.

— Cilex Vision
