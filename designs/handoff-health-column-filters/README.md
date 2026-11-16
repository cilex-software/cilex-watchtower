# Health screen — column filters (Excel-style) · handoff

Drop this folder into the repo at `designs/handoff-health-column-filters/`.

| file | what it is |
|---|---|
| `IMPLEMENTATION_PROMPT.md` | **the prompt to run**: scope, build order, traps, done-when |
| `2026-11-16-health-column-filters-spec.md` | **the spec**: anatomy, every px/hex/type value, states, filter semantics, RU copy |
| `prototype/Health Screen.dc.html` | **the reference build**: open in Chrome, every behaviour is live |
| `prototype/support.js`, `prototype/assets/` | needed by the prototype (runtime, logo, fonts) |
| `reference/health-current.jpeg` | screenshot of the current Health screen (baseline) |

## What the change is

The Health table gets Excel-style filter dropdowns on five headers: **Camera, Group, Live, Recording, Recent issue**. Last seen and the action column get no filter. Nothing else on the screen changes. There is no new toolbar, no chips row, and no change to the metric cards, the detail panel or the shell.

## About the prototype

The prototype is an HTML **drawing** of the QML screen. It is not code to port. Everything outside the filter feature was recreated from `qml/HealthScreen.qml`, `TopBar.qml`, `NavRail.qml`, `TitleBar.qml`, `StatusBadge.qml`, `LiveStatusBadge.qml`, `RecordingStatusBadge.qml`, `PlaceholderVid.qml`, `EmptyState.qml` and `Theme.qml`, so treat the repo as the truth for those parts. The camera data in the prototype is invented (133 cameras whose counts match the reference screenshot). Fidelity is **high**: final tokens, sizes and behaviour.

Opening the prototype: serve the `prototype/` folder over HTTP (`python3 -m http.server` in that folder), then open `http://localhost:8000/Health%20Screen.dc.html`. It is laid out for at least 1520 px of window width. Its Tweaks panel has three switches that were used to explore options. **Ship the defaults**: Instant apply, icons Always, counts On.
