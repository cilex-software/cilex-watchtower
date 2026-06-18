# Events redesign — task tracker

_Stable row set; only the **Status** changes as work lands. Rows are fixed until the
whole workstream is resolved (don't re-split/rename). Last updated: 2026-06-18._

Status key: ✅ done · 🔧 in progress · ⏳ outstanding · ◻︎ optional/polish

| # | Task | Status | Depends on |
|---|------|--------|-----------|
| 1 | Four-view redesign (Triage/Verify/Timeline/Map) + shell + primitives (mock) | ✅ done | — |
| 2 | Real-data foundation (`EventsStore.ingestReal`, `WT_EVENTS2`) | ✅ done | — |
| 3 | Backend contract wired (severity, triage_state, disposition, bookmark) | ✅ done | — |
| 4 | Assign — operator picker + `GET /operators` roster | ✅ done | — |
| 5 | in_progress mapping + unassign-revert | ✅ done | — |
| 6 | Imagery part 1 — real event frames (`image://cvframe`) | ✅ done | — |
| 7 | Situation Map on the real Camera Map (`/maps`) | ✅ done | — |
| 8 | Playback no-footage / transient-session-failure fix (side bug) | ✅ done | — |
| 9 | **Imagery part 2 — inline HLS playback in the Triage hero** | ✅ done¹ | Watchtower |
| 10 | **Export-clip toolrow button wiring** | ✅ done | Watchtower |
| 11 | **Production cutover** (default the redesign; retire legacy EventsScreen) | ✅ done | Watchtower |
| 12 | Live-frame fallback on event-snapshot 404 | ✅ done | Watchtower |
| 13 | Map-pin facing → **FOV coverage cones** via `rotation_deg` | ✅ done | Watchtower |
| 14 | Keyboard affordances (Triage `E` / ↑↓ / `Space`) | ✅ done² | Watchtower |
| 15 | Real critical/high severity + AI detection populating | ⏳ outstanding | Cilex Vision (deployment/config) |
| 16 | Cameras placed on the Camera Map (2/31 today) | ⏳ outstanding | Cilex Vision (operators place in editor) |
| 17 | Camera-group switcher (scope every view by group) | ✅ done | Watchtower |

**Notes**
- ¹ #9 built + structurally verified (session opens, plays, transport drives the player, no
  QML errors); the actual decoded video can't be screenshot-verified offscreen — confirmed
  visually in the running app is a final eyeball check.
- ² #14 built + compiles; key input can't be exercised offscreen — eyeball `E`/↑↓/`Space` live.
- #15–#16 are not code-resolvable by either side — they resolve operationally (camera
  detector config + AI tier; operator placement). Fully wired on our side; they light up as
  the deployment is configured. Nothing is blocked.
- Cilex Vision's Events **backend** workstream is closed (all engineering asks met).
- **The redesign is now the DEFAULT Events screen** (#9–#11 done). Flags: `WT_DEMO` → mock
  showcase; `WT_EVENTS_LEGACY` → the old table-style screen (instant fallback).
- **All client work is done (#1–#14, #17).** The only open rows are **#15–#16** — operational/
  config on Cilex Vision's side (severity/AI data, camera placement), which light up as the
  deployment is configured; nothing for us to build. Suggested live eyeball checks: inline
  video (#9) + keyboard shortcuts (#14).
- #13 upgraded from a thin facing tick to a translucent **FOV coverage cone** (wedge + outline,
  tinted by pin state — amber active / olive clear / red critical / blue offline), oriented by
  `rotation_deg`. #17 adds a group dropdown in the Events mode bar (`groupFilter` scopes the
  queue, wall/sessions, timeline lanes, and map pins to All / a named group / Ungrouped). Dev
  hook: `WT_EVENTS_VIEW=triage|review|timeline|map` opens a sub-view directly.
