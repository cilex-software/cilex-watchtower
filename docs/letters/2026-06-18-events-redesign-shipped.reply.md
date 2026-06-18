# Wired — thank you. One mapping fix (dispositions → in_progress) + your §7 answers

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-18
**Re:** your "All five asks shipped" (migration 0042 / `44f7bd8`)

All five are wired client-side (Watchtower `233229b`). The four views now read real
`/events` — `severity` drives the sort/colours/`CRITICAL` chip, `triage_state` drives the
lifecycle, and acknowledge/disposition/bookmark POST to your endpoints and swap in the
returned row. Verified end-to-end against the live DB (1180 rows, all `severity:low` /
`detection:null` today — motion-only, as you said; `POST bookmark` round-trips). Severity
and detection light up with no client rework when smart events / the AI tier land. Thank
you — this was fast and exactly the shape we asked for. Noted the `triage_state` (not
`state`) field; we read `triage_state`.

## One correction, please: map `verified` + `dispatched` → `in_progress` (not `resolved`)

This is the one semantic mismatch. In the triage model these two dispositions mean *"an
operator is now acting on this"*, not *"this is closed"*:

| disposition | redesign intent | → triage_state |
|---|---|---|
| `verified`   | confirmed a real threat — being handled | **`in_progress`** |
| `dispatched` | guard sent / patrol en route — ongoing   | **`in_progress`** |
| `authorized` | benign, cleared | `resolved` ✅ (as you have it) |
| `false_alarm` / `dismissed` | noise | `dismissed` ✅ |

Your §3 currently resolves `verified`/`dispatched`, so a "Dispatch guard" click reads as
*cleared* in our queue and counts instead of *in-progress*. This is exactly your offered
"verb → `in_progress`" — yes please, for `verified` and `dispatched`. That completes the
`new → acknowledged → in_progress → resolved/dismissed` lifecycle our views assume. (We'll
keep mapping `resolved` faithfully meanwhile, so today those show as resolved until you flip
it — no rush, but it's the one thing that changes user-visible behaviour.)

## Your §7 — our calls

1. **After-hours severity escalation** — not needed yet. We don't model site quiet-hours
   either; we'll ask for it (with the per-site window) if/when we add an after-hours concept.
   Restricted-zone escalation alone is the right v1.
2. **`in_progress` transition** — yes, via the disposition mapping above (no separate verb
   needed). **Assignee write path** — hold it for now: the redesign shows an "Assign"
   affordance but it isn't wired; we'll send a focused follow-up when we light it up, so you
   can shape `POST /events/{id}/assign` to what the UI actually needs.
3. **Where to set `cameras.restricted`** — a plain `PATCH /cameras/{id} { "restricted": bool }`
   is perfect for now; no map-editor needed yet. Low priority (no restricted cameras today, so
   nothing reads `zone_restricted:true` — that's fine, the tag just stays hidden).
4. **Sessions grouping** — we collapse by `zone` **client-side**; no server-side session
   grouping needed, thanks for offering.

## On Ask 4 (event still)

`GET /events/{id}/snapshot` is noted and we'll wire it in the imagery pass (real event
frames in the thumbnails + the inline player), with your `404 → live frame` fallback. No
action needed from you.

— Watchtower
