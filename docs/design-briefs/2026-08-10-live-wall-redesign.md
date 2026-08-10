# Cilex Watchtower — "Live" screen: full UI specification + redesign brief

**Audience:** Claude Design (no codebase access — this document is the complete
source of truth; anything not written here does not exist for you).
**Date:** 2026-08-10.
**Mandate:** redesign the Live wall in the density language you built and we
shipped — Triage "Lanes", Groups "Wall", Playback "One Axis". Live is the
**default screen, the one a guard stares at for eight hours**, and the last
major surface still in the pre-density idiom.

---

## 1 · Product context

Native Qt/QML desktop VMS for security guards at a residential development.
Dark theme only. 1440×900 default, often 1200×900, sometimes 1920×1080 on the
booth PC. Mouse-first, keyboard-assisted. EN + RU (RU runs ~30 % longer, 3-form
plurals). Fleet today: **39 cameras**, heading to 80+. Cameras are spoken about
by their last IP octet (".160"), never by index.

**Honesty rules are product law.** Never invent data. Never render an unknown
state as healthy. Every empty state names the filter that produced it. No
silent no-op controls. Nothing is stamped before the server answers.

**What Live is for.** Three jobs, in this order of frequency:
1. **Ambient watch** — the wall is glanced at, not read. A guard must notice
   something wrong without reading any text.
2. **Triage a glance into a decision** — something moved, or a tile looks
   wrong; get to that camera, or to its recent past, in one or two actions.
3. **Compose the wall** — choose which cameras occupy which cells, at what
   grid, and save that as a named view for a shift.

---

## 2 · Design tokens (exact)

bg `#1a1816` · panel `#221f1c` · panel2 `#2a2722` · panel3 `#322e28` ·
line `#34302a` · line2 `#443f37` · ink `#f0ece4` · ink2 `#a89f90` ·
ink3 `#6e6657` · accent `#e8a13a` · accentSoft = accent @8 % · accentDim
`#5a3f15` · bad `#d96649` · badSoft @10 % · good `#8eb96b` · warn (amber, used
for Degraded / Not-rec counts) · info `#6f9bc4` · violet `#9a7bd0`.
Tile background is its own token (`tileBg`), darker than panel.

Fonts: **Space Grotesk** (labels, names, buttons), **JetBrains Mono** (all
numbers, times, IPs, octets, and ALL-CAPS micro-labels at 8–11 px with
letter-spacing 0.6–1.6). Square corners, hairline borders, no shadows. The only
rounded things in the whole app today are the picker's group chips (radius 13)
and the ack checkbox (radius 3).

---

## 3 · Screen anatomy (current, code-truth)

Five regions: **window title bar**, **top bar**, **left nav rail**, **the wall**
(toolbar + grid + footer), **right ops sidebar**.

### 3.0 · Window title bar (24 px, frameless window)

App-drawn, because the window is frameless: `WATCHTOWER · Live wall` on the
left, minimise / maximise / close on the right. Hidden in full-screen.

### 3.1 · Top bar (52 px) — global, not Live-specific

Left → right:

- **Brand block**: `CILEX VISION` (9 px mono, ink3) over `Watchtower` (18 px)
  followed by the **build hash** in mono (`79ae8583`). The hash is deliberate:
  the operator quotes it in bug reports.
- **Global search**, ~440 px: magnifier + placeholder *"Search cameras, groups,
  views, clips, events…"* + a `CTRL K` key-cap chip on the right edge. Clicking
  it or pressing `Ctrl K` opens the **command palette** (a separate overlay, not
  part of this redesign).
- **Three fleet-status pills** — `● ONLINE 39` (good), `● OFFLINE 0` (bad),
  `● NOT REC 0` (accent). Counted across the **whole roster**, not the current
  page or group. **Each is a toggle** that sets the Live wall's status filter
  (clicking the active one clears it). On this screen that is the fastest path
  from "something is wrong" to "show me which". **They do not navigate**,
  though — pressed from any other screen they silently change a filter the
  operator cannot see, which is a defect tracked in the wall-playback brief.
- **Watch chip** — `Check in` when nobody is on watch (ghost button, opens a
  roster picker); when someone is on watch it shows who and for how long. This
  is the shift check-in, part of a separate feature called The Watch.
- **Clock** — `11:05 · UTC+3`, mono. The offset label is explicit because
  footage timestamps are read against it.
- **Side-panel toggle** — icon button, tooltip *"Hide side panel" / "Show side
  panel"*, collapses the right ops sidebar.
- **Alerts bell** — with an unread dot; opens an alerts popover.
- **Avatar** — operator initials monogram (`AD`), amber block. Opens the user
  menu (preferences, sign out). **Preferences live here, not in the nav rail.**

### 3.2 · Left nav rail (~72 px, icon + label stack)

Five destinations, vertical, icon over an 9–10 px label:
**Live** (monitor icon) · **Groups** (layers) · **Views** (grid) ·
**Events** (bell, carries a red count badge — `100` in the screenshot) ·
**Health** (pulse). The active item is accent with a left accent bar.

### 3.3 · The wall toolbar (single row, ~38 px controls, responsive)

Left → right:

**(a) Layout segmented control** — four segments, each a tiny grid pictogram
plus a mono label: `2×2` · `3×3` · `4×4` · `Other ⌄`. The active segment is a
filled accent block with `bg`-coloured content. **`Other` is active whenever the
layout is not 1/4/9/16.**

`Other` opens a **380 px popover** titled `OTHER LAYOUTS` containing:
- A 3-column grid of six **preset pictograms**, 108×72 each, each drawing the
  actual cell net plus a caption: **1** (single) · **plus4** (one tall 2×3 hero
  left + 4 cells) · **plus6** (2×2 hero + 6) · **plus8** (3×3 hero + 8, in a 4×4
  net) · **center13** (2×2 hero *centred* in a 4×4 net + 13 around it) · **25**
  (5×5). These are "feature layouts" — one big cell plus satellites.
- A divider, then a **custom N×M picker**: a 10×10 grid of 15 px squares.
  Hovering lights the top-left block and the caption reads
  `4 × 3 · 12 cameras`; clicking commits that grid. Idle caption:
  `CUSTOM — HOVER TO CHOOSE A GRID`. **This is how a guard gets a 6×5 or a 2×8.**

**(b) Group scope dropdown** — the control labelled **"All cameras"** in the
screenshot. 220 px popover listing `All cameras` first, then **every camera
group defined on the backend** (`Inside`, `Лифты`, `Снаружи`, `New group`…).
The current one is accent. Below a divider sits **`↻ Sync from server`**, a
manual re-pull of groups + membership (there is also a 15 s auto-poll).
Selecting a group re-scopes the entire wall, the footer count, and paging.

There is a transient sixth scope, **`Selected (N)`**, produced when the operator
selects cameras on the Situation Map and sends them here. While it is active an
extra **`✕ Clear selection`** button appears beside the dropdown.

**(c) Filter pills** — four, each toggling on click, each showing an `✕` to
clear when active:
- **`☆ Favorites`** — only cameras the operator starred.
- **`Online`** — only cameras currently streaming. *(Active in the screenshot,
  hence the `✕`.)*
- **`Recent events`** — cameras with **any event in the last hour**. While this
  filter is on, the wall re-polls the event model so the set stays live.
- **`+ Filter`** — opens the wider filter set; when a status filter from that
  set is applied the pill **renames itself to `Issues`** and gains an `✕`.
  Underlying statuses: offline, degraded, recording, notrec, favorites, issues.

**(d) Spacer**, then the right-hand action cluster:

- **`⏱ Go back in time`** — leaves Live and opens **synchronized wall playback**:
  the same set of cameras, same grid, played back in lock-step from the
  recorded archive. *This is the single most important button on the screen and
  currently the most under-weighted — it is a ghost button identical in weight
  to "Save current view".*
- **`Save current view`** — persists the current grid + group + arrangement as a
  named View (retrievable from the Views section).
- **`Arrange`** — toggles **arrange mode** (see §3.5). Label flips to
  **`Done arranging`** and the button fills accent while active. A **`Reset`**
  button appears next to it *only while arranging and only if this group already
  has a saved arrangement*.
- **`Sort: <mode> ⌄`** — 160 px popover with five modes: **Live first**
  (default), **IP address**, **Stream order**, **Status first**, **Alphabetical**.
- **`⛶` Full-screen monitoring** — 38×38 icon button, tooltip
  *"Full-screen monitoring (F)"*. Hides title bar, top bar, nav rail, sidebar,
  toolbar and footer — leaving only the grid — and floats a single
  **`✕ Exit full-screen`** button top-right.

**Responsive collapse.** When the row is too narrow, `Go back in time`,
`Save current view`, `Arrange` (and `Reset`) collapse into a right-edge
**`»` overflow menu** (MS-Office style). Sort and full-screen always stay
inline. The overflow menu repeats those commands, adds `Full-screen`, then a
divider and a `SORT BY` section listing all five sort modes.

### 3.4 · The camera grid

Tiles are laid out either in a **fixed net** (for the feature layouts) or
**auto-fitted**: for plain grids the wall computes the largest aspect-correct
cell that fits the available box for the number of cameras on the page, so
tiles are never stretched. Unused cells in a partially-filled grid are painted
as deliberate empty tiles (`tileBg`), not as grid frame showing through.

**Each tile carries, layered over the video:**

*Top-left:* camera **name** (elided) and **IP**, on a dark scrim.

*Top-right — a row of status badges, right-aligned:*
- **`◌ SNAPSHOT`** — this tile is showing a periodically-refreshed still image,
  not a live decode (see the decode cap below). Present so a stale still is
  never mistaken for a live feed.
- **`MOTION`** — accent, with a **pulsing dot**. Means motion is being
  registered *right now* (5 s poll). Distinct from ARMED.
- **`LIVE · 3d`** — live state plus **how long it has held that state**.
- **`ARMED · 5m` / `REC · 13h` / `NOT REC` / `STALLED` / `GAP` / `OFF` /
  `REC ?`** — recording state plus age. `ARMED` means motion-triggered
  recording is armed; the suffix is the age of the last motion. A variant reads
  **`ARMED · silent 4d`** when armed but nothing has been recorded for days.
- **Audio ear** — a filled ear when audio is being recorded, a muted ear when
  the camera has a mic but audio is not recorded. **No ear at all when unknown**
  (honesty rule).

*Bottom-left, only when something is wrong — the inline issue strip:* a 22 px
black band with a 3 px colour spine and a mono caption —
**`⚠ RECORDING STALLED · since 09:12`** (bad) ·
**`⚠ LIVE, NO RECORDING`** (accent) ·
**`~ STREAM DEGRADED`** (warn) — followed by a **`VIEW ISSUE ›`** link on the
first two.

*Bottom-right, on hover — the action row:*
`▶ Open playback` · `⛶ Capture snapshot` · `☆ Add to / Remove from favorites` ·
`⧉ Open in new tab` · `⊟ Split into 1×1 cells` (only on a merged tile) ·
**`SD`/`HD` toggle** (per-tile stream quality; the wall defaults every tile to
the substream and this promotes one tile to the main stream on demand) ·
**autofocus chip** (only on lens-capable models).

*Interactions:*
- **Left-click a tile** → opens that camera's single-camera Live detail.
- **Right-click a tile** → opens the **camera picker for that cell** (§3.6).
  This works in normal mode as well as arrange mode, and is the fastest way to
  swap one camera without entering arrange mode at all.
- **Shift+drag across cells** → rubber-band **merge selection** (§3.5).
- **Ctrl+click** → add a cell to the selection, or select a merged tile whole.

**The live-decode cap.** At most **16 tiles decode video simultaneously**
(hardware limit; drops to **1** automatically under memory pressure and
restores with hysteresis). Every other tile shows a refreshing **snapshot**
instead. Slots are not handed out by position — an **ARMED camera outranks an
idle one**, so the cameras most likely to matter are the real-time ones. This is
why a 39-camera wall shows a mixture of live and `◌ SNAPSHOT` tiles, and the
design must keep that distinction legible.

### 3.5 · Arrange mode and cell merging

**Arrange** (`Arrange` button): every cell becomes a click target; clicking one
opens the camera picker for that slot. The chosen camera is written into a
**per-group saved arrangement**, so it survives restarts and re-sorts. While
arranging, the status filter is ignored so the whole group is available.
`Reset` clears that group's arrangement. `Esc` leaves arrange mode.

**Merging** (no mode required): **Shift+drag** a rectangle across cells; a
floating pill appears reading the resulting action, and **`M`** or **`Return`**
commits the merge. The camera the drag *started* on becomes the big cell. A
merged region can be selected with **Ctrl+click** and split again — the pill
flips to Split, and the tile's own hover row grows a `⊟` button. `Esc` cancels.
The footer carries the standing hint **`⇧ DRAG — MERGE CELLS`**, which brightens
to **`M — MERGE · ESC — CANCEL`** while a selection is live.

### 3.6 · The camera picker (the second screenshot)

A modal panel, titled **`Camera for cell 9`** (or **`Camera for the center
cell`** on a feature layout). Contents:

- **Group chips** across the top — `All cameras`, then every group
  (`Inside`, `New group`, `Лифты`, `Снаружи`). Rounded (radius 13), active chip
  filled accent.
- **`Search cameras…`** text field, and a **`Hide on-wall`** toggle that removes
  cameras already visible on the current page — so the operator sees only what
  they could *add*.
- A **grid of camera cards**, 9 per row: a snapshot thumbnail (falling back to a
  large `H` glyph placeholder while loading), a green online dot, an
  **`ON WALL`** badge for cameras already placed, the model name and the IP. The
  currently-assigned camera is ringed accent.
- **`Cancel`** bottom-right. Tapping the scrim also closes.

Thumbnails are loaded lazily and are kept alive across cells for the duration of
an arrange session, so the picker opens instantly on the second and subsequent
cells.

### 3.7 · Footer (40 px)

`All cameras · 39 cameras · Page 1 of 1` in mono ink3, the merge hint, then a
right-aligned **pagination control** (`‹` `1–39 of 39` `›`). Paging exists
because the layout defines a page capacity: a 4×4 on 39 cameras is three pages.

### 3.8 · Right ops sidebar (320 px)

Two stacked blocks; hidden in full-screen and collapsible from the top bar.

**`SITE STATUS`** — a 2×2 of big numbers, hairline-separated:
**Online** (good) · **Offline** (bad) · **Degraded** (warn) · **Not rec** (warn).
Label is 10 px mono uppercase, value 22 px bold. **These duplicate the top-bar
pills** — see §4.

**`LIVE EVENTS`** with a **`View all →`** link — a scrolling feed, newest first.
Each row: a **thumbnail still** from the event (or a muted camera glyph when no
clip exists), a **coloured type dot**, the **event label** (`Motion detected`),
a **relative time** (`now`, `4m`, `7h`, `2d`), an **acknowledge checkbox** (`✓`,
tooltip *"Acknowledge"*, server-persisted), the **camera IP** in mono and the
**camera name**, and a **red unread dot** on the right for un-acknowledged
events. Acknowledged rows dim their label to ink2 and drop both the checkbox and
the dot. Clicking a row opens the full Events screen.

### 3.9 · Keyboard map (complete)

| Key | Action |
|---|---|
| `1` `2` `3` `4` | layout 1 / 2×2 / 3×3 / 4×4 |
| `F` | toggle full-screen monitoring |
| `F11` | toggle full-screen (always, even where `F` is taken) |
| `Esc` | unwind **one** layer: command palette → arrange / picker / merge selection → full-screen |
| `Ctrl K` | command palette |
| `M` or `Return` | commit the merge selection |
| `⇧ drag` | rubber-band merge selection |
| `Ctrl click` | extend selection / select a merged tile |
| `Ctrl W` | close the active view tab |
| `Ctrl Tab` / `Ctrl ⇧ Tab` | next / previous view tab |
| right-click a tile | camera picker for that cell |

### 3.10 · States the screen must express honestly

- **Loading** — brief, between sign-in and the first roster response:
  *"Loading cameras…"*.
- **Empty roster** vs **empty filter** — these are different messages. An empty
  roster means no camera access has been provisioned in the backend; an empty
  filter names the filter (e.g. *"All cameras are recording — none stopped."*).
- **Offline tile**, **degraded tile**, **live-view-off tile**
  (`LIVE VIEW OFF` — an operator setting, not a fault), **recording-off tile**.
- **Snapshot tile** — explicitly badged, never passed off as live.
- **Unknown** — a camera whose recording state has not been reported reads
  `REC ?`, never green.

---

## 4 · The problems, ranked (what the redesign should solve)

1. **The same four numbers are on screen twice.** The top bar's `ONLINE 39 /
   OFFLINE 0 / NOT REC 0` pills and the sidebar's `SITE STATUS` 2×2 are the same
   fleet counts in two places, 320 px apart, in two different visual languages —
   and the sidebar version costs a 64 px-tall block plus a header. One of them
   should go, or they should merge into one thing that is unambiguously the
   fleet's health.
2. **Ambient watch is not designed for.** A guard is not reading the wall; they
   are waiting to notice. Right now "something is wrong" is expressed as a small
   text badge in the corner of one tile among sixteen, in the same visual weight
   as the five badges that mean everything is fine. **Nothing about a healthy
   tile should draw the eye, and a broken one should be impossible to miss
   without reading.**
3. **Badge inflation.** A healthy tile can carry `SNAPSHOT`, `LIVE · 3d`,
   `ARMED · 5m` and an audio ear simultaneously — four chips, none of which is
   news. The `· 3d` age suffix in particular is precise trivia in the most
   valuable pixels on the screen.
4. **`Go back in time` is the screen's most valuable action and looks like the
   least.** It leaves Live entirely for synchronized playback, yet it is a ghost
   button of the same weight as `Save current view`.
5. **Discovery is bad for the two best gestures.** Right-click-to-swap and
   Shift-drag-to-merge are the fastest things on the screen, and are advertised
   only by a 9 px footer hint (merge) or not at all (right-click).
6. **Layout, group, filters and sort are four separate mental models** occupying
   one row — "what net", "which cameras", "which subset", "in what order" — with
   no visual grouping that says so.
7. **Paging on an ambient screen is questionable.** A guard watching 39 cameras
   on a 4×4 sees 16 and must remember that 23 exist on two other pages the
   screen never shows them.
8. **The live/snapshot distinction is load-bearing and under-designed.** Which
   16 of 39 tiles are real-time is genuinely important and is currently one
   small `◌ SNAPSHOT` chip.
9. **RU at 1200 px is tight.** `Full-screen monitoring`, `Save current view` and
   `Recent events` all grow ~30 %, which is what forces the `»` overflow.

---

## 5 · Non-negotiables

- **The decode cap is physics, not a preference.** At most 16 live decodes
  (1 under memory pressure). A design that implies 39 simultaneous live streams
  is writing a cheque the hardware cannot cash. Whatever replaces `◌ SNAPSHOT`
  must still tell the truth.
- **Motion-triggered recording means most cameras are not recording most of the
  time.** `ARMED` is the healthy resting state for the majority of the fleet;
  do not design it as a warning.
- **Every existing capability must survive**: all layout presets and the custom
  N×M picker, group scoping, all four filter pills, all five sort modes, save
  view, arrange, merge/split, per-tile SD/HD, favourites, new-tab, snapshot,
  autofocus, and the full keyboard map in §3.9.
- Honesty rules from §1 and the states in §3.10. Unknown is never green.
- Dark theme, §2 tokens, square corners, hairline borders, no shadows.
- EN + RU with 3-form plurals; works at 1440×900, 1200×900 and 1920×1080.
- QML primitives only (Rectangle / Text / MouseArea / ListView / Repeater — no
  Popup for large panels, no web views).
- The grid must stay a **positioner-based** layout, not a `GridLayout`
  (a Qt layout bug crashes on minimise/restore; we hit it and it is why the
  current code uses explicit cell maths).

---

## 6 · Deliverables

Same package as the last four handoffs: a spec `.md` (sizes, tokens, states,
interactions, edge cases — including: 39 cameras on a 4×4; one camera; a wall
where 6 are offline and 3 stalled; the `Selected (N)` scope; arrange mode with a
saved arrangement; a merged 2×2 hero inside a 4×4; RU at 1200 px; full-screen
with 25 tiles), a self-contained HTML prototype with a tweaks panel (grid size,
camera count, EN/RU, window width, fault mix, live-vs-snapshot ratio), and a
README with your variant decision made plus the implementation prompt for the
Watchtower builder, traps included.

**Success test:** a guard glancing at the wall for two seconds, from two metres
away, can tell whether anything needs them — without reading a word. And when
something does, they reach that camera's recorded past in one action.
