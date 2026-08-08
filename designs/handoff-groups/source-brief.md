# Cilex Watchtower — "Groups" screen: full UI specification + redesign brief

**Audience:** Claude Design (no codebase access — this document is the complete
source of truth; anything not written here does not exist for you).
**Date:** 2026-08-07.
**Mandate:** redesign Groups in the density language you built for the Triage
Queue (variant B "Lanes", shipped verbatim) — Groups is the last screen still
in the old spacious idiom, and it is the screen where an operator does the
one job the whole product depends on: deciding what each camera IS.

Your shipped prior work applies and is live product: gapless hairline cells,
26 px sticky lane headers, 44 px rows, shared-hairline segmented controls,
measured-fit strips, computed (never converging) layout math. Reuse it. Do
not redesign the shared chrome above the screen (52 px top bar → 30 px tab
strip); Groups has no sub-nav of its own.

## 1 · Product context

Native Qt/QML desktop VMS for security guards and their supervisors; dark
theme only; 1440×900 default, often 1200×900; mouse-first; every label ships
EN + RU (RU ~30% longer, counts need 3 plural forms). Fleet today: **39
cameras across 3 groups** (Inside 22, Лифты 3, Снаружи 14), heading to 80+.
Cameras are spoken about by IP octet (".146"); their full names are long and
nearly identical ("HiWatch DS-I202(E) (192.168.1.146)" — 34 chars, same
prefix on 30+ of them).

Honesty rules are product law here: never invent data, never render unknown
as healthy, every empty state names its filter, no silent no-op controls.

## 2 · Design tokens (exact)

bg `#1a1816` · panel `#221f1c` · panel2 `#2a2722` · panel3 `#322e28` ·
line `#34302a` · line2 `#443f37` · ink `#f0ece4` · ink2 `#a89f90` ·
ink3 `#6e6657` · accent `#e8a13a` · accentSoft = accent @8% · accentDim
`#5a3f15` · bad `#d96649` · badSoft @10% · good `#8eb96b` · info `#6f9bc4`.
Fonts: **Space Grotesk** (labels/names), **JetBrains Mono** (numbers, IPs,
octets, ALL-CAPS micro-labels 9–11 px, letter-spacing 1.2–1.6). Square
corners everywhere, hairline borders, no shadows, hover = fill swap.

## 3 · What Groups IS

The **organizational** screen. Three jobs, all persisted to the backend and
visible to every other screen instantly:

1. **Name cameras.** The vendor name is meaningless to a guard; the operator
   renames "HiWatch DS-I202(E) (192.168.1.146)" to "6th floor lift lobby".
   Names are user-owned — the product never invents one.
2. **Assign cameras to groups.** Groups drive the Live wall's filter, the
   Events section's scope strip, and the map's zones. A camera in the wrong
   group is invisible in the right place.
3. **See what you have** — one wall of every camera's live thumbnail, which
   in practice is also how an operator sanity-checks the fleet.

Permissions: create/rename/delete/assign are **admin and operator only**
(backend RBAC). Viewers and engineers see the same screen read-only — the
"New group" row, the "Delete group" button and the group-chip caret all
disappear rather than appearing disabled. A redesign must keep a coherent
read-only presentation.

## 4 · Current anatomy, pixel-exact (from code)

Two panes, no header of its own.

### 4a · LEFT — group list (fixed **320 px**, 1 px right hairline)

- **Section label** "CAMERA GROUPS", mono 10 px ink3, caps, letter-spacing
  1.6, at 16 px insets (top 16, bottom 8).
- **"All cameras" row** — 40 px tall: monitor icon 14 px, name (sans 13 px),
  right-aligned total (mono 11 px ink3). Selected = accentSoft fill + 3 px
  accent bar on the left edge + accent text + DemiBold. Hover = panel2.
  Below it a 1 px full-width divider.
- **Group rows**, same 40 px anatomy with a "layers" icon, one per group,
  showing the group's camera count. This list scrolls.
- **"+ New group" row** (44 px, top hairline, admin/operator only): amber
  "+", "New group" in ink2. Clicking creates a group **immediately, named
  literally "New group"**, then selects it — there is no dialog and no name
  prompt (the name is then edited in the right pane's header). This is a
  known rough edge; see §5.
- The list has **no search, no sort, no drag-and-drop, no reordering**, and
  no indication of which groups are empty.

### 4b · RIGHT — the selected group's cameras

- **Header (58 px, bottom hairline, 20 px insets):** the group name as an
  **inline-editable text field** (sans 16 px DemiBold; transparent until
  focused, then panel fill + accent border; commits on Enter/blur). For
  "All cameras" it is static text. Then "N cameras" (mono 11 ink3), a
  flexible gap, and two ghost buttons (32 px, 1 px line2 border, hover fills
  panel and turns the border accent): **"Open in Live Monitor"** (navigates
  to the Live wall filtered to this group) and **"Delete group"** (bad-red,
  visible only for real groups and only for admin/operator; **fires
  immediately, no confirmation** — see §5).
- **Hint strip (30 px, bottom hairline):** "Click a thumbnail to open it live
  · click the name to rename · use the group chip to move it into a group"
  (sans 11 ink3). A permanent instruction line, always visible, never
  dismissible.
- **Camera grid:** GridView, 8 px margins, columns = floor(width / 250) so
  cell width ≈ 250–300 px at 1440; cell height = 16:9 thumbnail + **64 px**
  of footer. Card = 5 px inset, panel2 fill, 1 px line2 border. Contents:
  - **Live thumbnail (16:9)** — the camera's current frame, refreshed on a
    poll (this is a *live* snapshot, not an event still), with the IP octet
    badge bottom-left (".146") and a small green/red online dot top-right.
    Click opens that camera in the focused Live view.
  - **Footer row 1:** recording-status badge + camera name. The name is
    click-to-rename in place (an inline text field with an accent border;
    Enter commits, Esc cancels).
  - **Footer row 2:** IP in mono 10 ink3, then a right-aligned **group chip**
    (20 px tall, bordered, showing the current group name or "Ungrouped"
    with a caret) which opens a **200 px popup list** of every group +
    "Ungrouped"; picking one reassigns the camera immediately.
- **Empty state** when a group has no cameras: layers icon, "No cameras in
  this group", "Assign cameras to this group from another group's list."

### 4c · The recording-status badge (shared with every other screen)

Small pill, mono 10 px, dot + label. States you must preserve exactly:
`REC` (red, pulsing dot), `STALLED` (red), `NOT REC` / `GAP` (amber, hollow
ring), `OFF` (grey), `REC ?` (unknown), and the ARMED family, which is where
the honesty lives:

| label | color | meaning |
|---|---|---|
| `ARMED` | ink2 | motion-armed, healthy |
| `ARMED · 4m` | ink2 | last motion event 4 minutes ago |
| `ARMED · NOT READY` | **bad** | backend says this camera's detector cannot fire |
| `ARMED · NOT RECORDING` | **bad** | detecting motion but its footage is not being written (added today: 12 of 23 cameras were in this state) |
| `ARMED · silent 2d` / `no motion ever` | warn | armed, nothing recorded for >24 h |

A redesign may restyle the badge but must keep all states distinguishable
at a glance, and must not let any fault state read as normal.

## 5 · The problems, ranked (what the redesign must solve)

1. **Density and the 250 px cell.** 39 cameras at ~250×205 px = about 15
   visible; 80 cameras will be four screens of scrolling. Meanwhile the
   footer spends two full rows on text that repeats ("HiWatch DS-I202(E)
   (192.168.1.1xx)" plus the IP again below it). The lanes lesson applies
   directly: say the model once, not 39 times.
2. **The thumbnail is doing two contradictory jobs** — it is the only visual
   ID of a camera (helpful) *and* a live video wall (expensive, and Groups
   is not where you watch). Decide what it is for; a smaller still, a
   hover-to-enlarge, or a lazy row-of-thumbs are all fair answers.
3. **Group assignment is one camera at a time.** Moving 14 cameras into
   "Снаружи" is 14 chip-clicks through a 200 px popup. There is no
   multi-select, no drag-to-group, no "select all in this filter". This is
   the single biggest workflow cost on the screen.
4. **Destructive actions have no confirmation.** "Delete group" fires on
   click. Nothing says how many cameras it will orphan.
5. **"New group" creates a group named "New group" with no prompt** — and
   creating two in a row produces two identically-named groups.
6. **No search or filter anywhere.** With 80 cameras you cannot find ".146"
   except by eye; there is no way to see "ungrouped cameras only", which is
   the most common real question when new cameras are provisioned.
7. **The hint strip is permanent chrome for information a first-time user
   needs once.** 30 px spent forever.
8. **Nothing shows a group's health.** A group's row shows only a count; the
   operator cannot see that 5 of Inside's 22 cameras are not recording. The
   data exists — every camera carries its badge state.
9. **No empty-group affordance** in the left list, and no indication of how
   many cameras are ungrouped (today: unknown at a glance).

## 6 · Contract any redesign must respect

- Renaming and grouping are **immediate server writes** with no undo — the
  design should make accidental edits hard rather than promising an undo we
  do not have. (An "undo" affordance would require a backend change; flag it
  if you want it rather than assuming it.)
- **Read-only mode** must be coherent for viewers/engineers (controls absent,
  not disabled-looking).
- **Thumbnails are live camera frames** fetched per visible tile; a design
  that puts 80 on screen must degrade gracefully (lazy/viewport-only) —
  Groups is not allowed to become a second video wall.
- Camera identity: **octet is the spoken name**, full vendor name is the
  formal one, the operator-chosen name (when set) is what should dominate.
- Groups are backend entities shared with Live/Events/Map; renaming one
  changes those screens' labels too.
- EN + RU; 3-form plurals for counts; tokens from §2; square corners; QML
  primitives only (Rectangle/Text/MouseArea/ListView/GridView — no Popup
  for large panels, no web); 1440×900 and 1200×900.

## 7 · Deliverables

Same package as your last two handoffs: (1) spec .md with exact sizes,
tokens, states, interactions and edge cases (0 groups; 1 group; 12 groups;
80 cameras; all ungrouped; a group with every camera faulty; RU at 1200 px;
read-only role), (2) a self-contained HTML prototype with a tweaks panel
(density, EN/RU, window width, camera count, role), (3) a README with your
variant decision made and the implementation prompt for the Watchtower
builder agent, traps included.

Success test: an operator who has just had 20 new cameras provisioned can
find the ungrouped ones, name them, and file them into the right groups in
a couple of minutes — and can see, without leaving the screen, which of
their cameras are not actually recording.
