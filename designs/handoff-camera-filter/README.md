# Triage Queue — camera filter redesign · implementation handoff

**Decision: build variant B ("Lanes").** Variant A is included for reference only — do not build it.

| file | what it is |
|---|---|
| `2026-08-06-triage-camera-filter-variant-b-lanes.md` | **the spec to build** — anatomy, sizes, tokens, interaction, edge cases |
| `triage-camera-filter-prototype-B-lanes.html` | **the reference build** — open in a browser; every behaviour below is live in it |
| `tweaks-panel.jsx` | required by the prototype (density / language / window controls) |
| `2026-08-06-triage-camera-filter-spec.md` | variant A, the rejected alternative. Reference only. Its §2.6 group-strip spec **does apply** — B uses the same control. |
| `source-brief.md` | the original brief: product context, exact tokens, current-state anatomy |

Open the prototype and use it before writing code. The A/B switch is top-left; density, language, window width and group count are in the Tweaks panel.

---

## The implementation prompt

Paste the block below into the Claude Code console from the repo root, with this folder dropped in at `designs/`.

---

Build the **Triage Queue camera filter redesign, variant B ("Lanes")** into the Qt6/QML Watchtower client.

**Source of truth**, in this order:
1. `designs/handoff-camera-filter/2026-08-06-triage-camera-filter-variant-b-lanes.md` — the spec. Every size, token and state is in here.
2. `designs/handoff-camera-filter/triage-camera-filter-prototype-B-lanes.html` — the working reference. When the spec is ambiguous, match the prototype's behaviour.
3. `designs/handoff-camera-filter/source-brief.md` — product context and the exact colour/type tokens.
4. `designs/handoff-camera-filter/2026-08-06-triage-camera-filter-spec.md` **§2.6 only** — the group segmented control, which variant B reuses unchanged. Ignore the rest of that file.

The prototype is React/HTML **as a drawing, not as an architecture**. Translate to native QML: `Rectangle` + `Text` + `MouseArea` + `ListView`. No `Popup`, no OS-native widgets, no web views. Lift exact px, hex and type from the spec — do not re-derive or "improve" spacing.

### What changes

The Triage Queue's left column loses its camera chip row entirely and the flat event list becomes **camera lanes**: events grouped by camera under 26px sticky headers, where the header *is* the filter. Rows drop from 67px to 44px because the camera name moves out of every row and into its lane header. Net effect at a 130-event morning: 14.5 rows visible instead of 9.3, and zero pixels spent on filter chrome.

### Build order

1. **Lane model + list.** `ListView` of lanes; each lane = sticky header + its events. Lanes sort busiest-first; events sort priority-then-recency *within* a lane. Row 44px (density-configurable 48/44/36), header 26px.
2. **Lane header.** Caret, octet, offline dot, model name, severity-mix bar, count. Solo / mute / fold states.
3. **Solo interaction.** Click = solo, ctrl/⌘-click = add, alt-click = fold, Esc = clear. Scope readout in the status-tab row.
4. **Digit type-ahead** + echo chip.
5. **Zero-count strip** at the bottom of the list.
6. **Group segmented control** (variant A spec §2.6) replacing the `All groups` dropdown.
7. **Density pass** on the surrounding chrome: top bar 52, tab strip 30, sub-nav 38, merged 40px detail control bar, 3-col facts grid, video stage capped at 372px.

### Traps — every one of these was hit and fixed while prototyping. Do not rediscover them.

- **Soloing must never remove other lanes from the list.** Collapse them to header-only at 60% opacity. Removing them kills ctrl-click multi-select (there is no second header left to click) and destroys the roster index that makes lanes work as a filter.
- **Never scroll to a soloed lane.** Sort soloed lanes to the top instead. A scroll computed before the other lanes collapse is measured against a layout that no longer exists, and at 80 cameras it lands arbitrarily. Positional, not scroll-based.
- **Type-ahead commits only on an unambiguous prefix, or at the third digit.** `14` matches five cameras; jumping to `.140` when the guard is typing `.146` is worse than waiting a keystroke. Show the remaining match count in the echo chip.
- **The octet is one text run** — `"." + octet`. If the `.` is a separate item in a spaced row it renders as `. 144`. This is the single most important label on the screen.
- **The group control's fit is a computed value, not a converging loop.** Read each cell's intrinsic width once, walk the cumulative sum against the band width reserving the `+M` cell, write the answer in one assignment. Reset-then-decrement needs a repaint per step and silently no-ops when the reset writes the value it already holds.
- **Recompute that fit on element width change** (`onWidthChanged`), not only on state change. A drag-resize produces no state change, and the strip will sit clipped with its own overflow control drawn outside the clip.
- **The active group is always promoted into the visible run** and the visible count floors at 1. A group scoping the whole section while being represented only by an unlabelled `+2 ▾` is an honesty violation, and worse than the dropdown it replaces.
- **Russian needs three plural forms** (1 / 2–4 / 5+) for every count-bearing string. Do not hand-build `n + " событий"`.
- **Muted lane headers bottom out at 60% opacity** — below that the 12px octet drops under 4.5:1 contrast.

### Non-negotiables from the brief

- **Honesty:** no silent blanks. A soloed camera with no events shows the inline `No events on .146 in Open queue.`; cameras with zero events in the tab appear in the zero strip, never vanish.
- Dark theme only, tokens from the brief's §2, **square corners**, hairline borders, no shadows.
- Every label works in English and Russian; Russian runs ~30% longer.
- `E` (acknowledge) and `Ctrl-K` (global search) stay untouched. Variant B has no text field, so digits are free.
- 1440×900 default, resizable and often smaller; at 1200px the left column stays 384px and the detail pane must clear a 16:9 player at ~700px.

### Done when

Every box in the spec's §6 edge-case table and this checklist passes at 1440×900 **and** 1200×900, in **both** languages:

- Lanes render at the stated geometry; 14+ rows visible at default density.
- Solo, ctrl-click multi, alt-fold, Esc, and the scope readout all behave as in the prototype.
- Typing `146` solos `.146` with it as the first lane on screen, in three keystrokes, with no panel.
- All lane headers stay on screen while soloed.
- Group control: measured fit, `+M ▾` panel, active group always named, recomputes on resize.
- Nothing goes blank; every empty state names its filter and its tab.
