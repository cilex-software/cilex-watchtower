# Triage Queue — camera quick-filter redesign

**Reply to:** `docs/design-briefs/2026-08-06-triage-queue-camera-filter.md`
**Date:** 2026-08-06 · **Status:** ready to build
**Companion prototype:** `designs/triage-camera-filter-prototype.html` — clickable, real tokens, 130 events / 22 cameras, EN+RU and 1440/1200 harness. Where this document and the prototype disagree, **this document wins**.

---

## 0 · What changes, in one screen

Row 2 of the queue stays **36px tall** — the redesign is **height-neutral when idle**, so the event list loses nothing.

```
┌ 384px ───────────────────────────────────────────────┐
│ Open queue 130   Critical 3   All 148        45px    │  Row 1 unchanged
├──────────────────────────────────────────────────────┤
│  All   .104 14  .143 15  .144 18        ⌕ 19  36px   │  Row 2 = OCTET BAR (new)
├──────────────────────────────────────────────────────┤
│ ● ▦ ◇MOTION  HiWatch DS-I202(E) (…144)               │  Row 3 unchanged
```

Three parts:

1. **Octet bar** — `All` + **3 most-recently-used camera chips** + a wordless **`⌕ N` palette button** welded to the right edge.
2. **Camera palette** — a 368px panel the button opens over the list: a search field that takes octets or names, the full roster with live per-tab counts, checkboxes for multi-select.
3. **Filter ribbon** — a 22px sticky strip that appears at the top of the list **only while a filter is active**, naming the filter and offering `✕ Clear`.

**Headline behaviour:** in the queue, **typing a digit opens the palette and starts the search with it.** "Check .146" → `1` `4` `6` `Enter` → a .146-only queue. Four keystrokes, no mouse, no hunting. Digits are safe: `E` is a letter, `Ctrl-K` is a chord.

---

## 1 · Chosen pattern and rationale

**Pattern: MRU octet chips + searchable camera palette.** A hybrid, not a pure dropdown and not a longer chip row.

A pure searchable dropdown would fix scale and kill the kept virtue (one-click busiest cameras). A wrapping or scrolling chip row scales to ~12 cameras and dies at 80. The two halves solve different halves of the job:

| Job | Solved by |
|---|---|
| "Check .146" — a *named* camera, arbitrary, said out loud | Palette + type-ahead |
| Backlog sweep — hop between the cameras I am working right now | MRU chips, one click each |

Against the brief's five failure modes:

| # | Failure | Fix |
|---|---|---|
| 1 | **Capacity** — ~5 chips for 15–80 cameras | The bar no longer tries to hold the fleet. It holds a **fixed 3** and delegates the rest. Bar width is now constant and predictable at any fleet size. |
| 2 | **Zero overflow discoverability** | The `⌕ N` button is always present, always at the right edge, and **states the number it is hiding**. Nothing clips. |
| 3 | **Ordering instability** | Chips are **MRU, not ranked by traffic**. The list only ever changes as a *direct result of the guard's own click*, never on its own as events arrive — and a camera already on the bar **does not move when re-used**. Counts change; positions do not. |
| 4 | **No search path** | The octet *is* a number and no shortcut owns digits. Type-to-find with digit-hotkey entry. |
| 5 | **Single-select only** | Palette rows are checkboxes; the queue ORs the selection. Entrance pairs work. |
| 6 | **Kept virtue: one-click busiest** | The MRU list is **seeded with the three busiest cameras** on first use, so day one behaves exactly like the shipped filter. Inside the palette the roster is busiest-first, so today's #1 is always the top row: one click to open, one to select — and it lands on the bar for the rest of the shift. |

**Why MRU rather than auto-ranking by traffic.** Failure 3 is caused by chips moving *for reasons the guard did not cause*. MRU only ever changes in response to a click the guard just made, so the bar is always a record of what they have been doing — the cameras they are actively working are the ones under the cursor. Two rules keep it from thrashing:

- **Entry, not re-use, moves things.** A camera already on the bar stays exactly where it is when clicked again. Only a *new* camera shifts anything, and it always enters at slot 1.
- **Eviction is least-recently-used, display order is entry order.** Re-using `.143` refreshes its recency (so it won't be evicted) without moving its chip. The two orderings are deliberately separate.
- **Seeded entries carry synthetic recency.** The three seeds are stamped with descending use-counters at seed time (busiest = most recent), so the very first new pick of a session evicts the *stalest* seed rather than whichever the scan happened to reach first. Without this every seed ties at zero and the eviction picks the newest — the busiest camera — which is the worst possible answer on the most common path.

**Why the roster shows zero-count cameras.** Per §6 the population rule permits the full roster if zero counts are visible and selecting one produces the honest empty state. We take that option: a guard told "check .146" must be able to *find* .146 and be told "no events" — not be unable to find it and conclude the camera is missing. Absence of a chip is ambiguous; a `0` is a fact.

---

## 2 · Layout spec

### 2.1 Octet bar (Row 2)

| property | value |
|---|---|
| height | **36px** fixed (unchanged from today) |
| background | `bg` `#1a1816` |
| bottom border | 1px `line` `#34302a` |
| padding | `0 12px` |
| layout | single horizontal row, `gap: 6px`, **no wrap, no scroll, no clipping** |
| order | `All` → **MRU chips (newest leftmost)** → session chip(s) → **flexible spacer** → `⌕ N` button |

The spacer guarantees the palette button is pinned to the right edge at every fleet size and window width — a fixed target.

### 2.2 Chip (all chips share one geometry)

| property | value |
|---|---|
| height | 22px, square corners |
| padding | `0 6px` |
| border | 1px |
| label | JetBrains Mono **10px** DemiBold, e.g. `.104` |
| count | JetBrains Mono **9px**, 6px to the right of the label |
| tooltip | full camera name + group, 500ms delay |

States:

| state | fill | border | label | count |
|---|---|---|---|---|
| idle | transparent | `line2` `#443f37` | `ink2` | `ink3` |
| hover | `panel2` `#2a2722` | `ink3` `#6e6657` | `ink` | `ink3` |
| **active** (selected) | `accentSoft` (accent @8%) | `accent` `#e8a13a` | `accent` | `accent` |
| **zero** (0 events in this tab) | transparent | `line` `#34302a` | `ink3` @55% | `ink3` @55% |
| active + zero | `accentSoft` | `accent` | `accent` | `accent`, count reads `0` |

**There is deliberately no disabled state.** A zero chip is dimmed but fully clickable, because clicking it must reach the honest empty state — "no events match .146" is information the guard asked for. Dimming communicates "nothing here"; blocking would communicate "broken".

**`All` chip:** count-less. Idle label `All`. When any camera filter is active it becomes **`✕ All`** with an `accent` border and `accent` label — the always-available one-click reset.

**Session chip:** because any selected camera immediately enters the MRU list, a session chip only appears when **more than 3 cameras are selected at once**. It renders after the MRU chips in the active state with a trailing `✕` (8px, `accent`).

**Entry animation:** a camera arriving at slot 1 flashes its fill from `accent` @30% to its resting state over **500ms** — the only motion on the bar. It tells the guard where the thing they just picked went, which is the whole point of MRU.

### 2.2b Fit ladder — how the bar guarantees it never clips

The bar has a **359px content box** and no scroll. Rather than trusting one arithmetic budget, lay the row out and, while it measures wider than the track, escalate one step. Each step sheds the *least* load-bearing thing next, and **no step ever moves a chip or changes what is selectable** — muscle memory survives all four.

| step | change | measured worst case |
|---|---|---|
| **L0** | full: `All` · 3 counted MRU chips · full session chip `.160 13 ✕` · `⌕ 19 ▾` | 48 + 195 + 69 + 47 + 30 = **389** |
| **L1** | session chips → one wordless **`+N ✕`** | 48 + 195 + 47 + 47 + 30 = **367** |
| **L2** | `✕ All` → bare **`✕`** icon chip (only reachable while filtered, which is the only time L2 occurs; the ribbon's `✕ Clear` carries the label) | 26 + 195 + 47 + 47 + 30 = **345** ✓ |
| **L3** | MRU chips **drop their counts**, keeping `.104` · the count moves to the tooltip, the palette and the ribbon | 26 + 123 + 47 + 47 + 30 = **273** ✓ |

Measured chip widths (mono 10px DemiBold, **6px** horizontal padding, 6px gaps): `All` 42 · `✕ All` 48 · bare `✕` 26 · `.104 12` 63 · `.104 130` 69 · `.104` alone 39 · `.160 13 ✕` 67 · `+1 ✕` 45 · `⌕ 19 ▾` 47. The table above is computed from slightly rounder numbers and is therefore conservative by a few px per chip.

**Label integrity:** the octet is **one text run** — `"." + octet` — never a separate glyph beside the digits. It is the single most important string on the screen (it is what the guard says out loud), and any inter-item spacing inside the chip splits it into `. 104`.

L3 clears the track by 86px even with three-digit counts on every chip, so the ladder **terminates in a guaranteed fit** — the bar never scrolls, wraps or clips at any fleet size, count magnitude, or language. `clip: true` stays on the bar as a last-resort guard that should never fire; if it ever does, the ladder is broken and that is a bug, not a layout strategy.

The collapsed chip is deliberately **wordless**: a word here (`2 cameras` / `2 камеры`) is the widest thing on the bar and grows in Russian — exactly the case the collapse exists to solve.

### 2.3 Palette button

| property | value |
|---|---|
| size | 22px tall, padding `0 6px`, border 1px `line2` |
| content | `⌕` glyph (11px, `ink2`) + gap 5px + count (JetBrains Mono 10px) + `▾` caret (8px, `ink3`) |
| count | **cameras not shown as chips**, i.e. roster − MRU. `⌕ 19 ▾` |
| idle / hover | as chip idle / hover |
| open | fill `panel3` `#322e28`, border `ink3` |
| **filter active** | fill `accentSoft`, border `accent`, glyph + count `accent`, and the count switches to **the number of selected cameras** |
| ≤0 overflow | number omitted; button renders `⌕ ▾` and stays in place |

**The button carries no words** — it is glyph + digit, so it is identical in English and Russian and immune to string growth. The sentence lives in the tooltip.

### 2.4 Camera palette panel

Anchored under the bar, overlaying the list. No scrim: the list stays readable behind it.

| property | value |
|---|---|
| position | left `8px` of the queue column, top = octet-bar bottom edge |
| width | **368px** |
| max height | **384px** (≈ list height at a 900px window minus breathing room) |
| background | `panel` `#221f1c` |
| border | 1px `line2`, square |
| elevation | none (no shadow) — separation is the border plus the `panel`/`bg` value step |

**a. Search field** — 34px tall, `bg` fill, bottom hairline `line`.
- `⌕` glyph 11px `ink3` at 12px inset.
- Input: JetBrains Mono 12px `ink`, caret `accent`, no border of its own.
- Placeholder 11px `ink3`: `Octet or camera name…`.
- Right: `Esc` key hint — mono 9px `ink3`, 1px `line` border, padding `1px 4px`.
- Focus is taken on open, always.

**b. Scope line** — 22px, mono **9px** caps `ink3`, letter-spacing 1.3, 12px inset:
`22 CAMERAS · OPEN QUEUE · ALL GROUPS` — states exactly what the list is drawn from. Reflects the active status tab and the section group dropdown.

**c. Roster list** — scrolls, 3px `line2` scrollbar. Ordered: **recent** (MRU order, newest first) → **has events** (count desc, then octet) → **zero in this tab** (octet asc), under 20px mono 9px caps `ink3` dividers `RECENT` / `BUSIEST` / `NO EVENTS IN THIS TAB`. While a search string is present the dividers are suppressed and results are one flat list ranked: exact octet match → octet prefix → name/group substring.

Row, **34px**:

| slot | spec |
|---|---|
| left bar | 2px, full height — `accent` when selected, `ink3` when keyboard cursor, else none |
| checkbox | 13×13, 1px `line2`; checked = `accent` fill + `bg` check glyph; 12px inset |
| offline dot | 5px `bad` circle, only when the camera is currently offline, 6px before the octet |
| octet | JetBrains Mono **12px** DemiBold, `ink` (`accent` when selected), min-width 42px |
| name | 11px `ink3`, flex, ellipsized — `HiWatch DS-I202(E) · Inside` |
| count | JetBrains Mono 11px, right-aligned, 30px column — `ink2`, or `ink3` when `0` |

Row states: hover `panel2` · keyboard cursor `panel2` + `ink3` left bar · selected `accentSoft` + `accent` left bar.

**d. Footer** — 30px, top hairline `line`, 12px inset.
- Left, mono 10px: `ink3` `Enter = only this · Space = add` when nothing is selected; `accent` `3 selected` when something is.
- Right: `Clear` ghost button, 10px — `ink3` when nothing selected, `accent` when something is.

**e. No-result state** — 48px block, centred, 11px `ink3`: `No camera matches "999".`
**f. Loading state** — same block: `Loading cameras…`. The octet bar meanwhile shows `All` plus mono 10px `ink3` `Loading cameras…` and no button.

### 2.5 Filter ribbon (active-filter strip)

Rendered **only when a camera filter is active**, as the sticky first child of the list scroll area — so it costs **0px when idle** and stays visible while the guard scrolls.

| property | value |
|---|---|
| height | 22px, sticky top of `.tq-scroll` |
| fill | `accentSoft`, bottom border 1px `accent` @ 25% |
| left | JetBrains Mono 10px `accent`: `12 events · .146` — two cameras: `.143 + .144` — three or more: `3 cameras` |
| right | `✕ Clear` — mono 10px `accent`, hover underline |

This is what stops the guard wondering why the queue looks short, and it carries the **filtered count** — which the status-tab pills, per contract, must not.

---

## 2.6 · Group strip (replaces the `All groups` dropdown)

A dropdown costs two clicks and a menu to change something that has **two options today and maybe six later**. Spend the empty band to its right and make it one click.

**Placement.** The sub-nav row, starting where the dropdown sits today, separated from the mode buttons by a 1px `line` divider + 10px. It **flexes to fill the band up to the section totals**, which stay right-aligned. This band currently holds the "CLEAR THE BACKLOG / Inbox triage…" rationale copy — **that copy has to move** (a tooltip on the `01 Triage Queue` mode button is the cheapest home). Flagging it rather than assuming: if the copy must stay, the strip can sit on its own 40px row instead, at the cost of 40px of list height.

**Group chip** — same visual language as the octet chips, sized for the sub-nav:

| property | value |
|---|---|
| height | 30px, square corners |
| padding | `0 10px`, `gap: 7px`, row `gap: 6px` |
| label | Space Grotesk **11px** (a group name is a word, not a number — unlike the octet chips) |
| count | JetBrains Mono 10px, events in the active status tab for that group |
| idle / hover / active / zero | identical token treatment to §2.2 |

Order: **`All groups`** first (always, always leftmost, carries the unscoped total), then **the active group**, then the remaining groups in the fleet's own configured order — *not* by count. Group membership is stable configuration; reordering it by traffic would reintroduce failure mode 3 one row higher up.

**The active group is always promoted into the visible run.** If the selected group could fall into the `+M` overflow, the strip would name five groups the guard is *not* in and represent the one they *are* in as an unlabelled `+2 ▾` — the section silently scoped by something with no name on screen. That breaks the honesty rule outright, and is worse than the dropdown it replaces, which always showed the selected group. So the fit walk runs over `[active, …rest]`, not over the configured order, and `visibleGroups` is floored at 1 whenever a real group is active. The only chip that ever moves is the one the guard just clicked; every other group keeps its position relative to its neighbours.

**Fit rule — same measured ladder as the octet bar.** Render `All groups` + every group; if the strip measures wider than its band, drop the last group and re-measure, until it fits. Any groups that didn't fit collapse into a trailing **`+M ▾`** chip that opens a 214px panel (`panel` fill, 1px `line2`, 30px rows, name left / count right) anchored under the button. So: ≤ what fits → pure one-click chips; more → the first N are one click and the rest are two, which is still no worse than today's dropdown.

**Remeasure on width change, and compute the answer — don't converge on it.** The window is resizable and often smaller, and a drag-resize changes the band's width without changing any application state, so the ladder must be driven by the *element's* width (`onWidthChanged` in QML, `ResizeObserver` on the web). Two traps, both of which produce a strip that is permanently one width-change behind:

- **Don't reset-then-decrement.** "Set visible = all, then drop one per pass until it fits" needs a repaint per step, and if the reset writes the value it already holds, most frameworks skip the update entirely and no re-measure ever happens.
- **Compute `visibleGroups` directly instead.** Read each chip's intrinsic width once (a hidden full-width ghost row is the cheap way), then walk the cumulative sum against the band's width — reserving the `+M` chip's width whenever anything will be hidden — and write the result in one assignment. It is idempotent, it is one pass, and it is correct when the band *grows* as well as when it shrinks.

The octet bar's ladder (§2.2b) needs the same resize trigger; its four levels are discrete enough to keep escalating one step per pass, but the reset must force a re-measure rather than silently no-op.

The threshold is **measured, not a magic X**: it moves with window width, language, and the length of the group names. At 1440px with the two real groups the strip uses roughly a third of the band; six English groups still fit; six Russian names spill one or two into `+M`.

**Scope semantics.** The group strip is the **section scope** — it narrows the queue, the status-tab counts, the section totals, and the camera palette's roster. The camera filter is the finer cut inside it and still touches none of those. Selecting a group that excludes a currently-filtered camera **drops that camera from the camera filter** and says so in a 22px `bad`-toned notice above the list for 4 seconds: `.190 is not in this group — dropped from the filter.` The MRU list keeps the entry (hidden while out of scope) so switching back restores the bar unchanged.

**Edge cases.** One group → the strip shows `All groups` + that group; harmless and honest. Zero groups configured → the strip is omitted entirely, not rendered empty. A group with no events in the active tab renders in the zero state and stays clickable, exactly like an octet chip.

---

## 3 · Interaction spec

**Select (exclusive).** Click a chip → that camera only. Click an active chip → clears it. In the palette, `Enter` (or double-click a row) → that camera only, palette closes.

**Multi-select (additive).** Click a palette row body or its checkbox → toggles that camera in the selection; palette stays open. `Space` does the same from the keyboard. Selection is an **OR** across cameras. Chips of every selected camera render active.

**Clear.** Any of: the `✕ All` chip · the ribbon's `✕ Clear` · the palette footer's `Clear` · `Backspace` in an empty search field · clicking the last active chip.

**Search.** Matches, in rank order: exact octet · octet prefix · octet substring · camera-name substring · group-name substring. Digits-only input is treated as an octet query first. Case- and language-insensitive.

**Keyboard.**

| key | context | action |
|---|---|---|
| `0`–`9` | queue focused, no text field | **open palette, seed search with the digit** |
| `F` | queue focused | open palette, empty search |
| `Esc` | palette open | close, selection unchanged |
| `↑` `↓` | palette open | move cursor (wraps; auto-scrolls) |
| `Enter` | palette open | exclusive-select cursor row (or top hit if the cursor hasn't moved) + close |
| `Space` | palette open | toggle cursor row, stay open |
| `Backspace` | palette open, empty field | clear the whole selection |
| `E` | palette open | **types "e" into the field — never acknowledges.** Acknowledge resumes when the palette closes. |
| `Ctrl-K` | anywhere | untouched, global search |

`Space` **never enters the search field** — it always toggles the cursor row. Search never needs a space character: octets have none, and name matching is per-token (`ds-i259` and `снаружи` both match without one).

**MRU list.** Selecting a camera — from a chip, a palette row, `Enter` or `Space` — puts it in the list. It enters at **slot 1** and pushes the others right; if the list is over capacity the **least recently used** entry falls off the end (which is not necessarily the rightmost). Re-selecting a camera already in the list refreshes its recency but **does not move its chip**. Deselecting does not change the list. Capacity **3**, matching the bar's budget (§2.2b).

**Seeding.** On first use per user+site the list is seeded with the three busiest cameras in the Open queue at that moment, so day one is one-click for the cameras that matter.

**Persistence across status-tab switches:**

| thing | behaviour |
|---|---|
| MRU list | persists — across tabs, group changes, restarts. Entries outside the active group scope are **hidden, not dropped**; switching back restores them in place. |
| selection | **persists** across tab switches. Filter .146, switch Open → Critical: still .146, counts recompute, and if .146 has none in Critical the list shows the honest empty state naming it. Predictable beats convenient. |
| search string | discarded on close |
| cursor | resets to the top row on open |
| counts | recomputed live per tab and as events arrive |

**Scope.** The filter is queue-local: it never touches the status-tab pills, the section totals (`130 OPEN · 3 CRITICAL · 0 CLEARED`), the group dropdown, or the other three sub-views. Changing the **group** dropdown narrows the palette roster; any selected camera outside the new group is dropped from the selection and the ribbon says so for 4 seconds: `.190 is not in this group`.

**Empty state.** When the filter zeroes the list, the existing centred `ink3` empty state **names the filter**: `No events match .146 in Open queue.` with a 10px `Clear filter` ghost button 12px below it.

---

## 4 · Active-filter indication when the picker is closed

Four simultaneous, redundant signals — the guard cannot miss it from any resting eye position:

1. **Chips** — every selected camera's chip is amber (accentSoft fill, accent border and text) in the bar; a selection beyond the 3 MRU slots appears as a `+N ✕` chip.
2. **`All` → `✕ All`** — amber-outlined, the obvious reset.
3. **Palette button** — turns amber and swaps its number from *hidden cameras* to *selected cameras*.
4. **Ribbon** — sticky amber strip at the top of the list, carrying the filtered event count, the camera names, and `✕ Clear`.

---

## 5 · Edge cases

| case | behaviour |
|---|---|
| **1 camera in the fleet** | Bar: `All` + its chip + `⌕ ▾` (no number, still at the right edge — position stays learnable). Palette lists the single row. |
| **80+ cameras** | Bar is unchanged — 3 MRU chips and `⌕ 77 ▾`. Palette uses a virtualised list (QML `ListView` is already lazy); dividers keep recent / busiest / zero separated; search is the primary path. Bar width does not grow with fleet size, ever. |
| **All 130 events on one camera** | Seeding produces **one** MRU entry, not three placeholders. Bar: `All  .144 130  ⌕ 21 ▾`. Ribbon on select: `130 events · .144`. |
| **Zero events in the whole tab** | Every chip is in the zero state; the palette shows only the `NO EVENTS IN THIS TAB` section; the list shows its normal "Queue clear" state. Nothing is hidden. |
| **Russian** | Only 4 strings translate (§6); the chips, counts and palette button are digits and glyphs. Longest RU control is the search placeholder, which is a flexible field. No layout changes. |
| **1200px window** | Left column is fixed 384px → right pane = 1200 − 72 nav − 384 = **744px**, above the 700px 16:9 floor. Palette (368px) fits inside the column. Below ~1120px the right pane breaches the floor for reasons unrelated to this filter — flagged, not solved here. |
| **900px height** | See §7 — 9 rows visible idle, 8 with the ribbon showing. Contract met. |
| **Duplicate octets across two sites** | Ready but off until multi-site lands: chip label gains a site letter as a 9px `ink3` prefix — `A·.146` — and the palette groups rows under site dividers. Detection is automatic: prefix appears only for octets that actually collide. |
| **Camera offline mid-shift** | Its historical events stay in the queue and its count is unchanged (honesty: the events happened). The palette row shows a 5px `bad` dot before the octet. |
| **New camera appears while the palette is open** | Row inserts in place; the cursor stays on the same camera, not the same index. |
| **Selected camera drops to 0 as events are handled** | Chip goes zero-state but **stays selected**; the ribbon reads `0 events · .146` and the list shows the honest empty state. The filter never silently self-clears. |

---

## 6 · Strings

| id | EN | RU | note |
|---|---|---|---|
| `filter.all` | `All` | `Все` | chip |
| `filter.clearAll` | `✕ All` | `✕ Все` | chip, filter active |
| `filter.search.ph` | `Octet or camera name…` | `Октет или имя камеры…` | flexible field |
| `filter.scope` | `{n} CAMERAS · {tab} · {group}` | `{n} КАМЕР · {tab} · {group}` | mono 9px caps |
| `filter.recent` | `RECENT` | `НЕДАВНИЕ` | divider |
| `filter.busiest` | `BUSIEST` | `САМЫЕ АКТИВНЫЕ` | divider |
| `filter.zero` | `NO EVENTS IN THIS TAB` | `НЕТ СОБЫТИЙ В ЭТОЙ ВКЛАДКЕ` | divider, wraps to 2 lines in RU → divider height auto |
| `filter.hint` | `Enter = only this · Space = add` | `Enter = только эта · Space = добавить` | footer, mono 10px |
| `filter.selected` | `{n} selected` | `Выбрано: {n}` | footer |
| `filter.clear` | `Clear` | `Сбросить` | footer + ribbon |
| `filter.cameras` | `{n} camera` / `{n} cameras` | `{n} камера / камеры / камер` | ribbon only — the collapsed chip is the wordless `+N ✕` |
| `filter.events` | `{n} event` / `{n} events` | `{n} событие / события / событий` | ribbon |
| `filter.none` | `No camera matches "{q}".` | `Нет камеры по запросу «{q}».` | palette |
| `filter.empty` | `No events match {list} in {tab}.` | `Нет событий: {list}, {tab}.` | list empty state |
| `group.all` | `All groups` | `Все группы` | group strip |
| `group.notIn` | `{list} is not in this group — dropped from the filter.` | `{list} не в этой группе — убрана из фильтра.` | transient notice |

The two dividers that can wrap in Russian (`filter.zero`) get `height: auto` with `padding: 4px 12px`; everything else is fixed-height and digit-based.

**Plurals.** Every count-bearing string needs plural forms, including `1`. English takes two (`1 event` / `2 events`). Russian takes three, selected by the standard rule — `n % 100` in 11–14 → *genitive plural*; else `n % 10 === 1` → *nominative singular*, `2–4` → *genitive singular*, otherwise *genitive plural*. Do not hand-build `n + " событий"`.

---

## 7 · Height budget proof (900px window)

```
OS title bar                 32
app top bar                  64
tab strip                    36
events sub-nav + rationale   58
─────────────────────────── 190
status tabs                  45
octet bar                    36   ← was 36. No change.
─────────────────────────── 271
list area = 900 − 271 =     629px  → 629 / 67 = 9.3 rows   ✓ idle
with ribbon = 629 − 22 =    607px  → 607 / 67 = 9.0 rows   ✓ filtered
```

Contract requires ≥8. Met with a row to spare in both states. The 384px column width is unchanged; no widening requested.

---

## 8 · QML build notes

Everything here is rectangles, text and `ListView` — no OS widgets, no popups that escape the window.

- **Octet bar** — `RowLayout` inside a 36px `Rectangle`. Chips are `Rectangle` + `Text` + `MouseArea`; `Item { Layout.fillWidth: true }` is the spacer. Drive the fit ladder off the real measurement — `onImplicitWidthChanged: if (contentRow.implicitWidth > bar.width - 24 && lvl < 3) lvl++`, resetting `lvl = 0` on `bar.onWidthChanged` and whenever the selection, MRU list, tab, locale or window width change. Never off `session.length`.
- **Palette** — a `Rectangle` child of the queue column with `z: 10`, shown/hidden by `visible`; **not** a `Popup`/`Window`, so it cannot land off-screen or steal the window's focus chain. Its inner list is a `ListView` over a `SortFilterProxyModel` (or a QML-side sorted `ListModel`) — lazily delegated, so 80 or 800 rows cost the same.
- **Digit hotkey** — a `Keys.onPressed` on the queue column; guard with `if (!searchField.activeFocus && event.text.match(/[0-9]/))`. Because the palette's field takes focus on open, no further shielding of `E` is needed.
- **Counts** — derive from the same in-memory event model the tabs use; bind, don't copy, so "counts are live" comes free.
- **MRU** — three octets in `QSettings` keyed by user+site, plus a parallel `{octet: useCounter}` map for eviction. Seeding is a one-shot write guarded by a `mruSeeded` bool **and must stamp descending counters onto the seeds** so the first eviction is correct. Display order is the stored array; **never re-sort it on re-use.**
- **Group strip** — `RowLayout` in the sub-nav with `Layout.fillWidth: true` and `clip: true`. **Do not** build it as a reset-and-decrement loop: compute `visibleGroups` in one pass from the chips' `implicitWidth`s against the band width (see §2.6), recomputed on `onWidthChanged` and on any count/locale change. The `+M` panel is a `Rectangle` child of the sub-nav (`z: 30`), anchored by the button's `x`, never a `Popup`.
- **Tooltips** — `ToolTip { delay: 500 }` with the design's own styling (`panel3` fill, 1px `line2`, mono 10px `ink2`), not the platform default.

---

## 9 · Acceptance checklist

- [ ] Octet bar is **36px** and never scrolls, clips, or reorders.
- [ ] `All` · 3 MRU chips (newest leftmost) · session chip · spacer · `⌕ N ▾` welded right.
- [ ] Chip states idle / hover / active / zero / active+zero match §2.2; **zero chips remain clickable**.
- [ ] Typing a digit in the queue opens the palette seeded with that digit; `146` `Enter` → .146-only queue.
- [ ] `F` opens · `Esc` closes without change · `↑↓` cursor · `Enter` exclusive · `Space` toggles · `Backspace` on empty field clears.
- [ ] `E` does not acknowledge while the palette is open; `Ctrl-K` is untouched.
- [ ] Palette: search field autofocused, scope line, RECENT / BUSIEST / NO EVENTS sections, 34px rows with checkbox, octet, full name, live count.
- [ ] Selecting a camera puts it at MRU slot 1 with a 500ms entry flash; re-selecting one already on the bar **does not move it**; eviction is least-recently-used, and the **first** eviction of a fresh session drops the stalest seed, not the busiest.
- [ ] Both fit ladders remeasure on **element width change** (drag-resize), not only on state change — and the group strip **regains** chips when the window widens, not just sheds them when it narrows.
- [ ] Zero-count cameras are listed with a visible `0` and select into the honest named empty state.
- [ ] Multi-select ORs cameras; the **fit ladder** (§2.2b) runs off measured width — L1 collapse to `+N ✕`, L2 bare `✕`, L3 pins drop counts — never off a hard count.
- [ ] Bar content never exceeds the 359px track in any language at any count magnitude; the clip guard never fires.
- [ ] Ribbon appears only when filtered, is sticky, names the filter, carries the filtered count, offers `✕ Clear`.
- [ ] Pins persist across tabs and restarts; selection persists across tab switches; counts recompute per tab.
- [ ] Group strip replaces the dropdown: `All groups` + one chip per group, measured fit, `+M ▾` panel for the remainder, counts per active tab.
- [ ] The **active group is always a named, visible chip** — never represented only by `+M ▾`.
- [ ] Group scope narrows queue + tab counts + section totals + palette roster; out-of-scope selected cameras are dropped with the 4s notice; MRU entries survive hidden.
- [ ] Tab pills, section totals, group strip and the other three sub-views are unaffected **by the camera filter**.
- [ ] Empty state names the filter and the tab; nothing ever goes silently blank.
- [ ] Correct in Russian with no layout change, **with correct 1 / 2–4 / 5+ plural forms**; correct at 1200×900 and 1440×900; ≥8 rows visible in both states.
