# Ask: per-camera state-transition timestamps in `/streams` (status_since / recording_since)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-07-10
**Re:** new, self-contained ask — feeds the status-badge timers shipped today

## TL;DR

Watchtower's camera badges now show **how long a camera has been in its current state** — `LIVE · 2h`, `REC · 12m`, `OFFLINE · 3d` (operator-requested; on by default, toggleable in Preferences). Today the client can only timestamp transitions **it witnesses** between its 15-second `/streams` polls — so a state that began before the app launched shows no timer at all, and every restart forgets the onsets. Two ISO fields per stream row would make the timers authoritative:

```json
{
  "camera_id": "hiwatch-0c75d29549ad",
  "status": "online",
  "status_since": "2026-07-08T14:01:22Z",        // ← when the current status began
  "recording": "armed",
  "recording_since": "2026-07-10T00:31:05Z",     // ← when the current recording state began
  ...
}
```

## Why this is cheap on your side (we believe)

Your health checker already *detects* these transitions (it flips `status`, emits `motion_not_ready` on ISAPI loss, etc.) — the ask is only to **remember the last flip time** per camera and echo it in the rows `/streams` already serves. No new endpoint, no schema break (additive fields; our parser is unknown-key-safe both ways).

## What it buys operationally

- **Timers correct from the first render** — "OFFLINE · 3d" instead of a blank until the client happens to witness a change. For the 31 unplugged cameras, that's the difference between a wall that says *how long* they've been gone and one that just says "offline".
- **Restart-proof**: shift handovers and app restarts keep the history.
- It pairs with the asks already on your list from the outage letter — a camera whose `recording_since` is days old while `recording: "armed"` is the same silent-failure class we keep converging on (armed-but-inert, clock-vetoed, auth-locked). One authoritative "since" field makes all of those humanly visible.

## Nice-to-have while touching it (optional)

- `last_seen_at` as machine-readable ISO (today we get a display string) — lets the OFFLINE badge fall back to *"offline since last_seen"* even before any flip is observed.

Client-side is already shipped and degrades gracefully: if/when the fields appear, the badges will prefer them over observed onsets with a small change on our side.

— Watchtower
