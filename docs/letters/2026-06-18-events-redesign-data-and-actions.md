# Events redesign on real data — we need per-event severity, AI detail, and shared acknowledge/disposition

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-18
**One problem:** we rebuilt the Events area as four operator views (Triage / Verify /
Timeline / Map) and want to run them on **real `/events`** instead of the mock store.
The event **types** you shipped (your `2026-06-14-camera-events-searchable.md`) already
carry us most of the way. To finish the move off mock data we need five things the
rows don't carry yet: **(1) per-event severity, (2) AI detection detail, (3) a shared
acknowledge + disposition lifecycle, (4) an event-moment still, (5) a restricted-zone
flag.** Severity and the action lifecycle are the load-bearing two — the redesign
sorts, colours, counts, and triages by severity, and its whole point is *acting* on an
event (confirm threat / dispatch / clear), which today only persists locally on one
operator's machine.

## Context (what we built)

Four views over one event stream (`docs/PROJECT_STATUS.md` → "Events screen redesign"):
- **Triage** — priority-sorted queue, clip plays inline, per-type SOP, record a disposition.
- **Verify** — snapshot wall + zone-collapsed "smart sessions", confirm/dismiss at a glance.
- **Timeline** — per-camera swimlanes, duration bars, markers.
- **Map** — pins on a site plan, pulsing where activity is.

All four are built and rendering; they're currently fed by a mock store **only because
the real rows lack the fields below**. We are not asking you to change the event
*types* — those are great. We need richer **per-event attributes** and a small
**action API**.

---

## Ask 1 — Per-event **severity** (the backbone)  ⟵ highest priority

The redesign ranks and colours everything by severity: a `critical` queue, a `CRITICAL`
count chip, red/amber/neutral markers and dots, priority-first sort. `/events` rows
carry no severity today, so we'd either flatten the whole design or invent it — and we
won't fake a backend value.

**Preferred:** a `severity` field on each `/events` row:

```json
{ "event_id": "…", "event_type": "intrusion", "severity": "high", … }
```

`severity ∈ {critical, high, medium, low}`. A simple **server-side rule map** is
completely fine for v1 (you know the event taxonomy better than a client heuristic
would) — e.g. `tamper | intrusion | line_crossing → high`, `video_loss → high`,
`motion_* → low`, escalated to `critical` when it lands in a restricted zone or
after-hours. If you'd rather we compute it client-side, then instead give us the
**inputs** (Ask 2's object class + Ask 5's restricted flag + your event-type weight) and
we'll own the mapping — but a field you control is our preference, so the whole platform
agrees on one severity.

## Ask 2 — AI **detection detail** on detection events

For analytic detections (person/vehicle/face/etc.) the redesign shows a confidence on
the type pill ("Person · 94%") and draws the AI box on the still. We have nowhere to
read that from. When `ai_analytics` is on and a row is a detection, please include:

```json
"detection": {
  "class": "person",            // person | vehicle | face | …
  "confidence": 0.94,           // 0..1
  "bbox": [0.42, 0.18, 0.12, 0.55]   // normalized x,y,w,h (0..1), optional
}
```

`class` + `confidence` alone unlock the pill + sorting; `bbox` is a nice-to-have for the
overlay. Absent this, we show the type with **no** confidence and **no** box (never a
fabricated one).

## Ask 3 — **Acknowledge + disposition** lifecycle (shared, persisted)

This is the redesign's reason to exist, and the biggest honesty gap. Today
**acknowledge is local-only** — each operator's machine remembers its own acks
(`QSettings`); a second operator sees the event as still-new. There is no disposition at
all. We need server-side, shared state:

- `POST /events/{id}/acknowledge` → marks acknowledged, returns `acknowledged_by`, `acknowledged_at`.
- `POST /events/{id}/disposition` `{ "disposition": "verified" | "dispatched" | "authorized" | "false_alarm" | "dismissed", "note": "…" }` → records the outcome.
- `POST /events/{id}/bookmark` `{ "value": true|false }` (or reuse your `bookmark` event type) → per-event flag.

…and surfaced back on the `/events` row so any client reflects it:

```json
"state": "new" | "acknowledged" | "in_progress" | "resolved" | "dismissed",
"disposition": "dispatched" | null,
"acknowledged_by": "ops-2", "acknowledged_at": "2026-06-18T20:47:46Z",
"note": "patrol dispatched"
```

Until this exists we keep acknowledge **local-only and labelled as such** ("not yet
synced") and the disposition buttons stay **disabled with a 'pending backend' note** —
we won't silently no-op them.

## Ask 4 — An **event-moment still** (thumbnail at `start_time`)

The wall, the queue thumbnails, and the map feed are snapshot-first. Your
`snapshot_url` is a **live** frame (good for live tiles) — for a past event we need the
frame **at the event moment**. Either is fine:

- `GET /events/{id}/snapshot` → a JPEG at the event's `start_time`, **or**
- `GET /cameras/{camera_id}/frame?at=2026-06-18T20:47:46Z` → a still at an instant.

Without it we fall back to the **live** `snapshot_url` (labelled "live") or a frame
pulled from playback — usable, but not the event itself.

## Ask 5 — **Restricted-zone** flag (small, optional)

The redesign tags events in restricted areas (`RESTRICTED ZONE`) and uses it to escalate
severity. A per-camera or per-zone boolean is plenty — e.g. `restricted: true` on the
camera record, or a `zone_restricted` on the event row. Absent it, we simply don't show
the tag.

---

## Priority for us

1. **Ask 1 (severity)** and **Ask 3 (acknowledge + disposition)** — these two unblock the
   redesign on real data; everything else degrades gracefully without faking anything.
2. **Ask 4 (event still)** — meaningfully better thumbnails; we have a live-frame fallback.
3. **Ask 2 (detection detail)** and **Ask 5 (restricted)** — polish; cleanly absent until then.

## What we'll ship now, without any of it

We're wiring the four views to **real `/events`** immediately, with honest "pending"
everywhere a field is missing: **neutral severity** (no invented critical/high), **no AI
confidence/box**, **local-only acknowledge** (clearly labelled) with **disabled**
disposition buttons, **real HLS playback** in the inline player (seeked to the event
moment, reusing the playback path), and **live-frame** thumbnails as the snapshot
fallback. As each ask lands, the corresponding pending state simply turns real — no
client rework, no fabricated data in the meantime.

— Watchtower
