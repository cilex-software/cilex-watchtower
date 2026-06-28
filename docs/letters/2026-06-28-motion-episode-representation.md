# Motion episodes are emitted as three events each, and near-continuous motion is over-segmented

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-28
**Re:** why one motion looked like several clips in the triage queue — the per-episode event lifecycle and motion re-triggering

## How to read this letter

One area (`/events` motion episodes), two related asks. An operator reported a **P0**: two triage rows
that "covered the same motion event" played overlapping footage, and a clip's duration in the player
disagreed with the list. We root-caused it and **shipped a client-side fix** (commit `556760a`: join the
lifecycle by `recording_id`, one row per episode, clip the exact `[start, end]`) — so **nothing below
blocks us**. But the underlying shape of the data is awkward for any client, and the second ask is a
genuine backend-tuning question the operator raised directly ("duplicative fragments should not exist on
the backend"). Neither is urgent.

## TL;DR

1. **Every motion episode emits three events** — `motion_started`, `motion_detected`, `motion_ended` —
   sharing a `recording_id`. There is no episode-level event, so a naive client lists each episode twice
   (started + ended) and has to pair them itself. Please consider an episode view, or confirm the contract.
2. **Near-continuous motion is split into many short episodes** (we measured consecutive episodes
   **0–11 s apart**, one pair contiguous). One person moving around for a few minutes becomes 5–7 separate
   "events." Please consider merging sub-gap episodes, or expose a min-gap parameter, or confirm it's
   intentional.

## Ask 1 — an episode-level representation (or a documented join contract)

For one physical motion the `/events` feed returns three rows with the same `metadata.recording_id`:

| event_type | `start_time` | `duration_ms` | notes |
|---|---|---|---|
| `motion_started` | episode **start** | `null` | no duration |
| `motion_detected` | episode **start** | episode length | carries `clip_url` |
| `motion_ended` | episode **END** | episode length | `start_time` is the END, not the start |

Two things make this error-prone for a client:

- **There is no single "episode" event.** A client that just renders rows shows every episode twice (a
  started row with no duration, and an ended row). To present one row per motion we must group by
  `recording_id` and pair `started`↔`ended` across pages.
- **`motion_ended.start_time` is the episode END.** This is a real trap: opening a review session
  *forward* from a `motion_ended` timestamp lands *after* the motion stopped, where (recording being
  motion-triggered) there is **no footage** — we hit exactly this and it produced an empty session /
  "No footage" until we special-cased it. An explicit `end_time` (and keeping `start_time` = the start on
  every lifecycle row) would remove the trap.

**Ask:** either expose an **episode-level events view** (one row per `recording_id`, with `start_time`,
`end_time`, `duration_ms`, `clip_url`, severity, triage state), or document the join contract above as
stable so clients can rely on it. We've implemented the client-side join, but it has edge cases (a
started/ended split across page boundaries shows a transient partial episode) that a server-side episode
view would eliminate.

## Ask 2 — over-segmentation of continuous motion

On camera `hiwatch-083bc14eff9a` (192.168.1.106), a ~20-minute stretch of one person moving around an
office produced this sequence of separate episodes (each its own `recording_id`):

```
17:30:02–17:31:14  (79 s)
17:31:14–17:32:26  (72 s)   gap 0 s   ← contiguous with the previous episode
17:32:37–17:33:29  (52 s)   gap 11 s
17:33:31–17:33:55  (24 s)   gap 2 s
17:34:18–17:34:37  (20 s)   gap 23 s
17:35:23–17:36:53  (90 s)   gap 46 s
17:36:57–17:49:40  (763 s)  gap 4 s
```

Several boundaries are **0–4 s apart** — i.e. the detector dropped below threshold for a moment and
re-armed, splitting one continuous presence into multiple "events." For an operator clearing a triage
backlog this is noise: the same person, the same continuous motion, listed as 5–7 alarms. (After our
client fix these are at least distinct, correctly-bounded clips — but they're still separate rows.)

**Ask:** consider one of —
- **merge episodes separated by less than a small gap** (e.g. < 10 s) into one recording/episode; or
- expose a **`min_gap` / `merge` parameter** on `/events` (and `/review/sessions`) so the client can ask
  for coalesced episodes; or
- if the segmentation is intentional (e.g. each `recording_id` is a discrete storage object), **confirm
  that**, and ideally provide a `continuation_of` / group id so clients can coalesce them for display.

## What we shipped (so this isn't blocking)

`556760a` joins `started`↔`ended` by `recording_id` into one row per episode, keyed off the exact start,
and the inline player now opens exactly `[start-15s, end+15s]`. This resolved the operator's P0 (duplicate
rows, overlapping clips, duration mismatch). The two asks above would let us delete the client-side join
and would reduce the episode count an operator has to wade through.
