# Health · column filters — spec

All sizes are logical px (the same units as `Theme.qml`). All colours are `Theme` tokens. Hex values are given for cross-checking only.

## 1. Scope

Filterable columns: **Camera, Group, Live, Recording, Recent issue**.
Not filterable: Last seen, the unlabelled action column.

The column filters combine (AND) with the active metric card (`activeFilter`) and with each other. The metric cards, the `page()` call, the detail panel, the subsystem strip, the availability row and the shell stay unchanged.

## 2. Filter keys (what a "value" is)

Each column filters on a **category key**, not on literal row text. Literal text varies over time (badge ages), and filtering on it would produce dozens of one-row values.

| column | key | list shows | sort order |
|---|---|---|---|
| Camera | `camId` (unique) | name (sans 12 ink) + camId (mono 10 ink3), gap 8 | the table's own order (status, then name) |
| Group | `groupName`; empty → `""` shown as `— (no group)` | group name, sans 12 ink | locale-aware A→Z (`localeCompare`), empty last |
| Live | live state label | `LiveStatusBadge` for that state | OFFLINE, NO SIGNAL, DEGRADED, LOADING, NO ACCESS, UNKNOWN, LIVE |
| Recording | recording **category** (below) | `RecordingStatusBadge`-styled badge with the category label | REC STOPPED, ARMED · NOT READY, ARCHIVE DELAY, ARMED · ARCHIVE DELAY, REC ?, ARMED · no motion, ARMED, REC, OFF |
| Recent issue | `issueText(cam)` | text in `issueColor(cam)`; `—` shown as `— (none shown)` in ink3 | No signal, Recording stopped, Motion detector not ready, Archive delayed, Archive unavailable, Status unknown, Stream degraded, — |

**Recording categories.** Use the same decision tree as `RecordingStatusBadge.label` (the tier-2 path), with the informational qualifiers collapsed:

- `OFF`, `REC STOPPED`, `ARCHIVE DELAY`, `REC`, `REC ?` stay as they are.
- `ARMED · NOT READY` (`_deafArmed`) and `ARMED · ARCHIVE DELAY` (`_notRecording`) stay as separate categories, because they are fault qualifiers.
- `ARMED · no motion ever` and `ARMED · silent Nd` become **`ARMED · no motion`** (amber, hollow).
- `ARMED` and `ARMED · <age>` become **`ARMED`**.

Put this logic in **one** JS function (for example `recCategory(cam, health)` in `GroupsStatus.js` or a new small `.js`). Both the filter and, ideally, the badge read from it, so the two cannot drift apart. The badge's colours and hollow/solid dot per category are the same as in the table.

Only show values that exist. A key appears in a dropdown only if at least one row has it (see cascading in §5).

## 3. Header trigger

Applies to the five filterable header cells. The `Th` text becomes a clickable trigger.

- Row: label + icon, gap **5**, height **24**, horizontal padding **6**, **left margin −6**, so the label text stays exactly aligned with the column's row content.
- Label: unchanged `Th` style (mono 10, DemiBold, letter-spacing 1.2, all caps).
- Icon: `chev`, **10 px**, stroke reads ~2 units in the 24 box (add a `w: 2` variant if 1.5 is too faint at 10 px).
- States:
  - **Idle**: label and icon `ink3` (#6e6657), transparent background.
  - **Hover**: background `panel` (#221f1c).
  - **Open** (its dropdown is showing): background `panel`, label `ink` (#f0ece4).
  - **Filtered**: label `accent` (#e8a13a); the icon becomes a **filled funnel**, 11 px, `accent`. Add an icon entry `funnelFill` = the `funnel` path with `f: true`.
- Whole trigger is the hit area, with a pointing-hand cursor.

**Camera header readout.** While any column filter is active, show `N of M` 10 px to the right of the Camera trigger. Style: mono 10, Medium, letter-spacing 0, normal case, `ink2` (#a89f90). N = rows shown. M = rows after the metric card only (the `page()` result). RU: `N из M`.

**Clear all.** While any column filter is active, the empty action-column header (72 px) shows a trigger: `x` icon 10 px + `CLEAR` (same `Th` type), in `accent`, with the same trigger geometry. Tooltip: "Clear all column filters". It clears all five filters and closes any open dropdown. In RU (`СБРОСИТЬ`), if the label does not fit in 72 px, drop the label and keep the icon with its tooltip. Do not let it spill into the Recent issue column.

## 4. Dropdown

Use `QC.Popup` with `padding: 0` and `background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }`, the same construction as `TopBar` `userMenu` and `WatchChip`. Square corners. **No shadow**; the prototype has one, but the repo's popups do not.

- **Position**: top edge = header bottom − 1 (it overlaps the header's bottom hairline). Left edge = trigger's left edge, clamped to stay 8 px inside the table area (it must never run under the detail panel).
- **Width**: Camera **300**, Group **240**, Live **220**, Recording **270**, Recent issue **260**.
- **Search** (Camera and Group only):
  - Wrapper padding 8 / 8 / 4 (top / sides / bottom).
  - Field: height 30, background `bg` (#1a1816), 1 px `line2` border; the border is `accent` while focused.
  - Inside the field: `search` icon 13 px `ink3` at left padding 9, gap 8; text sans 12 `ink`.
  - Placeholder `ink3`: "Search names or IDs…" (Camera) / "Search groups…" (Group).
  - When the query is non-empty, show a key hint at the right: box height 18, padding 0 5, 1 px `line2`, mono 9 `ink3`, `ENTER`. Tooltip: "Show only matching values".
  - Camera search matches name **or** camId, case-insensitive substring.
  - The field gets focus when the dropdown opens.
- **Select all row**:
  - Height 30, margin-top 2, padding 0 10, gap 10: checkbox, then label sans 12 Medium `ink`, then the total count right-aligned (mono 10 `ink3`).
  - Label is "Select all", or "Select all results (N)" while searching. The total is hidden while searching.
  - Checkbox is tri-state over the **listed** values: all, none, or mixed.
  - Click: if all listed values are checked, uncheck them all; otherwise check them all.
- Divider: 1 px `line`, margin 2 above and below.
- **Value list**:
  - Max height **300**, then it scrolls. Padding 2 top, 4 bottom.
  - Row: height **28**, padding 0 10, gap 10, hover background `panel2` (#2a2722). A click anywhere on the row toggles the value.
  - Content opacity is **0.6** when the value is unchecked.
  - Right side: count (mono 10 `ink3`, min-width 18, right-aligned). Camera rows show the camId instead, so they have no count.
  - **On row hover the count is replaced by an `Only` button**:
    - Height 20, padding 0 6, 1 px `accentDim` (#5a3f15) border, sans 11 Medium `accent`.
    - Hover: background `accentDim`, text `ink`.
    - Click selects just that value (it does not toggle the row).
  - Search with no matches: "No values match “q”." in sans 12 `ink3`, padding 10 / 10 / 8 (top / sides / bottom).
- **Checkbox**:
  - 14×14, 1 px border, square.
  - Unchecked: `line2` border, transparent fill.
  - Checked: `accent` fill and border, plus a `check` glyph 10 px in `bg` colour with a heavy stroke (~3.2 in the 24 box).
  - Mixed: `accent` fill with an 8×2 bar in `bg` colour.
- **Footer**:
  - Height 40, 1 px `line` top border, padding 0 8, gap 6.
  - Left: **Clear filter**, a ghost button (height 24, padding 0 8, hover `panel2`) holding a funnel-x icon 11 px (path `M4 5h16l-6 7v6l-4-2v-4z M15 15l5 5 M20 15l-5 5`) and sans 11 Medium `ink2`. When there is nothing to clear it is `ink3` and inert. It clears this column's filter and closes the dropdown.
  - Right: **Done**, a small outlined button (height 24, padding 0 10, 1 px `line2`, `bg` fill, sans 11 Medium `ink`; hover `panel` fill with `accent` border). It closes the dropdown.

## 5. Semantics

- **Filter state**: `filters = { camera, group, live, rec, issue }`. Each entry is `null` (no filter) or the array of **included** keys, as in Excel.
- **Apply mode: instant.** Every checkbox change applies to the table immediately. "Done" only closes the dropdown. If the selection grows to cover every key currently known for the column, store `null`.
- **Empty selection is allowed.** The table then shows the empty state (§6). The header stays amber.
- **Cascading values and counts**:
  - The list for column X shows the keys present in rows that pass the metric card **and every other column filter** (X's own filter is ignored).
  - Counts are computed over that same set.
  - A checked key that is no longer present stays checked but hidden.
- **Search + Enter**: sets the filter to exactly the values that match the query, then closes the dropdown (Excel's "only search results").
- **Esc** closes the dropdown. A click outside closes it.
- **Only one dropdown is open at a time.** Clicking the open trigger again closes it.
- **Metric cards**: unchanged, and they AND with column filters. Clicking a card still clears `sel` but does **not** clear column filters; VISIBLE resets only the metric.
- **Selection / detail panel**: a column-filter change does not clear `sel`. If the selected camera is filtered out, the panel stays open (this matches the existing "selected row may be off-screen" rule).
- **Lifetime**: the filters live in `HealthScreen`. They survive switching sections (the screen is hidden, not destroyed). They are not persisted across restarts.

## 6. Empty state

Same `EmptyState` (check icon, "Nothing here", "No cameras match this filter."). When any column filter is active, set `actionLabel: "Clear column filters"`; its action clears all column filters.

## 7. Honesty rules (from the existing screen)

- `—` in Recent issue means *no issue was derived*. It is not a certification. Label it `— (none shown)` in the list, never "OK", "Healthy" or "No issue".
- Keep the colour **and** the text label on every badge in the dropdown, as in the table.
- `N of M` must always be visible while a column filter is active, so a narrowed table can never pass for the whole fleet.
- **Known product decision (flag it, don't silently change it)**: inclusion semantics mean that a key appearing for the first time in a background update (for example a camera turning `NO SIGNAL` while Live is filtered to `OFFLINE`) is hidden until the operator re-opens the filter. The `N of M` readout makes this visible. An exclusion-based alternative is possible if the operator wants it.

## 8. Copy (EN → RU)

Reuse existing translations from `i18n/watchtower_ru.ts` wherever the string already exists (badge labels, "Nothing here", "No cameras match this filter.").

| EN | RU |
|---|---|
| Select all | Выбрать все |
| Select all results (%1) | Выбрать все результаты (%1) |
| Search names or IDs… | Поиск по имени или ID… |
| Search groups… | Поиск групп… |
| Only | Только |
| Show only this value | Показать только это значение |
| Show only matching values | Показать только совпадения |
| Clear filter | Сбросить фильтр |
| Done | Готово |
| Clear | Сбросить |
| Clear all column filters | Сбросить все фильтры столбцов |
| Clear column filters | Сбросить фильтры столбцов |
| %1 of %2 | %1 из %2 |
| — (none shown) | — (не указано) |
| — (no group) | — (без группы) |
| No values match “%1”. | Нет совпадений для «%1». |
| ARMED · no motion | ARMED · нет движения (match the existing badge style) |

## 9. Tokens used

`bg` #1a1816 · `panel` #221f1c · `panel2` #2a2722 · `line` #34302a · `line2` #443f37 · `ink` #f0ece4 · `ink2` #a89f90 · `ink3` #6e6657 · `accent` #e8a13a · `accentDim` #5a3f15. Badge colours come from the existing badge components.

Fonts: Space Grotesk (labels, buttons, values), JetBrains Mono (headers, ids, counts, key hints). Radius 0 everywhere.
