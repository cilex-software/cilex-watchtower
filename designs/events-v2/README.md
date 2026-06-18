# Cilex Watchtower — Events screen (UX explorations)

Native desktop VMS operator client (Qt6/QML/C++), thin client to the Cilex Vision backend.
This package is the **Events** area: how an operator (security guard / supervisor / owner)
turns a flood of camera events into **actioned** outcomes — acknowledge, verify, dispatch,
dismiss, document.

> This is a clickable HTML/React design prototype, not production code. It exists to agree
> the interaction model before it is rebuilt in QML. Mock data only; "video" is a procedural
> CCTV still — there is no real stream.

## Run / files

Open `index.html`. Load order matters (plain `<script type="text/babel">`, no modules):

| File | Responsibility |
|------|----------------|
| `styles.css` | Design tokens + all screen CSS. Charcoal `#1a1816`, amber `#e8a13a`, burnt-red `#d96649`, olive `#8eb96b`; Space Grotesk + JetBrains Mono. |
| `data.jsx` | Mock domain: cameras, zones, event types, the `RAW` event list, time helpers, the icon set `I`, and the **procedural `Snapshot`** component (CCTV frame with AI bounding box, tamper/offline states). Everything is exported onto `window`. |
| `view-triage.jsx` | View 1 + the inline `Player`. |
| `view-wall.jsx` | `WallBody` — the Wall layout of View 2. |
| `view-sessions.jsx` | `SessionsBody` — the Sessions layout of View 2. |
| `view-review.jsx` | `ReviewView` — View 2 shell that toggles Wall/Sessions and owns the contextual toolbar. |
| `view-timeline.jsx` | View 3. |
| `view-map.jsx` | View 4 (Situation Map). |
| `app.jsx` | Window chrome, nav rail, top bar, the **mode switcher**, shared event state + `act` handlers (`ack`, `bookmark`, `dispose`). Mounts everything. |
| `triage-queue-spec.md` | **Detailed implementation spec for the Triage Queue** (View 01) — element-by-element layout, sizes, colors, behavior, acceptance checklist. |
| `verify-screen-spec.md` | **Detailed implementation spec for the Verify screen** (View 02) — the Wall/Sessions toggle, both layouts, sizes, colors, behavior, acceptance checklist. |
| `timeline-screen-spec.md` | **Detailed implementation spec for the Activity Timeline** (View 03) — axis, lanes, marker + duration-bar model, popover, sizes, colors, behavior, acceptance checklist. |
| `map-screen-spec.md` | **Detailed implementation spec for the Situation Map** (View 04) — site plan, camera pins + states, legend, live-feed rail, camera detail panel, sizes, colors, behavior, acceptance checklist. |

**Shared state.** `app.jsx` holds one event array. Every action (`ack`, `dispose`, `bookmark`)
mutates it, so acknowledging/dismissing in any view updates the OPEN / CRITICAL / CLEARED
counts everywhere. New views should take `events` + `act` as props, never fork their own copy.

**Event lifecycle:** `new → ack → progress → resolved` (or `dismissed`). A disposition
(`verified`, `dispatched`, `authorized`, `false_alarm`, `env`) is recorded when an event is closed.

---

## The four screens (top mode switcher)

### 01 · Triage Queue  (`TriageView`)
**Job:** clear a backlog fast, one operator, keyboard-friendly.
Left = priority-sorted list (severity dot, thumbnail with clip-length badge, type, camera, time,
state). Right = detail pane that **plays the event clip inline** (`Player`: play/pause, −10/+10,
scrubber with the event in/out window highlighted, speed) — there is no separate "open playback"
step. Below the player: the event facts grid, a **per-type response procedure (SOP) checklist**,
a disposition note field, and the action bar: Authorized / False alarm / Dispatch guard / Acknowledge.
Best when the queue is deep and must be worked top-down.

> **📄 Full implementation spec: [`triage-queue-spec.md`](./triage-queue-spec.md)** — the
> authoritative, element-by-element description of this screen (layout, exact sizes, colors, type,
> behavior, and an acceptance checklist). **Use this file when implementing the Triage Queue.**

### 02 · Verify  (`ReviewView` → `WallBody` | `SessionsBody`)
**Job:** the two strongest review modes in one screen, switched by a top toggle. Contextual
controls live on the right of the toolbar and change with the layout.
- **Verification Wall** — snapshot-first grid; each card is a CCTV still with an AI label,
  severity, and a **clip-duration badge**. One-click *Threat* / *Dismiss* / bookmark without
  leaving the grid. Filter tabs: To verify / AI detections / All. Right-side control: **size S/M/L**.
- **Smart Sessions** — noise reduction: motion fragments collapse into sessions, grouped by zone,
  ranked by priority, with row actions + **bulk acknowledge/dismiss**. Stat header shows fragments
  collapsed / high-priority open / handled. Right-side control: **sort Priority/Recent**.

> **📄 Full implementation spec: [`verify-screen-spec.md`](./verify-screen-spec.md)** — the
> authoritative, element-by-element description of this screen (the toggle + contextual controls,
> the Wall grid/cards, the Sessions zone list/rows/bulk bar, with exact sizes, colors, type, and an
> acceptance checklist). **Use this file when implementing the Verify screen.**

### 03 · Activity Timeline  (`TimelineView`)
**Job:** investigation & pattern-spotting. One swimlane per camera across a time axis (90m / 3.5h / 8h).
Each event is a marker, and **extends a bar to the right sized to how long it lasted** — clusters and
dwell-times read at a glance. Click a marker for a popover (snapshot + Review / Bookmark / Ack).
A dashed "now" line anchors the right edge.

> **📄 Full implementation spec: [`timeline-screen-spec.md`](./timeline-screen-spec.md)** — the
> authoritative, element-by-element description of this screen (toolbar + window selector, the sticky
> time axis, per-camera lanes, the marker + duration-bar plotting model, the popover, and the "now"
> line, with exact sizes, colors, type, and an acceptance checklist). **Use this file when implementing
> the Activity Timeline.**

### 04 · Situation Map  (`MapView`)
**Job:** spatial awareness for supervisors/owners who think in places, not log lines. A schematic site
plan with camera pins; open events **pulse** on the pin where they physically occur, with a count badge.
Right rail = live feed; click a pin to drop into a per-camera panel with the latest snapshot and in-context
Verify / Dispatch / Clear.

> **📄 Full implementation spec: [`map-screen-spec.md`](./map-screen-spec.md)** — the authoritative,
> element-by-element description of this screen (the schematic site plan, camera pins + ping/badge
> states, the legend, the live-feed rail, and the per-camera detail panel, with exact sizes, colors,
> type, and an acceptance checklist). **Use this file when implementing the Situation Map.**

---

## Design rules to keep

- **Tokens only.** Use the CSS variables in `styles.css` (`--accent`, `--bad`, `--good`, `--ink*`,
  `--line*`). Don't introduce new colors. Severity: critical = `--bad`, high = `--accent`,
  medium = `--ink-2`, low = `--ink-3`.
- **Type:** Space Grotesk for UI, JetBrains Mono (`.mono`) for IDs, times, codes, labels.
- **No external imagery.** The `Snapshot` component is the only "video"; reuse it (pass `mini`
  for thumbnails to drop overlay labels, `playing` for the playback feel).
- **Actionability first.** Every event must be closable from wherever it is shown. Match the
  existing action vocabulary (Acknowledge / Threat / Dismiss / Dispatch / Bookmark / Export).
- **Window is fixed 1440×900** (desktop client). Keep it a single non-scrolling app shell; scroll
  only inside lists/grids.

## Context for the next change
<!-- Fill in before handing to claude-cli -->
**Screen:** Triage Queue (View 01) — implement from **[`triage-queue-spec.md`](./triage-queue-spec.md)**.
or Verify (View 02) — implement from **[`verify-screen-spec.md`](./verify-screen-spec.md)**.
or Activity Timeline (View 03) — implement from **[`timeline-screen-spec.md`](./timeline-screen-spec.md)**.
or Situation Map (View 04) — implement from **[`map-screen-spec.md`](./map-screen-spec.md)**.
**What we are changing:** _describe the specific change here._
**Do NOT redraw** anything not named above; keep all other layout, spacing, tokens, and copy intact.
