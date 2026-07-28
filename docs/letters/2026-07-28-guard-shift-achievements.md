# Guard check-in & achievements ("The Watch"): backend support for shift identity, accrual, and badges

**From:** Watchtower
**To:** Cilex Vision
**Date:** 2026-07-28
**Scope:** one feature — a guard-morale progression system. Watchtower adds a
check-in identity (guards never log out — stations run 24/7 on one operator
session) and displays ranks/badges; the ask is the authoritative backend for
it. Full product design: `docs/plans/guard-achievements.md` (thresholds,
badge families, responsible-gamification constraints). Not urgent; nothing
client-side blocks on a specific week.

## 1. Why the backend owns this

Accrual must survive client reinstalls and Warden restarts, follow a guard who
works at several stations, and be un-gameable from a client. And most source
data is already yours: sessions of presence need server time, event overlap
comes from your events store, and weather (if you can source it) is a
server-side concern. The client is a renderer + a check-in button.

## 2. Proposed contract

### 2.1 Roster (admin-owned — never invented names, our shared product rule)

```
GET  /guards                     → [{guard_id, display_name, active}]
POST /guards {display_name}      → admin-only create (console UI up to you)
POST /guards/{id}/deactivate     → admin-only
```

### 2.2 Shift sessions (the check-in button)

```
POST /guards/{id}/checkin  {station_id}   → {shift_id, started_at}
POST /guards/{id}/checkout {shift_id?}    → closes the open shift
GET  /stations/{id}/watch                 → {guard_id?, display_name?, shift_id?, started_at?}
```

- One open shift per guard; a check-in while another guard's shift is open on
  the station closes theirs (handover). A check-in with a shift already open
  elsewhere closes that one (a guard is in one place).
- **Server auto-closes any shift at 16 h** with `auto_closed: true` — a hard
  responsible-gamification cap: accrual must never reward marathon fatigue.
- `GET /stations/{id}/watch` lets a restarted client (Warden!) restore the
  "ON WATCH · <name>" chip without any local state.
- Auth: the station's existing session; guard identity is NOT authentication —
  it's attribution, chosen from the roster on a shared screen.

### 2.3 State for rendering (one call drives the whole UI)

```
GET /guards/{id}/watchstate?since=<iso>
→ {
    rank: {key:"raven", hours: 1207, next:{key:"sentinel", at_hours: 2000}},
    badges: [ {family:"nightwatch", tier:"iron", earned_at:"…",
               progress:{current: 63, next_tier:"silver", next_at: 120}}, … ],
    unlocked_since: [ …same shape… ]      // drives the client's unlock toasts
  }
```

Progress on LOCKED tiers included always — visible partial progress is the
retention mechanic (design doc §1).

### 2.4 Accrual engine (server-side classification)

From each closed (or running) shift, accrue per the design-doc matrix:

- **hours** (rank ladder), **night shifts** (majority 22:00–06:00 station-local),
  **hollow hours** (00:00–04:00), **seasonal shifts**, **sunrise-spanning
  shifts** (solar math from the site's lat/long — pure computation, works
  air-gapped), **full-moon night shifts** (lunar math), **Yearkeeper**
  (on watch across Dec 31 → Jan 1 midnight), **weekly streak** (≥3 shifts per
  ISO week, consecutive weeks), **distinct stations**, **clean checkouts**
  (not auto-closed, consecutive).
- **Incident overlap:** shifts during which ≥1 real event fired on that
  station's cameras — from your events store, no client involvement. (v2, once
  an acknowledge endpoint exists — our old ask — upgrade to acknowledged-
  during-shift, which rewards attention rather than luck.)
- **Weather overlap** (only where the backend has internet): on-watch hours
  during rain / snowfall / ≤ −15 °C / ≥ +30 °C at the site's location.
  Suggestion: **Open-Meteo** — free, no API key, hourly history + forecast;
  one call per site per hour is plenty. Where there's no internet, the weather
  families are reported `available: false` and the client shows "not available
  at this site" — never fake-zero progress.

Thresholds: ship them server-side as config (the design doc's table as
defaults) — they'll need per-climate tuning (a Sochi site earns Snow Watch
slower than a Norilsk one), and tuning must not require client updates
(frozen guard boxes).

### 2.5 Sizing (so you can say no cheaply)

Tiny by your standards: a shifts table (~500 rows/station/year), an accruals
rollup per guard, one weather observation row per site-hour (ly ~9 k
rows/site/year), and the threshold config. No media, no new heavy surfaces.

## 3. What the client does (for context)

TopBar check-in chip ("ON WATCH · <name>"), corner rank badge, Achievements
matrix screen with progress bars, unlock toasts. Feature-flagged until your
endpoints exist — honest pending, per house rules. Badge artwork is generated
offline from the design doc's descriptions and ships with the client.

## 4. Open questions for you

1. Roster admin: your console or a simple API-only v1?
2. Weather sourcing: Open-Meteo acceptable, or do you prefer another source /
   none at v1? (The matrix degrades gracefully without it.)
3. Threshold config location/format — env, DB table, or file?
4. Anything about the shift model that collides with how you'd rather model
   presence (e.g., you may prefer deriving presence from station heartbeats —
   we'd argue explicit check-in is the point: it's the guard's ACTION and
   their name on the wall, not telemetry).

— Watchtower
