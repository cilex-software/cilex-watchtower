---
name: motion-event-lifecycle
description: "How motion_started/motion_detected/motion_ended relate — one episode, three rows joined by recording_id; clip_url lives on motion_detected."
metadata: 
  node_type: memory
  type: reference
  originSessionId: 057dd61f-f06d-42c8-ac7c-9035085a07c1
---

cilex-vision emits **three event rows per motion episode**, joined by a shared `metadata.recording_id`. They are NOT three kinds of motion — they are lifecycle points of ONE episode (verified against live backend rows on 2026-06-15, camera hiwatch-083bc14eff9a):

- **`motion_started`** — onset boundary. `state=active`, no `end_time`, no clip. metadata: `recording_id`, `raw_motion_event_id`, `trigger_type:"motion"`. From the recorder pipeline.
- **`motion_detected`** — the consolidated **incident** record; its `[start_time, end_time]` span equals `[motion_started, motion_ended]`. Opens `state=active`, finalizes `state=closed` with `end_time`. **This is the ONLY one of the three carrying the playable `clip_url`** (S3/MinIO `event-clips/...mp4`). Provenance = camera ISAPI VMD (`metadata.source="hikvision_isapi"`, `event_type:"VMD"`, `kind:"motion_detected"`). This is the ADR-006 first-class camera event.
- **`motion_ended`** — stop boundary; a point event (`start_time == end_time`), `state=stopped`. metadata: `status:"finalized"`, `recording_id`, `segment_count`, `duration_seconds`. No clip.

**UPDATED 2026-06-28 — the client now COLLAPSES the lifecycle to ONE row per episode.** `EventsStore.ingestReal` joins `motion_started`↔`motion_ended` by `recording_id` (across all loaded pages via `eventModel.all()`): one event keyed off the EXACT start (`motion_started.start_time`) with the true span `[start, end]` (`end` = `motion_ended.start_time`). Before this, showing started+ended raw listed every episode TWICE and the inline player's wide window bled into the neighbouring episode → operator P0 (commit `556760a`; backend letter `docs/letters/2026-06-28-motion-episode-representation.md`). **GOTCHA: `motion_ended.start_time` is the episode END, not the start** — opening a review session forward from it lands in empty space (recording is motion-triggered; nothing after motion stops) → the earlier "No footage" P0 (`b0597ee`). `EvHeroPlayer`/Export now open exactly `[start-15s, end+15s]` via `EventsStore.episodeWindow`.

**Earlier (2026-06-15): the client SUPPRESSED `motion_detected`** (still does, via `isSuppressedType()`) so only the `motion_started`/`motion_ended` lifecycle reaches `ingestReal` (operators don't need the deep VMD-incident detail). Drop happens at the single chokepoint `EventModel::fetchPage` via `isSuppressedType()` in `src/models/EventModel.cpp` — fixes the feed, the nav unack badge, and the alerts dropdown consistently. Safe because started/ended cover every episode (totals: started=ended=93, detected=51 ⊂ them). Paging uses a new `m_fetched` counter (raw server rows) for the offset, since kept rows < fetched rows. The "Motion" pill no longer uses `has_clip=true` (that filter = motion_detected only, which we now hide) — it's a client-side pill now (`onFMotionChanged: recompute()`), like Offline/Bookmark. To re-expose detected later, edit `isSuppressedType()` (or gate it behind a setting).

Other consequences:
- `motion_started` + `motion_detected` share (within ~15 ms) the same onset second; before the suppression the panel showed them on the same `HH:MM:SS` (sorts by `start_time`).
- `GET /events/types` is authoritative for labels and also lists `motion` ("Motion (analytics)") and `motion_not_ready` — defined but not emitted by the HiWatch VMD cameras (0 rows).
- Minor cosmetic: the "Load more · X / Y" Y (= `serverTotal`) is the raw DB count incl. the hidden detected rows, so X tops out below Y before the button hides. Acceptable; reconcile only if it confuses operators.

Client side: `src/models/EventModel.cpp` `descForType()` only hardcodes `motion_started`/`motion_ended`; other types fall through the snake_case→Sentence humanizer. See [[s06-playback-gaps]] and [[cilex-vision-playback-api]] for the broader events/playback contract.
