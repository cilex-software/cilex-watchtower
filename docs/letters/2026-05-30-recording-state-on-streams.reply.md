# `recording` on `/streams` — delivered (MVP subset)

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision
**Date:** 2026-05-30
**Re:** Standalone brief [`2026-05-30-recording-state-on-streams.md`](./2026-05-30-recording-state-on-streams.md) (D6 in the master letter)
**Status:** ✅ DELIVERED — `"recording"` + `"unknown"`; `"not_recording"` / `"recording_gap"` deferred (rationale below).

---

## TL;DR

`GET /streams` now carries `recording` on every entry, vocab `"recording" | "unknown"`. Computed at request time from `video_segments` (a row with `start_time` in the last 90 s ⇒ `"recording"`, otherwise `"unknown"`). Per-user-scoped exactly like the rest of the response. No new endpoint. cilex-vision commit `d71c78c`; deployed and verified end-to-end.

`"not_recording"` and `"recording_gap"` aren't being emitted yet — see *Roadmap* below — per your "ship what you can honestly source" guidance. Your forward-compatible parser will pick them up the moment they land.

---

## What shipped

One field on each `/streams` entry, alongside `status`:

```jsonc
{ "camera_id": "…", "status": "online", "recording": "recording", … }
```

- Always present (never absent, never JSON `null`). A clean string is easier for the client to reason about than tri-state present/null/absent.
- Per-user-scoped — admin sees all cameras' state; scoped operators see only their own cameras' state (D5 contract unchanged).
- Code path: `services/query-api/routers/streams.py::list_streams` (cilex-vision).

---

## How we compute it

One query per `/streams` request, after the camera fetch:

```sql
SELECT DISTINCT camera_id FROM video_segments
WHERE camera_id = ANY($1)
  AND start_time > now() - interval '90 seconds'
```

- **Why `start_time` (not `end_time`).** The hypertable's indexes are on `(camera_id, start_time)` — `start_time` is the indexed dimension, so chunk exclusion + index lookup keep this sub-ms even under your 15 s poll. An `end_time` filter would force per-chunk seq-scans.
- **Why 90 s.** Segments are ~30 s long, so a healthy recording has a `start_time` within ~30 s of `now()`. 90 s = ~3× segment length, tolerating both the recorder's segment-write latency and one missed segment without lying about a camera that just stopped. False-positive window after recording actually stops: up to 90 s — fine at your 15 s poll cadence.
- **What counts.** Any `video_segments` row (any `stream_type`, any `tier`) — if anything is being written for the camera, the camera is being recorded. Easy to tighten to "main only" later if you want stricter semantics.

---

## Why `"not_recording"` / `"recording_gap"` aren't shipping yet

Both need positive signals the cilex-vision side doesn't expose today:

- **`"not_recording"`** requires **intent** — i.e. recorder is healthy AND deliberately not writing this camera (operator stop, schedule off, policy gate). Without a per-camera recording-enabled bit (separate from camera health), we can't honestly distinguish "stopped on purpose" from "stopped because storage hung." We'd rather say `"unknown"` than guess wrong on a surveillance wall.
- **`"recording_gap"`** requires **gap detection** — comparing the most-recent segment's `end_time` to `now()` (or the previous segment's `end_time`) against a threshold. The recorder already has this concept (`review.py` uses `GAP_THRESHOLD_S = 0.5`), but the gap state isn't published anywhere we can read at `/streams` time. Wiring a writer for it is straightforward; we just haven't built it yet.

---

## Acceptance, against your list

- [x] `GET /streams` returns `recording` on every entry (string, always present).
- [x] Admin: state computed for every camera the admin can see.
- [x] Scoped user: state computed for cameras in their scope (D5 carry-through).
- [x] Reflects **current** state — computed at request time from `video_segments`, no cached/frozen values.
- [x] Vocabulary subset (`"recording"` + `"unknown"`) per your "ship what you can honestly source" guidance.

---

## What you'll see today (caveat, not a contract issue)

When we verified the live response just now, **every camera** read `"unknown"`. That's not a field bug — `video_segments`' most recent row is **~1 h 37 min old** (last `start_time` at 21:17 UTC). The recorder is stalled, almost certainly downstream of the go2rtc memory pressure we surfaced earlier today (20 main streams trying to VA-API-transcode to H.264 simultaneously, hitting the 512 MB cgroup cap, repeated `[exec] timeout` + HEVC decode errors). The field is doing exactly what it should — telling you the truth about an unhealthy system, rather than falsely claiming everything's recording.

Two operational follow-ups on our side, both separate from this contract:
1. Get the recorder writing again (likely blocked on the go2rtc situation above).
2. The §D3 HD-passthrough fast-follow (register `main` as dual-source `[raw rtsp, ffmpeg:…#hardware=vaapi]`) — once `main` is passthrough, the 20 simultaneous VA-API transcodes go away, go2rtc stops thrashing, and the recorder gets clean input again.

---

## Roadmap to the full vocab

Both deferred values land without a client change once we have the signals:

| Value             | What we'd need on the cilex-vision side                                                   |
|-------------------|-------------------------------------------------------------------------------------------|
| `"not_recording"` | A per-camera recording-enabled flag in the control plane, exposed at `/streams` time.    |
| `"recording_gap"` | A near-real-time gap detector against the latest segment; bool exposed at `/streams` time. |

If/when you want a leaner shape for the 15 s poll — e.g. `GET /streams/status` returning just `[{camera_id, status, recording}]` — say the word. Payload-wise the full `/streams` (~20 fields per camera) is fine for now, but at 15 s × N operators it's not nothing.

---

## Cross-reference

- Master letter `watchtower-to-cilex-vision-api-requests.md`: D6 row in the open-asks table + `BACKEND RESPONSE — 2026-05-30 (D6)` block + changelog.
- Sibling delivered earlier today: D1/D2/D5 on `/streams` (rtsp URLs, identity metadata, per-user scope + admin-only `direct_rtsp_*`).
- Commits:
  - cilex-vision `d71c78c` — `feat(query-api): /streams recording field — honest MVP (Watchtower D6)`
  - cilex-watchtower `80a43b7` — `docs(letter): log backend D6 delivery — /streams recording field shipped`

Thanks for the well-scoped brief — the single-field shape made this a small, easily-verifiable change.

— Cilex Vision
