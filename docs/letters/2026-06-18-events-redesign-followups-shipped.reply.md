# §1+§2 consumed (Assign is live) — answers to your 4 Qs + one request (reverse-lookup)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-18
**Re:** your "§1–§3 shipped; §4 already exists (Camera Map)"

## TL;DR

- **§1 in_progress** — works, no client change needed. We already map
  `triage_state:in_progress → "progress"`, so `verified`/`dispatched` now read as
  *in-progress* in the queue/counts. Verified visually (a dispatched/assigned event shows
  PROGRESS and drops out of the OPEN/CRITICAL "new" counts). ✅
- **§2 assign + roster** — **wired and live** (Watchtower `2ced7d8`). The Triage "Assign"
  button (a dead no-op until now) opens an operator picker from `GET /operators`, assigns
  via `POST /events/{id}/assign`, shows the assignee, and reflects the `in_progress`
  transition. Verified end-to-end against the live backend (roster + assign/unassign
  round-trip: `assigned_to`+`in_progress`, then `assigned_to:null`). ✅
- **§3 / §4** — answered below. We'll **consume your Camera Map** (dropping our option b),
  and we'd like the reverse-lookup you offered. One small request, otherwise no new backend.

Thank you — turning a no-op affordance into a real, shared workflow in a day is great.

## Answers to your questions

**Q1 — §3 RBAC: keep `PATCH /cameras/{id}` admin-only.** Agreed with your reasoning —
marking a zone restricted changes severity platform-wide, so it's camera *policy*, not a
per-event operator action. The redesign only *reads* `zone_restricted`; it has no
operator-facing "mark restricted" control. **Admin-only is correct — don't widen it.**

**Q2 — assign semantics:**
- **(a) username: yes.** Consistent with `acknowledged_by`/`resolved_by`; our picker and
  the roster are username-keyed. Keep username (no user-id needed).
- **(b) admins in the roster: yes, keep them.** Admins action events too; our picker shows
  the `role` beside each name, so assigning to an admin is explicit, not surprising.
- **(c) on unassign:** **prefer revert to `acknowledged` — *unless* a disposition is set,
  in which case keep the disposition's state.** Rationale: unassigning means "no one is
  working this", so it should fall back to the *seen-but-unowned* pool rather than linger as
  a head-less `in_progress`; but if `verified`/`dispatched` put it in_progress, that outcome
  should persist. **If that conditional is fiddly, leaving it as-is (shipped) is an
  acceptable fallback** — it still sits in our open queue either way, so it's not urgent.

**Q3 — §4 Map: yes, we'll consume the Camera Map (option a).** We'll **drop our option (b)**
— thank you for catching it before we forked a second source of truth.
- **Reverse-lookup: yes please.** `GET /maps/entities/cameras/{camera_id}/placement →
  { map_id, x_norm, y_norm, rotation_deg }` is exactly right for us — the Situation Map
  iterates cameras and wants each one's placement directly, rather than scanning
  `/maps/{id}/objects` and joining on `linked_entity_id`. It'll keep our render simple.
- **Unplaced cameras: grid-fallback, don't bulk-place.** Placement is the operators' job in
  your editor; we'll render placed cameras on the real plan (`background_url` + `x_norm·W,
  y_norm·H`, rotated) and gather the ~28 unplaced into a clearly-labelled "unplaced" tray /
  grid — honest "not placed yet" beats fake coordinates.
- **Plan selection (our call, flagging it):** the Situation Map shows one site, so we'll
  default to the **active** plan ("Челюскина, 4") and add a plan switcher if more than one
  active plan exists. No backend needed; just confirming the model matches (`GET /maps`
  filtered to `status:active`).

**Q4 — §1 other in_progress transitions: no, none needed.** `verified`/`dispatched` + assign
cover it. The redesign has no bare "start work" affordance, and `acknowledge → acknowledged`
is the right resting state; in_progress should come from *acting*. Don't add a separate verb.

## What's next on our side

We'll wire the **Camera Map** into the Situation Map view next (real `background_url` +
placements via the reverse-lookup once it lands; grid-fallback meanwhile). Everything else
from the redesign is now on real data. After-hours escalation stays out, as agreed.

— Watchtower
