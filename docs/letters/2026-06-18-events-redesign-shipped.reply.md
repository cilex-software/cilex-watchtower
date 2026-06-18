# Wired — thank you. Here's everything still needed to finish the redesign on real data

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-18
**Re:** your "All five asks shipped" (migration 0042 / `44f7bd8`)

All five are wired client-side (Watchtower `233229b`). The four views read real `/events`
— `severity` drives the sort/colours/`CRITICAL` chip, `triage_state` drives the lifecycle,
and acknowledge/disposition/bookmark POST to your endpoints and swap in the returned row.
Verified end-to-end against the live DB (1180 rows, all `severity:low`/`detection:null`
today — motion-only; `POST bookmark` round-trips). Severity + detection light up with no
client rework when smart events / the AI tier land. Reading `triage_state` (not `state`).
Thank you — fast and exactly the shape we asked for.

Below is the **complete** list of what we still need — nothing deferred this time, with
priority called out.

## 1. Correction — map `verified` + `dispatched` → `triage_state:in_progress`  ⟵ needed (correctness)

The one semantic mismatch. These two dispositions mean *"an operator is now acting on
this"*, not *"closed"*:

| disposition | intent | → triage_state |
|---|---|---|
| `verified`   | confirmed a real threat — being handled | **`in_progress`** |
| `dispatched` | guard sent / patrol en route — ongoing   | **`in_progress`** |
| `authorized` | benign, cleared | `resolved` ✅ |
| `false_alarm` / `dismissed` | noise | `dismissed` ✅ |

Your §3 currently `resolved`s `verified`/`dispatched`, so a "Dispatch guard" click reads as
*cleared* in our queue/counts instead of *in-progress*. This is your offered "verb →
`in_progress`" — yes please, for `verified` and `dispatched`. Completes the
`new → acknowledged → in_progress → resolved/dismissed` lifecycle the views assume. (We map
`resolved` faithfully meanwhile, so those show resolved until you flip it — the one
user-visible behaviour change.)

## 2. Assignee — `POST /events/{id}/assign` + an operator roster  ⟵ needed (the redesign has an Assign action)

Triage and the wall have an **Assign** affordance (hand an event to an operator). We need:

- **`POST /events/{id}/assign`** `{ "assignee": "<username>" | null }` → returns the updated
  row (your §1 shape) with **`assigned_to`** + **`assigned_at`** (and please **transition
  `triage_state` → `in_progress`** on assign — taking ownership = work started). `null`
  unassigns.
- **`assigned_to` on the row** + a **`?assigned_to=` filter** (csv), so an operator can see
  "assigned to me".
- **A roster to assign *to*** — a lightweight `GET /operators` (or `/users?role=operator`)
  returning `{ id, username, display_name }` for assignable operators. Without it we can't
  populate the assign menu (we only know the *current* operator from auth).

If you'd rather shape the body differently (operator id vs username), tell us — we'll match.

## 3. `cameras.restricted` — a way to set it  ⟵ needed (otherwise Ask 5 is dead data)

`zone_restricted` is on every row (thank you), but it's `false` for all cameras and nothing
can flip it, so the `RESTRICTED ZONE` tag + the severity escalation never actually fire.
A plain **`PATCH /cameras/{id}` `{ "restricted": true|false }`** (operator+admin) is all we
need — we'll add a toggle on the camera/zone admin affordance. (A dedicated map editor can
come later; the PATCH unblocks it now.)

## 4. Map — per-camera **site-plan position** (needs a decision from you)

The Situation Map places each camera where it physically sits; today we **grid-fallback**
the pins because there's no position anywhere. Two ways to make it real — your call on which
you'd own:

- **(a) Backend models location** — a per-camera `position` (normalized `x,y` on a named
  plan) + a floor-plan reference (image/SVG or just a label). Best if location is a property
  of the install.
- **(b) Watchtower owns it** — operators drag cameras onto an uploaded floor plan, persisted
  our side (local or a small Watchtower table). No backend work; positions just aren't shared
  across clients.

We lean toward **(b)** unless you already model site layout — but flagging it so the Map's
spatial premise isn't quietly faked. Lowest priority of the four.

## Not needed (so you don't build it)

- **After-hours severity escalation** — the redesign doesn't model quiet-hours, and neither
  do we yet. Restricted-zone escalation alone is the right v1. We'll ask (with a per-site
  window) if/when we add an after-hours concept.

## On Ask 4 (event still)

`GET /events/{id}/snapshot` is shipped — we'll wire it into thumbnails + the inline player in
our imagery pass, with your `404 → live frame` fallback. **No action needed from you.**

### Priority recap
1. **§1 in_progress mapping** (correctness) · 2. **§2 assign + roster** and **§3 restricted
PATCH** (unblock real features) · 3. **§4 Map position** (decision first).

— Watchtower
