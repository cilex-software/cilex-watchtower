# Wall playback — redesign · implementation handoff

**Decision: build "Roll Call".** A cell that recorded nothing stops apologising and starts navigating: it renders the fact, and the nearest moment that camera *did* record, as a clickable offer that seeks the whole wall there.

| file | what it is |
|---|---|
| `2026-08-10-wall-playback-spec.md` | **the spec to build** — anatomy, sizes, states, interactions, keyboard, edge cases |
| `wall-playback-prototype.html` | **the reference build** — open in a browser; every behaviour is live |
| `wall-playback-core.jsx` · `wall-playback-parts.jsx` · `tweaks-panel.jsx` | required by the prototype |
| `source-brief.md` | the original brief |
| `reference-one-axis-spec.md` | the shipped single-camera Playback redesign — the sibling screen, and the source of the window-model, letterbox-fit and scrubber-hierarchy rules. Reference only. |
| `reference-groups-wall-spec.md` | the shipped Groups redesign — gapless cells, inset rings, growable-child rule. Reference only. |

Open the prototype before writing code. Tweaks: **archive** (ribbon / calendar — the two tier-1 presentations, carried over from One Axis), **cameras** (4 / 14 / 16), **lit cells** (sparse / typical / busy — typical gives the brief's 3–4 of 16), **motion** (quiet / typical / heavy), **span**, **state** (normal / noFootage / pending / failed / emptyGroup — every honest state is reviewable, not imagined), EN/RU, 1920/1440/1200.

**Why Roll Call.** Problem 1 looks like a labelling job — write "no recording" on the black cells and move on. That fixes the honesty failure and leaves twelve-sixteenths of the screen doing nothing. But a dormant cell knows something nothing else on the screen knows: **when that camera did record, nearest to the moment you are looking at.** So it renders that as its content, and clicking it seeks the wall there. Twelve dead cells become twelve signposts to footage. The wall calls the register and every cell answers — *present*, or *absent, and here is where I was*.

The second idea follows from the first: the 4×4 geometry is the server's and cannot reflow, so what changes is that the wall stops presenting sixteen equal cells and starts presenting **two populations** — recording and dormant — with the register mirrored in the aside as a scannable column, and a shared hover linking cell ↔ lane ↔ row.

The fourteen timestamps go, replaced by **one clock** carrying the date. That is not a pixel saving, it is a stronger claim: fourteen chips imply the cells *could* differ and happen not to; one clock says they cannot, because there is one stream. `T` held stamps every cell on demand, so the proof stays demonstrable without being asserted fourteen times.

**On the open question — keep the presets rolling.** The arrival is the argument: the operator pressed "Go back in time" because something just happened, and "the last 15 minutes" is the shape of that thought. Calendar days are the right model for "check Thursday afternoon" and already have their own control. Two jobs, two models, two controls — what was broken is that both printed "24 hours", so each now names its model before its value and states what the far-left edge is.

**One genuine ambiguity in the brief, flagged rather than guessed** (spec §1): §3.3 says the span presets "re-scope the view", §3.7 says the scrubber shows "a zoomable subset of the loaded session window". Those read as either *a preset loads a new session* or *a preset only re-frames inside one already loaded*. This design assumes the former — it matches "re-scope" and it is the only reading under which `24h` can reach yesterday at all. **Confirm before building**; if it is the latter, the window statement is still right but the prewarm behaviour changes.

---

## The implementation prompt

Paste the block below into the Claude Code console from the repo root, with this folder dropped in at `designs/`.

---

Build the **Wall playback redesign, "Roll Call"**, into the Qt6/QML Watchtower client.

**Source of truth**, in this order:
1. `designs/handoff-wall-playback/2026-08-10-wall-playback-spec.md` — the spec. Every size, token, state and edge case is in here.
2. `designs/handoff-wall-playback/wall-playback-prototype.html` — the working reference. When the spec is ambiguous, match the prototype.
3. `designs/handoff-wall-playback/source-brief.md` — product context, exact tokens, the compositor's architecture and measured performance, the current anatomy.
4. `designs/handoff-wall-playback/reference-one-axis-spec.md` and `reference-groups-wall-spec.md` — the shipped sibling screens. Reuse their window-model vocabulary, letterbox-fit rule, scrubber hierarchy, inset-ring state vocabulary and growable-child rule. Do not rebuild them.

The prototype is React/HTML **as a drawing, not as an architecture**. Translate to native QML: `Rectangle` + `Text` + `MouseArea` + `Repeater` / `ListView`. No `Popup` for the modals, the banners or the group dropdown. No web views. Lift exact px and hex from the spec — do not re-derive spacing.

**This is ONE composited video, not sixteen players** (brief §1.1). Every per-cell thing is a client-drawn overlay over a cell of that single picture. Do not design or build per-cell playback, pause, speed or zoom — none of it is possible.

Do not touch: the window title bar beyond correcting its text, the nav rail, global search, Check in, the alerts bell, the avatar, or any other screen.

### What changes

A black cell becomes one of **three explicit states** — recording, dormant (hatched, named, with a clickable nearest-footage offer), or empty (`+ ADD CAMERA`). The fourteen timestamp chips collapse into **one authoritative clock** carrying the date, with `T`-held per-cell stamping as the sync proof. The aside narrows 320 → 296px, loses `STATUS` and the hint line, and gains a **window-model statement** and a **ROLL CALL** list. The scrubber grows 88 → 160px, gains a resize grip and a real hierarchy. The transport gains a coverage readout and self-naming span chips. The top-bar pills gain `↗` and navigate. The title bar stops saying "Live wall".

Target: at 03:00 with 2 of 16 recording, the operator's first read is *"two cameras were recording"*, not *"fourteen tiles failed"*.

### Build order

1. **Cell state machine** — recording / dormant / empty, with the dormant cell's hatch, `NOTHING RECORDED`, and the nearest-footage offer. This is the redesign; build it first.
2. **The one clock** in the aside + sync badge + `T`-held per-cell stamping.
2b. **Tier 1 archive ribbon** above the scrubber, with the loaded window drawn across it.
3. **Roll call** in the aside, and the shared `hoverCamera` linking cell ↔ lane ↔ row.
4. **Window statement** (`ROLLING` / `CALENDAR DAY`) and the coverage percentage.
5. **Scrubber** — coverage band with `warming`, ruler, lanes with the 7px floor, resize grip, hover tooltip with weekday, In→Out with the gap warning.
6. **Transport** — two anchors, self-naming span chips, `FIT`, lane toggle, export with duration.
7. **Motion-now** ring and tag; the `bad` hatch on lanes with no footage in view.
8. **Gesture affordances** on the cells; delete the hint line.
9. **Modals** — per-cell picker (swap on already-on-wall), `EDIT CAMERAS` with the stated 16 cap, export with the grid-clip disclosure.
10. **Keyboard** (§3), physical-code bound, `Esc` unwinding one layer per press.
11. **Honest states** (§4) — all six.

### Traps — every one was hit and fixed while prototyping, or carried forward from the four shipped screens. Do not rediscover them.

- **Never float the clock over the mosaic.** A 16:9 mosaic in a 16:9 stage leaves ~24px of letterbox, so any overlay is *on* a camera — and top-left is where the operator looks first. The clock lives in the top block of the aside: status column, eye level, zero picture cost, and directly above the roll call so "what moment" and "which cameras recorded at it" read as one block.
- **Tier 1 is an archive ribbon above the scrubber, matching the shipped single-camera screen.** Same axis, same idiom — and the loaded window drawn across it makes a rolling 24h visibly straddle two day cells, which is problem 3 solved without words. Distribute the ribbon's pixel remainder across cells; `floor()` misaligns the ribbon from the ruler beneath it.
- **Position cell overlays from the server's `cells[]` map, never from a client-side list index.** After a swap the client's order and the composite's order disagree for the 191–643 ms the re-composite takes, and drawing from the client list puts every camera name on the wrong picture for that whole time. The overlays must follow the composite.
- **A dormant cell and an empty slot are different facts and must never share pixels.** "This camera recorded nothing" and "there is no camera here" are the two things the current build conflates; a hatch plus a name for the first, a flat field plus `+ ADD CAMERA` for the second.
- **Do not use flat black for the dormant state.** Black is what a failure looks like. A 6px diagonal hatch is unmistakably *drawn*, which is the entire point of the state.
- **The dormant cell's jump offer must come from per-camera segment data, not from the fragment-level manifest.** The brief's §1.2 field is a hard dependency; without it there is no honest dormant state at all. If the backend field is not in yet, ship the hatch and the name and render `availability unknown` — **never** infer "nothing recorded" from a black pixel, which would be rendering an unknown as a fact.
- **Never assert instant random access.** A raw random-offset segment returns 503 until prewarm reaches it (14 of 14 measured). A seek outside a `ready` stretch moves the playhead immediately and renders the band under it as `warming` until served. `warming` is a first-class colour, never a spinner and never a gap.
- **Key the letterbox fit on the state that changes the stage** (scrubber height, window width, lane toggle), not only on a resize observer — observer-only runs a drag-step behind, and a mosaic taller than its stage is cropped, not letterboxed.
- **Style the frame renderer on its own class, never through a host ancestor.** It has multiple hosts (mosaic cells now, more later); scoped to one it computes `display:inline; position:static` and measures 0×0 in the others — correct gradients, no box to paint into. This trap has appeared three times across this product.
- **Only the lanes absorb a scrubber resize.** Coverage and ruler are fixed, so exactly one child grows; flexing a container whose children are all fixed relocates the void rather than filling it. Lane height `floor(area / cameras)` with a **7px floor** and a scrolling lane area below it — never compress to 2px.
- **The scrubber grip straddles its top edge (`absolute`) so it costs 0px of picture at rest.** A 5px band spends picture on chrome.
- **One shared `hoverCamera` value, three renderers.** Separate hover states for the cell, the lane and the roll-call row will drift, and the correspondence between fourteen 9px lanes and fourteen pictures is the only thing making the lanes usable.
- **Picking an already-on-wall camera in the per-cell picker SWAPS the two cells.** Duplicating a camera produces a composite nobody asked for.
- **The 16 cap must be visible and inert, not silent.** `N / 16` in the footer, `bad` at the cap, and unchecked rows carrying `16 of 16 — deselect one first`. A checkbox that silently refuses is a silent no-op control.
- **Disclose the grid-clip dependency BEFORE the export, in the modal** — §3.8's endpoint is not shipped. Failing honestly after the fact is worse than saying so first.
- **The two window models must never print the same words.** Tag the model before the value and state what the far-left edge *is* in a sentence. This is the defect that made an operator read the far left of `24H` as "just past midnight".
- **The date belongs on the wall's own clock, not in fourteen places or one corner.** One clock, `weekday · date · hh:mm:ss` with `accent` milliseconds.
- **Do not make the top-bar pills act on this wall.** They are fleet-wide counts and this wall is ≤16 cameras, so the number and the action would disagree. They navigate to the Live wall with that filter, and the tooltip says so. Hiding them is also wrong — chrome that vanishes on one screen teaches the operator that chrome is unreliable.
- **Bind keys by physical code** (`BracketLeft`, `KeyX`, `KeyT`, `Digit1`) — a Russian layout emits Cyrillic and every letter binding dies silently.
- **`Esc` unwinds one layer per press** — modal, then selection, then zoom. Anything else is ambiguous.
- **Hold the type floor**: mono micro-labels 8–11px with letter-spacing 1.2–1.6. Audit localization by extraction, not by eye; RU needs 3-form plurals and runs ~30% longer.

### Non-negotiables from the brief

- **One composited stream, server-defined 4×4 geometry, 480×270 cells, ≤16 cameras.** The cap is the composite's, not a UI choice.
- **Millisecond synchronisation is the product.** Whatever replaces the fourteen chips must still let an operator *prove* every cell is the same instant — here, the badge names the mechanism and `T` stamps every cell on demand.
- **Honesty:** never invent data; never render an unknown as healthy; every empty state names its cause; no silent no-op controls; nothing stamped before the server answers.
- Every existing capability survives: group scoping with per-group counts and an inert 0-camera group, `EDIT CAMERAS` with its 16 cap, right-click swap, drag rearrange, all five span presets, wheel zoom + `Shift`-pan + `FIT`, the motion-lane toggle, calendar day loading with debounce, In→Out selection, dual-archive export, return to live, and the whole of brief §3.9's keyboard map.
- Dark theme only, §2 tokens, square corners, hairline borders, no shadows.
- EN + RU, 3-form plurals. QML primitives only. 1920×1080, 1440×900 and 1200×900.

### Done when

Every box in the spec's §7 checklist passes at 1920×1080, 1440×900 **and** 1200×900, in **both** languages:

- Recording, dormant and empty cells are three unmistakably different things.
- Every dormant cell either offers its camera's nearest footage as a working seek, or says `none in this window`.
- There is **one** timestamp on the screen, it carries the day, and `T` held stamps all sixteen cells.
- Hovering a cell highlights its lane and its roll-call row, and vice versa.
- The window statement makes a rolling 24h and a calendar day impossible to confuse.
- Fourteen lanes are ≥7px at the default scrubber height, and the lane area scrolls rather than crushing them.
- An In→Out selection spanning a gap says so before the operator exports it.
- A swap never mislabels a picture during the re-composite.
- All six honest states render as tag + fact + consequence.
- **The success test passes:** at 03:00 with 2 of 16 recording, the operator can say at a glance which cells hold video and which had nothing to record, can read the moment including the day, and can mark and export the whole site's view of an incident without leaving mouse-and-keyboard.
