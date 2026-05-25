# Handoff: Watchtower — Lightweight VMS native client

## Overview

Watchtower is the chosen design direction for a **lightweight end-user Video Management System (VMS)** native client running on Ubuntu. It is intended for security operators who spend long shifts in front of the application, monitoring 1 to 500 cameras across one or more sites.

The design is a **tactical hybrid**: warm graphite surfaces with amber accents, sharp orthogonal chrome, a single dense type pairing (Space Grotesk + JetBrains Mono), and a persistent operations sidebar on the Live Monitor so live events stay visible without leaving the grid.

Scope of this handoff covers the full end-user surface:

1. Sign-in
2. Live Monitor (default landing)
3. Camera Groups
4. Saved Views
5. Playback (per camera, with timeline scrubber)
6. Events & Alerts
7. Health
8. Clips & Snapshots (artifact library)
9. Preferences
10. Full-screen monitoring variant

Plus the overlays the operator interacts with constantly: command palette (Ctrl+K), group/view selector popover, save-view modal, bookmark modal, clip export drawer, export confirmation modal, event detail drawer, artifact detail drawer, layout picker popover, and the alert toast stack.

## About the Design Files

The single HTML file in this bundle (`design/watchtower.html`) is a **design reference, not production code**. It is a clickable React + Babel prototype rendered inline so the design intent is exact and inspectable. It is **not** the implementation; do not lift its JSX, inline `<style>` block, or component structure into the real client.

The implementation target is an **Ubuntu native desktop application**. Recreate this design in whichever framework the project standardizes on (Qt/QML, GTK, Electron + React/Vue, Tauri + React, Flutter desktop, etc.). If the project has no codebase yet, choose a framework appropriate for Ubuntu native delivery and the team's expertise. Use that framework's idiomatic patterns — its component library, its state management, its layout primitives — and apply this design's tokens (color, typography, spacing, iconography) on top.

## Fidelity

**High-fidelity.** The prototype is pixel-precise for a 1440×900 design size and includes final colors, typography, spacing, borders, hover states, and interactions. Implementers should recreate the UI as shown, using the design tokens enumerated below. The window-frame styling is generic Linux/GNOME-style; the host OS chrome will replace it in the real application.

---

## Design Tokens

### Color

All colors are warm-shifted graphite. The accent is a single amber used for emphasis, selection, and primary actions. Status colors are restrained.

| Token | Hex | Purpose |
|---|---|---|
| `--bg` | `#1a1816` | Window background, table headers, sub-bars |
| `--panel` | `#221f1c` | Cards, drawers, modals, top bar |
| `--panel-2` | `#2a2722` | Hover/secondary panel surface |
| `--line` | `#34302a` | Hairline dividers (subtle) |
| `--line-2` | `#443f37` | Component borders, table cells |
| `--ink` | `#f0ece4` | Primary text |
| `--ink-2` | `#a89f90` | Secondary text |
| `--ink-3` | `#6e6657` | Tertiary text, labels, placeholder |
| `--accent` | `#e8a13a` | Amber — primary, active, focus |
| `--accent-dim` | `#5a3f15` | Amber background for chips/badges |
| `--accent-soft` | `rgba(232,161,58,0.08)` | Subtle accent fill |
| `--good` | `#8eb96b` | LIVE indicator (olive) |
| `--good-dim` | `#2a4015` | LIVE chip background |
| `--bad` | `#d96649` | OFFLINE indicator, REC indicator |
| `--bad-dim` | `#4a2218` | Offline/REC chip background |
| `--rec` | `#d96649` | Recording (same as bad) |
| Window background (behind app) | `#0d0c0b` | OS-level chrome backdrop |

### Status semantics

A camera has **two independent statuses**, both must be communicated:

- **Live status**: `live` (olive `--good`), `offline` (`--bad`), `degraded` (`--accent`), `unknown` (`--ink-3`)
- **Recording status**: `recording` (`--bad` pulsing dot), `not-recording` (`--accent`, hollow ring), `unknown` (`--ink-3`), `gap` (`--accent`, diagonal stripe pattern)

A common combination is **live + not-recording** (operator must be made aware: "monitoring works, no footage is being saved"). The badge stack always shows live state first, recording state second.

### Typography

Two families only:

- **Space Grotesk** — primary UI font (400 / 500 / 600 / 700). Used for body, controls, headings, button labels, table cells.
- **JetBrains Mono** — used for timestamps, camera IDs, counts inside chips, table column headers (uppercase), and any tabular numeric data (400 / 500 / 600).

Letter-spacing on Space Grotesk body is `-0.005em`; on display sizes ≥ 18px use `-0.01em` to `-0.03em` (tighten as size grows). All-caps labels in JetBrains Mono use `letter-spacing: 0.06em` to `0.16em` depending on size; **never** use all-caps in Space Grotesk.

| Use | Family | Size | Weight | Tracking |
|---|---|---|---|---|
| Display number (login stat, health card) | Space Grotesk | 32–36px | 700 | -0.03em |
| Page H1 | Space Grotesk | 24px | 600 | -0.01em |
| Modal/drawer title | Space Grotesk | 16px | 600 | -0.01em |
| Body | Space Grotesk | 13px | 400 | -0.005em |
| Small body / table cell | Space Grotesk | 12–13px | 400/500 | 0 |
| Tabular numeric / timestamp / ID | JetBrains Mono | 11–13px | 500/600 | 0 |
| Uppercase label / eyebrow / column header | JetBrains Mono | 10–11px | 600 | 0.08em – 0.16em |
| Status badge text | JetBrains Mono | 9px | 600 | 0.06em |

### Spacing & geometry

- **Base unit**: 4px. Common rhythm: 4 / 8 / 10 / 12 / 14 / 16 / 18 / 20 / 22 / 24 / 28 / 32 / 36 / 48 / 56.
- **Border-radius**: **0** everywhere. Watchtower is intentionally orthogonal. The only round elements are the live/recording dot indicators (8px circles), the user avatar (square — not round in this variant), and SVG glyph internals.
- **Borders**: 1px solid on chrome (`--line-2`); 1px solid `--line` for low-emphasis dividers; 3px solid `--accent` on selected/active nav rail; 4px solid `--bad` or `--accent` as left-edge on toasts; 3px top-bar on tile when in a fault state.
- **Camera-grid separator**: 1px hairline. Implemented as a `--line-2` background on the grid container with `gap: 0` and `outline: 1px solid var(--line-2); outline-offset: -1px` on each tile. No gutter between tiles.
- **Shadow**: Reserved for floating surfaces (modals, drawers, palette, toasts). Use `0 24px 60px rgba(0,0,0,0.6)` for centered modals; `-20px 0 40px rgba(0,0,0,0.4)` for the right-drawer; `0 12px 30px rgba(0,0,0,0.5)` for toasts. Tiles, chips, cards, nav items do **not** carry shadow.

### Iconography

Stroke-based outline icons, 1.5px stroke, 24×24 viewbox, sized 14/16/20 in the UI. The prototype uses an inline SVG set inside the `I` object — implement these in your icon library or adopt an equivalent set (e.g. Lucide). The named icons referenced in the design:

`monitor`, `grid`, `layers`, `clip`, `bell`, `pulse`, `gear`, `search`, `x`, `play`, `pause`, `back`, `fwd`, `jumpBack`, `jumpFwd`, `full`, `shot` (snapshot/camera), `bookmark`, `star`, `newtab`, `download`, `audio`, `audioMute`, `chev`, `alert`, `off`, `rec` (filled dot), `motion`, `check`.

---

## Layout primitives

### Window shell

The application window is 1440×900 design size, **fixed**, but the chrome scales:

```
┌─────────────────────────────────────────────────────────────┐
│ Title bar (36px) — generic OS-style, replaced by host       │
├──────┬──────────────────────────────────────────────────────┤
│      │ Top bar (64px)                                       │
│ Nav  ├──────────────────────────────────────────────────────┤
│ rail │ Sub-bar (56px, per-screen)                           │
│ 72px ├────────────────────────────────────┬─────────────────┤
│      │ Main content                       │ Ops sidebar     │
│      │                                    │ 320px           │
│      │                                    │ (Live only)     │
└──────┴────────────────────────────────────┴─────────────────┘
```

Backgrounds layer: window root `--bg`; top bar `--bg`; sub-bar `--bg`; nav rail `--bg`; panels (cards/sidebars) `--panel`; hover/secondary `--panel-2`. Hairlines `--line` between bars and rail.

### Nav rail (left, 72px)

Visible items, top → bottom: **Logo** (36×36, solid `--accent` square, white "W" in JetBrains Mono 700 16px), **Live**, **Groups**, **Views**, **Events** (with a badge count when there are unacknowledged events), **Health**. Nothing else — no "Clips", no "Preferences" in this variant. Preferences and account live behind the avatar in the top bar.

Each item: 72px wide × 56px tall, vertical stack: icon (20px stroke) above an uppercase JetBrains Mono 9px label (`letter-spacing: 0.12em`). Color rest = `--ink-3`. Hover: bg `--panel`, color `--ink-2`. Active: bg `--panel`, color `--accent`, plus a 3px-wide `--accent` left edge bar.

Unacknowledged-event badge: 16px tall, square (not pill), `--bad` bg, white JetBrains Mono 10px 600, top-right of the icon, padding 0 4px.

### Top bar (64px)

Five regions, left → right:

1. **Operator card** — column. Eyebrow `VMS OPERATOR` (JetBrains Mono 10px 600 uppercase `--ink-3`), then the operator's username at 16px 600 Space Grotesk. Right-bordered with `--line`.
2. **Global search** — flex-grow up to ~420px max width. Height 38px, bg `--panel`, border 1px `--line-2`. Left icon. Placeholder: `Search cameras, groups, views, clips, events…`. Right end shows a `CTRL K` kbd hint in JetBrains Mono 10px.
3. **Site status strip** — flush against the right of search. A row of three chips inside a single bordered container: **Online 89** (good dot), **Offline 4** (bad dot), **Not Rec 3** (accent dot). Chip height 38px, label in JetBrains Mono 11px 600 uppercase `letter-spacing: 0.08em`, count in Space Grotesk 18px 700. Cells are separated by a 1px `--line` divider, no gutter. Clicking a chip filters the visible grid by that status.
4. **Clock** — JetBrains Mono 12px. Format `HH:MM · UTC+1`. Updates every second. The offset is in 600 weight.
5. **Bell icon + avatar** — bell with red dot for unacknowledged alerts. Avatar is a 34px solid `--accent` square (not round) with initials in JetBrains Mono 12px 700, dark `--bg` ink.

### Sub-bar (per-screen)

Holds screen-local controls. For Live, see the Live section below. For list screens (Events, Clips, Health), holds filter pills and right-aligned actions.

### Ops sidebar (320px, Live Monitor only)

Right-docked, full-height. Two stacked sections:

- **Site Status** (header `JetBrains Mono 10px 600 uppercase 0.16em` `--ink-3`). Below it a 2×2 grid of "stat cells" separated by 1px `--line`: Online 89 (good), Offline 4 (bad), Degraded 3 (warn), Not rec 3 (warn). Each cell: label JetBrains Mono 10px uppercase, value Space Grotesk 22px 700, colored by category.
- **Live Events** (header right-aligned link "View all →" in `--accent` 11px). Below, a vertical feed of event rows. Each row: 22px circular icon (live/motion/offline glyph, color-coded), title in Space Grotesk 12px 500, secondary in JetBrains Mono 10px (camera name + time). Unacknowledged events show a 6×6 `--bad` square at the right.

This sidebar **hides** in full-screen mode.

---

## Screen specifications

### 1. Sign-in

Two-pane, 1440×900, full-bleed. **Left pane** (flex 1) is `--panel` with a faint radial highlight (`radial-gradient(circle at 20% 80%, rgba(232,161,58,0.06) 0, transparent 50%)`). Contains, top-aligned: 56px amber logo, `JetBrains Mono 11px` eyebrow "VMS — OPERATIONS", H2 in Space Grotesk 36px 600 (`-0.02em`): *"Watchtower keeps your sites visible."*; padding 48px 56px. Bottom-aligned: a 2-column stat block — `137 Cameras online` and `7 Active issues` (in `--bad`).

**Right pane** (480px) is `--bg`. Contains H1 "Sign in" (Space Grotesk 24px), subtitle "Operator console · HQ Campus" (`--ink-3` 13px). Two fields: Operator ID, Password. Sign-in button is a full-width amber primary at 42px tall, JetBrains Mono 13px 600 uppercase `0.06em`. Below: build version `v 4.2.1 · build 2026.05.18` in JetBrains Mono 11px `--ink-3`. Error state: a `--bad-dim` block with 1px `--bad` border, "Incorrect operator ID or password."

### 2. Live Monitor (default landing)

The center grid sits between the sub-bar and the ops sidebar.

**Sub-bar layout, left → right**:

1. **Layout segmented control** — height 38px, single bordered container. Four buttons separated by 1px dividers:
   - `2×2` — small grid glyph + label
   - `3×3` — 9-cell glyph + label
   - `4×4` — 16-cell glyph + label
   - `Other ⌄` — separated by a `--line-2` left border; opens the layout picker popover (Single / 1+3 / 1+9 / 2×3 / 5×5 / 1+3 wide)
   - Active button: bg `--accent`, ink `--bg` (high contrast block).
2. Vertical 1px divider.
3. **Filter pills** (3 only): `Online ×` (active by default), `Recent events`, `+ Filter`. Active pill = `--accent-soft` bg + `--accent` border + `--accent` text. Inactive: `--panel` bg, `--line-2` border, `--ink-2` text. No "Favorites" pill in this variant.
4. Spacer.
5. **Right cluster**: `Save current view` (ghost button), `Sort: Layout` dropdown (`--panel`, 38px), full-screen icon button.

**Camera grid**:

- Width fills (vw − rail − ops sidebar), padding `14px 20px`.
- Grid container is the separator: `display: grid; gap: 0; background: var(--line-2); border: 1px solid var(--line-2);`. Tiles inside have **no** border; instead they carry `outline: 1px solid var(--line-2); outline-offset: -1px;` so neighbours share exactly one hairline.
- Tile aspect comes from `grid-template-rows: repeat(N, 1fr)`. Always 16:9 effective per cell.

**Camera tile**:

- Background `#0a0908` (near-black, warm).
- Top-left overlay (linear-gradient 70% → transparent from top): camera **name** at 11px 600 white, **id** at JetBrains Mono 10px 60% white below it.
- Top-right overlay: badge stack — live state then recording state. Badges are 18px tall, padding `0 6px`, color-coded background (`--good-dim` / `--bad-dim` / `--accent-dim`), text in matching color, JetBrains Mono 9px 600 uppercase 0.06em.
- Fault tiles get a 3px colored top edge (`--bad` if offline, `--accent` if not-recording or degraded). Border color matches.
- An **inline issue strip** sits 34px from the bottom on faulted tiles: black bg, 3px left edge in `--accent`, JetBrains Mono 10px uppercase 0.06em — e.g. `⚠ LIVE, NO RECORDING — VIEW ISSUE ›`.
- On hover, an action column appears at the right edge: 5 buttons (open playback, snapshot, bookmark, favorite, open-in-new-tab), each 30×30 with `rgba(0,0,0,0.85)` bg and `--line-2` border. Hover: `--accent` bg/border, `--bg` ink.
- Offline state: instead of feed, a centered group — large `off` glyph in `--bad`, "NO SIGNAL" in white 13px 600 0.04em, "last seen HH:MM" in JetBrains Mono 11px 50% white.

**Layout picker popover** (when "Other" is clicked):

- Centered scrim modal, 480px wide, 1px `--accent` border.
- Header "Other layouts" 14px 600.
- 3×2 grid of layout option buttons, 18px padding, each containing a small SVG diagram (40×30) and a JetBrains Mono 11px uppercase 0.08em label.
- Each option is a separate cell with 1px `--line` separator. Hover: bg `--panel-2`, label `--accent`, diagram stroke `--accent`.
- Footer right-aligned `Cancel` ghost button.

**Full-screen monitoring**:

- Activated by the full-screen icon button or pressing **F**.
- Nav rail hides. Sub-bar hides. Ops sidebar hides.
- Top bar becomes a translucent floating overlay: `rgba(26,24,22,0.85)` with `backdrop-filter: blur(8px)`.
- Grid padding shrinks to `4px` (with `padding-top: 72px` for the floating top bar).
- Tile gap stays at the same 1px hairline.
- Esc or the explicit "Exit full-screen" floating button (top-right) returns to normal.

### 3. Camera Groups

Two-pane: 320px left tree + main pane.

**Group tree** (left): hierarchical, indented by level (16px per level). Each row: 12px chevron · group name (13px Space Grotesk) · right-aligned counts in JetBrains Mono 11px (`12` neutral, `1!` warn amber, `1` bad red as appropriate). Active row: `--accent-soft` bg, name colored `--accent` 600. Hover: `--panel-2` bg. Search input at top of pane.

**Main pane**:

- Top header: group display name (Space Grotesk 14px 600), breadcrumb path in JetBrains Mono 11px `--ink-3`, right-aligned "Save as view" ghost + "Open in Live Monitor" primary buttons.
- Status strip row: chips like Online 14 / Offline 1 / Degraded 1 / Recording 14 / Not recording 1.
- Camera table: thumbnail (44×28) · camera (name + id) · Live badge · Recording badge · Last seen (mono) · Audio glyph · row actions (Live / Playback ghost buttons).

### 4. Saved Views

Top sub-bar: filter pills (All views / Mine / Shared / Favorites / Contains issues), right-aligned `+ Save current view` primary.

Card grid, 3 columns, 18px gap, 20px padding. Each card has a 16:10 mosaic preview (4×4 cells, 3px gap, occasional `--bad`/`--accent` tinted cells for at-a-glance status), then a body block: view name (Space Grotesk 15px 600), meta line "Shared/Mine · 4×4 · 16 cams" in 12px `--ink-3`, status counts `14 online · 2 issues`, last-used time right-aligned, and "Open" + new-tab buttons.

### 5. Playback

Layout: main player + 340px right info aside + bottom timeline (full-width grid-column span).

**Player area** (`--bg` padding 16px, gap 16px between regions):

- Full-bleed video frame (`#1d2120`) with overlays.
- Top overlay (linear-gradient from top): back button, "PLAYBACK" tag pill (amber bg, JetBrains Mono 10px) + camera name + id, right-aligned "Today · 14:32:18 · Europe/Warsaw" in JetBrains Mono 12px.
- Below top overlay: a **selection chip** showing the active clip range `CLIP 14:28:00 → 14:35:24 · 7:24` with a small `Export Clip` primary button in-line.
- Bottom controls: a left cluster (prev event / -10s / play-large / +10s / next event / speed select) and a right cluster (snapshot / bookmark / mute / full-screen / red `● Return to Live`). Cluster backgrounds are `rgba(0,0,0,0.5)` with `backdrop-filter: blur(8px)`.

**Right info aside** (`--panel`, 340px, scrollable):

- Sections separated by 1px `--line`, each with a 11px uppercase JetBrains Mono header.
- Camera identity (name + breadcrumb + badge stack).
- Status (Stream, Recording, Audio, Last gap — KV rows).
- Recent events — same row format as ops sidebar.
- Same-group thumbnails — 4 sibling cameras with 48×32 preview + name/id + status; click switches the player.

**Timeline** (full-width, below player area):

- Controls row: preset chips (Last hour / Yesterday / Exact time) in JetBrains Mono uppercase, then `PLAYHEAD · Today 14:32:18 · Europe/Warsaw`, then right-aligned zoom chips (15m / 1h / 24h).
- Bar: 80px tall, `--bg` with `--line` border. Top 20px holds hour ticks. Below:
  - **Footage** track: olive `--good` 16px bar at top (opacity 0.7).
  - **Gap** track: red diagonal stripe in the same row where there's no footage.
  - **Motion** track: amber bar below (opacity 0.4).
  - **Event** ticks: bottom 14–18px vertical lines — motion (amber), bookmark (violet 18px), offline (red), generic (olive).
  - **Selection range**: amber-tinted overlay with hard 2px `--accent` left/right edges, draggable handles (10×28 amber blocks), label tab above (`14:28:00 → 14:35:24 · 7:24`).
  - **Playhead**: 2px white line with a small downward arrow at top, soft white shadow.

### 6. Events & Alerts

Sub-bar holds filter pills: `Today ×`, `Unacknowledged ×`, `All cameras`, `Motion`, `Offline`, `Bookmarks`, `+ Filter`. Right side: `Clear all` ghost.

Table columns: icon · Event (desc + type uppercase mono small) · Camera (name + id) · Group · Time (mono) · Status · row actions.

Row icons by type: motion (amber), offline (bad red), online (good olive), gap (amber alert), bookmark (violet).

Status cell: if acknowledged → `✓ Acknowledged` in good color + `username · time` JetBrains Mono 10px below. If new → `● NEW` in `--bad` 11px 600 with a 6×6 dot.

Clicking a row opens the event detail drawer.

### 7. Health

Sub-bar replaced by a strip of **6 stat cards** spanning full width, no gaps between them, separated by 1px `--line`:

- Visible 96 · Online 89 (good) · Offline 4 (bad, default active) · Degraded 3 (warn amber) · Not recording 3 (warn) · Recent gaps 2 (warn)

Each card 18px padding, big number (Space Grotesk 32px 700 -0.03em), label below (JetBrains Mono 10px uppercase 0.14em 600). Active card: 3px `--accent` top edge.

Below: a wide table with columns Camera · Group · Live · Recording · Last seen · Recent issue · row action. When a row is selected, the right side opens a 380px detail panel:

- Header with camera name + breadcrumb.
- 16:9 preview (or "NO SIGNAL" centered glyph when offline).
- A status callout block — left-bordered `--bad` (offline), `--warn` (recording fault), or `--good` (healthy), with full natural-language sentence describing the state and what is/isn't recording.
- KV facts (Live status, Recording status, Last seen, Last available footage, Group).
- Actions row: `Open live`, `Playback`, `Events`.

### 8. Clips & Snapshots (artifact library)

Sub-bar pills: `All cameras`, `Last 7 days ×`, `Clips only`, `Snapshots only`, `My exports`, `+ Filter`.

Table columns: type glyph (clip/snapshot) · Title · Camera (name + breadcrumb) · Range / Captured (mono) · Duration · Created by · When · Purpose · Status · download icon.

Status cell uses uppercase JetBrains Mono 11px 600: **READY** in good olive, **PREPARING…** in amber, **EXPIRED** in `--ink-3`. Only `READY` shows the download icon in the action column.

Click a row → right drawer with a 16:9 preview, KV facts (Camera, Group, Time range / Captured, Duration, Created by, Created at, Purpose, Timestamp overlay, Camera-name overlay, Audio included), and `Download` primary + `Open in playback` secondary actions in the footer.

### 9. Preferences

Personal preferences only — system administration lives elsewhere. Layout: max-width 680px, left-aligned, vertical stack of `--panel` sections.

Sections:

1. **Workspace** — Default landing screen (dropdown: Last opened view / Live Monitor / Favorite saved view: ___ / Specific group: ___), Theme (radio: Light / Dark / System — note the design here is dark; light is provided as a sibling variant).
2. **Alerts** — Alert sound (toggle), Browser desktop notifications (Enable button).
3. **Time & language** — Time format (radio: 24-hour / 12-hour), Timezone display (dropdown: Camera-site-local default / User-local), Language.

Row pattern: label column (title 14px 500 + description 12px `--ink-3`), control column. 14px vertical padding, 1px `--line` between rows.

### 10. Command Palette (Ctrl+K)

Center-top scrim modal (90px from top). 680px wide, `--panel`, 1px `--accent` border (the only place an `--accent` border is used on a non-active surface — it makes the palette unmistakable). 56px tall search input with the search glyph in `--accent`, 16px Space Grotesk text.

Results grouped: `CAMERAS · n`, `GROUPS · n`, `SAVED VIEWS · n`, `EVENTS · n`, `CLIPS · n`. Each row: 36×26 video thumbnail or category glyph · title 13px 500 · subtitle JetBrains Mono 11px. Selected row: 3px `--accent` left edge, `--panel-2` bg.

Footer: keyboard hints (`↑↓ Navigate`, `↵ Open`, `Esc Close`) and a result-count summary, all JetBrains Mono 10px.

---

## Interactions & Behavior

### Global

- **Ctrl+K** → open command palette.
- **Esc** → close any overlay (palette, modals, drawers, full-screen).
- **F** → toggle full-screen monitoring when in Live.
- **1 / 2 / 3 / 4** → cycle Live grid layouts (1 / 2×2 / 3×3 / 4×4) — when not in palette.

### Live Monitor

- Click a tile → open playback for that camera at the current live time (back arrow returns to grid).
- Hover a tile → reveal 5-button action column on the right edge.
- "Other layouts" button → centered popover with 6 layout diagrams.
- Filter pills are stateful; clicking re-filters the visible cameras and updates the page count footer.
- Layout buttons mutate the grid template; selection persists across visits (and is what `Save current view` snapshots).

### Playback

- Clicking the timeline moves the playhead.
- Dragging a selection handle (or click+drag on the timeline) creates a clip range; the selection chip overlay updates live.
- `Export Clip` opens the right drawer.
- Speed select cycles 1× / 2× / 4×.
- `Return to Live` swaps the player out of playback mode and returns to the matching tile in Live Monitor.

### Export drawer

- Lives on the right side, 440px, opens from a Playback clip selection or a row in Events/Clips.
- Shows a 16:9 PREVIEW frame with a `PREVIEW · NOT LIVE` mono ribbon.
- KV facts (Camera, Group, Timezone, Recording avail, Est. size).
- Range editors (Start / End text inputs in HH:MM:SS.mmm) with `-1s` / `+1s` / `Set start from playhead` nudges.
- Options: timestamp overlay, camera-name overlay, audio (disabled if camera has no audio).
- Purpose dropdown (required, with options like Incident review / Police request / Customer complaint / Internal investigation / Maintenance check / Other…).
- A warning ribbon appears if the selection spans a known recording gap, listing exactly which range will be a freeze frame.
- Footer: Cancel ghost · `Export clip` primary.
- Submitting opens a centered confirmation modal that restates the export (camera, range, duration, purpose, options, est. size, supervisor visibility note) before final commit.

### Alert toasts

- Bottom-right stack, 380px wide. Two states:
  - **Grouped** (5+ similar events in a short window): `--accent` left edge, header summarizes count + camera list, actions `View N events` + `Acknowledge all`.
  - **Single**: `--bad` left edge, header + secondary line, actions `Open playback` + `Acknowledge`.
- Toasts can be dismissed individually (× icon top-right). Acknowledged events also disappear from the ops sidebar's "new" highlight.

### Status semantics — what to communicate

The Live Monitor and Health screens are the operator's primary trust surface for "is my system actually working". The following must always be unambiguous:

- A camera that is **live but not recording**: the tile must show both states, and an inline "LIVE, NO RECORDING" issue strip is the design's chosen affordance. Do not let a non-recording camera look like a healthy one.
- A camera that is **offline**: tile has a `--bad` top edge, the feed area shows the "NO SIGNAL" affordance with last-seen time, and the ops sidebar lists it under Offline. Playback may still work for footage recorded before the outage — make this clear in the Health detail copy.
- A recording **gap**: shown as diagonal red stripes on the timeline footage track, plus a `gap` badge equivalent on tiles, plus a warning in the export drawer if a selection crosses one.

---

## State Management

State that is screen-local and not persisted:

- Selected camera (Playback)
- Playhead position
- Timeline zoom level (15m / 1h / 24h)
- Selection range
- Drawer / modal / popover open state
- Active filter pills
- Hover/focus states

State that **must persist across sessions** per operator:

- Default landing screen (preference)
- Theme (preference)
- Time format (preference)
- Timezone display mode (preference)
- Language (preference)
- Last opened group / view (for the "Last opened" landing option)
- Saved Views library (CRUD, mine vs shared visibility)
- Favorites (cameras flagged ★)
- Acknowledged events (per event, with operator id + timestamp)

State that **must be globally available** (system-state, not user-state):

- Per-camera live status (live / offline / degraded)
- Per-camera recording status (recording / not-recording / unknown / gap)
- Per-camera last-seen timestamp
- Recent events feed (cap ~50 for the ops sidebar; full history for the Events screen)
- Active alerts (unacknowledged set)

Data fetching expectations:

- Live grid: subscribe to per-camera status pushes; render placeholders/fallbacks if status is `unknown` for >2s.
- Timeline: range-fetch footage/motion/event markers for the visible window; refetch on zoom change.
- Health and Events: paginate the table; the stat cards at top should reflect live counts (subscribe, don't poll on a long interval).

---

## Assets

- Fonts: Space Grotesk and JetBrains Mono — both Open Font License, available from Google Fonts. Self-host in the application.
- Icons: see the icon list above. The prototype draws them inline as SVG; substitute with your icon library or extract the paths from `watchtower.html` (look for the `const I = { … }` block).
- No bitmap imagery is part of the design. The "fake video" placeholders in the prototype are CSS gradients and a sparse SVG schematic; in production the player surface is real video frames from the cameras.
- No raster brand assets. The "W" logomark is the letter set in JetBrains Mono 700 16px inside a 36px solid `--accent` square.

---

## Files

- `design/watchtower.html` — the full clickable design reference. Contains every screen, overlay, and state described above. Open it directly in a browser at 1440×900.
- The companion variants (`sentinel.html`, `atlas.html`) are not part of this handoff — Watchtower is the chosen direction.
- `README.md` — this document.
