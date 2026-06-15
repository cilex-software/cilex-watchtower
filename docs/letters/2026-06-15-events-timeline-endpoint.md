# `/events/timeline` returns empty — we need it (or a variant) for event markers on the scrubber

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-15
**One problem:** we now draw motion episodes on the playback scrubber and need a
*lightweight, server-side* timeline source so a busy camera over a wide (24h)
window stays cheap to render. `GET /events/timeline` already exists and is
documented for exactly this — but it returns empty, and only accepts a calendar
`date`. We need it confirmed/finished, its block contract pinned down, and
(ideally) arbitrary windows + an optional density-bucket mode.

## What we built (context)

Phase 1 of motion markers on the playback timeline shipped (Watchtower `28da64a`):
`motion_started`→`motion_ended` episodes render as start→end spans in a lane under
the footage bar, merged into density bands at wide zoom. Design rationale in
`docs/research/2026-06-15-timeline-event-markers.md`.

Today the client builds those episodes from **raw `/events`**:
`GET /events?camera_id=&start=&end=`, paginated (100/page, capped at 1500), then
pairs `motion_started`↔`motion_ended` by `metadata.recording_id` in the client.
This works for normal windows but is the wrong shape for a busy camera over 24h:
many round-trips, and the cap can silently truncate (a `.106`-class camera emits
hundreds of motion events/day).

## What we found

`GET /events/timeline` is already in your OpenAPI, described verbatim as:

> "Lightweight response for timeline rendering. Returns {camera_id:
> [event_summaries]} — only fields needed to draw blocks, not full metadata.
> Metadata is fetched on click via /events/{id}."

That is exactly the source we want. **But it returns nothing.** Probing the busy
camera `hiwatch-083bc14eff9a`:

```
GET /events/timeline?date=2026-06-14&tz_offset_minutes=180&camera_ids=hiwatch-083bc14eff9a
  → { date, tz_offset_minutes, utc_start, utc_end, cameras: {} }     # 0 summaries
GET /events?camera_id=hiwatch-083bc14eff9a&start=2026-06-14T00:00:00Z&end=2026-06-14T23:59:59Z
  → { total: 144 }                                                   # same window, raw
```

Empty for every camera/date we tried (with and without `camera_ids`), while raw
`/events` has data. So `/events/timeline` looks **defined but not wired** — or there
is a gating/keying detail not visible in the OpenAPI.

## The ask

1. **Status.** Is `/events/timeline` implemented? Why is `cameras` empty when
   `/events` has rows for the same camera+day? If we're missing a required
   param/keying, point us at it; if it's unfinished, please treat this as the
   request to finish it.

2. **Block contract.** Define each `event_summary`. For motion we specifically
   need each block to be an **episode with both a start and an end** (`start_time`
   + `end_time`), so we can draw a start→end span rather than a point — plus
   `event_type` and `event_id` (for click-through to `/events/{id}`). If episodes
   are pre-joined server-side, we don't need `recording_id`; if not, include it so
   we can pair.

3. **Arbitrary window, not just a calendar day.** Our scrubber zooms to any
   `[start, end]` (and sessions can be rolling windows, not whole days). Please
   accept explicit UTC `start`/`end` (like `/events`) in addition to
   `date`+`tz_offset_minutes`. Without it we can't use the endpoint for non-day
   views.

4. **(Optional — the real scalability win) density buckets.** For very busy
   cameras over wide windows, returning every block is still O(thousands). A mode
   that returns **aggregated buckets** — given a bucket count or target pixel width,
   `[{bucket_start, bucket_end, episode_count, motion_seconds}]` — lets us draw a
   clean density band with a bounded, fixed-size response regardless of activity.
   This is the one thing the client genuinely cannot do cheaply on its own.

## Client status — not a blocker

Phase 1 works today via raw `/events` + client-side pairing/merge, so this is a
scalability/cleanliness upgrade, not an outage. If `/events/timeline` returns
lightweight start→end blocks for an arbitrary window, we'll switch to it and drop
the client-side pagination + pairing. Buckets would further let us scale 24h busy
views without truncation.

## How we'll verify

Re-probe `/events/timeline` for `hiwatch-083bc14eff9a` over a known-busy day
(2026-06-14, 144 raw events) and confirm: non-empty `cameras`; blocks carrying
`start_time`+`end_time`+`event_type`+`event_id`; and (if added) a bucketed mode
whose episode/seconds totals reconcile with the raw `/events` count. Then we swap
the scrubber's `EventModel`-pagination path for the new call and re-render a 24h
view of `.106`.

## Related

- `docs/research/2026-06-15-timeline-event-markers.md` — the marker/density UX research this implements.
- `docs/letters/2026-06-14-camera-events-searchable.md` — your note adding first-class event types; same `/events` table this endpoint would summarize.
