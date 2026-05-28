# Cilex Watchtower — Backlog

_Last updated: 2026-05-28. Outstanding work after P1–P6 (all phases shipped). This
is the single prioritized list of open items._

**Priority** = impact (P1 highest). **Status:** 🟢 ready (we can do now, no
dependency) · 🔴 blocked (on what) · 🟡 buildable but low-value until a blocker
clears. Backend items map to the living letter
`docs/letters/watchtower-to-cilex-vision-api-requests.md` (codes A#/B#/C#).

## Prioritized

| Pri | Task | Status | Owner |
|-----|------|--------|-------|
| P1 | Events pipeline actually producing (B2) | 🔴 Blocked — backend bug (`detections=0` → no tracklets → no events) | Cilex Vision |
| P1 | Export metadata + Clips server list — `purpose` (A1) + typed job response (A3) + exports LIST (A6) | 🔴 Blocked — backend "first batch" | Cilex → then us (wire, ~½ day) |
| P1 | Shared acknowledge (B1) | 🔴 Blocked — backend endpoint | Cilex → then us (flip ack local→server) |
| P2 | Mixed-codec playback switch — verify H.264 720p ↔ H.265 1440p across `#EXT-X-DISCONTINUITY` doesn't stall | 🔴 Blocked — needs cilex's synthesized multi-day timeline (test data) | Cilex (data) → then us |
| P2 | Burn-in overlays in export (A2) | 🔴 Blocked — backend re-encode path (sequenced last) | Cilex |
| P2 | Light / Dark theme switching | 🟢 Ready | us — largish (`Theme` is a static singleton; needs to become reactive) |
| P2 | Same-group camera switch in the playback aside | 🟢 Ready | us — medium |
| P2 | Events detail drawer: Export-clip action + camera/date filter pills | 🟢 Ready | us (Bookmark sub-item needs a backend/local decision) |
| P3 | `compact` (drop-gaps) export-mode toggle in the drawer | 🟢 Ready | us — quick |
| P3 | "−15s" precise seek on Open-playback (from events / clips) | 🟢 Ready | us — small (needs playback seek-to-wallclock) |
| P3 | Alert-firing pipeline (toast / sound / desktop notification) | 🟡 Buildable, blocked-for-value on B2 (no events to fire yet) | us — after B2 |
| P3 | Audio export (A5) | 🔴 Blocked — backend (no audio path) | Cilex |
| P3 | Typed manifest fragment schema + read real `resolution` (C1 + latent) | 🔴 Blocked — backend (mostly) | Cilex |
| P3 | Denormalized event camera name/group (C2) | 🔴 Blocked — backend (cosmetic; local MAC lookup works) | Cilex |
| P3 | `"hydrating"` fragments dropped (`availability !== "ready"`) | 🔴 Blocked — needs warm/cold-tier footage to exist before it manifests / can be tested | data condition |

## Actionable now (🟢, no blocker) — quickest first
1. `compact` export-mode toggle — quick.
2. "−15s" precise seek on Open-playback — small.
3. Same-group camera switch in the playback aside — medium.
4. Events drawer Export-clip + filter pills — medium.
5. Light/Dark theme switching — largest (reactive `Theme` refactor).

## Blocked — what clears each
- **Backend "first batch" (A1 + A3 + A6, B1)** → real export purpose/size, the Clips library's server exports, and shared server-backed acknowledge. Our side is then mostly wiring (no UI rework).
- **Backend pipeline fix (B2)** → the Events feed populates (and the alert-firing pipeline becomes worth building/testing). Until then: honest empty state.
- **cilex's synthesized multi-day timeline** → unblocks the mixed-codec playback verification (the one real technical risk). Alternatively wait for natural hot→warm aging at 3 days. _Ask cilex to send it._
- **Backend re-encode path (A2)**, **audio path (A5)**, **typed schemas (C1/C2)** → backend-sequenced; we wire when they land.
- **Warm/cold-tier footage existing** → the latent "hydrating" fragment fix can be made + tested.

## Resolved since the roadmap (context)
`mode` → `wallclock` (A4 closed); `/detections` 500 fixed + verified (B3 closed);
event_type vocab corrected to the authoritative enum; `GET /health/storage` wired
(Health-screen storage strip).

---
See also: phase status → [PROJECT_STATUS.md](PROJECT_STATUS.md); backend contracts
→ [letters/watchtower-to-cilex-vision-api-requests.md](letters/watchtower-to-cilex-vision-api-requests.md); architecture/build → [DEVELOPMENT.md](DEVELOPMENT.md).
