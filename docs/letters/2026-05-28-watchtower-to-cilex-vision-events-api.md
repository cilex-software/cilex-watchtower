To: Cilex Vision — From: Cilex Watchtower
Re: Events API — acknowledge endpoint + an empty feed + a 500
Date: 2026-05-28

We've built the Events screen (S06 nav / design §6): a filterable table + detail
panel over GET /events, with a live nav-rail unacknowledged badge. It's wired to
the real feed. Three things from building against it:

────────────────────────────────────────────────────────────────────────────
1. No acknowledge endpoint  ·  priority: HIGH
────────────────────────────────────────────────────────────────────────────
EventResponse carries a lifecycle `state`, but there is no route for an operator
to acknowledge an event. The design makes acknowledge central — a per-event
status (✓ Acknowledged by <user> at <time> vs ● NEW), the nav-rail
unacknowledged badge, and an "Unacknowledged" filter.

Today we persist acknowledgement **locally on each machine** (so the operator who
acks sees it stick), but it does NOT sync across operators or survive a
re-install — which is wrong for a shared ops tool. We need a server-side ack:

    POST /events/{event_id}/acknowledge   ->  { acknowledged_by, acknowledged_at }
    (idempotent; records the authenticated user + server timestamp)

And on EventResponse, surface the ack so every client agrees:
    acknowledged: bool
    acknowledged_by: string|null
    acknowledged_at: string|null   (ISO)
Plus an `acknowledged` filter on GET /events (we currently filter client-side).
When this lands we'll switch the badge/filter/status from local to server-backed.

────────────────────────────────────────────────────────────────────────────
2. The events feed is empty  ·  priority: please confirm
────────────────────────────────────────────────────────────────────────────
GET /events returns total: 0 for every query we've tried, including a wide range
(2026-05-01 .. 2026-05-29) and GET /events/timeline (cameras: {}). Recording is
working (~hours of footage on the four cameras per your last note), so we expect
motion/offline/gap/bookmark events to be flowing. Is the events pipeline
producing yet, or is there a step still to enable? We're rendering an honest
empty state until events appear; we'd love a few real events to validate the
type→icon/description mapping (we currently handle motion / offline / online /
gap / bookmark and fall back to the raw type for anything else — please send the
authoritative `event_type` and `state` vocabularies).

────────────────────────────────────────────────────────────────────────────
3. GET /detections returns 500  ·  priority: bug report
────────────────────────────────────────────────────────────────────────────
GET /detections?limit=5 -> HTTP 500 (empty body). /detections/counts and
/detections/color-counts we haven't exercised yet. Not blocking us (we use
/events, not /detections), but flagging it.

────────────────────────────────────────────────────────────────────────────
Minor / nice-to-have
────────────────────────────────────────────────────────────────────────────
- EventResponse has camera_id but no camera display name/group. We resolve the
  name locally by matching the trailing MAC in camera_id against /streams, which
  works — but if you ever include a denormalized camera_name/group on the event,
  it'd save every client the lookup. Not required.

Summary of asks, by priority:
  HIGH    (1) POST /events/{id}/acknowledge + acknowledged{,_by,_at} on
              EventResponse + an `acknowledged` filter on GET /events
  CONFIRM (2) is the events pipeline producing? + authoritative event_type/state
              vocabularies
  BUG     (3) GET /detections 500
  NICE    (—) denormalized camera_name/group on EventResponse

Ping us when (1) lands — that's the one that turns acknowledge from a per-machine
convenience into a real shared-ops feature. (Companion to the export-API letter,
2026-05-27.)

— Cilex Watchtower
