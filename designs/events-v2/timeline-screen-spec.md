# Activity Timeline — implementation spec

> **For claude-cli.** Authoritative, element-by-element description of the **Activity Timeline**
> screen (mode `03`, `view-timeline.jsx` / `TimelineView`). Implement to this. Use the CSS variables
> from `styles.css`; the token table at the end gives the resolved hexes. Do not add elements not
> listed here and do not restyle shared primitives or other screens.

---

## 0. Purpose & placement

The Activity Timeline is the **forensic / investigation** view. Instead of a list, it lays every camera
out as a horizontal **swimlane** across a shared time axis and plots each event on it — with motion/
sessions drawn as **bars whose length = how long the event lasted**. This makes clusters, dwell-times,
and "what happened between 5 and 8" read at a glance, and lets the operator jump from any marker into
review.

Reached by the **`03 · Activity Timeline`** button in the top mode switcher (`app.jsx`). It fills the
`.stage` of the fixed 1440×900 shell. Root element: `<div class="tl">`, a vertical flex column:
a fixed **toolbar** (`.tl-bar`) on top, then the **scrolling grid** (`.tl-grid`) which holds a sticky
time axis and the stack of lanes.

**Default window:** **3.5h** (the visible time span ending "now").

---

## 1. Toolbar (`.tl-bar`)

Horizontal flex, `align-items:center; gap:16px; padding:12px 20px;` bottom border
`1px solid var(--line)`. Left → right:

- **Title (`.tl-title`)** — 14px 600 "Activity timeline", followed by a mono sub-string
  (`.mono`, 11px `var(--ink-3)`, weight 400): "· {N} cameras · {N} events" (live counts).
- **Spacer** (`flex:1`).
- **Legend (`.tl-legend`)** — flex `gap:14px`, 11px `var(--ink-2)`. Three entries, each a 9px color
  dot (`.lg`) + label: **critical** (`--bad` red), **high** (`--accent` amber),
  **motion / session** (`--ink-3` neutral). This is the key to the marker/bar colors.
- **Window selector (`.modeseg`, `height:32px`)** — a 3-button segmented control
  (buttons `padding:0 12px; font-size:11px`): **90m**, **3.5h**, **8h**. The active one is the amber
  pill (`var(--accent)` fill, `var(--bg)` text). Sets how much history is visible (`hours` → the axis
  re-scales; the right edge is always "now").

---

## 2. Grid (`.tl-grid`)

`flex:1; overflow-y:auto; display:flex; flex-direction:column`. The **only vertically scrolling
region** (when there are more lanes than fit). It contains a sticky axis row and the lanes.

### 2.1 Coordinate system (how everything is positioned)
- The visible span is `winSec = hours × 3600`. `t0` (left edge) = `NOW − winSec`; the right edge = now.
- Horizontal position of any timestamp `d` is a percentage: `pct(d) = (d − t0) / winSec × 100`.
- Both the axis track and every lane track use the **same 188px label gutter + fluid track** grid, so
  vertical gridlines line up perfectly between the axis and the lanes.

### 2.2 Time axis (`.tl-axis`) — sticky header
`display:grid; grid-template-columns:188px 1fr;` bottom border `1px solid var(--line)`,
`position:sticky; top:0; background:var(--bg); z-index:5` (stays pinned while lanes scroll).
- **Corner (`.tl-axis-corner`)** — the 188px cell above the lane labels; just a right border
  `1px solid var(--line)`.
- **Track (`.tl-axis-track`)** — `position:relative; height:30px`. Holds **hour ticks** (`.tl-tick`):
  one per whole hour from `t0`, a full-height `border-left:1px solid var(--line)` at `left:pct%`,
  with a mono **10px** `var(--ink-3)` time label (`HH:MM`) pinned `top:9px; left:6px` just right of
  the line.

### 2.3 Lanes container (`.tl-lanes`)
`position:relative; flex:1`. One lane per camera (iterating `CAMS` in order), plus the **now line**
overlay (§2.6).

### 2.4 Lane (`.tl-lane`) — one per camera
`display:grid; grid-template-columns:188px 1fr;` bottom border `1px solid var(--line)`,
`min-height:64px`.
- **Lane header (`.tl-lane-h`)** — the 188px left gutter, right border `1px solid var(--line)`,
  `padding:10px 14px`, flex column centered vertically, `gap:3px`:
  - **Camera name** (`.ln-name`): 12px `var(--ink)`, weight 500 (e.g. "Loading Bay — Dock 2").
  - **Zone** (`.ln-zone`, mono): 10px `var(--ink-3)` (e.g. "Loading Bay").
- **Lane track (`.tl-lane-track`)** — `position:relative`, the plotting area. Contains, in z-order:
  1. **Vertical gridlines** (`.tl-vline`): one at each hour tick, full height,
     `border-left:1px solid var(--line); opacity:0.5` — the faint continuation of the axis ticks.
  2. **Duration bars** (`.tl-barseg`) — see §2.5.
  3. **Event markers** (`.tl-mk`) — see §2.5.

Only events with `ts ≥ t0` (inside the window) are plotted for that camera.

### 2.5 Events on a lane — **bar + marker** (the signature element)
For each event, positioned at `left = pct(ts)`:

**Duration bar (`.tl-barseg.<priority>`)** — drawn only when the event has a duration (width > 0.6%).
A 6px-tall rounded bar, vertically centered (`top:50%; translateY(-50%)`), starting at the event's
timestamp and extending **right** for its duration: `width = durationSec / winSec × 100%` (min 0.6%).
This is the "how long it lasted" cue. Color/opacity by priority:
- critical → `var(--bad)` @ 0.7, high → `var(--accent)` @ 0.6, everything else → `var(--ink-3)` @ 0.5.

**Marker (`.tl-mk.<priority>`)** — a circular button centered on the event time
(`left:pct%; translate(-50%,-50%)`), containing the **event-type icon**. Base: 22px circle,
`background:var(--panel-2); border:1px solid var(--line-2); color:var(--ink-2); border-radius:50%;`
`z-index:2`.
- **critical** and **high** events are `.big` → **28px** circle, with a larger (13px) icon.
- **critical:** `background:var(--bad-soft); border-color:var(--bad); color:var(--bad)`.
- **high:** `background:var(--accent-soft); border-color:var(--accent); color:var(--accent)`.
- **handled** (status ≠ new) → `.done`, `opacity:0.4` (recedes once actioned).
- **hover:** border `var(--ink-2)`, color `var(--ink)`, scales to **1.12×**.
- Clicking a marker **toggles its popover** (clicking again, or another marker, closes it).

### 2.6 "Now" line (`.tl-now`)
A vertical marker at the right edge of the lanes (`left:100%`), `border-left:1.5px dashed var(--bad)`,
`z-index:4`, spanning all lanes. A small mono **9px** `var(--bad)` label "now {HH:MM}" sits at its top
(`top:2px; right:4px`). Anchors the timeline's present moment.

### 2.7 Marker popover (`.tl-pop`)
Opens below the clicked marker: `position:absolute; top:calc(50% + 20px); transform:translateX(-50%);`
**248px** wide, `background:var(--panel-3); border:1px solid var(--line-2);`
`box-shadow:0 14px 34px rgba(0,0,0,0.55); z-index:20`. Clicks inside it don't bubble (so it stays open).
Top → bottom:
- **Snapshot (`.tl-pop-snap`)** — 16:9 CCTV still (`<Snapshot ev showOsd={false}>`), bottom border
  `1px solid var(--line)`.
- **Body (`.tl-pop-b`)** — `padding:10px 11px; gap:8px`, flex column:
  - **Type pill** (`.tpill.<type>`): icon + label (color-coded as elsewhere).
  - **Meta** (`.tl-pop-meta`, mono 10px `var(--ink-3)`): `HH:MM:SS · {duration|"instant"} · {NN%|"—"}`.
  - **Actions (`.tl-pop-act`, `gap:5px`)**, three equal-width buttons:
    - **▶ Review** (`.btn.sm.pri`, amber) → `setSel(id); setMode('triage')` — opens the event in the
      Triage Queue.
    - **▣ Bookmark** (`.btn.sm`) → `act.bookmark(id)` (filled icon when saved).
    - **✓ Ack** (`.btn.sm`) → `act.ack(id)` and closes the popover.

---

## 3. State, data & behavior

- **`TimelineView` state:** `hours` (window: 1.5 / 3.5 / 8) and `pop` (the id of the event whose
  popover is open, or null).
- **Props in:** `events`, `act`, `setSel`, `setMode`. Markers, bars, counts, and `.done`/handled
  styling all derive from `events`; actions go through `act` so the rest of the app stays in sync.
- **Lanes** come from `CAMS` (fixed camera order); each lane filters `events` to that camera within the
  current window.
- **Cross-view jump:** "Review" in a popover opens the event in the **Triage Queue**.
- This view is **read/triage-light**: it's for spotting and routing, not full disposition — heavier
  workflow lives in Triage and Verify.

---

## 4. Token reference (resolved values)

| Token | Value | Role on this screen |
|-------|-------|---------------------|
| `--bg` | `#1a1816` | sticky axis bg, active-window text |
| `--panel-2` | `#2a2722` | default marker fill |
| `--panel-3` | `#322e28` | popover bg |
| `--line` | `#34302a` | axis/lane borders, gridlines, ticks |
| `--line-2` | `#443f37` | marker/control borders, popover border |
| `--ink` | `#f0ece4` | camera names, marker hover |
| `--ink-2` | `#a89f90` | legend text, default marker icon |
| `--ink-3` | `#6e6657` | zone/meta/tick labels, motion bars |
| `--accent` | `#e8a13a` | amber: high markers/bars, active window, Review |
| `--accent-soft` | `rgba(232,161,58,0.08)` | high marker fill |
| `--bad` | `#d96649` | critical markers/bars, now line |
| `--bad-soft` | `rgba(217,102,73,0.10)` | critical marker fill |
| `--info` | `#6f9bc4` | (offline legend dot) |

Type: **Space Grotesk** for the title/names; **JetBrains Mono** (`.mono`) for the count sub-string,
tick labels, zone, popover meta, and the "now" label.

---

## 5. Acceptance checklist

- [ ] Toolbar: title + live "{N} cameras · {N} events", legend (critical/high/motion), and a
      **90m / 3.5h / 8h** window selector (3.5h default, amber active).
- [ ] Sticky **time axis** with hourly ticks + `HH:MM` labels, aligned to the lanes via the shared
      **188px gutter + fluid track** grid.
- [ ] **One lane per camera** (name + zone in the 188px gutter), min 64px tall, faint vertical
      gridlines through every lane.
- [ ] Each event = a **marker at its timestamp**, with a **duration bar extending right** sized to
      `durationSec` (critical red / high amber / else neutral); critical & high markers are larger.
- [ ] Marker states: hover (scale 1.12, brighten), handled (`opacity 0.4`); click toggles a **popover**
      (16:9 snapshot, type pill, mono meta, **Review / Bookmark / Ack**). Review opens the event in Triage.
- [ ] Dashed **"now {HH:MM}"** line pinned at the right edge across all lanes.
- [ ] Only the grid scrolls vertically; the axis stays pinned. All actions flow through shared state.
