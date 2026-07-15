# URGENT: all recorded footage unplayable — pre-07-15 data apparently deleted, fresh data indexed but not servable

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-16 ~01:30 MSK (22:30 UTC 07-15)
**One problem:** playback is fully blind. Every session we open — including a
window your own coverage index lists as recorded — returns
`availability: "no_recording"`.

## Timeline

- **2026-07-14 13:20 MSK:** our 12 h soak finished, having served hours of
  footage from `.201` (2026-07-08…07-13) and June archive days on
  `.106`/`.120` — all playable then (`docs/perf/2026-07-14-night-3x-soak.md`).
- **2026-07-16 ~00:45 MSK:** discovered while validating a new harness.

## Evidence (all repro-able verbatim, admin session)

1. **Coverage (UTC) now empty for everything pre-07-15:**
   `GET /review/coverage?camera_id=hiwatch-0c75d29549ad` (.201) → `days: []`
   (retention_days: 35!). Same for `.106`. Only `.67` and `.50` show one day:
   2026-07-15, first `21:29:04Z`, last `21:55:10Z`. `generated_at` clusters at
   21:55–22:07 Z — did the index regenerate then?
2. **Sessions can't serve even the indexed fresh window:**
   `POST /review/sessions {camera_id: cam-192-168-1-67, wall_start:
   2026-07-15T21:30:00Z, wall_end: 2026-07-15T21:50:00Z}` — inside the window
   coverage itself lists — manifest = ONE fragment,
   `availability: "no_recording"`. Same for `.201` 07-10 12:00–13:00 Z.
   Index and data disagree in BOTH directions.
3. **Seaweed volumes were vacuuming tonight** (deletion compaction):
   `volume_vacuum.go: Committing volume 1990 vacuuming` on **raw-video-hot**
   at 19:31 Z and volumes 575/726 on **raw-video-warm** at 22:09 Z.
4. **Not an outage of the components we can see:** no container restarted
   (uptimes 3–12 days across query-api / playback-service / recorder /
   seaweed-*), `GET /health/storage` returns 200 continuously, recorder
   reports healthy. Disk on the box has been at 96–97 % all week — if a
   space-pressure cleanup ran, it is the prime suspect from where we sit.

## Questions

1. Did a retention/cleanup job (or manual action) delete pre-07-15 data? Is
   **any** of it recoverable, or is the loss final? (Operator needs to know.)
2. Why does a window present in the UTC coverage index serve
   `no_recording`? Where is the recorder writing right now, and can the
   serve path see it?
3. `retention_days: 35` is what coverage advertises — if effective retention
   is now disk-pressure-driven, we'd like the real policy on the record.

## Client-side impact (why you'll get operator reports)

Watchtower keys its calendar dots and honest-empty day states off coverage —
operators currently see an empty calendar everywhere and cannot reach any
playback. (A separate, possibly related coverage bug — non-UTC `tz` returns
`days: []` even where the UTC index has entries — is filed on its own:
`2026-07-16-coverage-tz-empty.md`.)

We changed nothing client-side; nothing needs changing once serving recovers.
Session/fragment IDs above are yours to pull serve-path logs on — say the
word if you want more probes run from here.

— Watchtower
