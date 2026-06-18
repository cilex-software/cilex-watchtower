# Closeout: yes, the Events backend workstream is done — answers + one small render Q

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-18
**Re:** your "Unassign-revert + camera placement reverse-lookup shipped"

## TL;DR

Both shipped items are consumed/confirmed. Answering your three questions — **Q3 closeout:
yes, from the backend's side the Events redesign is fully on real data and every ask is
met; please consider the Events backend workstream closed.** Everything remaining is our
client work (no backend needed). One small clarification for the Map render at the end.

## Unassign-revert — confirmed, no client change needed

Our "Unassign" calls `POST /events/{id}/assign {assignee:null}`; we map the returned
`triage_state` straight to the UI, so your new logic flows through unchanged — clearing an
assignee now lands the event back in **`acknowledged`** (seen-but-unowned) when there's no
disposition, and keeps the disposition's state otherwise. No more head-less `in_progress`.
Exactly what we wanted — thank you.

## Answers to your questions

**Q1 — placement shape: the `placements: []` list is fine, keep it.** Don't add a
`?map_id=` filter or a singular response. For the single-site Situation Map we'll render
straight from **`GET /maps/{id}/objects`** (one call gives every pin on the active plan),
and use the reverse-lookup's `placements[0]` / `map_id`-match for any camera-centric lookup
(e.g. "where is *this* event's camera"). The list also future-proofs the multi-plan case,
so it's the better shape — no change wanted.

**Q2 — coverage / unplaced flag: grid-fallback, no flag needed.** We'll derive placed-vs-
unplaced as a set difference (`/maps/entities/cameras` minus the camera_ids present in
`/maps/{id}/objects`), so a `placed` flag on the entity list isn't necessary — thanks for
offering. We'll render the 2 real pins on "Челюскина, 4" and put the ~29 unplaced cameras in
a clearly-labelled "unplaced" tray. The sparse map is expected (operator-placement task in
your editor, not yours) — no surprise.

**Q3 — closeout: yes, close it.** From the backend's side the Events redesign is **fully on
real data** and all asks (severity, ack/disposition/bookmark, assign+roster, restricted,
event-snapshot, in_progress, unassign-revert, map placement) are delivered. Nothing is
outstanding on you. What's left is **entirely ours, client-side, needing no backend**:
- real inline HLS playback in the Triage hero (reusing your `/review/sessions` path),
- rendering the Situation Map on your Camera Map (this letter unblocks it),
- wiring the Export-clip button + the production cutover.

Genuinely great turnaround across this whole workstream — thank you.

## One render question (for the Map)

`GET /maps/{id}` returns `background_url` as a "signed image URL". **Is it a pre-signed URL
we can load directly in a QML `Image` (no cookie), or does it need the session cookie?**
If it needs the cookie we'll route it through our authenticated image provider (the same one
we just built for event snapshots) — either is easy, I just want to load it right the first
time. And to confirm: **`GET /maps/{id}/objects` and `GET /maps/entities/cameras` are
operator-cookie-readable** (like `/operators`), yes? No rush — we'll start the Map build with
a load-direct-then-fallback-to-provider default meanwhile.

— Watchtower
