# Implementation prompt — Health column filters

Build **Excel-style column filters** on the Health screen's camera table in the Qt6/QML Watchtower client.

## Source of truth (in this order)

1. `designs/handoff-health-column-filters/2026-11-16-health-column-filters-spec.md`. Every size, token, state, filter rule and RU string is in it.
2. `designs/handoff-health-column-filters/prototype/Health Screen.dc.html`, the working reference. Serve `prototype/` over HTTP and open it in Chrome. Where the spec is ambiguous, match the prototype's behaviour (ship the defaults: Instant apply, icons Always, counts On).
3. `qml/HealthScreen.qml` and its components, which are the truth for everything that is *not* the filter feature. Do not restyle anything else.

The prototype is HTML **as a drawing, not as an architecture**. Translate it into native QML built from `Rectangle` + `Text` + `MouseArea` + `ListView`, plus `QC.Popup` built the same way as `TopBar.userMenu` and `WatchChip`. Lift exact px, hex and type values from the spec.

## What changes

The table header's five cells (Camera, Group, Live, Recording, Recent issue) become dropdown triggers. Each opens a checklist of that column's values with counts, tri-state "Select all", an "Only" shortcut on hover, search (Camera and Group), "Clear filter" and "Done". The Camera header shows `N of M` while a filter is active. The empty action-column header shows `CLEAR`, which clears all filters. Nothing else on the screen changes: no new toolbar, and no change to metric cards, detail panel, strips or shell.

## Build order

1. **Category functions.** Write a single JS source for each column's filter key (spec §2):
   - `liveKey(cam)`
   - `recCategory(cam, health)`, which mirrors `RecordingStatusBadge.label` with the age and silent qualifiers collapsed
   - `issueKey(cam)` = `issueText(cam)`
   - `groupKey(cam)`
   - `camId`

   Have the Recording badge read `recCategory` too if you can, so the filter and the badge cannot drift apart.
2. **Filter state + derived rows.**
   - Add `property var colFilters` (five entries, each `null` or an array of keys).
   - Derive `viewRows` from `_rows` by AND-ing the filters.
   - Point the `ListView` at `viewRows`.
   - Keep the `_rowsSig` trick: reassign `viewRows` only when its content actually changed (include the filter state in the signature), so the 15-second poll does not reset the scroll position.
3. **Header triggers** (spec §3): idle, hover, open and filtered states; `funnelFill` icon; `N of M` readout; `CLEAR` in the action header.
4. **Dropdown** (spec §4): position and clamp, per-column widths, search with focus on open, Select all tri-state, 28 px rows, checkbox, Only on hover, counts, no-match line, footer.
5. **Semantics** (spec §5):
   - instant apply; `null` when everything is selected
   - cascading lists and counts
   - Enter = keep only matches
   - Esc and click-outside close; one dropdown at a time
   - metric cards AND with the filters and do not clear them
6. **Empty state action** "Clear column filters" (spec §6).
7. **i18n.** Every new string goes through `qsTr`. Add the RU entries from spec §8 to `i18n/watchtower_ru.ts`, reusing the existing badge translations.

## Traps

- **Never filter on literal badge text.** `ARMED · 4m`, `ARMED · 2h` and `ARMED · silent 3d` change every 30 s and would create a new one-row "value" each time. Filter on the category.
- **Do not lose the scroll position.** Filtering must not create a fresh array on every `countsChanged` or `healthRevChanged`. Same lesson as `_refreshRows`.
- **Use `camId` as the Camera key, not `name`.** Names are not guaranteed unique.
- **`—` is not "healthy".** In the Recent issue list it reads `— (none shown)`, never "No issue" or "OK".
- **Keep the column alignment.** The trigger uses a −6 px left margin so the header label stays exactly over the row content. Check this at the Live (110 px) and Recording (170 px) columns.
- **The dropdown must not run under the 380 px detail panel.** Clamp it to the table area.
- **RU `СБРОСИТЬ` may not fit in 72 px.** Drop to icon + tooltip rather than overflow into Recent issue.
- **Cyrillic needs a fallback.** Space Grotesk has no Cyrillic glyphs, so check that the dropdown's text inherits the same fallback as the table rows (the prototype's first draft fell back to a serif).

## Done when

- [ ] All five triggers show idle, hover, open and filtered states exactly as in the spec; labels stay aligned with their columns.
- [ ] Unchecking a value updates the table immediately; re-checking everything returns the column to "no filter" (header back to ink3 with the chevron).
- [ ] Counts cascade: with Live = OFFLINE, the Group list shows only `4стр` (2) on the pilot-like data.
- [ ] Camera search matches names and IDs; Enter keeps only the matches; `N of M` is correct.
- [ ] `Only` selects a single value; Select all is tri-state and acts on search results while searching.
- [ ] Esc, click-outside, Done and Clear filter all behave as specified; only one dropdown opens at a time.
- [ ] Metric cards and column filters combine; clicking a card keeps the column filters.
- [ ] An empty result shows "Nothing here" plus "Clear column filters".
- [ ] Scroll position survives at least two background polls with a filter active.
- [ ] Verified at 1440×900 and 1200×900 (detail panel open and closed), in **EN and RU**, with screenshots.
