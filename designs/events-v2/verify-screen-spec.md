# Verify screen — implementation spec

> **For claude-cli.** Authoritative, element-by-element description of the **Verify** screen
> (mode `02`, `view-review.jsx` / `ReviewView`, with bodies `view-wall.jsx` / `WallBody` and
> `view-sessions.jsx` / `SessionsBody`). Implement to this. Use the CSS variables from `styles.css`;
> only the literal values in the token table at the end are the resolved hexes. Do not add elements
> not listed here and do not restyle shared primitives or other screens.

---

## 0. Purpose & placement

**Verify is two review modes fused into one screen**, switched by a toggle at the top-left:

- **Verification Wall** — a snapshot-first grid for *visual* verification: the operator eyeballs each
  event ("real threat vs. courier / animal / weather") and confirms or dismisses in one click.
- **Smart Sessions** — a *noise-reduction* list: motion fragments collapse into sessions, grouped by
  zone, ranked by priority, with bulk acknowledge/dismiss.

The screen is reached by the **`02 · Verify`** button in the top mode switcher (`app.jsx`). It fills
the `.stage` of the fixed 1440×900 shell and **does not scroll as a whole** — only the grid / list
inside scrolls. Root element: `<div class="review">`, a vertical flex column with two parts:
the **toolbar** (`.review-bar`, fixed) and the **body** (`.review-body`, fills remaining height).

**Default state:** layout = Wall, Wall size = **M**, Sessions sort = **Priority**. The toolbar
remembers each layout's own control while you switch back and forth (component state in `ReviewView`).

---

## 1. Toolbar (`.review-bar`) — shared, contextual right side

Horizontal flex, `align-items:center; gap:14px; padding:12px 20px;` bottom border
`1px solid var(--line)`. Left → right:

### 1.1 Layout toggle (`.modeseg.review-toggle`) — the defining control
A 2-button **segmented control** (`.modeseg`: `inline-flex; border:1px solid var(--line-2);`
`background:var(--panel); height:40px`). Each button (`.review-toggle button`): `inline-flex;`
`align-items:center; gap:8px; padding:0 18px; font-size:13px; font-weight:600;` with a 14px leading
icon and a `1px solid var(--line)` divider between them.

1. **⊙ Verification Wall** — person icon + label. Sets `layout = 'wall'`.
2. **〰 Smart Sessions** — motion icon + label. Sets `layout = 'sessions'`.

**Active button:** solid **`var(--accent)`** fill with `var(--bg)` text (amber pill). **Inactive:**
`var(--ink-2)` text; hover → `background:var(--panel-2)`, text `var(--ink)`. Exactly one is active.

### 1.2 Spacer
`<span class="spacer">` (`flex:1`) pushes the contextual control to the far right.

### 1.3 Contextual control (`.review-ctl`) — **changes with the active layout**
Flex row, `align-items:center; gap:10px`. A mono label `.ctl-lbl` (11px `var(--ink-3)`) + the control:

- **When Wall is active → "Size" + S / M / L** (`.wall-size`): a segmented group
  (`inline-flex; border:1px solid var(--line-2)`), three **30×30** buttons (JetBrains Mono 11px,
  `var(--ink-2)`, `1px` dividers). Active size = amber fill + `var(--bg)` text. Sets the grid density.
- **When Sessions is active → "Sort" + Priority / Recent** (a `.modeseg` at `height:32px`, buttons
  `padding:0 14px; font-size:11px`): the active one is the amber pill. Sets the session ordering.

> The S/M/L group must **only** appear on the Wall; Priority/Recent **only** on Sessions. Never both.

### 1.4 Body (`.review-body`)
`flex:1; min-height:0; display:flex; flex-direction:column`. Renders `WallBody` (passing `size`) or
`SessionsBody` (passing `sortBy`) depending on `layout`. Both fill the body and scroll internally.

---

## 2. LAYOUT A — Verification Wall (`WallBody`, root `.wall`)

A vertical flex (`flex:1; flex-direction:column; min-height:0`): a **sub-bar** of filter tabs, then a
**scrolling card grid**.

### 2.1 Wall sub-bar (`.wall-subbar`)
Flex, `align-items:center; gap:16px; padding:11px 20px;` bottom border `1px solid var(--line)`.
- **Filter tabs** (`.wall-tabs`, `gap:4px`), three buttons (`padding:7px 14px; font-size:12px;`
  `font-weight:600; color:var(--ink-2);` transparent 1px border):
  1. **To verify** — events with status `new | ack` (the work queue). *Default.*
  2. **AI detections** — `person | vehicle | line_cross | loiter`.
  3. **All** — every event.
  **Active tab:** text `var(--accent)`, `border-color:var(--accent)`, `background:var(--accent-soft)`
  (an outlined amber pill).
- **Hint** (`.wall-hint`): a person icon (amber) + 12px `var(--ink-2)` text —
  "Verify what you see — confirm a real threat or dismiss a false alarm without leaving the grid."

### 2.2 Card grid (`.wall-grid.sz-<size>`)
`flex:1; overflow-y:auto; padding:18px 20px; display:grid; gap:16px; align-content:start`. Column
count is driven by the toolbar **Size**:
- **S → 5 columns** (`repeat(5,1fr)`), **M → 4 columns**, **L → 3 columns**.
Cards are sorted **priority → recency** (`SEV_RANK`, then newest first).

### 2.3 Event card (`.wcard`)
`background:var(--panel); border:1px solid var(--line); display:flex; flex-direction:column;`
`transition:border-color .12s`. Hover → `border-color:var(--line-2)`. A handled card
(status `resolved | dismissed`) is `.verified` → whole card `opacity:0.62`. Three stacked parts:

**a) Snapshot (`.wcard-snap`)** — `position:relative; cursor:pointer;` bottom border
`1px solid var(--line)`. Clicking it **jumps to the Triage Queue with this event selected**
(`setSel(id); setMode('triage')`). It contains:
- The CCTV still — `<Snapshot ev playing={hover && !verified}>`. **On hover** the snapshot enters its
  "playing" look (animated scrub feel) so the card previews the clip; verified cards don't animate.
- **Severity tag** (`.wcard-sev.<priority>`): top-right (`top:8px; right:8px`), JetBrains Mono **9px**
  UPPERCASE 700 on `rgba(0,0,0,0.6)`, `padding:2px 6px`. Color: critical = `--bad`, high = `--accent`,
  medium/low = `--ink-2`.
- **Clip-duration badge** (`.wcard-dur`, when `durationSec > 0`): bottom-right (`bottom:8px; right:8px`),
  a play glyph + humanized duration, **10px** white on `rgba(0,0,0,0.72)`, `padding:2px 6px`. For
  `offline` events show `.wcard-dur.off` "no clip" in `var(--ink-2)`.
- **Verified stamp** (`.wcard-stamp.<status>`, only when handled): a full-cover overlay
  (`inset:0`, centered) on `rgba(10,9,8,0.55)`, JetBrains Mono **13px** 700 letter-spaced —
  **"CLEARED"** in `var(--good)` (resolved) or **"DISMISSED"** in `var(--ink-2)`.

**b) Info (`.wcard-info`)** — `padding:10px 11px; gap:5px`, flex column:
- **Type pill** (`.tpill.<type>`) with icon + label + `· NN%` AI confidence when present
  (color-coded as elsewhere: person amber, vehicle blue, tamper/line_cross red).
- **Camera name** (`.wcard-cam`): 12px `var(--ink)`, weight 500.
- **Time** (`.wcard-time`): JetBrains Mono 10px `var(--ink-3)` — `HH:MM:SS · {n}m ago`.

**c) Action row (`.wcard-act`)** — `padding:0 11px 11px; gap:5px`, **only on un-verified cards**.
Three buttons; the two text buttons flex to fill, the icon button is fixed:
- **↑ Threat** (`.btn.good.sm`, olive): `act.dispose(id,'verified')` — confirms a real threat.
- **✕ Dismiss** (`.btn.sm`, neutral): `act.dispose(id,'false_alarm')` — clears a false alarm.
- **▣ Bookmark** (`.btn.sm.icon`): toggles `act.bookmark(id)`; filled amber + `.is-on` when saved.

After Threat/Dismiss the card flips to `.verified` (dimmed + stamp), the action row disappears, and the
shared OPEN/CLEARED counts update.

---

## 3. LAYOUT B — Smart Sessions (`SessionsBody`, root `.ses`)

`flex:1; flex-direction:column; min-height:0; position:relative` (relative so the floating bulk bar
anchors to it). A **stat header**, then a **scrolling list of zone groups**, with a **bulk action bar**
that appears when rows are selected.

### 3.1 Stat header (`.ses-statbar`)
Flex, `align-items:center; gap:24px; padding:13px 20px;` bottom border `1px solid var(--line)`.
Three `.ses-stat` blocks, each a big number (`b`, **26px** 700) + a 2-line mono caption
(`span`, 10px UPPERCASE `var(--ink-3)`):
1. **38** — "motion fragments collapsed into sessions" (the noise-reduction headline; static demo value).
2. **{n}** in `--bad` — "high-priority need action" (open critical+high count).
3. **{n}** in `--good` — "handled this shift" (events with status ≠ new).

### 3.2 Zone list (`.ses-scroll`, `overflow-y:auto; flex:1`)
Events are **grouped by `cam.zone`**. Each zone's rank = its most severe event; zones are ordered by the
toolbar **Sort**: *Priority* → by zone rank; *Recent* → by newest event in the zone. Within a zone,
rows are sorted priority → recency.

**Zone header (`.ses-zone-h`)** — full-width button, flex `gap:10px; padding:11px 20px;`
`background:var(--panel)`, bottom border `1px solid var(--line)`; hover `var(--panel-2)`. Contents:
- **Chevron** (`.ses-zchev`): rotates **90° (open)** ↔ **0° (collapsed)**, `var(--ink-3)`,
  `transition:transform .12s`. Clicking the header collapses/expands the group.
- **Zone severity dot** (`.sevdot.<rank>`): 8px, colored by the zone's worst event.
- **Zone name** (`.ses-zname`, 13px 600).
- **Session count** (`.ses-zcount`, mono 11px `var(--ink-3)`) — "{n} sessions".
- **Open badge** (`.ses-zopen`, only if any `new`): pushed right (`margin-left:auto`), mono 10px
  `var(--bad)`, `border:1px solid var(--bad-dim)`, `padding:1px 7px` — "{n} open".

**Session row (`.ses-row`)** — an **8-column CSS grid**, `align-items:center; gap:12px;`
`padding:10px 20px;` bottom border `1px solid var(--line)`. Columns, in order:
`grid-template-columns: 24px 64px 1fr 150px 84px 88px 92px 150px;`
1. **Checkbox (`.ses-cbx`, 24px col):** 18×18, `border:1px solid var(--line-2)`; selected `.on` =
   amber fill + white check. Toggles row selection for bulk actions.
2. **Thumbnail (`.ses-thumb`, 64px):** 64×38, `border:1px solid var(--line)`,
   `<Snapshot ev mini showOsd={false}>`.
3. **Main (`.ses-main`, 1fr):** type pill (`.tpill`) over a one-line note (`.ses-note`, 12px
   `var(--ink-2)`, ellipsized) — e.g. "Unscheduled presence in Server Room after hours." / "Motion session".
4. **Camera (`.ses-cam`, 150px):** 12px `var(--ink)`.
5. **Duration (`.ses-dur`, 84px):** clock icon + mono 11px duration (icon `var(--ink-3)`).
6. **Time (`.ses-time`, 88px, right-aligned):** mono 11px `HH:MM:SS` over a 10px `var(--ink-3)`
   "{n} ago".
7. **Severity (`.sev.<priority>`, 92px):** mono 10px UPPERCASE label + 3×12px color bar.
8. **Row actions (`.ses-rowact`, 150px, right-aligned):**
   - if `new` → **✓ Ack** (`.btn.sm`, `act.ack(id)`) + **▣ bookmark** icon button (`act.bookmark`).
   - else → a `.statetag.<status>` showing the disposition label or status.

**Row states:** hover `var(--panel)`; **selected** (`.picked`) `background:var(--accent-soft)`;
**handled** (`.handled`, status ≠ new) `opacity:0.5`.

### 3.3 Bulk action bar (`.ses-bulk`) — floating, appears when ≥1 row is selected
Centered near the bottom of the body (`position:absolute; bottom:18px; left:50%;`
`transform:translateX(-50%)`), `background:var(--panel-3); border:1px solid var(--line-2);`
`padding:10px 14px;` strong drop shadow `0 14px 34px rgba(0,0,0,0.5)`, `min-width:480px`, flex `gap:10px`:
- "{n} selected" (mono 12px `var(--accent)`), spacer, then:
- **✕ Dismiss as noise** (`.btn.sm`) → bulk `dispose(...,'false_alarm')`.
- **✓ Acknowledge selected** (`.btn.sm.pri`, amber) → bulk `ack`.
- **Clear** (`.btn.sm.ghost`) → clears the selection.
After a bulk action, selection resets and the affected rows update (handled/dimmed) with counts.

---

## 4. State, data & behavior summary

- **`ReviewView` state:** `layout` ('wall' | 'sessions'), `size` ('s'|'m'|'l'), `sortBy`
  ('priority'|'recent'). Each persists while you toggle layouts.
- **`WallBody` state:** `tab` (filter), `hover` (which card is previewing).
- **`SessionsBody` state:** `picked` (selected row ids), `collapsed` (which zones are folded).
- **Props in:** both bodies receive `events` + `act` (and Wall also `setSel`/`setMode`). They never
  fork their own copy — all mutations go through `act`, so the top-bar OPEN/CRITICAL/CLEARED counts
  and every other view update live.
- **Cross-view jump:** clicking a Wall card's snapshot opens that event in the **Triage Queue**.
- **Action vocabulary:** Wall uses *Threat* (`verified`) / *Dismiss* (`false_alarm`) / *Bookmark*;
  Sessions uses *Ack* / *Bookmark* per row and *Acknowledge / Dismiss as noise* in bulk.

---

## 5. Token reference (resolved values)

| Token | Value | Role on this screen |
|-------|-------|---------------------|
| `--bg` | `#1a1816` | active-toggle text, screen bg |
| `--panel` | `#221f1c` | cards, zone headers, toggle bg |
| `--panel-2` | `#2a2722` | toggle/tab hover |
| `--panel-3` | `#322e28` | bulk bar bg |
| `--line` | `#34302a` | hairlines, card borders, grid dividers |
| `--line-2` | `#443f37` | control borders |
| `--ink` | `#f0ece4` | primary text |
| `--ink-2` | `#a89f90` | secondary text, dismissed stamp |
| `--ink-3` | `#6e6657` | muted labels, chevron, captions |
| `--accent` | `#e8a13a` | amber: active toggle/tab/size/sort, Acknowledge, selection, bookmark-on |
| `--accent-soft` | `rgba(232,161,58,0.08)` | active wall tab fill, picked row |
| `--bad` | `#d96649` | critical, "open" badge, high-priority stat |
| `--good` | `#8eb96b` | Threat button, CLEARED stamp, handled stat |
| `--info` | `#6f9bc4` | vehicle pill / in-progress |

Type: **Space Grotesk** UI; **JetBrains Mono** (`.mono`) for counts, times, durations, severities,
size/sort labels, and all-caps tags.

---

## 6. Acceptance checklist

- [ ] One screen, top-left **[Verification Wall | Smart Sessions]** toggle (amber active pill);
      default Wall.
- [ ] Right-side control is **contextual**: S/M/L only on Wall, Priority/Recent only on Sessions;
      each remembers its value across toggles.
- [ ] **Wall:** filter tabs (To verify default / AI detections / All); grid is **5/4/3 cols** for S/M/L;
      cards show hover-preview snapshot, severity tag, **clip-duration badge** (or "no clip"),
      type pill + confidence, camera, time; **Threat / Dismiss / Bookmark** actions; handled cards
      dim with **CLEARED / DISMISSED** stamp; snapshot click opens the event in Triage.
- [ ] **Sessions:** 3-stat header; events **grouped by zone**, zone headers collapse via chevron,
      show rank dot + session count + "open" badge; 8-column rows (checkbox, thumb, type+note,
      camera, duration, time, severity, row actions); sort by **Priority/Recent**; row select →
      **floating bulk bar** (Dismiss as noise / Acknowledge selected / Clear).
- [ ] All actions flow through shared state; counts and dimming update everywhere immediately.
