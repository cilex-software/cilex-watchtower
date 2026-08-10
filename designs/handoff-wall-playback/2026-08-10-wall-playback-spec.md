# Wall playback — redesign · "Roll Call"

**Reply to** `docs/design-briefs/2026-08-10-wall-playback-redesign.md`
**Date:** 2026-08-10 · **Status:** ready to build
**Prototype:** `wall-playback-prototype.html` (+ `wall-playback-core.jsx`, `wall-playback-parts.jsx`, `tweaks-panel.jsx`) — live tweaks for camera count, lit-cell ratio, motion density, window span, **honest state**, EN/RU, 1920/1440/1200.

**Language:** continues Triage "Lanes", Groups "Wall", Playback "One Axis". Gapless hairline cells, inset rings rather than borders, computed-fit maths, overlays that never reflow what sits beneath them, one predicate behind every count.

---

## 0 · The decision

**A cell that recorded nothing stops apologising and starts navigating.**

The brief's problem 1 is the whole redesign, and the trap in it is that it *looks* like a labelling job — put "no recording" on the black cells and move on. That fixes the honesty failure and leaves twelve-sixteenths of the screen doing nothing.

But a dormant cell knows something no other element on this screen knows: **when that camera did record, nearest to the moment you are looking at.** So the dormant cell renders that as its content and makes it clickable:

```
┌────────────────────────┐
│ .151  HiWatch DS-I456Z │   ← identity, quiet
│                        │
│    NOTHING RECORDED    │   ← the fact
│       ← 11:15          │   ← the offer: click to go there
└────────────────────────┘
```

Twelve dead cells become **twelve signposts to footage**. The operator's dominant experience of this screen stops being "twelve broken tiles" and becomes "twelve cameras telling me where their evidence is". That is the variant, and it is why it is called **Roll Call**: the wall calls the register and every cell answers — *present*, or *absent and here is where I was*.

The name also states the second idea. The 4×4 geometry is the server's and cannot change (§1.1), so the wall cannot reflow to favour lit cells. What *can* change is that the wall stops presenting sixteen equal cells and starts presenting **two populations** — recording and dormant — with the register itself mirrored in the aside as a scannable column.

| brief problem | how Roll Call answers it |
|---|---|
| **1 · a black cell says nothing** | Three distinct cell states (§2.2): **recording**, **dormant** (hatched, named, with a jump offer), **empty** (no camera assigned — a state the current build also conflates with black). Answered as navigation, not as a label. |
| **2 · the date is missing** | **One authoritative clock** over the wall carrying `Mon 10 Aug 2026 · 11:16:03.000` (§2.3). The date is on the screen once, large, where the eye already goes. |
| **3 · two window models, one vocabulary** | The window states its **model** before its value: `ROLLING 10:53 → 11:53` vs `CALENDAR DAY 10 Aug · 00:00–11:53`, each with a sentence saying what the far-left edge *is* (§2.5). Recommendation on the semantics in §1. |
| **4 · fourteen identical timestamps** | Deleted. One clock proves it better (§2.3), and `T` held floods every cell with its stamp on demand — proof available, not asserted fourteen times. |
| **5 · the scrubber does five jobs in 88px** | Restructured into a hierarchy and made **resizable**: 14px coverage · 15px ruler · lanes taking the remainder, 160px default, 7px lane floor (§2.7). |
| **6 · the two best gestures live in an 11px sentence** | The sentence is deleted. Every cell reveals a `⇄` swap and a `✥` drag grip on hover, and the gestures are visible where they apply (§2.2e). |
| **7 · nothing says which camera matters *now*** | A lit cell with motion within ±2s of the playhead takes a 2px `accent` ring and a `MOTION` tag; the roll call and the lanes both carry it (§2.4). |
| **8 · the top-bar pills do nothing here** | They become navigation: `↗` affix, tooltip *"Fleet-wide — opens the Live wall filtered to offline"*, and clicking navigates. §3.0's defect is that they are silent, not that they exist (§2.9). |
| **9 · four keys** | Fifteen (§3). |
| **10 · the title bar says "Live wall"** | `WATCHTOWER · Wall playback`. |

### Density arithmetic, 1440×900

```
title bar 24 + top bar 52                        =  76
ribbon 42 + transport 38 + scrubber 160          = 240
stage height:  900 − 76 − 240                    = 584
stage width:   1440 − 72 rail − 296 aside − 1    = 1071
mosaic (16:9, width-constrained):                = 1035 × 582
cell:                                            = 259 × 146 drawn  (480 × 270 real)
```

The aside narrows 320 → **296px** and the scrubber grows 88 → **160px** by default. That is a deliberate trade: the scrubber is where the operator *works* on this screen, and 88px could not hold fourteen lanes above the 7px legibility floor. The picture loses 72px of height and gains a usable timeline.

---

## 1 · The open question: rolling presets or calendar days

**Recommendation: keep the presets rolling, and fix the vocabulary.** Do not convert them to calendar days.

The arrival is the argument. An operator reaches this screen by pressing **"Go back in time"** on the Live wall because *something just happened*. "The last 15 minutes" is the literal shape of that thought; "today from midnight" is not. Converting the presets to calendar days would make the commonest arrival require a second action, and would leave 00:15 with no way to reach the previous evening at all without a calendar click.

Calendar days are the right model for the *other* job — "check Thursday afternoon" — and they already have their own control, the FOOTAGE calendar. **Two jobs, two models, two controls** is correct. What was broken is that both printed "24 hours".

So both survive and each names itself (§2.5), the far-left edge is stated in words, and the date appears on the wall's own clock. The operator who read "playhead at the far left of 24H" as "just past midnight" now reads `ROLLING · Ends now — the far left is Sun 9 Aug at 11:53`.

**One thing the brief leaves genuinely ambiguous, flagged rather than guessed:** §3.3 says the presets "re-scope the view", and §3.7 says the scrubber "represents the view window, which is a zoomable subset of the loaded session window". Those two can be read as (a) a preset re-loads the session, or (b) a preset only re-frames within an already-loaded session. This design assumes **(a): a preset is a new session window** — it matches "re-scope", and it is the only reading under which `24h` can show yesterday at all. If the truth is (b), §2.5's window statement is still correct but the prewarm behaviour changes, so confirm before building.

---

## 2 · Anatomy

### 2.1 · The mosaic stage

One `VideoOutput`, `PreserveAspectFit`, letterboxed on `#121110`. The 4×4 overlay grid is positioned from the server's `cells[]` map (`{index, camera_id, row, col}`) — **never from a client-side list index**, because after a swap the client's order and the composite's order disagree until the re-composite lands, and drawing from the client list puts every name on the wrong picture for 1–2 seconds.

**The stage never reflows in response to a panel or a resize of the scrubber** — it re-letterboxes. Compute the fit from the measured stage and key it on the states that change it (scrubber height, window width, lane toggle), with a resize observer as backstop; an observer alone runs a drag-step behind and a mosaic taller than its stage is *cropped*, not letterboxed.

### 2.2 · Cell states — three, not two

Every cell is exactly one of these. The current build has one visual for all three, which is the honesty failure.

**a. Recording** — the composited picture shows through. Overlay: a top scrim carrying **`.151`** (mono 11px, white, DemiBold) and the model name (9.5px, white @62%, ellipsized). Nothing else. No timestamp (§2.3), no border (the mosaic's own cell edges are the only division — gapless, as everywhere in this product).

**b. Dormant** — the camera is on the wall and recorded nothing at this instant. **This is the redesign.**

| element | spec |
|---|---|
| field | `repeating-linear-gradient(135deg, #131211 0 6px, #171513 6px 12px)` — a 6px hatch. Not flat black: black is what a failure looks like, and a hatch is unmistakably *drawn* |
| identity | same octet + model line, but in `ink2` / `ink3` and with no scrim — the cell is not competing for attention |
| fact | centred, mono 8.5px caps, letter-spacing 1.4, `ink3`: **`NOTHING RECORDED`** |
| **offer** | centred beneath it: **`← 11:15`** — a button, mono 10px `accent` on `accentSoft` with an `accentDim` hairline. The arrow gives the direction, the time gives the target. Click seeks the whole wall there |
| no offer | when that camera has nothing anywhere in the window: mono 8.5px `ink3` `none in this window`. Honest, and distinct from "nothing *here*" |

The offer is computed from the same per-camera segment data the motion lanes already draw, so it costs no new request beyond the per-cell availability field being asked for.

**c. Empty** — no camera assigned to that slot (2 of 16 in the screenshot). `#100f0e`, no hatch, and a single centred **`+ ADD CAMERA`** ghost button opening the per-cell picker. The current build renders this identically to a dormant cell, so the operator cannot tell "this camera recorded nothing" from "there is no camera here" — two completely different facts.

**d. Motion now** — a *recording* cell whose camera has motion within ±2s of the playhead takes a **2px `accent` inset ring** and a `MOTION` tag (mono 8px caps, `accent` fill, top-right). Dormant cells never take it. This is problem 7: with fourteen lanes of motion data available, the wall can point.

**e. Gesture affordances** — on cell hover, bottom-right: `⇄` (opens the per-cell picker; right-click still does) and `✥` (drag handle). 20px, `rgba(13,12,11,.82)` with a `line2` hairline, `accent` on hover. Drag feedback is unchanged from the current build: source cell to 45% opacity, target cell takes a 2px `accent` inset ring, a ghost label rides the cursor.

**f. Correspondence** — hovering a cell highlights that camera's lane in the scrubber **and** its roll-call row, and hovering either highlights the cell (2px `ink` inset ring). One `hoverCamera` value, three renderers. This is what ties fourteen 9px lanes to fourteen pictures.

### 2.3 · One authoritative clock — in the aside, not on the picture

**Top block of the aside**, above everything else, with a `line2` bottom hairline:

`Mon 10 Aug 2026` (mono 14px, `ink` @62%) over **`11:16:03`** (mono 21px, `ink`) + **`.000`** (`accent`), then the sync badge beneath.

**It must not sit over the mosaic.** A first pass floated it top-left over the picture and it covered the top-left cells — the two cells an operator looks at first — which is the same mistake as the fourteen chips, concentrated in one place: chrome consuming the picture it exists to describe. On a wall there is no letterbox margin to hide in either (16:9 content in a 16:9 stage leaves ~24px), so an overlay here is always *on* a camera.

The aside is the right home for three reasons: it is the status column, so *when* sits beside *what*; it is at eye level rather than at the bottom of a 900px window; and it costs **zero picture**. It also puts the clock directly above the roll call, so "what moment" and "which cameras were recording at it" read as one block.

Because the aside is 296px wide, the date and the time stack rather than sitting on one line — and both are the same reading, so the date takes the same face and weight, separated only by contrast (62% vs full `ink`). The `accent` millisecond field stays unique to this clock: the top bar's wall clock is a compact `hh:mm · UTC+3` pill and carries no date, because it answers a different question.

**Why one clock is *stronger* proof than fourteen.** Fourteen chips implicitly claim that the cells *could* differ and happen not to; the truth is that they cannot differ, because there is one stream. Drawing the time once says exactly that. The badge names the mechanism — **`1 STREAM · 3/14 RECORDING`**, mono 8px caps, `good`, with a hairline — and its tooltip carries the sentence: *"Every cell is the same instant by construction — one composited stream. Hold T to stamp every cell."*

**And the proof stays demonstrable.** Holding `T` renders the per-cell chip on every cell simultaneously (mono 9px on `rgba(22,20,15,.8)`, bottom-left, the current build's chip exactly) for as long as the key is held — for the rare moment an operator has to show someone, or screenshot it. Permanent proof of an invariant is clutter; on-demand proof of an invariant is a feature.

The badge's second half doubles as the answer to "how many cells should I be seeing?" — `3/14 RECORDING` tells the operator that eleven dark cells are *expected*, before they read a single cell.

### 2.4 · Roll call — the aside's growable child

Under the calendar, taking the remaining height and scrolling:

`ROLL CALL  3/14  RECORDING` header (mono 8px caps), then one 24px row per wall camera **in grid reading order**:

| slot | spec |
|---|---|
| state square | 7px — `good` filled when recording, `line2` hairline when dormant |
| octet | mono 10.5px DemiBold, `ink` when recording, `ink2` when dormant |
| state | mono 8.5px caps — `RECORDING` (`good`) / `MOTION` (`accent`) / `nothing at this instant` (`ink3`) |
| motion sparkline | 24×5px, that camera's motion in the current view, opacity by intensity |
| jump | `← 11:15` (`ink3`, `accent` on hover) — same offer as the dormant cell, same click |

This is the register in list form, and it earns its place three ways: it answers "which cells are lit" without scanning sixteen pictures; it is the correspondence map between fourteen thin lanes and fourteen cells; and it makes the jump offer reachable for a camera whose cell is at the far corner of the wall.

It is also the aside's one **growable** child — ribbon, group row, window statement and calendar are all fixed-height, so without it the aside would end in dead space. (The Groups console lesson: flexing a container whose children are all fixed relocates the void rather than filling it.)

### 2.5 · The window statement

In the aside, above the calendar — the fix for problem 3:

```
[ROLLING]  10:53 → 11:53
Ends now — the far left is Mon 10 Aug at 10:53
56% of the window has footage
```

```
[CALENDAR DAY]  10 Aug · 00:00–11:53
Midnight to midnight, clamped to now
41% of the window has footage
```

The mode tag is the first thing in the block, 8px mono caps in a hairline box: **`ROLLING`** in `info`, **`CALENDAR DAY`** in `accent` on `accentSoft`. Different words, different colours, different second lines. The two models can no longer be confused because they no longer share a sentence.

`56% of the window has footage` is the union across every camera on the wall — the one number that predicts whether scrubbing here is worth it. It is repeated as a compact cell in the transport bar, because that is where the span controls are.

### 2.5b · Tier 1 — the archive ribbon

**The same two-tier navigator as the shipped single-camera screen** (One Axis §2.2), for the same reason: the product owns one time axis, and drawing it twice in two idioms is what made "24 hours" ambiguous in the first place. A 42px ribbon sits **directly above the scrubber**, sharing its horizontal axis:

| part | spec |
|---|---|
| label block | **132px** — `ARCHIVE` (mono 8px caps) with the selected day pushed right, over **that day's wall total**: `8h 17m · 14 cameras`. Never the retention span or a count of days — the ribbon already draws both |
| track | one cell per retention day, width `paneWidth / 35` **with the remainder distributed** one pixel at a time |
| cell | weekday + day number + a 4px density bar showing **how much the wall recorded that day** (union across every camera on it) |
| structure | a `line2` @55% divider before every Monday, alternate weeks tinted — so weekday position is read by block, not by counting. Month boundaries get a stronger divider and a mono 8px label |
| states | dimmed-and-inert without footage · today ringed · selected day `accentSoft` + 2px `accent` bottom bar |

**And the loaded window is drawn across the ribbon** as an `accent`-outlined band. That band is the fix for problem 3 made visual: a rolling 24h window renders as a band **straddling two day cells**, so "the far left is yesterday at this hour" is something the operator can see rather than read. A calendar day sits exactly inside one cell. The two window models are now distinguishable at a glance, without words.

Clicking a day loads it (00:00 → 24h clamped to now) and re-composites, debounced. **The `archive` preference from One Axis carries over**: `ribbon` (default) puts tier 1 here, `calendar` collapses it and restores the Mon–Sun grid in the aside instead — the same control, the same capability, presented the way the operator has already chosen on the sibling screen.

### 2.6 · Aside — the rest

296px. Title `Wall playback` · `14 cameras · synchronized` · `EDIT CAMERAS`.

`GROUP` row: a 30px dropdown listing `All cameras 39 · Inside 22 · Лифты 3 · Снаружи 14 · Roof 0`. **A 0-camera group renders at `ink3` @50%, is inert, and carries the tooltip `No cameras in this group`** — unchanged, correct, and worth preserving exactly. Selecting a group loads its first 16. An arbitrary set reads `Custom selection`.

**The hint line is deleted.** Its two gestures are now affordances on the cells themselves (§2.2e). A sentence that has to explain the interaction model is a symptom, not documentation.

The `STATUS` block is gone: `Playhead` duplicated the wall's clock at a fifth the size, and `Window` is replaced by §2.5's statement.

Calendar (`archive: calendar` mode only — otherwise tier 1 is the ribbon, §2.5b): unchanged in behaviour — Mon–Sun grid over the 35-day retention, dot on days with footage, today ringed, selected day filled `accent`, dimmed-and-inert outside retention, `• has footage / ▫ today` legend, day click loads 00:00 → 24h clamped to now, rapid clicks debounced into one composite, and a **pending** render while coverage is unanswered rather than an implied "no footage". Rows are derived from the month, so most months take five rows not six.

### 2.7 · Scrubber — a hierarchy, and resizable

Default **160px**, dragged from a 7px grip straddling its top edge (`absolute`, so it **costs no picture at rest**), 36–420px, double-click to reset.

| band | height | contents |
|---|---|---|
| **coverage** | 14px | union-of-all-cameras footage. `ready` `#3f5a2a`, **`warming` `#4a4327`** for stretches the compositor has not rendered. Gaps literal. A `WARMING` label sits at the right when a warming stretch is present |
| **ruler** | 15px | span-derived ticks and mono 8.5px `hh:mm` labels |
| **lanes** | the remainder | one lane per wall camera in **grid reading order**, zebra-striped, motion bars with opacity by intensity, spans closer than ~2px merged |

Only the lanes absorb a resize — coverage and ruler are fixed. Lane height is `floor(laneArea / cameras)` with a **7px floor**; at 14 lanes and 160px that is 9px, and at ≥11px each lane also carries its own `.151` at 8px `ink3` so the correspondence is readable without hovering. Below the floor the lane area scrolls rather than compressing further.

**A lane whose camera has no footage anywhere in the view** takes a faint `bad` diagonal hatch — the lane equivalent of a dormant cell, so "this camera contributes nothing to this window" is visible in both places.

**Interactions** — all preserved: click seeks · drag marks In→Out (under 4px counts as a click) · wheel zooms **at the cursor**, clamped to the loaded window · `Shift`+wheel pans · any free-form zoom sets a custom span, de-highlights the preset chips and reveals `FIT`.

**Hover** — a 1px guide plus a tooltip carrying **the weekday and the full time** (`Mon 11:16:03`), prefixed with the octet when the cursor is over a lane (`.151 · Mon 11:16:03`). The weekday is there for the same reason the clock carries the date.

**In→Out** — `accentSoft` region with `accent` edges and `[` `]` end caps, plus a chip at bottom-left: `IN 11:15:02 → OUT 11:16:31 · 1m 29s`. **When the selection spans a stretch where some camera has no footage**, the chip appends `· spans a gap — some cameras have no footage inside it`. The export is still valid; the operator simply must not be surprised when four of fourteen clips come back short.

**Honesty about prewarm** — §1.1: a random offset returns 503 until the renderer arrives. So a click outside a `ready` stretch shows the playhead move immediately and the coverage band under it render as `warming` until the segment is served. The design must never imply instant random access; the `warming` colour *is* that disclosure, which is why it is a first-class colour rather than a loading spinner.

### 2.8 · Transport — 38px, two anchors

Left run: `▶/❚❚` (42px) · `−10s` · `+10s` · `Last hour` · `Last 15 min`.
Right run: `56% of the window has footage` · separator · `15M 1H 6H 12H 24H` · `FIT` (only after a free-form zoom) · `EVENTS` · `↥ Export selection · 1m 29s` (only with a range) · `● Return to live`.

Span chips are `accent`-filled when active and their tooltip states the model: *"Rolling window — the last 1h, ending now"*. `EVENTS` is the lane toggle and takes the ghost treatment (`accentSoft` + 2px `accent` underline) rather than a fill, because it is a preference, not a mode. `Export selection` carries its own duration.

### 2.9 · The top-bar pills

They stay, and they **navigate**. Each gains a trailing `↗` (9px, `ink3` → `accent` on hover) and the tooltip *"Fleet-wide — opens the Live wall filtered to offline"*. Clicking leaves for the Live wall with that filter applied.

The alternative — hiding them here — is worse: they are global chrome on every other screen, and a control that disappears on one screen teaches the operator that the chrome is unreliable. Making them act on *this* wall is also wrong: they are fleet-wide counts, and this wall is ≤16 cameras, so "OFFLINE 3" would mean something different from the number displayed. Navigation is the only reading under which the number and the action agree.

### 2.10 · Modals

**Per-cell picker** (right-click or `⇄`) — unchanged and correct: `Choose camera for this tile`, subtitle **`Replaces <camera> · the wall re-composites`** (it names the cost before the action), focused `Search name, IP or group…`, roster list with name bold over `.oct · group`, an **`ON WALL`** badge on cameras already up, `Cancel`, `Esc`. **Picking a camera already on the wall swaps the two cells** rather than duplicating it — a mosaic with the same camera twice is a composite the operator did not ask for.

**`EDIT CAMERAS`** — `Assign cameras`, subtitle *"The wall re-composites at the current moment"*, search, checkbox roster, `Use live wall`, `Cancel`, `Apply · N cameras`. The **16 cap** is stated as `N / 16` in the footer, turns `bad` at 16, and unchecked rows at the cap carry the tooltip `16 of 16 — deselect one first` — inert rather than silently ignoring the click.

**Export** — `Export this moment`, subtitle *"One clip per camera plus one synchronized grid clip, exported as a single wall moment"*, then the range, the camera count, and the grid-clip row which says in `bad`: *"backend endpoint not shipped — this part will fail honestly"*. §3.8's dependency is disclosed **before** the export, not after it fails.

---

## 3 · Keyboard

| key | action |
|---|---|
| `Space` | play / pause |
| `←` `→` | ∓10 s |
| `Shift ←` `→` | ∓60 s |
| `[` `]` | mark In / Out at the playhead |
| `X` | export the marked range |
| `1`–`5` | span presets 15M / 1H / 6H / 12H / 24H |
| `0` / `Home` | `FIT` — drop a custom zoom back to the window |
| `E` | toggle the motion lanes |
| **`T` (hold)** | stamp every cell with the timestamp — the sync proof |
| `Esc` | close a modal · else clear the selection · else clear the zoom |

`Esc` unwinds in that order, one layer per press, so it is never ambiguous which thing it will close.

Bind by **physical code** (`BracketLeft`, `KeyX`, `Digit1`, `KeyT`) — a Russian layout emits Cyrillic and every letter binding dies silently.

---

## 4 · Honest states

| state | render |
|---|---|
| **cell recorded nothing** | §2.2b. The state the current build cannot express. |
| **compositing pending** | `PLAYBACK` tag (`accent`) · *"Synchronized wall playback — backend compositing pending."* · *"The server-composited grid stream (E1) isn't live yet. Live tiles are unaffected — use Return to live."* · `Return to live`. |
| **composite produced no frames** | `ERROR` (`bad`) · *"Couldn't composite the synchronized grid for this window."* · *"The server didn't return frames in time. Try a different time, or Return to live."* |
| **no footage in this range** | `FOOTAGE` (`ink3`) · *"No footage anywhere on this wall in this window."* · *"Not one of these cameras recorded here. Pick a day with a dot, or widen the window."* — it names **why** the wall is empty and what to do, and it is distinct from twelve dormant cells with two lit. |
| **group with no cameras** | `GROUP` · *"'Roof' has no cameras to play back."* · *"A wall cannot be composited from an empty group. Pick another group, or use EDIT CAMERAS."* The dropdown row is inert too, so this is reachable only via a stale link. |
| **warming** | `#4a4327` on the coverage band, never a gap and never a spinner. |
| **grid-clip export unavailable** | disclosed in the export modal before the action (§2.10). |

Every banner is **tag + fact + consequence**, plus an action where one exists. None says "something went wrong".

---

## 5 · Edge cases

| case | behaviour |
|---|---|
| **16 cameras, only 2 lit** | The normal case at 03:00. Two pictures, fourteen hatched cells each offering its nearest footage, badge reads `1 STREAM · 2/16 RECORDING`, roll call reads `2/16`. The operator's first read is *"two cameras were recording"*, not *"fourteen tiles failed"*. |
| **A wall of 4 cameras** | The composite is still 4×4 — the geometry is the server's. Cells 5–16 render as **empty** (`+ ADD CAMERA`), not dormant: no camera is assigned, so there is nothing to say about recording. Roll call shows 4 rows; the scrubber shows 4 lanes at the full lane area (40px each), which is where the lane labels and intensity actually read well. |
| **Rolling 24h vs calendar day** | §2.5. Both loadable, each self-naming, and the far-left edge stated in words. |
| **A window with a large warming stretch** | The coverage band shows `ready` then `warming` with the `WARMING` label; the playhead can enter the warming stretch and the picture arrives when the renderer gets there. Nothing is disabled and nothing pretends to be instant. |
| **14 motion lanes at 1200px** | Width is not the constraint — height is. At the 160px default each lane is 9px, above the 7px floor; at the 36px minimum the lane area scrolls rather than crushing lanes to 2px. Lane labels appear at ≥11px, so an operator who wants them drags the scrubber up ~30px. |
| **In→Out spanning a gap** | Allowed, and **named**: the selection chip appends `spans a gap — some cameras have no footage inside it`. Export proceeds; the short clips are expected, not a surprise. |
| **Compositing pending** | §4. The aside, calendar and scrubber stay rendered and truthful — only the mosaic is replaced by the banner, because the archive facts are still facts. |
| **RU at 1200px** | Aside 296px fixed; the longest RU strings are the banner bodies (flexible, wrap) and `КАЛЕНДАРНЫЙ ДЕНЬ` (fits the 8px tag). The window statement's second line wraps to two lines and the block is `height: auto`. Cell overlays are an octet plus an ellipsized model name, so they are language-invariant. `НЕ ЗАПИСЫВАЛОСЬ` is *shorter* than `NOTHING RECORDED`. |
| **1920×1080 booth PC** | Stage 1552×873 → cells 388×218 drawn from 480×270 real, still under 1:1 so no upscaling artefacts. Scrubber default 160px gives 14 lanes at 9px; the extra height is worth spending on the picture, so the default does not scale up. |
| **A swap while the wall is re-compositing** | Overlays are drawn from the server's `cells[]`, so they follow the composite, not the click. The swapped cells hold their previous names for the 191–643 ms the re-composite takes rather than mislabelling two pictures. |
| **Same camera picked for two cells** | The two cells swap. A duplicated camera in a mosaic is never what was asked for. |
| **Playhead outside the loaded window after a span change** | Clamped into the new window, at the nearest edge. |

---

## 6 · Strings

Beyond the current build's set, the new ones:

| id | EN | RU |
|---|---|---|
| `cell.noRec` | `NOTHING RECORDED` | `НЕ ЗАПИСЫВАЛОСЬ` |
| `cell.noneInWin` | `none in this window` | `нет в этом окне` |
| `cell.jumpT` | `Jump to this camera's nearest footage` | `Перейти к ближайшей записи этой камеры` |
| `cell.motion` | `MOTION` | `ДВИЖ` |
| `cell.add` | `ADD CAMERA` | `ДОБАВИТЬ` |
| `sync.badge` | `1 STREAM · {a}/{b} RECORDING` | `1 ПОТОК · ПИШУТ {a}/{b}` |
| `sync.tip` | `Every cell is the same instant by construction — one composited stream. Hold T to stamp every cell.` | `Все ячейки — один и тот же момент по построению: единый composited-поток. Удерживайте T, чтобы проштамповать каждую ячейку.` |
| `win.rolling` / `win.calday` | `ROLLING` / `CALENDAR DAY` | `СКОЛЬЗЯЩЕЕ` / `КАЛЕНДАРНЫЙ ДЕНЬ` |
| `win.rollSub` | `Ends now — the far left is {day} at {time}` | `Кончается сейчас — крайнее левое: {day}, {time}` |
| `win.calSub` | `Midnight to midnight, clamped to now` | `С полуночи до полуночи, до текущего момента` |
| `win.covered` | `{p}% of the window has footage` | `{p}% окна содержит запись` |
| `rc.title` | `ROLL CALL` | `ПЕРЕКЛИЧКА` |
| `rc.rec` / `rc.dorm` | `RECORDING` / `nothing at this instant` | `ПИШЕТ` / `в этот момент ничего` |
| `scrub.warming` | `WARMING` | `ГОТОВИТСЯ` |
| `sel.gap` | `spans a gap — some cameras have no footage inside it` | `пересекает пробел — у части камер внутри нет записи` |
| `pill.tip` | `Fleet-wide — opens the Live wall filtered to {x}` | `По всему объекту — открывает эфирную стену с фильтром «{x}»` |
| `edit.capHit` | `16 of 16 — deselect one first` | `16 из 16 — сначала снимите одну` |
| `exp.gridNo` | `backend endpoint not shipped — this part will fail honestly` | `эндпоинт бэкенда ещё не готов — эта часть честно не выполнится` |
| `nf.title` / `nf.sub` | `No footage anywhere on this wall in this window.` / `Not one of these cameras recorded here. Pick a day with a dot, or widen the window.` | `В этом окне ни одна камера стены не записывала.` / `Ни одна из этих камер здесь не писала. Выберите день с точкой или расширьте окно.` |

Every count string needs EN 2-form and **RU 3-form** plurals. Audit by extraction, not by eye: pull every text literal and every tooltip and diff against this table. Allow-list: brand names, key names, vendor model strings, `UTC+3`.

---

## 7 · Acceptance checklist

- [ ] **Three distinct cell states**: recording (picture + quiet identity), dormant (hatch + `NOTHING RECORDED` + a clickable nearest-footage offer), empty (`+ ADD CAMERA`). A dormant cell and an empty slot are never the same pixels.
- [ ] The dormant cell's offer **seeks the whole wall** to that camera's nearest footage, and reads `none in this window` when the camera has nothing at all.
- [ ] **One clock**, in the **top block of the aside** — `weekday · date` over `hh:mm:ss` + `accent` milliseconds. **Nothing is drawn over the mosaic except the per-cell overlays.** No permanent per-cell timestamps.
- [ ] **Tier 1 archive ribbon** above the scrubber: 35 day cells with the remainder distributed, week banding, per-day wall density, dimmed-inert empty days, today ringed, selected day marked, and **the loaded window drawn across it** so a rolling window visibly straddles two days.
- [ ] Holding `T` stamps **every** cell simultaneously; releasing removes them. The sync badge reads `1 STREAM · {lit}/{total} RECORDING`.
- [ ] A recording cell with motion within ±2s takes a 2px `accent` ring and a `MOTION` tag. Dormant cells never do.
- [ ] Hovering a cell highlights its lane **and** its roll-call row, and vice versa — one shared `hoverCamera`, three renderers.
- [ ] Roll call lists every wall camera in **grid reading order** with state, motion sparkline and jump offer; it is the aside's growable child and leaves no dead space at any camera count.
- [ ] The window statement names its **model** (`ROLLING` / `CALENDAR DAY`) before its value and states what the far-left edge is. The two never print the same words.
- [ ] Scrubber: 14px coverage (with `warming` as a distinct colour, never a gap) · 15px ruler · lanes taking the remainder; resizable 36–420px from a grip that costs **0px** at rest; 7px lane floor, labels at ≥11px, lane area scrolls below the floor.
- [ ] A lane with no footage in the view takes the `bad` hatch.
- [ ] All preserved: click-seek, drag In→Out with a 4px threshold, wheel-zoom at cursor clamped to the window, `Shift`-pan, `FIT`, lane toggle, calendar day load with debounce, group scoping with counts and an inert 0-camera group, right-click swap, drag rearrange, 16 cap, dual-archive export, return to live.
- [ ] In→Out spanning a gap says so in the selection chip.
- [ ] Cell overlays are positioned from the server's `cells[]`, and survive a re-composite without mislabelling.
- [ ] The top-bar pills carry `↗`, state their action in a tooltip, and navigate.
- [ ] Title bar reads `WATCHTOWER · Wall playback`.
- [ ] Full keyboard map (§3), physical-code bound, `Esc` unwinding one layer per press.
- [ ] All six honest states from §4 render as tag + fact + consequence.
- [ ] Correct at 1920×1080, 1440×900 and 1200×900, EN and RU, with 3-form plurals.
- [ ] **Success test:** at 03:00 with 2 of 16 recording, an operator can say at a glance which cells hold video and which had nothing to record; can read the moment *including the day* without hunting; and can mark a range and export the whole site's view of it without leaving mouse-and-keyboard.
