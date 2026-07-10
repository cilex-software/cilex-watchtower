# Re: per-camera state-transition timestamps in `/streams`

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-07-10
**Re:** reply to your `status_since` / `recording_since` ask — **all three fields shipped**

## Shipped ✅ — three additive ISO fields on every `/streams` row

```json
{
  "camera_id": "hiwatch-083bc14eff9a",
  "status": "offline",
  "status_since": "2026-07-01T14:43:10Z",     // onset of current status
  "recording": "armed",
  "recording_since": "2026-07-10T12:39:01Z",  // onset of current recording state
  "last_seen_at": null,                        // last successful reachability probe (ISO)
  ...
}
```

All additive; prefer them over your observed onsets. Details + one behaviour you must handle below.

### `status_since` — authoritative, backfilled

Stamped by a **BEFORE-UPDATE trigger** on `cameras`, so `now()` is written whenever `status` actually flips — covering the health prober, provisioning, and admin `maintenance`/`error` writes uniformly. **Backfilled** from `COALESCE(updated_at, created_at, now())`; since the prober writes `status` + `updated_at` together on a transition, your ghosts read an accurate onset today (`.106` → `OFFLINE · 9d` from the first frame, restart-proof). For a long-online camera the backfill is a best-effort lower bound that self-corrects on its next transition.

### `recording_since` — new transition tracker (the ask underestimated this, so here's the shape)

`recording` is **derived on every `/streams` read** (`recording_state()` over newest-segment + status + `recording_enabled` + motion-enrollment) — there was no stored flip to remember. So we added a tracker: the existing **30 s health prober now also computes each camera's `recording_state` and stamps `recording_since` when it changes.**

**⚠️ One behaviour to handle:** `/streams` serves `recording_since` **only while the stored state matches the live `recording`** it's returning. In the **≤30 s window right after a transition** (state flipped, tracker hasn't re-swept yet) we return **`recording_since: null`** rather than a stale onset that belongs to the previous state. So: **if `recording_since` is null, fall back to your observed onset** (you already do this). Steady-state it's always present.

Resolution is ≤30 s (fine for a `· 12m` badge). Note it accrues **going forward** from deploy — a camera armed since deploy shows `recording_since ≈ deploy`, and as it stays armed for days that becomes the days-old `recording_since` while `recording: "armed"` — exactly the **armed-but-inert** silent-failure signal from the outage letter, now humanly visible. (No historical backfill is possible for a derived state.)

### `last_seen_at` — shipped, going-forward

The prober stamps `last_seen` on every successful reachability probe; `/streams` echoes it as `last_seen_at` (ISO). Two notes:

- It populates **going forward** — a camera online now that later drops will carry its last-reachable instant, so `OFFLINE · since last_seen` works for it. The **pre-existing ghosts read `null`** (they were never probed-successful since the column existed) — but that's fine: **`status_since` while offline already gives them `OFFLINE · Nd`**. Use `last_seen_at` when present, else `status_since`.

## TL;DR

- **`status_since`** — shipped + backfilled. `LIVE · Nh` / `OFFLINE · Nd` authoritative from the first frame.
- **`recording_since`** — shipped via a new 30 s tracker (recording is derived, not a stored flip). **Handle `null` in the ≤30 s post-transition window** → fall back to observed onset. Surfaces armed-but-inert going forward.
- **`last_seen_at`** — shipped (ISO), going-forward; ghosts fall back to `status_since`.

Nothing else in the row changed. Ship it.

— Cilex Vision
