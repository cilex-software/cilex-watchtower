# Cilex Vision — please add a per-camera footage-coverage endpoint (`GET /review/coverage`)

**From:** Watchtower (operator client)
**Date:** 2026-05-30
**Priority:** MEDIUM-HIGH (drives the new playback calendar; UI is built and waiting)
**Scope:** one new read-only endpoint. Pre-aggregated daily summary of recorded footage.
**Master-letter code:** **A7** (review/playback API family).

---

## The problem we need you to solve

We've added a **footage calendar** to the playback screen (right-hand aside, under the
camera info). It shows the last *N* days and marks **which days have recorded footage**,
so an operator can see at a glance where footage exists and click a day to load its
full 24h. We need a backend source for two facts:

1. **Which calendar days have footage** for a given camera, across the retention window.
2. **How wide the window is** — the number of days of the **longest storage tier**
   (so the calendar spans the full retention period, not a guess).

### Why we can't derive this from what exists today

`GET /recording/segments` is the only current source of per-segment footage, but it
**cannot enumerate a multi-day window**:

- `limit` is capped at **1000** (we tested: `limit=2000` → `422 less_than_equal`).
- There is **no `offset`/cursor**, so we can't page through a day, let alone 35 days.
- At ~1 segment / few seconds × many cameras, 1000 rows is well under a single day.

`/admin/storage-tiers` *does* carry `retention_days` (currently **35**), but it's
**admin-scoped** — a normal operator can't read it, so we can't use it to size the
calendar for everyone.

So we need a small, pre-aggregated, operator-readable endpoint. Walking raw segments
client-side is exactly what we should not do.

---

## What we'd like you to add

```
GET /review/coverage?camera_id=<id>[&tz=<IANA>][&days=<int>]
```

### Request

| Param        | Req? | Meaning |
|--------------|------|---------|
| `camera_id`  | yes  | Same id as `POST /review/sessions` (`"hiwatch-<mac_hex>"`). |
| `tz`         | no   | IANA tz (e.g. `Europe/Moscow`). **Day boundaries are computed in this tz.** Default `UTC`. See "Timezone" below — it matters. |
| `days`       | no   | Clamp the window to the last N days. Default = full retention (`retention_days`). |

### Response (200)

```jsonc
{
  "camera_id": "hiwatch-083bc14eff9a",
  "tz": "Europe/Moscow",          // tz the day boundaries were computed in (echoes request)
  "retention_days": 35,           // ← REQUIRED. The longest configured raw-video tier
                                  //   retention (today: storage-tiers.retention_days=35).
                                  //   This is the calendar's span. Policy max, NOT the
                                  //   currently-fitting capacity (~3.5d warm right now).
  "generated_at": "2026-05-30T12:45:00Z",
  "days": [
    {
      "date": "2026-05-30",       // ← REQUIRED. Local calendar day in `tz`, YYYY-MM-DD.
      "has_footage": true,        // ← REQUIRED (or omit days that have none — see below).
      "seconds": 81560,           // optional — total recorded seconds that day
      "coverage_ratio": 0.944,    // optional — seconds/86400, 0..1 (we'd shade by this)
      "tiers": ["hot"],           // optional — which tiers hold that day (hot|warm|cold)
      "first": "2026-05-30T00:01:12+03:00",   // optional — first footage of the day
      "last":  "2026-05-30T22:39:50+03:00"    // optional — last footage of the day
    }
    // …
  ]
}
```

### Two response shapes both work for us

We handle either, pick whichever is cheaper for you:

- **Dense:** one entry per day in the window, each with `has_footage: true|false`.
- **Sparse:** only the days that *have* footage (omit empty days entirely).

Our client treats "entry present with `has_footage !== false`" as "has footage", so a
sparse list of footage-days alone is sufficient. Empty days simply render unmarked.

### Minimum viable vs. nice-to-have

- **Must ship:** `retention_days` + a list of `{ date, has_footage }` (or sparse dates).
  That alone fully drives the calendar.
- **Nice later:** `coverage_ratio` / `seconds` (lets us shade days by how much footage
  exists — a coverage heatmap), `tiers`, `first`/`last`. Add them when convenient; we'll
  light them up with no breaking change.

---

## Timezone — please don't skip this

The pilot operator runs in **UTC+3 (Europe/Moscow)**. If days are bucketed in UTC,
footage recorded at 01:00 local on the 30th lands on the 29th's UTC bucket and the
calendar mislabels it. Bucket `date(start_time AT TIME ZONE :tz)` so a "day" means the
operator's local calendar day. Echo the resolved `tz` back so we can show it if needed.

## Performance / cadence

- Called **once per camera** when a playback session opens, and again on camera switch.
  **Not polled.** A request-time `GROUP BY date(...)` over `video_segments` for one
  camera over the retention window should be cheap; a daily rollup table is even better
  but not required for v1.
- One camera per call is fine. If you'd prefer a batch shape
  (`camera_ids[]` → coverage per camera) for a future multi-camera calendar, mention it
  and we'll adopt it; single-camera is all we need today.

## Scoping

- **Operator-readable** (this is the whole point — it must not be admin-only like
  `/admin/storage-tiers`).
- Respect per-user scope consistent with **D5**: a scoped user gets coverage only for
  cameras in their scope; `404`/`403` for cameras they can't see is fine.

---

## What Watchtower already does (built and shipped on `main`)

The full feature is implemented and live in the client now; it just shows an honest
"availability pending" calendar until this endpoint exists:

1. **`PlaybackClient::fetchCoverage(camera_id)`** calls `GET /review/coverage` on session
   open. On `200` it populates the calendar; on `404`/error it sets an honest
   **"availability pending"** state — **no fabricated coverage** (our standing product rule).
2. **`PlaybackCalendar.qml`** renders a `retention_days`-wide grid (default 35 until you
   return the real value), Mon-first, with out-of-window days dimmed and today marked.
   Days with footage get an amber dot; days are shaded by `coverage_ratio` once you send it.
3. **Click a day → loads its full 24h** via the *existing* `POST /review/sessions` over
   `[local-day 00:00, 00:00+24h]` (clamped to now), **gaps included**, exactly like the
   current windowed views. No new endpoint needed for the load itself — only this
   coverage summary to populate the calendar.
4. We also added **6H and 12H** rolling-window presets alongside 15m / 1h / 24h.

So the day this ships, the calendar's day-marks light up with **zero further client work** —
same forward-compatible pattern as D6.

---

## Acceptance, from our side

Delivered when:

- `GET /review/coverage?camera_id=…` returns `200` with `retention_days` (int) and a
  `days` array using the schema above, **operator-readable** (not admin-only).
- `retention_days` reflects the **longest configured raw-video tier** retention.
- Day bucketing honors the `tz` param (default UTC).
- Values reflect **current** footage (computed/rolled-up at request time, not frozen).

We don't need real-time push, pagination, or sub-day granularity here — the calendar is
a day-level overview; intra-day footage/gaps already come from the session manifest.

---

## Cross-reference

- Sibling, already delivered: **D6** (`recording` state on `/streams`) and D1/D2/D5.
- This is **A7** in the master rollup `watchtower-to-cilex-vision-api-requests.md`; this
  dated file is the canonical, focused version going forward.
- Related client-side: the playback session/manifest contract (`/review/sessions`) is
  unchanged — this endpoint only *feeds the calendar* that decides which day to open.

Happy to adjust the schema, the tz handling, or move to a daily-rollup table if that fits
the recording subsystem better. Thank you.
