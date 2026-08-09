# Playback — redesign · implementation handoff

**Decision: build "One Axis".** The calendar and the zoom buttons are collapsed into **one navigator with two tiers** — a 35-day archive ribbon over the loaded window's FOOTAGE/MOTION lanes, sharing one horizontal time axis, with a bracket linking them.

| file | what it is |
|---|---|
| `2026-08-09-playback-redesign-spec.md` | **the spec to build** — anatomy, sizes, states, interactions, keyboard, edge cases |
| `playback-redesign-prototype.html` | **the reference build** — open in a browser; every behaviour is live |
| `tweaks-panel.jsx` | required by the prototype |
| `source-brief.md` | the original brief |
| `reference-groups-wall-spec.md` | the shipped Groups redesign — same language, and the source of the overlay-never-reflows and computed-fit rules. Reference only. |
| `reference-triage-lanes-spec.md` | the shipped Triage density language. Reference only. |

Open the prototype before writing code. Tweaks: **archive** (ribbon / calendar — the two tier-1 presentations), **footage** (sparse / typical / dense), **events** (none / typical / many), **state** (normal / recordingOff / playbackOff / offline / sessionError — every honest state is reviewable, not imagined), EN/RU, 1440/1200.

**Why One Axis.** The brief's problem 2 — *"a guard asked 'yesterday 3pm' must use both"* — is not a labelling failure but a modelling one. The product owns **one** thing, a time axis 35 days long, and was drawing it twice, in two idioms, in two corners, with no visible relationship. So the month calendar is unrolled onto the axis it was always describing and becomes tier 1 — **week-banded**, so the grid's one real advantage (all Thursdays in a column) survives as "Thursday is the 4th cell of every block"; the span buttons become visibly tier 2's zoom; and an amber bracket inside the selected day cell shows exactly where the window sits. The ribbon also shows what a grid could not — a density bar per day — so *"is it even worth scrubbing here"* is answered without a click.

Dissolving the info rail pays for it. Five of its seven blocks were duplicates of the picture (`Playhead`), restatements of a control (`Window`), or static trivia (`Quality`); `Last motion` was never a status value but a jump, and `Coverage` was the one number that predicts whether scrubbing is worth it, buried fifth in a key/value stack. Rail gone, `Coverage` promoted onto the navigator beside the lanes it describes: **video goes from ~1120×630 to 1246×701, +24% picture area**, and the navigator costs 111px.

---

## The implementation prompt

Paste the block below into the Claude Code console from the repo root, with this folder dropped in at `designs/`.

---

Build the **Playback screen redesign, "One Axis"**, into the Qt6/QML Watchtower client.

**Source of truth**, in this order:
1. `designs/handoff-playback/2026-08-09-playback-redesign-spec.md` — the spec. Every size, token, state and edge case is in here.
2. `designs/handoff-playback/playback-redesign-prototype.html` — the working reference. When the spec is ambiguous, match the prototype.
3. `designs/handoff-playback/source-brief.md` — product context, exact tokens, current-state anatomy, engine constraints.
4. `designs/handoff-playback/reference-groups-wall-spec.md` and `reference-triage-lanes-spec.md` — the shipped density language this continues. Reuse the computed-fit math, the inset-ring state vocabulary and the overlay-never-reflows rule. Do not rebuild those screens.

The prototype is React/HTML **as a drawing, not as an architecture**. Translate to native QML: `Rectangle` + `Text` + `MouseArea` + `ListView`. No `Popup` for the events panel, the banners or the speed ladder. No web views. Lift exact px and hex from the spec — do not re-derive spacing.

Do not touch the shared chrome above the screen (52px top bar → 30px tab strip). The three fleet-status pills are **fleet-wide filters, not playback controls** — leave them alone.

### What changes

The **info rail is deleted**. The **month calendar and the zoom buttons become one navigator**: a 35-day archive ribbon (tier 1) over the ruler and FOOTAGE/MOTION lanes (tier 2), sharing one time axis, with an amber window bracket inside the selected day cell. `Coverage` is promoted onto the navigator header; `Last motion` becomes an action cell there. The **transport regroups into four gapless groups by job**. **Speed becomes a ladder** with a visible `SCAN` boundary above 10×. **Export becomes a marked range on the timeline** instead of a hidden drawer. The events list and the motion lane become **one selection model**. A full keyboard map arrives.

Target: **1246×701 video at 1440×900** against today's ~1120×630, with a 115px navigator.

### Build order

1. **Navigator tier 1** — the archive ribbon: 42px, 120px label block, one cell per retention day, density bars, dimmed-and-inert days, today ring, selected day, window bracket, month dividers, the §2.2 degradation ladder.
2. **Navigator header** — 26px gapless cells: playhead, coverage, `LAST MOTION ›`, `MARKED ✕`, spacer, `MOTION` / `EVENTS` toggles, five span buttons.
3. **Navigator tier 2** — ruler with span-derived ticks, FOOTAGE lane, MOTION lane, playhead with preview-drag.
4. **Video stage** — letterboxed frame, mode chip, camera name, the 20px millisecond timestamp.
5. **Transport** — four groups by job; the backward-step cache hairline.
6. **Speed ladder** — all ten rates, `SCAN — frames skipped` divider, scan chip on the picture.
7. **Events overlay** — 296px, type chips, rows; wire the shared hover/selected model to the motion lane.
8. **Export as selection** — `[` / `]`, the bracket band, the header cell, the duration on the export button.
9. **Keyboard** (§3), physical-code bound.
10. **Honest states** (§4) — all seven.

### Traps — every one was hit and fixed while prototyping. Do not rediscover them.

- **Selecting a day must not change the zoom.** Forcing 24H on every day click while first paint opened at 1H made the same day show a 1H slice on arrival and a 24H sweep after a day-hop and back — 24× the window and 24× the events, with no visible cause. Operators read that as the archive changing under them. The span is the operator's; a day click moves the day and the playhead only. Land just inside the day's first segment so the window always opens on real footage.
- **One evidentiary timestamp, one wall clock, and they must not look alike.** Giving the top-bar clock the frame timestamp's face and size produced two full date-and-time readings 40px apart. They answer different questions (*when did this happen* vs *what time is it now*); only the first is evidentiary and only it carries a date and milliseconds. Keep the clock as a compact `hh:mm · UTC+3` pill.
- **Never seek during a scrub drag.** §3.6 measures p90 at 986 ms per session re-open; a drag that seeks per pointer-move issues ~60 a second and melts the backend. The drag **previews only** — the line follows, a `release to seek` chip explains why the picture has not moved, and exactly **one** seek is issued on release. Verify by counting session opens during a 3-second drag: it must be 1.
- **Relative moves must be functional updates, and handlers that need the current playhead must read a ref — never the render closure.** Two `→` presses in one tick both read the same stale playhead and the second overwrites the first, so `+10s +10s` moves 10 s. It looks like a dropped keypress. Same class as the Groups range-select anchor: an interaction pointer is not render state.
- **Never size ribbon cells with `floor(width / days)`.** The discarded remainder leaves the ribbon ending short of its track — and here it also **misaligns the ribbon from the ruler beneath it**, which is worse than the cosmetic seam it caused on the Groups wall. Distribute the remainder one pixel at a time across the leading cells.
- **A minimum stated twice will disagree with itself.** The drag clamped the navigator at 83px while the lane arithmetic floored the lanes at 18px, so at the bottom of the drag the lanes were 18px tall inside 0px of remaining container and overflowed it. Derive the clamp from the floor (`NAV_MIN = NAV_FIXED + LANE_MIN`) so there is one fact, not two that happen to agree in the middle of the range.
- **If layout arithmetic subtracts a constant, CSS must enforce that constant.** `laneH = navH − 83` assumes ribbon 42 + header 26 + ruler 15, but the ribbon was left content-sized and rendered 36.5px — so 5.5px was never allocated to any child and showed as a dead strip of background under the last lane at every drag position, worst at the minimum height where it is a quarter of the lane area. Pin the height rather than adjusting the constant, so the build matches the stated anatomy.
- **Clear the events panel OR the letterbox margin, never their sum.** The panel already covers the right letterbox margin, so subtracting both parked the exit group ~105px short of every edge — visibly aligned to nothing. Right inset = `max(letterboxMargin, panelWidth) + 11`.
- **Do not name the scan mode in the UI.** `SCAN` / `frames skipped` is engineering vocabulary that reads as a fault report to a guard under pressure. Disclose the boundary with **colour** (rates above 10× in `bad`, a `bad` rate chip on the picture) and a **plain-language tooltip** on the rate cell. The behaviour must still be disclosed — this is a change of register, not a removal.
- **The right rail is a COLUMN, not an overlay — this reverses the Groups rule on purpose.** Groups overlaid because a covered tile is still where the operator left it. A single continuous video frame is the opposite: overlaid, it is larger but a third hidden and the visible part is off-centre, and everything centred on the stage — the honest-state banners especially — centres on a stage the operator can only partly see, so `Could not open a playback session` sits off to the side of the picture it describes. Shrink the stage; every centred element then lands correctly with no per-element offset.
- **A "classic view" preference must be persistent, not a popover.** Putting the month grid behind a `▦` cell produced a date picker, not a calendar — the operator asking for it wants to see the month's shape without clicking. Put it in the right rail above the events list, where it costs no picture: with the rail open the video is width-bound, so the height a collapsed tier 1 gives back is height the frame cannot use.
- **`archive` is an operator preference with two presentations of tier 1** (ribbon / classic month grid). If you build the grid, it belongs **in the navigator header beside the span buttons** — a calendar in a different corner is problem 2 rebuilt. Grid mode collapses tier 1: navigator 115 → 73px, video +42px.
- **Do not put a caps label, a rule and a prose note on one line inside a narrow popup.** The speed ladder's `SCAN — frames skipped` divider needed ~133px in EN and ~190px in RU inside a 104px panel, so the note rendered outside the panel and broke its fixed row height. Stack it (label + rule on one line, note beneath, height auto) and set the note in the sans face — it is a sentence fragment, not a label.
- **Gate the input, not just the controls.** `[` / `]` were left ungated while their cells were hidden behind frame mode, so a range could be created that was drawn on the timeline, counted in the header, and had no export control anywhere — brief problem 8 rebuilt in a worse form, because the operator can now *see* the selection and still cannot act on it. Make the mark keys **enter** the mode; do not make them inert (that is two documented shortcuts silently doing nothing).
- **`Esc` unwinds ONE layer at a time, most-nested first:** fullscreen → open speed ladder → frame mode → selection and mark. Written flat it cleared the mark and left the operator in frame mode — so the permanent on-picture chip reading `ESC TO EXIT` was advertising a route that did not work while silently destroying data. Never let `Esc` reach the mark while a mode is still open.
- **Every advertised shortcut must do something visible.** `Shift F` was in the fullscreen tooltip while the handler called `preventDefault()` and returned — an intercepted keystroke that does nothing is a silent no-op control, which the honesty rules forbid. Wire it or stop advertising it.
- **Frame mode must not re-hide export.** `F` reveals mark-in / mark-out / export, which is right — they are meaningless at scan speed — but brief problem 8 was export being hidden behind a door. Keep the mode on a **visible labelled cell** in the bar, and keep the marked range a visible object on the timeline. A key-only mode would reintroduce the exact defect.
- **Keep a mode switch and the tools it reveals in one cluster.** The range cells belong beside the ⊞ at the centre, not at the far end of the left run — a switch whose consequence appears at the other end of the bar makes the operator hunt for what they just caused. The cluster centres as a whole; the ⊞ shifting when the tools appear is the accepted cost of that, and it is bounded because entering the mode is one deliberate press.
- **Style the frame renderer on its own class — NEVER through a host ancestor.** It has two hosts (the stage and every filmstrip cell); scoped `.vid .im` it computes `display:inline; position:static` and measures 0×0 in the other, so the filmstrip renders seven empty rectangles with correct gradients and no box to paint into. This trap has now appeared three times in this project, and here it landed on the one element that IS the feature. Hosts supply `position:relative; overflow:hidden` and nothing else.
- **Keep the exit legend out of the filmstrip entirely.** A sentence inside the band spends picture-grade width, and inline it clipped to `FRAME-BY-FRAME · F / Esc to exi` — losing the exit instruction it exists to give. Put it in the video's mode chip row beside `PLAYBACK`, where the operator already looks for mode; the band then holds nine frames instead of seven.
- **The toggle and its range cells are ONE group, hairline-separated** — not two groups 9px apart, which read as two objects that happen to be adjacent. Inline in the cell row it made 1522px of content in a 1438px box and was clipped to `FRAME-BY-FRAME · F / Esc to exi` — losing exactly the exit instruction it exists to give. Cells take `flex: 1` with a width cap, a height cap and a 16:9 ratio so whichever dimension binds drives the other; pad the band by the rail width so frames sit under the picture.
- **Frame mode must show frames.** A 25fps archive changes almost imperceptibly frame to frame, so a bare step button leaves the operator unsure anything happened. The 112px filmstrip (seven frames at the 40ms step, ms captions, current one ringed, neighbours clickable, visible exit tag) is the mode's subject, not decoration — and it puts the expensive backward direction on screen instead of behind a keypress.
- **Pin the centre control absolutely, never with flex spacers.** The frame toggle floated between two `flex: 1` spacers centres on the *leftover* space, so it slid 75px the moment frame mode revealed the range cells next to it. Use `left: 50%` plus a half-width translate so its position depends on the bar, not on its neighbours.
- **The transport has three anchors:** a continuous left run (move · rate · evidence), the frame toggle at the centre, and a right-anchored exit group. Rate sits beside the step buttons because it modifies how they move; the centre belongs to the mode switch alone, which is what marks it as a mode rather than another action — and is why it carries no word. Left run = act on the footage (move · rate · evidence), right = leave (fullscreen · Return to Live). A group with no edge to belong to has its position decided by the widths of its neighbours, which reads as aligned to nothing — that is what three right-crowded clusters produced. Put the only width-changing cell (export, `Export` → `4m 12s`) at the end of the left run so it cannot shift a button the operator is aiming at.
- **Every playhead WRITE goes through one synchronously-updated pointer.** A ref synced on render returns the same stale value to every event in a burst (key repeat, a held arrow), so 40 presses move the playhead once. Read and write the pointer inside the handler; drive the state from it, not the reverse. This is the third form of the same bug in this series — an interaction pointer is not render state.
- **Hold the brief's §2 type floor everywhere: mono micro-labels are 8–11px with letter-spacing 1.2–1.6.** Five classes in this screen drifted to 7–7.5px or 0.6–0.8 tracking, including the ribbon's weekday label — the one element the whole "the calendar is unrolled, not deleted" argument depends on. A wayfinding label may not be the smallest, least-tracked text in the design. There is no layout cost: "Wed" is 18px in a 37.7px cell.
- **The ribbon must be week-structured, not just 35 cells long.** A month grid's one real advantage is weekday alignment — all Thursdays in a column — and the brief's success test is a weekday question. Band the ribbon: divider before every Monday, alternate week blocks tinted, so Thursday is always the 4th cell of a block. Compute both from the dates, never from a cell index, so it survives any retention length or start weekday. Without this the ribbon throws away structure the data already has, and the grid's removal is a net loss.
- **Do not let a label restate the visualisation beside it.** The ribbon's label block first read `last 35d · 4 days w/ footage` — the retention span is the ribbon's left edge and the day count is the dots, so both halves were describing the picture six pixels away. It carries the selected day's footage total instead (`50m · 83 clips`), which is the quantity behind the dot and the thing that decides whether scrubbing this day is worth two minutes. Dissolving the info rail was this same judgement applied five times; do not reintroduce it one block over.
- **A fixed-width label block must contain its own text — never let it spill.** The `ARCHIVE` block is 120px because the ribbon track and the ruler track align on it; its summary line rendered ~170px and painted straight across the day cells. Split it across the block's two lines, drop to 9px, and clip. It may not widen to fit.
- **Key the letterbox fit on the state that changes the stage, not only on a resize observer.** Once the navigator became resizable the stage changed size for a new reason, and an observer-only fit ran one drag-step behind — the frame stayed 696px tall inside a 604px stage and was cropped. A `useLayoutEffect` keyed on navigator height / window width / panel width (in QML: bind the fit to those properties) makes it synchronous; keep the observer as the backstop for everything else.
- **Never compute the letterbox from a one-shot measurement of the stage.** The stage's height depends on the navigator, which depends on fonts and on the ribbon's own layout, so a single read taken at mount lands 2px short and the clamp letterboxes against a stale rect — the frame is then flush to the top and **cropped at the bottom** rather than centred. Observe the stage (and re-fit on `fonts.ready`), exactly as the ribbon track already does. In QML this is `onWidthChanged`/`onHeightChanged` on the stage item, not a one-time binding evaluation. A cropped evidentiary frame contradicts the letterbox rule outright, and at 1200px or with late-resolving fonts the error is larger than a rounding error.
- **Do not reuse generic class/id names between the transport and the video overlays.** The transport bar and the top-right timestamp overlay collided on a two-letter name; the overlay inherited `left:0; right:0` and stretched 1333px across the stage, landing on top of the camera name. Namespace anything new. (Third time this class of bug has appeared in this series.)
- **The events panel must never occlude the millisecond timestamp.** The panel overlays the *video* — geometry must not jump mid-review — but the video's own chrome yields to it: the timestamp's right offset and the transport's right padding both grow by the panel width. Covering the picture is acceptable; covering the evidentiary timestamp is not.
- **`J` is not reverse shuttle.** The industry idiom is `J` = play backwards and §3.6 forbids it — reverse playback decodes from a keyframe for every delivered frame. `J` walks the rate ladder down, and the tooltip says `Playback rate — J / L` so the operator learns the local rule in one hover. Do not "fix" this back to the idiom.
- **Bind keys by physical code** (`Comma`, `Period`, `KeyJ`, `BracketLeft`, `Digit1`), never by character — a Russian layout emits Cyrillic and every binding dies silently.
- **Backward frame stepping is visibly asymmetric, and must stay visible.** A 2px accent hairline on the back-step cell for the cache fetch; forward never shows it; `,` key-repeat is rate-limited to the cache refill. Do not disable the button and do not use a spinner — the step still happens.
- **`recordingOff` and `offline` must NOT block playback.** They are facts about the live stream and about the future, not about the archive. Blocking them is the exact conflation the honesty rules exist to prevent — a camera that dropped an hour ago still has a complete, playable archive. Only `playbackOff` and `sessionError` block.
- **A gap-seek never snaps.** Land where the operator dropped the playhead, state the gap, and *offer* the nearest footage as a button. Snapping silently is the player deciding where they meant to look.
- **Do not decimate the motion lane at 24H with 200 events.** Merged dense blocks are the correct picture of a busy day; the lane is a density plot and the list is the precise instrument. No "+N more", no thinning.
- **A single 3-second clip in a 24H window renders at the 1px minimum, not at its true 0.003% width.** It must remain visible and clickable; `1 segment · 0% covered` is honest because the count is exact and only the percentage is rounded.
- **The FOOTAGE lane must never round short gaps away.** A motion-recorded camera is 80–120 segments a day totalling under an hour; a lane that smooths that into bars implies a continuity the archive does not have.
- **Audit localization by extraction, not by eye.** Weekday and month names need both full and single-letter forms; every count needs RU 3-form plurals. Allow-list: brand names, key names, vendor models, `UTC+3`.

### Non-negotiables from the brief

- **Honesty:** never invent data; never render unknown as healthy; every empty state names its filter or window; no silent no-op controls; nothing stamped before the server answers.
- **The millisecond timestamp and the FOOTAGE/MOTION lane distinction are the evidentiary core** and survive any change — they may not be shrunk, merged, occluded or smoothed.
- Above 10× is **scan**, not playback, and the UI says so on the picture.
- Sessions are per-camera and per-window; changing the day or the span is a new session, not a client-side crop.
- Dark theme only, §2 tokens, square corners, hairline borders, no shadows.
- EN + RU, RU ~30% longer, 3-form plurals.
- QML primitives only. 1440×900 and 1200×900.

### Done when

Every box in the spec's §7 checklist passes at 1440×900 **and** 1200×900, in **both** languages:

- There is exactly **one** navigator. No month-grid calendar exists anywhere in the screen.
- Video is ≥ +20% in area against today, and its geometry never changes when a panel opens.
- A 3-second scrub drag issues **one** seek.
- Two rapid `→` presses move 20 s.
- The ribbon's last cell aligns with the ruler's right edge at every window width.
- The speed ladder shows all ten rates with the scan boundary visible, and the picture chip reads `SCAN 50×` above 10×.
- Selecting an event in the list highlights its bar in the lane, and vice versa — there is no state where they disagree.
- Marking `[` `]` puts a visible bracket on the timeline and a duration on the export button.
- All seven honest states render; `recordingOff` and `offline` still play the archive.
- **The success test passes:** "the lift at about quarter past ten last Thursday" — under 15 seconds, frame-stepped, out with a timestamped snapshot, without once choosing between two navigators.
