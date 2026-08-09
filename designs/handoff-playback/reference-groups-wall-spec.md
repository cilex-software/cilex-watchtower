# Groups — density redesign · "Wall"

**Reply to** `docs/design-briefs/2026-08-07-groups-redesign.md`
**Date:** 2026-08-07 · **Status:** ready to build
**Prototype:** `groups-redesign-prototype.html` — 39/59/80 cameras, live tweaks for **per-row (4 / 6)**, thumbnails, **role**, fleet size, EN/RU, 1440/1200. Where this document and the prototype disagree, **this document wins.**

**Language:** continues the shipped Triage "Lanes" and the queued Verify "Strips". Gapless hairline cells, computed (never converging) layout math, in-place arming for destructive actions, 34px rows, mono for every number. Nothing above the tab strip is touched; Groups still has no sub-nav.

---

## 0 · The decision

**Groups becomes a gapless mosaic.**

Big tiles, 4 or 6 per row, **butting edge to edge with no gutter, no card inset and no border between frames** — a wall of video, the way a VMS wall is meant to look. Every piece of chrome the old card spent 64px of footer on now lives **on** the frame as an overlay.

That is the whole trick, and it follows from the constraint: *if there are no gaps between videos, the metadata cannot live in a footer — because the footer would **be** the gap.* So the octet, the name and the status move onto the picture, and the picture goes back to being as large as the pane allows.

| brief problem | how the mosaic answers it |
|---|---|
| **1 · density, and the repeated 34-char name** | Zero gutter, zero card chrome, zero footer. The model name appears **only when there is no operator name** — it is the fallback, not the label, and the IP is never repeated beside it. **41 cameras on screen at 6-per-row vs ~15.** |
| **2 · thumbnail doing two jobs** | Split explicitly: the tile is the *identity*, opening a camera (§2.7) is the *look*, and Live Monitor is the *watch*. No hover-triggered panel anywhere. |
| **3 · assignment one at a time** | Click / shift-click / ⌘-click / ⌘A select; then **one click in the selection bar**, or **drag the selection onto a group row**. 14 cameras into Снаружи: one drag. |
| **4 · destructive with no confirmation** | `Delete group` **arms in place** and states the blast radius: `Delete "Inside"? 22 cameras become ungrouped.` |
| **5 · "New group" named "New group"** | The row becomes an **inline field**; the group is created on commit, with the name the operator typed. No name, no group. |
| **6 · no search or filter** | Camera search (octet / IP / name / model) + three facets: `All` · **`Unnamed`** · **`Faults`**. Group search in the left pane. |
| **7 · permanent 30px hint strip** | Deleted. Its 30px becomes the filter bar — same height, now load-bearing. |
| **8 · no group health** | Every group row carries a **34×3px stacked health bar** (bad / warn / ok) beside its count. |
| **9 · no empty-group or ungrouped affordance** | `EMPTY` marker on zero-count group rows; a pinned **`Ungrouped N`** row above the group list, present only when the count is non-zero. |

### Density arithmetic, 1440×900

```
chrome above the panes:  30 os + 52 top bar + 30 tab strip = 112
panes height:            900 − 112 = 788
right pane header:       34 group header + 30 filter bar = 64
wall height:             788 − 64 = 724
pane width:              1440 − 64 rail − 264 left − 1 hairline = 1107

6 per row:  tile 184×104   rows 724/104 = 6.9   →  41 cameras   (2.7× today)
4 per row:  tile 276×155   rows 724/155 = 4.7   →  18 cameras   (1.2× today)
```

**6-per-row is the shipping default** at 2.7×, comfortably past the 2.5× bar — and the tile is still 184px wide, i.e. only slightly smaller than the *entire old card* while showing nearly three times as many cameras.

**4-per-row is the identify gear** — 276px tiles, larger than anything on the screen today, for a freshly provisioned batch nobody has seen yet. At 1.2× it does not clear the density bar and is not meant to: it is the deliberate slow gear, chosen when the picture is the job.

At 1200×900 the columns hold and the tiles shrink (6-per-row → 145×82), which *raises* the count to 52. The narrow window is denser, not poorer.

### What this gives up

A dedicated text column for the name. At 6-per-row a long operator name ellipsizes in a 184px scrim, and the vendor fallback ellipsizes hard (`HiWatch DS-I2…`). That is the honest cost of edge-to-edge video, and it is mitigated three ways: the octet — the name operators actually speak — is always fully visible; the hover magnifier shows the full name in its caption; and 4-per-row exists for when names are what you are reading.

---

## 1 · Why not the alternatives

**Keep the gutters, shrink the cards.** A 5px inset plus a 1px border plus a 64px footer is ~40% of a small card's area spent on not-video. At 6-per-row that overhead would cost the tile a third of its width for information that fits on the frame.

**A dense text roster.** It wins on pure density (42 rows) and on name legibility, and it is the right shape for a spreadsheet — but Groups is where an operator *recognises* cameras, and a 44px thumbnail is too small to recognise a scene. The mosaic gets the same density with the picture intact, which is the better trade for this screen.

**A footer strip under each tile, gutters only between rows.** Half-gapless. It reintroduces exactly the repeated-text band the brief ranked #1, and horizontal-only seams look like a bug rather than a decision.

## 2 · Anatomy

### 2.1 · Left pane — group list, **264px** (was 320)

56px narrower, because nothing in it is wide: a name, a health bar, a count.

**a. Group search** — 30px, `panel` fill, bottom hairline. `⌕` 11px `ink3`, mono 11px input, placeholder `Find a group…` (sans 11px `ink3`). Filters the group list by substring. Present for every role — reading is not a privilege.

**b. Rows** — 34px, bottom hairline, in this fixed order:

1. **`All cameras`** — always first, solid 12px icon, total count.
2. **`Ungrouped N`** — dashed icon, rendered **only when N > 0**. This is the provisioning answer: 20 new cameras land here and the row appears by itself.
3. **`CAMERA GROUPS`** divider — mono 8.5px caps `ink3`, letter-spacing 1.4, with the group count right-aligned.
4. **The groups**, in the fleet's configured order — never sorted by count. (Reordering by traffic is the Triage failure-mode-3 lesson.)

Row contents: 12px icon · name (sans 12px `ink2`, ellipsized) · `EMPTY` marker · **health bar** · count (mono 10px `ink3`).

States: idle · hover `panel2` · **selected** `accentSoft` + 3px `accent` inset left bar + `accent` DemiBold name and count · **drop target** `accentSoft` + 1px `accent` inset ring.

**c. Health bar** — 34×3px, `panel3` track, three segments in fixed order, each ≥2px when non-zero:

| segment | colour | states |
|---|---|---|
| bad | `bad` | `NOT REC` · `STALLED` · `ARMED · NOT READY` |
| warn | `accent` | `GAP` · `REC ?` · `OFF` · `silent 2d` · `no motion ever` |
| ok | `good` | `REC` + armed and healthy |

Three pixels of height answers problem 8 completely: *5 of Inside's 22 are not recording* is now visible without selecting Inside. Tooltip gives the numbers.

**d. `+ New group`** — 34px, top hairline `line2`, `panel` fill, **admin/operator only**. Click swaps the row into an inline field (`Group name…`, `↵` hint, `✕` cancel). **Enter or blur with text creates the group and selects it; Escape or empty commits nothing.** No dialog, no placeholder-named group, and two in a row cannot collide because the operator typed both names.

### 2.1b · The empty pane — four layouts

At three groups the left pane spends **102px of its 788** and leaves ~600px of black. The list is not the problem; treating a list as a whole column is. Four layouts are built (`Group pane` tweak), and they answer it on different axes.

| layout | what fills the space | cameras on screen | extra thumbnail fetches |
|---|---|---|---|
| `rows` (today) | nothing — ~600px of black | 18 @4-per-row | 0 |
| `cards` | each group's own cameras | 18 | **+78 small frames** |
| **`console` — recommended** | the fleet's exceptions **and the queue of cameras behind them** | 18 | 0 |
| `bar` | *the pane is deleted* | 18 at **343px** (was 277) | 0 |

#### A · `cards` — groups become previews

Group rows grow to `flex: 1` and divide the column exactly (4 groups × 181px = 722px, **zero remainder at any group count**). The height each one gains fills with a wrapped strip of **35×20 thumbnails of that group's own cameras**, each carrying the same 2px fault bar as the wall. Below ~12 groups the cards hit a 76px floor and the column scrolls, degrading gracefully into `rows`.

It answers "what is actually in Снаружи?" before you select it, which helps when you are dragging a selection into a group you cannot see.

**But it costs thumbnail budget** — 78 additional frames on a screen whose §3 exists to stop Groups becoming a second video wall. Only ship it if the pane strip reuses frames already fetched for the wall and caps at ~12 per group. Stated plainly because it is the one variant whose cost is invisible in a screenshot.

#### B · `console` — the space carries the exceptions · **recommended**

Rows stay at 34px and stop stretching. Everything below is a three-part panel:

1. **`NEEDS ATTENTION` summary** — one 32px row per exception class: `13 not recording` · `23 still unnamed` · `0 ungrouped` · `2 offline` · `2 recording state unknown`, each **one click from being the filter that shows them**. All five resolve from the §2.5 predicates, so they reconcile with the wall's rings and the header's counts.
2. **Fleet bar** — 6px stacked bad/warn/ok with `13 FAULT · 12 WARN · 14 OK · 36% HEALTHY`.
3. **`WORK QUEUE` — the growable child.** The actual cameras behind those counts, worst first (not recording → detector not ready → offline → unknown → unnamed), as 26px rows of octet + name + reason with a severity dot. Clicking one **opens that camera in the modal**, so the panel is not a readout but a queue you work through. It takes `flex: 1` and scrolls when it overflows.

**Part 3 is what makes this layout honest.** An earlier draft had only parts 1 and 2: the container took `flex: 1` and stretched to absorb the remainder, but every child inside it was fixed-height, so 336px of the pane — 43% of its height — landed as trailing whitespace in `panel` instead of `bg`. **Flexing a container without making one child flexible does not remove a void; it relocates it and repaints it a lighter colour.** The queue is the child that grows, and it is long precisely when the fleet has problems — which is when the space is worth spending.

When the fleet is clean the queue renders a centred `Nothing needs attention. Every camera is named, grouped and recording.` that fills the same space. That is a legitimately empty state — earned, stated, and reached only when there is genuinely no work.

This is the recommendation because the space stops being decoration and starts answering the brief's own success test — *see, without leaving the screen, which of your cameras are not actually recording* — and it costs nothing to fetch. It also puts the naming backlog (`23 still unnamed`) permanently in view, which is the other half of the provisioning story.

A zero row renders in `ink3` with no arrow: an exception that does not exist is worth stating, but is not a destination.

#### C · `bar` — delete the pane

The most space-efficient answer available: there is no column, so none of it can be empty. Groups become a **32px horizontal chip strip above the wall** — `All cameras 39` · `Ungrouped` · separator · one chip per group, each with its count and a 22×3px health bar — reusing the shipped Triage octet-bar language. Chips are drop targets exactly as the rows are.

The wall goes **1107 → 1371px** and tiles **277 → 343px, 24% wider**, which is the largest single density gain available anywhere in this redesign.

Costs: the group list must live on one line (it scrolls horizontally past ~10 groups, and scrolling to reach a group is worse than a vertical list); the group search field is gone; and camera search moves up beside the chips. Right answer if maximum video is the priority and the fleet has few groups.

### 2.2 · Right pane header — 34px (was 58)

Gapless cells: group name (sans 14px DemiBold, **double-click to rename** for real groups, admin/operator only) · count (mono 10px `ink3`) · flexible spacer · `▤ Open in Live Monitor` · `Delete group`.

**Rename is double-click, not single.** Renaming is an immediate server write with no undo and it changes the label on Live, Events and the map; a single click is how you select a row, not how you start an unrevertable edit. Enter commits, Escape cancels, blur commits. Empty is refused silently (the old name stands) — a group with no name is not a thing the operator can want.

`Delete group` **arms in place** — the cell is replaced, at the same coordinates, by `Delete "Inside"? 22 cameras become ungrouped.` (mono 10px `bad` on `#2c211d`) + `✓` + `✕`. Escape cancels. Empty groups get the shorter `Delete "Inside"?`. No dialog, no scrim, no travel, and **the blast radius is in the sentence** — the one thing the current button never said.

### 2.3 · Filter bar — 30px (replaces the hint strip)

`⌕ Octet or name…` (196px, mono 11px) ‖ `All N` · `Unnamed N` · `Faults N` ‖ spacer ‖ `N not recording` (`bad`) · `N of M`.

- **Facets** are counted against the **current group scope**, live. Active facet = `accentSoft` + 2px `accent` inset underline; the `Faults` facet arms in `bad` instead of `accent`, because it is a fault filter and should not read like a preference.
- **Search** matches octet prefix, full IP substring, operator name, and model — so `.146`, `146`, `192.168.1.146`, `lift` and `I259` all find things.
- **`N not recording`** is the success test's second half, permanently on screen in every scope.

The hint strip's content moves into the harness note and a first-run tooltip. 30px of permanent chrome for a sentence read once is exactly the trade the brief flagged.

### 2.4 · Camera tile — gapless, 16:9

`grid-gap: 0`. **No card inset, no border between frames, no footer.**

**Columns are `1fr`, never `floor(paneWidth / cols)`.** Flooring discards `paneWidth % cols` pixels and leaves a lighter strip of page background down the right edge — a visible seam on a wall whose entire premise is that there are none, and the one place a rounding error shows. Let the layout engine distribute the remainder (`1fr` columns in CSS, `Layout.fillWidth` / an explicit +1px to the first `paneWidth % cols` tiles in QML). Row height is `round(paneWidth / cols × 9/16)` — one shared value, so every tile in a row is exactly as tall as its neighbours.

**The scroll gutter counts too.** The pane's 3px scrollbar sits between the wall and the pane edge; with a default (lighter) track it reads as exactly the seam this design exists to remove. Give the track the tile colour `#141312` so the wall appears to run to the edge.

| | 6 per row | 4 per row |
|---|---|---|
| tile @1440 | 184×104 | 276×155 |
| scrim height | 20px | 24px |
| octet / name | mono 11px / sans 11px | mono 12px / sans 12px |

**Every state is an INSET ring**, so no state ever changes the layout or opens a gap:

| state | ring |
|---|---|
| resting | 1px black @55% inset — a shadow seam, not a gutter: it separates neighbouring frames without spending a pixel of space |
| **fault** (`NOT REC` · `STALLED` · `NOT READY`) | **2px `bad`** inset |
| warn (`GAP` · `REC ?` · `OFF` · silent · no-motion) | 1px `accent` @55% inset |
| **selected** | **2px `accent`** inset + the scrim shifts to an amber gradient |
| dragging | 45% opacity |

**The fault ring is the honesty mechanism at wall scale.** Across 41 tiles a red-ringed cell is unmissable, which is what makes "see which cameras are not actually recording" true without reading a single word.

**Overlays, painted on the frame:**

**a. Bottom scrim** — the only permanent chrome. A transparent-to-black-86% gradient, so it never hides a hard edge of the image:
- **octet** — mono 11/12px **white** DemiBold, always fully visible, never truncated. It is the name operators speak.
- **name** — sans 11/12px white @90%, ellipsized. When the operator has not named the camera: the **model in white @50%** plus an `UNNAMED` chip (mono 7.5px `accent`). The IP never appears here — it lives in the magnifier caption and the search index.
- `SAVED` flash after a rename.

**b. Top row** — checkbox (14px, appears on hover or when selected; **absent entirely for read-only roles**), then the **status marker**: a mono 7.5px caps pill, `bad`-filled for faults, `accent`-outlined for warnings, and **absent for a healthy camera**. A healthy tile is clean video; only exceptions get ink. Far right: the 5px online dot.

**c. Hover row** (above the scrim) — the **full badge text** (`ARMED · NOT RECORDING`) and the **group chip**. These are the two things that need words, and they are only needed on the tile you are pointing at.

**Double-click the scrim** to rename in place. Enter or blur commits, Escape cancels.

### 2.5 · Status — two axes, one predicate

The camera data carries **two independent faults**, and the screen must never blur them into one number:

| axis | states | question it answers |
|---|---|---|
| **recording** | `notrec` · `stalled` | *is footage being written?* — the brief's success test |
| **detector** | `notready` | *can motion fire at all?* |

Three derived predicates, and **every count on the screen must come from one of them** — never from an ad-hoc filter written at the call site:

```
REC_BROKEN(c) = rec is notrec or stalled          → the "N not recording" readout AND the top-bar pill
DET_BROKEN(c) = motion is notready
FAULT(c)      = REC_BROKEN(c) or DET_BROKEN(c)    → the 2px bad ring AND the Faults facet
UNKNOWN(c)    = rec is unknown                    → never counted as either
```

Two rules follow, and both were violated by an earlier draft of this spec:

1. **The ring and the facet share the single `FAULT` predicate.** If the facet is even slightly broader, a guard who filters to `Faults` gets tiles that do not wear the fault ring — two classifications wearing the same word, in the same pane.
2. **`REC ?` is never asserted as a fault.** Counting unknown as broken is the exact mirror of the brief's "never render unknown as healthy" rule; both are lies, in opposite directions. It gets a warn ring, its own `REC ?` marker, and its own small `N unknown` readout — surfaced, never asserted.

**Marker precedence puts recording first.** A camera that is both not-recording *and* detector-faulted shows `NOT REC`, not `NOT READY` — otherwise the wall's red-`NOT REC` tiles undercount the header's number and the two contradict each other. The compound state is not lost: the hover badge reads `ARMED · NOT RECORDING + NOT READY`.

The badge appears in the tile`s **hover row** as mono 8.5px + 4px dot; its short form is the always-visible **status marker** in the top row. Fixed precedence, so a fault can never be masked by a lesser state:

| condition | render | colour |
|---|---|---|
| `rec: off` | `OFF` + solid dot | `ink3` |
| `motion: notready` | **`ARMED · NOT READY`** | **`bad`**, `badSoft` fill, `bad` border |
| `rec: notrec` / `stalled` | **`ARMED · NOT RECORDING`** / `STALLED` | **`bad`**, `badSoft` fill, `bad` border |
| `rec: unknown` | `REC ?` + hollow ring | `accent` |
| `motion: never` / `silent` | `no motion ever` / `ARMED · silent 2d` + hollow ring | `accent` |
| `rec: gap` | `GAP` + hollow ring | `accent` |
| healthy | `ARMED` / `ARMED · 4m` + solid `bad` dot (recording) | `ink2` |

Only the two genuinely-broken families get a **`bad`-filled badge and a `bad`-filled marker**, and only they raise the tile`s **2px `bad` ring** (§2.4) — so a screen of faults reads as a wall of red cells before any text is read, and no fault state can be mistaken for normal. Marker short forms: `NOT READY` · `NOT REC` · `STALLED` · `REC ?` · `NO MOTION` · `SILENT` · `GAP` · `OFF`.

### 2.6 · Multi-select and assignment

**Select:** click (toggles a single) · **shift-click** (range in visual order) · **⌘/ctrl-click** (add) · **⌘A** (everything in the current filter) · checkbox (add). The range anchor is an **interaction pointer, not render state** — see §6.

**Assign, two ways:**

1. **Selection bar** — sticky at the bottom of the list, 34px, `#2b2318` on a 1px `accent` top border, gapless: `12 selected` · `MOVE TO` · one cell per group · `Ungrouped` · spacer · `✕ Clear`. **One click files the whole selection.**
2. **Drag** — drag any selected row onto a group row in the left pane. A 1px `accent` ring marks the drop target; a `12 selected →` pill follows the cursor. Dropping on `All cameras` is a no-op (it is not a group).

Filing 14 cameras into Снаружи: search or facet, ⌘A, one click. **Two gestures instead of fourteen popups.**

### 2.6b · Group-chip popup

186px wide, `panel` fill, 1px `line2`, 28px rows: one per group plus `Ungrouped`.

**Its height is derived from the row count — never assumed.** `height = (groups + 1) × 28 + 2`. It is anchored under the chip, **flips above** when it would overflow the bottom, and is clamped on **both** axes with a lower bound as well as an upper one (`6px` inside the frame). If the list is taller than the frame itself, the popup scrolls rather than clipping.

A fixed pixel guess here — subtracting a constant from the frame height — holds for a three-group fleet and silently breaks at seven, which is exactly the §4 "12 groups" case this spec already promises works. Same discipline as the magnifier (§2.7): measure or compute, then clamp.

### 2.7 · Opening a camera — modal lightbox

**The hover magnifier is withdrawn.** A panel that appears because the pointer paused is the wrong instrument here: it covers the wall it is explaining, fires when you did not ask, and cannot hold an action. Opening a camera is an explicit **click**.

Today's behaviour is the defect this replaces: a click loads the camera's **live stream into the Groups tab**, destroying the screen the operator was working in with no way back. Opening now presents the camera *over* the wall and returns you to it untouched. "Watch this camera" is demoted to an explicit `▤ Open in Live Monitor` action rather than an accident of clicking.

**Selection and opening are separated.** A plain click selects *and* opens; ⌘-click and shift-click select **without** opening. Filing a batch and inspecting one camera are different intents, and a modified click must never tear the operator out of a batch they are assembling. **Every role can open** — inspecting is non-destructive and is the read-only user's entire job (§2.8).

#### Geometry

The wall **blurs behind a 62% scrim** (7px blur, 70% saturation) and one camera is presented in a card **sized as a share of the window, never a pixel constant**, centred:

```
cardWidth  = round(windowWidth × 0.84)
videoH     = min(cardWidth × 9/16, round(windowHeight × 0.86) − 60)     // 60 = header + footer
```

At 1440×900 that is a **1210×743 card with a 1208×681 frame** — 2.5× the picture area of a fixed 760px card, and the reason for the fraction is that a bigger window must give a bigger *picture*, not more empty scrim. The `0.86` height share is what keeps the card clear of the window edges at every size; the `9/16` term keeps the frame at the cameras' own aspect so it is never letterboxed.

| band | height | contents |
|---|---|---|
| header | 30px | octet (mono 13px `accent`) · editable name · `UNNAMED` chip · badge · `6 / 39` position · `✕` |
| frame | see above | the camera, with a nav plate in a hover zone on each edge |
| footer | 30px | address · model · recording · last motion · spacer · `Rename` · group chip · `Open in Live Monitor` · `← → ESC` |

The card **clips its own children**, and the footer's four metadata cells shrink and ellipsize while the action cells and key hints never do — a row of nowrap cells at fixed padding cannot shrink at all, so it overruns the card the moment a string grows.

Closing: **click anywhere in the blur**, `Esc`, or the `✕`.

#### Navigation — the plate, not the chevron

`←` / `→` and the two on-image plates walk the **current filtered order**, not the full fleet, so the modal is a *reading position in the wall* rather than a detached window.

**The two plates are ONE control layer, not two independent hover targets.** They share a single visibility state, so reaching toward `Next` reveals `Prev` as well and the operator sees the whole navigation at once. A control that has to be discovered independently of its twin is a control half the operators will never know exists.

The layer follows the player convention:

| trigger | result |
|---|---|
| modal opens | **shown** — the controls announce themselves rather than waiting to be found |
| camera changes (click or `←`/`→`) | **shown** — keyboard-only navigation still reveals where it has landed |
| pointer moves anywhere over the frame | shown, fade in 130ms |
| pointer still for **2.6s** | hidden, fade out 100ms |
| pointer leaves the frame | hidden **immediately** |

Idle-hiding rather than zone-hiding is the correction of an earlier draft that gated each plate on a 210px edge zone. Two separate zones meant the plates could never be seen together, and a pointer resting in the middle of the picture hid controls that the operator had not finished with. Stillness is the honest signal that the operator is *looking* rather than *navigating*; position is not.

The keyboard path (`←` / `→`) is always live and never depends on the pointer being anywhere.

**A bare chevron cannot answer the question the operator actually has — "which camera am I about to see?"** So each side carries a **168×58 preview plate**:

| slot | spec |
|---|---|
| thumbnail | **50×29** frame of the adjacent camera, with a 2px bottom bar — `bad` if that camera is faulted, `accent` if warned, absent if healthy. Same frame primitive as the tile and the modal: **styled on its own class, never through an ancestor**, so it renders identically in all three hosts |
| label | mono 7.5px caps `PREV` / `NEXT` at 50% |
| octet | mono 11.5px DemiBold white — `accent` on hover |
| — | **no chevron, no arrow glyph** |
| name | 9px @68%, ellipsized; operator name, else the model |

Next-plate content is **right-aligned and mirrored** (meta, thumb) so both plates read outward from the image.

**There is no chevron.** Direction is already stated three times over — by the `PREV` / `NEXT` label, by which edge the plate is anchored to, and by the mirrored internal order — so an arrow glyph adds nothing but the most over-used mark in interface design. The 21px it occupied goes to the camera name, which was the one element genuinely short of room.

Three consequences worth having:

1. **You can skip.** Seeing `NEXT .109` before clicking means an operator sweeping for a specific camera stops guessing.
2. **The fault bar makes the sweep predictive** — you know a broken camera is coming before you arrive at it.
3. **Fixed 168×58 whatever it holds**, so the click target never moves between cameras. Name length changes nothing. This is a control clicked dozens of times in a row; it must not migrate — and because the hot zone is fixed too, the gesture that summons it is identical every time.

**At the ends the plate keeps its footprint** and states the boundary — `START OF LIST` / `END OF LIST`, dimmed and inert — rather than disappearing. A vanishing control relocates its neighbour, and wrapping from camera 39 to camera 1 silently loses the operator's place.

Pair the modal with the `Unnamed 23` facet and it becomes a naming conveyor: open, type, `→`, type — the plate showing which camera is coming while you finish the current one.

### 2.7b · Inventory of transient controls

Everything in this design that appears and disappears, and why each is the way it is. Three items, no more — and any fourth added later belongs in this table.

| control | trigger | shared? | why |
|---|---|---|---|
| **modal nav plates** (`PREV` / `NEXT`) | pointer activity over the modal frame; idle 2.6s hides | **yes — one layer** | Navigation is a *set*. Seeing one without the other hides half the map. |
| **tile checkbox** | that tile hovered, or selected | no — per tile | It is an affordance *of that tile*. |
| **tile hover row** (full badge text + group chip) | that tile hovered | no — per tile | It is metadata *about that tile*. Showing all 41 at once is precisely the density bug this redesign exists to remove. |

The wall's two are deliberately **not** a shared layer: they are per-object, and revealing them across the whole wall would repaint 41 tiles with text the operator did not ask for. The modal's are a layer because they are chrome, not content.

**One open question for the build.** The tile checkbox is the wall's only clue that multi-select exists, and it is currently invisible until a tile is hovered — the same discoverability gap the nav plates had. Revealing **every** checkbox whenever the pointer is anywhere over the wall would fix it, at the cost of 41 small boxes appearing on every mouse move. Flagged rather than decided: it is a live judgement call, not an oversight.

### 2.8 · Read-only roles

Viewers and engineers get a **coherent screen, not a disabled one**:

- Absent: tile checkboxes (nothing shifts — the top row is an overlay, so removing it just leaves clean video), group-chip carets, the selection bar, `+ New group`, `Delete group`, rename-on-double-click.
- **Present and fully working: opening a camera (§2.7).** Inspecting is the read-only user's entire job and is non-destructive — a viewer who cannot open a camera has no screen. What is absent is only the edit affordances *inside* the opened surface: rename, the group chip's caret, the checkbox.
- Present and fully working: both searches, all three facets, health bars, badges, the magnifier, `Open in Live Monitor`, and the `Ungrouped` row.
- One 22px `panel` strip under the header states the situation once: `⃠ READ-ONLY · your role cannot rename, group or delete`.

The result reads as an **inspection** screen — which is what it is for those roles. Nothing looks broken because nothing is greyed out.

---

## 3 · Thumbnail fetch discipline

Groups must not become a second video wall — and a gapless mosaic is the layout most at risk of becoming one, so this section is load-bearing. 41 × (184×104) is **785 kilopixels** against today`s 15 × (250×140) = 525 kp: **1.5× the pixels for 2.7× the cameras**. Acceptable, but only because every rule below holds. At 4-per-row it is 18 × (276×155) = 770 kp — deliberately the same budget, which is why the big gear costs nothing extra.

1. **Viewport-only — mandatory, not prudent.** Only tiles actually rendered request a frame; no cache buffer. At 80 cameras an eager wall would request 6 megapixels.
2. **One in flight per camera**, queued in the wall`s **visual reading order** — row-major, left-to-right, top-to-bottom — 4 concurrent. Derive the order from the layout, never from the model index: a queue that jumps around the visible wall feels broken even at identical throughput (the Verify lesson).
3. **Cancel on scroll-out and on filter change.** A queue full of tiles nobody is looking at starves the visible ones.
4. **The placeholder is a flat `#141312` tile**, never a spinner. With no gutters an unfilled tile does not read as a hole — the wall fills in rather than flashing.
5. **Offline cameras are never requested** — they render a flat `#191817` field plus the red dot. There is no frame to fetch.
6. **The open camera's larger view reuses the tile's frame** at scale before requesting a higher-resolution one, so opening costs nothing until it is held open. Only the opened camera is ever fetched at size — never a hover.
7. **Refresh is a slow poll, not a stream** — Groups is an organisational screen. Neither per-row setting raises the rate; 4-per-row fetches fewer, larger frames for the same total pixels.

---

## 4 · Edge cases

| case | behaviour |
|---|---|
| **0 groups** | Left pane: `All cameras` + `Ungrouped 39` + the divider showing `0` + `+ New group`. Right pane lists every camera with `Ungrouped` chips. Coherent and obviously actionable — no empty-list void. |
| **1 group** | Normal. `Delete group` still arms and still names its blast radius. |
| **12 groups** | The list scrolls; group search earns its 30px. Order is configured order. The chip popup is 13 rows = 366px and **must be positioned from that computed height** (§2.6b), flipping above the chip near the bottom of the wall. The selection bar's `MOVE TO` cells overflow — it scrolls horizontally rather than wrapping, and the group chip popup remains the complete list. |
| **80 cameras** | 2 screens at 6-per-row. Thumbnails viewport-only (§3) — this is the case that makes rule 1 mandatory. Facet + search is the primary path, not scrolling. |
| **All ungrouped** (the provisioning case) | `Ungrouped 20` appears by itself; click it, facet `Unnamed 20`, name them top-down with double-click + Enter, ⌘A, one click into the group. **This is the success test and it is two minutes.** |
| **A group where every camera is faulty** | Health bar is solid `bad`; `Faults 22` equals the group total **and equals the number of red-ringed tiles** (§2.5 rule 1); **every tile carries a 2px `bad` ring** — the wall goes visibly red. If some are only *unknown* rather than broken, they are warn-ringed and excluded from that 22 — an honest smaller number beats an alarming wrong one. |
| **Rename to empty** | Refused silently, old name stands. |
| **Two groups with the same name** | Possible only if the operator types the same name twice; the inline field makes that a deliberate act rather than an artifact. Flagged: a uniqueness check belongs in the backend, not the UI. |
| **Delete a group while its cameras are selected** | The cameras become ungrouped and **stay selected**, so the operator can immediately re-file them. |
| **RU at 1200px** | Tile geometry is language-invariant (octet + ellipsized name). `ОХРАНА · НЕ ПИШЕТ` is *shorter* than the English; marker short forms take RU equivalents at the same 7.5px. The longest RU string is the read-only strip, a single flexible line. No layout change. |
| **1200×900** | Left 264 fixed, right 871 → 6-per-row gives 145×82 tiles, 8.8 rows = **52 cameras**; 4-per-row gives 217×122, 5.9 rows = 23. The column count never changes with window width — only the tile size does. |
| **Offline camera** | Flat `#191817` tile + red dot + `OFF` marker + `accent` warn ring; counted as `warn` in the health bar, never as `ok`. No frame is requested. |

---

## 5 · Strings

| id | EN | RU |
|---|---|---|
| `g.section` | `CAMERA GROUPS` | `ГРУППЫ КАМЕР` |
| `g.all` | `All cameras` | `Все камеры` |
| `g.ungrouped` | `Ungrouped` | `Без группы` |
| `g.search` | `Find a group…` | `Найти группу…` |
| `g.new` | `New group` | `Новая группа` |
| `g.newPh` | `Group name…` | `Название группы…` |
| `g.empty` | `EMPTY` | `ПУСТО` |
| `g.delQ` | `Delete “{g}”? {n} camera(s) become ungrouped.` | `Удалить «{g}»? {n} камера/камеры/камер останутся без группы.` |
| `g.delQ0` | `Delete “{g}”?` | `Удалить «{g}»?` |
| `g.live` | `Open in Live Monitor` | `Открыть в мониторе` |
| `c.search` | `Octet or name…` | `Октет или имя…` |
| `c.all` / `c.unnamed` / `c.faults` | `All` / `Unnamed` / `Faults` | `Все` / `Без имени` / `Неисправные` |
| `c.unnamedChip` | `UNNAMED` | `БЕЗ ИМЕНИ` |
| `c.notRecN` | `{n} not recording` | `{n} не пишут` |
| `c.ofN` | `{a} of {b}` | `{a} из {b}` |
| `c.selected` | `{n} selected` | `Выбрано: {n}` |
| `c.moveTo` | `MOVE TO` | `ПЕРЕНЕСТИ В` |
| `c.saved` | `SAVED` | `СОХР` |
| `m.prevK` / `m.nextK` | `PREV` / `NEXT` | `НАЗАД` / `ДАЛЕЕ` |
| `m.listStart` / `m.listEnd` | `START OF LIST` / `END OF LIST` | `НАЧАЛО СПИСКА` / `КОНЕЦ СПИСКА` |
| `c.emptyGroup` | `No cameras in “{g}”.` | `Нет камер в «{g}».` |
| `c.emptyHint` | `Select cameras in another group and move them here.` | `Выберите камеры в другой группе и перенесите их сюда.` |
| `c.noFault` | `Every camera in scope is recording.` | `Все камеры в этой области записывают.` |
| `c.noUnnamed` | `Every camera in scope has a name.` | `У всех камер в этой области есть имя.` |
| `c.readOnly` | `READ-ONLY · your role cannot rename, group or delete` | `ТОЛЬКО ЧТЕНИЕ · ваша роль не может переименовывать и группировать` |
| badges | `ARMED` · `ARMED · {m}m` · `ARMED · NOT READY` · `ARMED · NOT RECORDING` · `ARMED · silent 2d` · `no motion ever` · `REC` · `NOT REC` · `GAP` · `OFF` · `REC ?` · `STALLED` | `НА ОХРАНЕ` · `ОХРАНА · {m}м` · `ОХРАНА · НЕ ГОТОВА` · `ОХРАНА · НЕ ПИШЕТ` · `ОХРАНА · тихо 2д` · `движения не было` · `ЗАПИСЬ` · `НЕ ПИШЕТ` · `ПРОБЕЛ` · `ВЫКЛ` · `ЗАПИСЬ ?` · `СБОЙ` |

**Auditing this table is a build step, not a review step.** Untranslated strings in this design hid three times — in the rail, in the tile's status marker, and in the `EMPTY` group marker — because each lives inside a component rather than a header, and the last only renders once a group has zero cameras. Do not eyeball it: extract every text literal and every `title`/`placeholder` in the screen's source and diff against this table. Anything not sourced from the string table is a miss unless it is on the allow-list — brand names (`CILEX VISION`, `Watchtower`), key names (`CTRL K`) and vendor model strings, which are correctly untranslated in both languages.

Every count string needs EN 2-form and **RU 3-form** plurals (`n%100` 11–14 → genitive plural; else `n%10`: 1 → nominative singular, 2–4 → genitive singular, otherwise genitive plural).

---

## 6 · Flags for the engine room

- **No undo, and the design does not pretend otherwise.** Every unrevertable write is either double-click-gated (rename) or armed in place with its blast radius stated (delete). The `SAVED` flash is a receipt, not an undo. **If you want real undo it is a backend change** — a soft-delete window on groups and a last-value field on names would let us add `↶ Undo` to the flash. Worth costing; not assumed here.
- **Group-name uniqueness** belongs in the backend. The inline-create field makes duplicates deliberate but cannot prevent them.
- **`ARMED · NOT RECORDING` on 12 of 23 cameras** is a fleet fault, not a UI problem. The design surfaces it three ways (badge box, group health bar, permanent `N not recording` readout) — that is as loud as a UI can honestly be.

---

## 7 · Acceptance checklist

- [ ] Left pane **264px**: group search 30px, `All cameras`, conditional `Ungrouped N`, divider, groups in configured order, `+ New group` (admin/operator only).
- [ ] Every group row carries a **34×3px bad/warn/ok health bar** and an `EMPTY` marker at zero.
- [ ] Right header **34px**; filter bar **30px**; the permanent hint strip is **gone**.
- [ ] Tiles are **truly gapless**: `gap: 0`, no card inset, no border between frames, no footer. Measured horizontal AND vertical gaps are exactly 0.
- [ ] Overlays only: bottom scrim (octet always full, name ellipsized, `UNNAMED` chip when unnamed), top row (checkbox + status marker + online dot), hover row (full badge + group chip). **No text band between tiles, and the IP is never on a tile.**
- [ ] Every state is an **inset ring** — fault 2px `bad`, warn 1px `accent`, selected 2px `accent` — so no state opens a gap or shifts the grid.
- [ ] A healthy tile shows **no status marker** — only exceptions get ink.
- [ ] **Every fault count on the screen agrees**: the `Faults` facet, the number of `bad`-ringed tiles, the `N not recording` readout and the top-bar `NOT REC` pill all resolve from the §2.5 predicates. Audit the full fleet and confirm the numbers match.
- [ ] `REC ?` is counted as neither fault nor healthy — warn ring, own marker, own `N unknown` readout.
- [ ] A camera that is both not-recording and detector-faulted shows the `NOT REC` marker and a compound hover badge.
- [ ] Per-row is **4 or 6, set by the preference and never changed by window width**; columns are `1fr` (never floored), so the wall reaches the pane's right edge with **zero leftover pixels**. Row height recomputed on `onWidthChanged`.
- [ ] The thumbnail queue order follows the wall`s visual order — row-major, left-to-right, top-to-bottom.
- [ ] ≥2.5× cameras on screen vs today at 6-per-row (41 vs ~15); 4-per-row is the deliberate 1.2× identify gear.
- [ ] Select: click, **shift-click range**, ⌘-click, ⌘A, checkbox. Range anchor survives two clicks in the same tick.
- [ ] Assign: selection bar **one click**, and **drag a selection onto a group row** with an `accent` drop ring.
- [ ] `+ New group` takes a name **before** creating; empty commits nothing. No group is ever named "New group".
- [ ] `Delete group` **arms in place** and names the camera count it will orphan.
- [ ] Rename is **double-click**, Escape cancels, empty is refused, and a `SAVED` flash confirms the write.
- [ ] All badge states from §2.5 distinguishable; only the two fault families get a filled box; no fault reads as normal.
- [ ] Search matches octet prefix, IP, operator name and model. Facets count against the current scope.
- [ ] Thumbnails viewport-only (**mandatory**), row-major reading-order queue, 4 concurrent, cancelled on scroll-out and filter change, never requested for offline cameras.
- [ ] Clicking a tile opens it per §2.7; ⌘-click and shift-click select **without** opening. Escape closes. An open camera that leaves the current filter closes rather than lingering.
- [ ] Modal: blurred scrim, click-in-blur / `Esc` / `✕` all close, footer never overruns the card, card clips its children. **No hover-triggered panel anywhere.**
- [ ] Modal card and frame are **fractions of the window** (0.84 / 0.86), not pixel constants; the frame holds 16:9 and the card fits vertically at 1440×900 and 1200×900.
- [ ] Nav plates are **168×58 fixed** and show the adjacent camera's thumbnail, octet, name and fault bar; they never resize or move with name length.
- [ ] Both plates **share one visibility state** — either one appearing means both appear. Shown on open and on every camera change; hidden after 2.6s of stillness; hidden at once when the pointer leaves the frame. Keyboard navigation never depends on them.
- [ ] `←` / `→` and the plates walk the **filtered** list, do **not** wrap, and hold their footprint at the ends with `START OF LIST` / `END OF LIST`.
- [ ] Arrow navigation works for **read-only roles** — it is not gated behind the edit permission.
- [ ] **Read-only role**: controls absent not disabled, alignment preserved, one 22px explanatory strip, everything else fully functional.
- [ ] Correct at 1440×900 and 1200×900, EN and RU, with 3-form RU plurals.
- [ ] Every empty state names its filter or scope; nothing goes silently blank.
