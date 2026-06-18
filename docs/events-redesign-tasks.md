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
| 11 | **Production cutover** (default the redesign; retire legacy EventsScreen) | 🔧 in progress | Watchtower |
| 12 | Live-frame fallback on event-snapshot 404 | ◻︎ optional | Watchtower |
| 13 | Map-pin facing via `rotation_deg` | ◻︎ optional | Watchtower |
| 14 | Keyboard affordances (Triage `E` / ↑↓ / `Space`) | ◻︎ optional | Watchtower |
| 15 | Real critical/high severity + AI detection populating | ⏳ outstanding | Cilex Vision (deployment/config) |
| 16 | Cameras placed on the Camera Map (2/31 today) | ⏳ outstanding | Cilex Vision (operators place in editor) |

**Notes**
- ¹ #9 built + structurally verified (session opens, plays, transport drives the player, no
  QML errors); the actual decoded video can't be screenshot-verified offscreen — confirmed
  visually in the running app is a final eyeball check.
- #15–#16 are not code-resolvable by either side — they resolve operationally (camera
  detector config + AI tier; operator placement). Fully wired on our side; they light up as
  the deployment is configured. Nothing is blocked.
- Cilex Vision's Events **backend** workstream is closed (all engineering asks met).
- Current critical path to default-on: **#9 → #10 → #11**.
