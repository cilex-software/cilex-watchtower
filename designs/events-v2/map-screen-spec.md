# Situation Map — implementation spec

> **For claude-cli.** Authoritative, element-by-element description of the **Situation Map** screen
> (mode `04`, `view-map.jsx` / `MapView`). Implement to this. Use the CSS variables from `styles.css`;
> the token table at the end gives the resolved hexes. Do not add elements not listed here and do not
> restyle shared primitives or other screens.

---

## 0. Purpose & placement

The Situation Map is the **spatial situational-awareness** view for supervisors and owners who think
in *places*, not log lines. A schematic site plan shows each camera as a pin where it physically sits;
**open events pulse on the pin** where they're happening, color-coded by severity, with a count badge.
A right rail carries the live feed, and clicking any pin (or feed item) drops into a **per-camera panel**
to verify and dispatch *in context*.

Reached by the **`04 · Situation Map`** button in the top mode switcher (`app.jsx`). It fills the
`.stage` of the fixed 1440×900 shell. Root element: `<div class="map">`, a **2-column grid**:

```
grid-template-columns: 1fr 360px;   /* map canvas | side rail */
min-height: 0;
```

- **Left (fluid):** `.map-canvas` — the site plan + legend.
- **Right (360px fixed):** `.map-side` — live feed, or the selected-camera detail.

**Default state:** no camera selected (`active = null`) → the right rail shows the **Live feed**.

---

## 1. LEFT — map canvas (`.map-canvas`)

`position:relative; padding:24px; display:flex; flex-direction:column; min-height:0`. Background is a
subtle amber glow over the base: `radial-gradient(circle at 30% 20%, rgba(232,161,58,0.03), transparent
60%)` layered on `var(--bg)`. Two stacked parts: the **plan** (fills) and the **legend** (below).

### 1.1 Site plan (`.map-plan`)
`flex:1; position:relative; border:1px solid var(--line-2); background:var(--panel); min-height:0`.
It is a coordinate space `0–100` in both axes (pins are positioned by percentage). Three layers:

**a) Rooms (`<svg class="map-rooms">`)** — `position:absolute; inset:0; width/height:100%`,
`viewBox="0 0 100 100" preserveAspectRatio="none"` (so the schematic stretches to fill). Drawn shapes:
- **Outer wall** (`.mr-out`): `rect` 2,2 → 96×96, `fill:none; stroke:var(--line-2); stroke-width:0.4`.
- **Seven room rects** (`.mr`): `fill:rgba(255,255,255,0.012); stroke:var(--line); stroke-width:0.3` —
  the building's internal partitions (loading/stock/server/parking/etc.), as laid out in the source.
- **One door gap** (`.mr-gap`): a short `line` painted in `var(--bg)` `stroke-width:1.2` that "erases"
  a slice of wall to suggest an opening.

> The room rectangles are a **schematic backdrop**, not data — keep them simple and architectural.

**b) Zone labels (`.map-labels span`)** — absolutely positioned mono captions
(`transform:translate(-50%,-50%); font-family:JetBrains Mono; font-size:10px; color:var(--ink-3);`
`text-transform:uppercase; letter-spacing:0.06em; pointer-events:none`). Eight labels at fixed
`left%/top%` positions naming the areas: Rear Yard, N. Perimeter, Stockroom, Server Rm, Parking E.,
Loading, Reception, Main Ent.

**c) Camera pins (`.map-pin`)** — one per camera in `CAMS`, positioned at the camera's own
`left:x%; top:y%` (`transform:translate(-50%,-50%)`), a **30×30** flex-centered button. Pin state is
computed per camera: if it has open (`new`) events → its **most-recent event's priority**; else if its
latest event is `offline` → `offline`; else `idle` (clear). Inside each pin:
- **Ping ring (`.map-ping`, only when open>0):** a 30×30 ring (`border:2px solid var(--accent)`) that
  **animates outward** — `@keyframes ping` scales 1→2.4 and fades 0.8→0 over 1.8s, looping. For a
  critical pin the ring is `var(--bad)`. This is the "something is happening here" pulse.
- **Dot (`.map-dot`):** the 30px disc, `border-radius:50%; background:var(--panel-3);`
  `border:1px solid var(--line-2); color:var(--ink-2); z-index:2`, holding a 14px map-pin glyph.
  Color by state:
  - **idle** → `color:var(--good)`, `border:var(--good-dim)` (calm olive = clear).
  - **offline** → `color:var(--info)`, blue-grey border.
  - **medium / low** open → `color:var(--ink)` (neutral, present but not urgent).
  - **high** → amber: `color/border:var(--accent)`, `background:var(--accent-soft)`.
  - **critical** → red: `color/border:var(--bad)`, `background:var(--bad-soft)`.
  - **selected** (`.on`, the active camera) → `box-shadow:0 0 0 3px var(--accent)` halo.
- **Count badge (`.map-badge`, only when open>0):** top-right (`top:-4px; right:-4px`), a red pill
  (`background:var(--bad)`, white, mono 9px 700, `min-width:16px; height:16px; border-radius:8px;`
  `z-index:3`) showing the number of open events at that camera.
- **Click** selects the camera (`setActive(cam.id)`) → the right rail switches to its detail panel.

### 1.2 Legend (`.map-legend`)
Below the plan, `display:flex; gap:16px; padding-top:14px; font-size:11px; color:var(--ink-2)`. Four
entries, each a 9px `.lg` dot + label: **critical activity** (`--bad`), **elevated** (`--accent`),
**offline** (`--info`), **clear** (`--good`). Decodes the pin colors.

---

## 2. RIGHT — side rail (`.map-side`)

`360px`, `border-left:1px solid var(--line); display:flex; flex-direction:column; min-height:0;`
`background:var(--bg)`. It shows **one of two states**: the live feed (nothing selected) or the
camera detail (a pin/feed item selected).

### 2.1 State A — Live feed (when `active == null`)
- **Header (`.map-side-h`)** — `padding:14px 16px;` mono **11px** UPPERCASE `var(--ink-3)`,
  space-between, bottom border `1px solid var(--line)`: "Live feed" on the left, "{N} open" on the
  right in `var(--accent)`.
- **Feed list (`.map-feed`, `overflow-y:auto; flex:1`)** — all open (`new`) events, sorted
  **priority → recency**. Each row (`.map-feed-row`, full-width button, `display:flex; gap:10px;`
  `padding:11px 16px 11px 0`, bottom border `1px solid var(--line)`; hover `var(--panel)`):
  - **Severity bar (`.sevbar.<priority>`):** a 3px-wide full-height color stripe at the very left
    (critical red / high amber / medium ink-2 / low ink-3).
  - **Thumbnail (`.mf-thumb`):** 76×44, `border:1px solid var(--line)`, `<Snapshot ev mini showOsd={false}>`.
  - **Body (`.mf-body`, flex column `gap:4px`):** type pill (`.tpill`, 11px icon), zone name
    (`.mf-cam`, 12px `var(--ink)`), and relative time (`.mf-time`, mono 10px `var(--ink-3)`).
  - **Click** selects that event's camera (`setActive(e.cam.id)`) → opens the detail panel.

### 2.2 State B — Camera detail (when a camera is `active`)
Container `.map-detail` (`display:flex; flex-direction:column; padding:16px; overflow-y:auto; gap:6px`).
Top → bottom:
- **Back (`.map-back`):** "‹ All zones", 12px `var(--ink-2)`, hover `var(--accent)`. Clears selection
  → returns to the live feed.
- **Camera name (`.map-d-cam`):** 16px 600 (e.g. "Server Room — Rack A").
- **Sub-line (`.map-d-zone`, mono):** 11px `var(--ink-3)` — "{zone} · {device id}".
- **Latest snapshot (`.map-d-snap`):** the camera's most-recent event as a full `<Snapshot>` (with OSD),
  `border:1px solid var(--line)`, `margin-bottom:12px`. (Omitted if the camera has no events.)
- **Action row (`.map-d-act`, `gap:6px; margin-bottom:16px`)** — three equal-width buttons acting on
  the latest event, **in context**:
  - **▶ Verify** (`.btn.pri.sm`, amber) → `setSel(curEv.id); setMode('triage')` — opens it in Triage.
  - **➤ Dispatch** (`.btn.danger.sm`, red) → `act.dispose(curEv.id,'dispatched')`.
  - **✓ Clear** (`.btn.good.sm`, olive) → `act.dispose(curEv.id,'authorized')`.
- **Recent header (`.map-d-h`):** mono 10px UPPERCASE `var(--ink-3)` "Recent at this camera".
- **Recent list (`.map-d-list`)** — up to 6 latest events at this camera, each `.map-d-row`
  (`display:flex; align-items:center; gap:10px; padding:8px 0;` top border `1px solid var(--line);`
  `font-size:12px`): a severity `.sevdot`, a borderless type pill (icon + label, `var(--ink-2)`),
  a spacer, a mono `HH:MM:SS` time, and a `.statetag` state dot. If the camera has no events, show
  `.map-d-empty` "No events at this camera."

---

## 3. State, data & behavior

- **`MapView` state:** `active` — the selected camera id, or null.
- **Derived per render:** `byCam` (latest event per camera, drives pin state), `openByCam` (open count
  per camera, drives the badge + ping), `feed` (all open events, sorted), and for the active camera its
  sorted `curEvents` + latest `curEv`.
- **Props in:** `events`, `act`, `setSel`, `setMode`. Pins, badges, feed, and the detail panel all
  derive from `events`; actions go through `act`, so dispatching/clearing here updates the pin color,
  the badge, the top-bar counts, and every other view immediately.
- **Cross-view jump:** "Verify" opens the event in the **Triage Queue**.
- **Selection sources:** both a map pin and a live-feed row select a camera (same `setActive`).

---

## 4. Token reference (resolved values)

| Token | Value | Role on this screen |
|-------|-------|---------------------|
| `--bg` | `#1a1816` | canvas/rail base, door-gap erase |
| `--panel` | `#221f1c` | plan fill, feed-row hover |
| `--panel-3` | `#322e28` | pin dot base |
| `--line` | `#34302a` | room strokes, rail/row borders |
| `--line-2` | `#443f37` | plan border, outer wall, pin border |
| `--ink` | `#f0ece4` | camera names, medium/low pins |
| `--ink-2` | `#a89f90` | legend/body text, default pin glyph |
| `--ink-3` | `#6e6657` | zone labels, headers, muted meta |
| `--accent` | `#e8a13a` | amber: elevated pins, ping ring, selection halo, "open" count, Verify |
| `--accent-soft` | `rgba(232,161,58,0.08)` | high pin fill |
| `--bad` | `#d96649` | critical pins + ping, count badge, sev bar, Dispatch |
| `--bad-soft` | `rgba(217,102,73,0.10)` | critical pin fill |
| `--good` | `#8eb96b` | idle/clear pins, Clear action |
| `--info` | `#6f9bc4` | offline pins |

Type: **Space Grotesk** for names/labels; **JetBrains Mono** (`.mono`) for zone labels, header counts,
device id, times, and the recent-list times.

---

## 5. Acceptance checklist

- [ ] 2-column layout: **fluid map canvas + 360px side rail**.
- [ ] Schematic **site plan** (outer wall, room partitions, door gap) with 8 mono **zone labels**.
- [ ] **Camera pins** placed by percentage; state = critical/high(amber)/neutral/offline(blue)/idle(olive);
      open pins show an animated **ping ring** + red **count badge**; selected pin gets an amber halo.
- [ ] **Legend** decodes the four pin states.
- [ ] Rail default = **Live feed**: header "{N} open"; rows with sev bar, 76×44 thumb, type pill,
      zone, relative time; clicking a row selects its camera.
- [ ] Selecting a pin/row → **camera detail**: back link, name + zone·device, latest full snapshot,
      **Verify / Dispatch / Clear** action row, and a "Recent at this camera" list (≤6, sev dot +
      type + time + state).
- [ ] Verify opens the event in Triage; Dispatch/Clear update pin color, badge, and counts live via
      shared state.
