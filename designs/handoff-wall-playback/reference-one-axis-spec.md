# Playback — redesign · "One Axis"

**Reply to** `docs/design-briefs/2026-08-09-playback-redesign.md`
**Date:** 2026-08-09 · **Status:** ready to build
**Prototype:** `playback-redesign-prototype.html` — live tweaks for footage density, event count, **honest state**, EN/RU, 1440/1200. Where this document and the prototype disagree, **this document wins.**

**Language:** continues Triage "Lanes", Verify "Strips" and Groups "Wall". Gapless hairline cells, computed (never converging) layout math, overlays on the picture rather than columns beside it, one predicate behind every count, honest states that name themselves.

---

## 0 · The decision

**The calendar and the zoom buttons are not two navigators. They are one axis at two scales.**

That is the whole redesign. Problem 2 in the brief — *"a guard asked 'yesterday 3pm' must use both"* — is not a labelling failure, it is a modelling failure: the product owns one thing, a time axis 35 days long, and has been drawing it twice in two idioms in two corners with no visible relationship between them.

So Playback gets **one navigator**, in two tiers that share a horizontal time axis and are always visible together:

```
┌ ARCHIVE ─────────────────────────────────────────────────────────────┐
│ last 35d · 4 days w/ footage │ ▁▁▃▁▁▁▁▁█▁▁▁▁▂▁▁▁▁▁▁▁▁▅▁▁█▁▁▁▁▁▁█▁▁ │  tier 1 · 35 days
├──────────────────────────────┴───────────────────────────────────────┤
│ PLAYHEAD Sun 22:21:55 │ 3 segments · 7% covered │ … │ 15M 1H 6H 12H 24H│
├──────────────────────────────────────────────────────────────────────┤
│ FOOTAGE  │ 21:55      22:00      22:05      22:10      22:15         │  tier 2 · the window
│ MOTION   │ ▬▬   ▬        ▬▬▬▬        ▬     ▬▬▬▬▬▬        ▬▬          │
└──────────────────────────────────────────────────────────────────────┘
```

Tier 1 is the month calendar, **unrolled onto the axis it was always describing**. Tier 2 is today's timeline. The span buttons are now visibly *tier 2's* zoom, not a rival navigator — and an amber bracket inside the selected day cell shows exactly where the window sits in it, so the relationship the old screen never drew is now a visible object.

| brief problem | how "One Axis" answers it |
|---|---|
| **1 · chrome vs video** | The info rail is **dissolved** (§1). The video keeps the full width; the navigator costs 111px. **1254×706 picture against today's ~1120×630 — +24% area.** |
| **2 · two competing navigators** | One axis, two tiers, one bracket linking them. Answered structurally, not by relabelling. |
| **3 · transport is 8 undifferentiated cells** | Four gapless groups by *job*: move · rate · evidence · exit (§2.3). |
| **4 · speed cycling, scan invisible** | A **120px ladder** showing all ten rates at once, with rates above 10× **colour-marked** in `bad` across a hairline break, and a `bad` rate chip on the picture. No jargon (§2.4). |
| **5 · events list and motion lane are the same data twice** | One selection model. Hover or select in either highlights both; the type chips filter both (§2.6). |
| **6 · density: five static rows, Coverage reads like trivia** | `Playhead`, `Quality`, `Window` leave the rail; **`Coverage` is promoted onto the navigator header** beside the lanes it describes, as `3 segments · 7% covered` (§2.5). |
| **7 · no keyboard story** | `,` `.` step · `J K L` shuttle · `←→` ±10s · `[` `]` mark · `1–5` span · `Space` `S` `X` `F` (§3). |
| **8 · export is hidden** | Export stops being a drawer and becomes **a selection on the timeline**: `[` and `]` mark a range, the range is an amber bracket across both lanes, and the export button carries its duration (§2.7). |

### Density arithmetic, 1440×900

```
top bar 52 + tab strip 30                            =  82
navigator: ribbon 42 + header 26 + ruler 15 + lanes (14+18)  = 115
stage height:  900 − 82 − 115 − 2 rules              = 701
video (16:9, height-constrained):                    = 1246 × 701
─────────────────────────────────────────────────────────────────
today: stage shares width with a ~340px rail AND a ~180px timeline
       →  ~1120 × 630
picture area:  873k px²  vs  706k px²                = +24%
```

Every one of those five numbers is load-bearing: `laneH = navH − 83` (§2.2b) subtracts the ribbon, header and ruler as constants, so **CSS must give the ribbon an explicit `height: 42px`**. Left content-sized it renders 36.5px, the constant over-subtracts, and the difference lands as a dead strip of `bg` under the MOTION lane at every drag position — a flexible container whose children are all fixed relocates the void rather than filling it.

At **1200×900** the video becomes width-constrained: 1198×674. The navigator is unchanged — its tiers are proportional, not fixed-count.

### What happened to the month calendar

It is still here — **unrolled**. The §3.3 grid and the §3.4 span buttons were the brief's problem 2, and a grid cannot be tier 1 of a shared axis because its second dimension is not time, it is *week wrapping*. So the grid became a row.

A grid earns its keep in exactly one way, and it must be paid back: **weekday alignment.** In a Mon–Sun grid all Thursdays share a column, so "last Thursday" is a column scan. The brief's own success test is a weekday question, so this is not a nicety.

The ribbon pays it back by **being week-structured rather than merely 35 cells long**:

- retention begins on a Monday and the ribbon runs Mon→Sun, so **every 7th cell is a Monday**;
- a 1px `line2` @55% divider falls before each Monday, cutting the ribbon into week blocks;
- alternate week blocks carry a `rgba(240,236,228,.028)` tint, so the five weeks read as five bands;
- **Thursday is therefore always the 4th cell of a block** — position, not counting.

The first draft of this ribbon had none of that and drew 35 undifferentiated cells, which threw away structure the data already had. Week banding is not decoration; it is the grid's one real advantage, recovered on a single axis.

What the grid still cannot do, and the ribbon does: show **how much** footage each day holds, as a density bar, and put that directly above the timeline it feeds.

---

## 1 · The rail is dissolved, not shrunk

The brief's problem 1 invites "make the rail resizable". That is deferring the decision to the operator. Instead, each of the rail's seven blocks was asked *what is this for* and sent where it belongs:

| rail block | verdict |
|---|---|
| `Playhead` | **Deleted.** It is burned into the picture at millisecond precision, 20px, top-right. A second copy in 10px mono is not information. |
| `Last motion` | **Moved to the navigator header** as an action cell: `LAST MOTION 22:17:07 ›`. It was never a status value — it is a jump, and it belongs with the other navigation. |
| `Quality` | **Moved to hover** on the camera name. Static per session; it does not earn a permanent row. |
| `Coverage` | **Promoted** to the navigator header, beside the lanes it describes (§2.5). |
| `Window` | **Deleted as a readout.** It is the span control; a control does not need a label restating its own state. |
| `FOOTAGE` calendar | **Became tier 1 of the navigator.** |
| `EVENTS` | **Kept**, as the one genuinely list-shaped thing — as a toggleable overlay (§2.6). |

Five of seven blocks were either duplicates of the picture or restatements of a control. The rail was not too big; it was mostly not information.

---

## 2 · Anatomy

### 2.1 · Video stage

Fills everything between the tab strip and the navigator. Letterboxed on `#0b0a0a`, frame drawn at its own aspect, centred. **The video's geometry never changes in response to a panel opening** — same rule as the Groups wall: overlays layer, they do not reflow. What *does* move is the video's own chrome (§2.6).

**Top-left overlay** — `‹` back · the mode chip · camera name + IP (13px, white @82%, 1px black shadow).

The mode chip is mono 9.5px caps, letter-spacing 1.3:

| state | chip |
|---|---|
| archive playback | `PLAYBACK`, `accent` on `#241a08` |
| returned to live | `LIVE`, `good` |
| **rate > 10×** | **`SCAN 50×`, `bad` on white** — see §2.4 |

**Top-right overlay** — the evidentiary timestamp. Mono **20px** DemiBold white (`16px` below 1300px window width), `0 1px 4px` black shadow:

`Sun 9 Aug 2026 · ` in white @62% then `22:21:55` in white then **`.370` in `accent`** — **all at the same 20px**.

The date is not a caption on the time; it is the same reading, and a size step made it read as subordinate rather than as part of one value. Hierarchy is carried entirely by **contrast** — 62% white for the date qualifier, full white for the value, `accent` for the milliseconds — which separates the three parts without breaking them into two objects.

**The top-bar wall clock must NOT take this treatment.** It was briefly given the same face, size and weight, and the result was two full date-and-time readings of identical shape sitting 40px apart — one the frame's, one the wall's — which is a duplication, not a system. They are different facts: the frame timestamp answers *when did this happen*, the wall clock answers *what time is it now*, and only the first is evidentiary. The clock stays in the top bar's own pill idiom — running `hh:mm` plus the zone, mono 10px, `ink2` — carrying no date at all, because the date it would show is either today's (already implied) or a repeat of the frame's.

The milliseconds are the only part in colour, because the millisecond field is what distinguishes this from a clock: it is the frame's identity. **This element may never be occluded** (§2.6).

### 2.2 · Navigator tier 1 — the archive ribbon · 42px

| part | spec |
|---|---|
| label block | **120px, a hard width** — the ribbon track and the ruler track align on it, so it may not grow to fit its text; the text yields, not the block. Line 1: `ARCHIVE` (mono 7.5px caps, `ink3`) with the **selected day** pushed right — `Sun 9`. Line 2: **how much footage that day actually holds** — `50m · 83 clips` (mono 8.5px, `ink2`, ellipsized), or `no footage this day`. Day totals round to whole minutes. |
| track | the remaining width, divided into **one cell per retention day** |

**Cell width is `paneWidth / days` with the remainder distributed**, one extra pixel to each of the first `remainder` cells — never `floor()`, which leaves the ribbon ending short of its track (the Groups wall trap, and it is worse here because the ribbon must align with the ruler beneath it).

Cell contents, bottom-aligned: weekday label (**mono 8px, letter-spacing 1.2**, `ink3`) · day number (mono 10px, `ink2`) · a **4px density bar** whose height is that day's recorded minutes against a 6-hour ceiling.

**The weekday label sits at the brief's §2 floor deliberately, not below it.** Every mono micro-label in this screen is ≥8px with letter-spacing 1.2–1.6; the weekday label in particular carries the ribbon's entire wayfinding argument (§0), so it may not be the smallest text in the design. "Wed" measures 18px at that size against a 37.7px cell, so the floor costs nothing.

| state | render |
|---|---|
| has footage | full colour, `good` density bar, hover `panel2` |
| **no footage** | day number at `ink3` @42%, no bar, **inert** — per the brief, dimmed and not clickable |
| today | 1px `ink3` inset ring |
| **selected day** | `accentSoft` fill, 2px `accent` bottom bar, `accent` day number |
| **window bracket** | inside the selected cell only: an `accent`-outlined band at `(winStart−dayStart)/24h`, min-width 2px — where tier 2 is looking |

**What this block must not contain.** It first carried `last 35d · 4 days w/ footage`, and both halves were restatements of the picture six pixels to their right: the retention span *is* the ribbon's left edge, and the count of days with footage *is* the dots. That is the same failure the info rail was dissolved for (§1) — a label describing the visualisation beside it is not information. The block instead carries the one fact nothing else on the screen states: **the quantity behind the dot you just clicked.** The dot answers *is there anything here*; the block answers *how much*, which is what decides whether scrubbing this day is worth the guard's next two minutes. It is live — it retargets on every day click.

At retention lengths where the ribbon degrades below a countable number of cells (§2.2, <15px), the block regains a `{n} days w/ footage` line, because at 90 dots the count stops being something the eye can do and becomes information again.

**Week and month structure.** A 1px `line2` @55% divider falls before every Monday, and alternate week blocks take a `rgba(240,236,228,.028)` tint — this is what makes weekday position readable (see §0). Month boundaries get a stronger full `line2` divider plus a mono 7px month label. Both are computed from the dates, never from a cell index, so they survive any retention length and any start weekday.

**Degradation with retention length** (the ribbon must survive a 90-day install):

| cell width | render |
|---|---|
| ≥ 26px | weekday word + day number + bar |
| 15–26px | weekday **letter** + day number + bar |
| < 15px | density bar only, with month dividers and Monday ticks |

Density never disappears — it is the last thing to survive, because it is the thing the ribbon exists for.

### 2.2b · Both panels resize

The brief's problem 1 is that *neither the rail nor the timeline is resizable*. Two real grips:

| grip | range | reset |
|---|---|---|
| **navigator height** — straddles its top edge, 7px tall, `position: absolute` so it **costs no picture** | **101px** to 52% of the window | double-click |
| **events panel width** — its left edge, 6px | 232–560px | double-click |

Both show a 36×1px `line2` nub that turns `accent` on hover and during the drag, with `accentSoft` behind it.

The floor is `83 + 18`, not 83: the fixed chrome plus the lanes' own minimum, **stated once and shared** by the clamp and the lane arithmetic. Given as two independent numbers they disagree at the extreme, and the drag reaches a position where the lanes are 18px tall inside 0px of remaining container.

**Only the lanes absorb the change.** Ribbon (42), header (26) and ruler (15) are fixed; `laneH = navH − 83` is split 14:32 / 18:32 between FOOTAGE and MOTION, and FOOTAGE takes all of it when MOTION is hidden. Growing a container whose children are all fixed does not fill space, it relocates the void — the Groups console lesson, and here the lanes are the child that genuinely scales, because a taller MOTION lane is a bigger hit target in a 24H window with 200 events.

**The video re-letterboxes on every change**, and the fit must be **keyed on the state that causes it** — the navigator height, the window width, the panel width — and not left to a resize observer alone. An observer-only fit lags one drag-step behind, and a frame taller than its stage is *cropped*, not letterboxed (§7).

### 2.3 · Navigator header · 26px

Gapless cells, hairline-separated, in order:

`PLAYHEAD / Sun 22:21:55` (120px, matching the label block above) ‖ **coverage** ‖ `LAST MOTION 22:17:07 ›` ‖ `MARKED 4m 12s ✕` ‖ spacer ‖ `MOTION` ‖ `EVENTS` ‖ `15M` `1H` `6H` `12H` `24H`

**Picking a day never changes the span.** It changes which day is loaded and where the playhead sits — nothing else. An earlier build forced 24H on every ribbon or grid click while first paint opened at 1H, so the same day showed a 1H slice on arrival and a 24H sweep after a day-hop and back: 24× the window, 24× the events, with no visible cause. The operator reads that as the archive changing under them, and it is the fastest way to make a screen feel untrustworthy.

The span is a view setting and it belongs to the operator, exactly as the group-filter selection does elsewhere in the product — predictable beats convenient. Tier 1 already answers "how much is in this day" without a zoom change, so nothing is lost by leaving the zoom alone.

Landing position **is** a stated rule: a day click seeks to just inside that day's first segment, so the window always opens on real footage. First paint instead opens on the newest footage in retention, because "what happened most recently" is the commonest arrival. Both are deliberate, and both leave the span untouched.

The two ghost toggles (`MOTION`, `EVENTS`) take `accentSoft` + a 2px `accent` underline when on; the span buttons take a **solid `accent` fill** when active, because one of them is always true and the set is a radio, not a pair of switches.

`LAST MOTION` and `MARKED` render **only when they have something to say** — the header is not padded with disabled cells.

### 2.4 · Transport · four groups, on the picture

A gradient scrim (transparent → 86% black) carries the groups, each a `rgba(13,12,11,.72)` block with a 1px `line2` inset ring. Cells are 34px tall, hairline-separated inside the group, 9px between groups.

**There are exactly two anchors, and one rule: left = act on the footage, right = leave the screen.** Everything the operator does *to* the recording — navigate it, set its rate, take evidence out of it — sits in a continuous left run, read in that order. The only right-anchored group is the two ways off the screen. A third floating cluster has no edge to belong to: its position is then decided by the widths of whatever sits beside it, which from the operator's side is arbitrary. An earlier draft had evidence, capture and exit all crowded against the right edge, and the middle one read as aligned to nothing.

| group | cells |
|---|---|
| **move** *(left)* | `‹‹` back 10s · `❘◀` step back · **`▶/❚❚` 42px** · `▶❘` step forward · `››` forward 10s |
| **rate** *(left)* | the speed cell, opening the ladder — **directly beside the step buttons**, because it modifies how they move |
| **frame** *(centre)* | `⊞`, icon only, 42px — **and, in frame mode, `[` `]` `↥ export` in the same group**, hairline-separated, the whole cluster centred as one |
| **evidence** *(left)* | **only in frame mode:** `[` mark in · `]` mark out · `↥ 4m 12s` export |
| *(spacer)* | |
| **exit** *(right)* | `⛶` fullscreen · **camera** snapshot · **camera T** snapshot with timestamp · `● Return to Live` |

Snapshots sit in the right group between fullscreen and Return to Live: they are single-click actions that end an errand, like the two beside them, and they need no frame-accurate setup. The icon is a **drawn camera** — a 15×11 body with a lens circle and a top bump, in `currentColor` — not a filled square, which named nothing, and not an emoji.

Snapshots and range-marking are one group because they are one job — getting evidence out — ordered instant-first, deliberate-second. **The export cell ends the run** because it is the only cell whose width changes (`Export` → `4m 12s`), so nothing it grows into can shift a neighbour the operator is aiming at.

**Speed ladder geometry.** 120px wide, opening upward from the rate cell. Ten rate rows at 24px, and between 10× and 20× a **5px hairline rule** — no text.

**The scan boundary is shown, not named.** Rates above 10× are rendered in `bad` against `ink2` for the rest, carry a small `▸`, and the picture gains a second chip in `bad` reading just the rate (`50×`) beside the unchanged `PLAYBACK` chip. The words `SCAN` and `frames skipped` are gone from the interface.

This is a deliberate reversal. "Scan" and "frames skipped" are engineering vocabulary; on a screen a guard uses under pressure they read as a fault report rather than a mode, and the likeliest response to unexplained red jargon is to stop and ask someone. The honesty requirement is that the *behaviour* be disclosed, not that it be named in the operator's face: the colour marks the boundary at a glance, the picture visibly jumps, and the rate cell's tooltip says it in plain words — **"Playback rate — J / L. Above 10× the picture skips ahead to keep up."** A guard who wonders gets a sentence; a guard who doesn't is not alarmed by one.

#### Archive preference — ribbon or classic grid

Tier 1 has two presentations, an operator preference. **`ribbon` is the default and the recommendation** (§0); `calendar` exists because reading a month as a *shape* is a real, learned skill and some operators have years of it.

| | `ribbon` | `calendar` |
|---|---|---|
| tier 1 | 42px ribbon | **none** — the calendar is in the rail |
| navigator | 115px | **73px** |
| video, rail closed | 1246×701 | rail is always open in this mode |
| video, rail open | 1142×642 | **1142×642 — identical** |
| footage at a glance | all 35 days, as quantity | the open month, as dots |

**Calendar mode costs no picture at all once the rail is open.** With the rail out, the video is width-bound (1438 − 296 = 1142 → 642 tall), and 642 is well inside the 743 the shorter navigator leaves — so the extra height ribbon mode would have bought is height the picture cannot use anyway. The mode's real cost is that the rail is *always* open, which is only a cost for an operator who would otherwise have closed it.

**It is persistent, and it lives in the right rail** — above the events list, in the same column, under an `ARCHIVE` header carrying the selected day's total. A first pass put it behind a `▦` cell in the navigator header (that is a date picker, not a calendar — the product already had one), and a second put it in tier 1 beside a day strip, which cost 110px of picture height. The rail costs none, because of the arithmetic below.

The grid is classic: Mon–Sun columns, 22px day cells, a `good` dot on days with footage, dimmed-and-inert days without, today ringed, the selected day filled `accent`, `‹ ›` between the months retention spans. Row count is derived from the month, so most months take five rows rather than a padded six.

**Beside it, a 24-hour day strip** fills the rest of tier 1: the selected day's footage across midnight-to-midnight, hour ticks, and the loaded window drawn on it as an `accent` bracket. Clicking seeks. This is what makes the mode coherent rather than a grid with 1000px of dead space next to it — **calendar picks the day, strip picks the hour, lanes hold the window**: three tiers of one axis, which is the same idea as the ribbon at a different grain.

**Why this does not reinstate problem 2.** The grid lives *in the navigator header, in the same row as the span buttons* — days on the left, spans on the right, one control strip. Problem 2 was a calendar in one corner and zoom buttons in another with no visible relationship; a popover anchored beside the spans it feeds is not that. It is still one navigator; only tier 1's presentation changes.

**What `calendar` costs, stated plainly:** the rail can no longer be dismissed, and footage density stops being ambient across retention — the ribbon answers *is it worth scrubbing here* for all 35 days at once as a quantity; the grid answers it for the open month only, as a yes/no dot. What it buys is the month as a *shape* — which weekday, which week, how the month is filled — read without a click by an operator who has years of that habit. Since the picture cost is nil (above), this is a genuine preference rather than a compromise.

#### Frame-by-frame mode

`F`, or the `⊞` cell at the **centre of the bar**, enters the brief's §3.2 frame-by-frame affordance. Entering it **pauses playback and returns the rate to 1×** — stepping frames at 50× is not a thing — and **reveals `[`, `]` and `↥ export`** at the end of the evidence group. Leaving it — by `F`, the `⊞` cell, or `Esc` — clears any marked range, as part of leaving.

**`Esc` must unwind exactly one layer, most-nested first** (fullscreen → ladder → frame mode → selection). A flat handler that clears everything at once let `Esc` destroy a marked range while leaving the operator inside the very mode the on-picture chip advertises exiting — a signposted trap that is still shut, and worse than an unadvertised one.

The reasoning: range-marking is precision work on a specific moment, and it is meaningless at scan speeds. Tying it to the mode that already means *"I am working on this moment"* removes three cells from the bar during ordinary review and puts them there exactly when they are wanted.

**This must not re-hide export** (brief problem 8). Four things keep it discoverable: the mode has a **visible labelled cell**, not just a key; entering it is one click from the bar the operator is already using; the marked range remains a **visible object on the timeline** (§2.7) rather than a setting inside a drawer; and **`[` / `]` enter frame mode themselves**.

That last one is not a convenience. Gating the *cells* on the mode while leaving the *keys* ungated lets a range be created that is drawn on the timeline, counted in the header, and has no export control anywhere on screen — problem 8 rebuilt, in a worse form, because now the operator can see the selection and still cannot act on it. Pressing a mark key **is** the statement "I am working on this moment", which is the same reasoning that justifies gating the cells; the keys must therefore assert the mode rather than assume it. Making them inert instead would be worse still — two documented shortcuts that silently do nothing.

**Every advertised shortcut must do something visible.** `Shift F` appears in the fullscreen tooltip, so it enters fullscreen: the top bar, tab strip and navigator hide and the video fills the window (1438×809 at 1440×900); `Esc` or the `⛶✕` cell leaves. A key that is intercepted and then does nothing is a silent no-op control, which §1 forbids.

**The frame toggle owns the centre of the bar, and is pinned there absolutely** (`left: 50%`, translated back by half its width) rather than floated between two flex spacers. Spacers centre it on *the leftover space*, so revealing the range cells beside it slid the toggle 75px — the worst possible behaviour for the one control an operator presses to enter that mode. Absolute centring makes its position depend on the bar alone, so it is identical in both states and at every window width.

It is **icon only**. The centre is a position nothing else can claim, and that is what marks it as a mode rather than an action; the ⊞ carries the meaning and the tooltip names it. A word there would make it read as one more button in a row of buttons.

**The range tools sit inside the same group as the toggle** — hairline-separated cells in one block, not a neighbouring block with a 9px gap. Two adjacent groups read as two objects that happen to be near each other; one group reads as a switch and its consequences. A switch and the tools it reveals are one object; putting them at opposite ends of the bar makes the operator hunt for the consequence of the thing they just pressed. The cluster centres as a whole, so the ⊞ does shift when the tools appear. That is the accepted cost of keeping them together, and it is bounded: entering the mode is one deliberate press, not a repeated one.

#### The filmstrip

Frame mode opens a **96px band between the picture and the navigator**: nine frames at the decoder's 40ms step, four either side of the playhead, each 16:9 with its own `hh:mm:ss.mmm` caption; the current frame is ringed `accent` with an `accent` caption. Clicking a neighbour seeks to it.

**Cells are flexible, not fixed** — `flex: 1` with a 171px width cap, an 80px height cap and a 16:9 ratio, so whichever dimension binds drives the other and the band fits its frames at any window width. The band is padded by the rail's width so the frames sit under the *picture*, not under the rail.

**The exit legend is not in the band.** It began as a tag inside the strip, which cost picture-grade width for a sentence — and, laid out inline, clipped to `FRAME-BY-FRAME · F / Esc to exi`, losing the exit instruction that was its only purpose. Mode indication already has a home: the chip row on the video, beside `PLAYBACK`. It moves there as an `accentSoft` chip reading `⊞ FRAME-BY-FRAME · ESC TO EXIT`, which costs nothing, sits where the operator already looks for mode, and gives the band back two more frames.

**This is what frame mode is for.** Stepping through a 25fps archive changes the picture almost imperceptibly frame to frame — the operator presses `.` and cannot tell whether anything happened. The filmstrip makes the step legible by showing the neighbours it moved between, and it turns the surrounding second into something you can read at a glance rather than reconstruct from memory. It also makes the §3.6 asymmetry visible in the right place: the frames to the left are the expensive direction, and they are on screen already rather than fetched on each press.

The band costs 112px of picture (701 → 631 at 1440×900) and is present **only in frame mode** — precision work, where a smaller picture and more context is the right trade.

The right group is unchanged and stays **flush to the right edge of the visible video**, 11px in. When the events panel is open it clears the *panel*, not the panel plus the letterbox margin — the panel already covers that margin, so subtracting both leaves the exit group parked ~105px short of any edge, aligned to nothing.

Evidence and capture cells are `good`; `Return to Live` is `bad`-tinted and labelled. Destructive-adjacent actions are now two groups away from frame stepping, with a spacer between — you cannot fat-finger an export while stepping.

**Backward stepping is visibly asymmetric.** `❘◀` paints a 2px `accent` hairline across its own bottom edge for the duration of the cache fetch. It is not a spinner and not a disabled state — the step still happens; the hairline is the honest signal that this direction costs more. Per §3.6, forward stepping never shows it, and key-repeat on `,` is rate-limited to the cache's refill.

### 2.5 · Coverage — promoted, and the honesty readout

In the navigator header, mono 9.5px:

`3 segments · 7% covered`   —   `segments` in `ink2` DemiBold, the rest `ink3`.

When the window holds nothing: **`no footage in this window`, entirely in `bad`**, and the FOOTAGE lane itself carries a centred `NO FOOTAGE IN THIS WINDOW` in mono 9px caps. Both, because the readout answers "should I be scrubbing here" and the lane answers "and here is the nothing I mean".

This is the number that predicts whether scrubbing is worth it, so it sits **next to the lanes it describes** rather than fifth in a key/value stack. A motion-recorded fleet routinely reads 4–7% — that is not a bug, it is the truth the old screen buried.

### 2.6 · Navigator tier 2 — ruler and lanes · 47px

Label block 120px: `FOOTAGE` (`good`) over `MOTION` (`accent`), both mono 7.5px caps.

**Ruler, 15px** — ticks at an interval chosen from the span, tall ticks and mono 8.5px labels at the label interval:

| span | tick | label |
|---|---|---|
| 15M | 1 min | 5 min |
| 1H | 5 min | 5 min |
| 6H | 30 min | 1 h |
| 12H | 1 h | 2 h |
| 24H | 1 h | 3 h |

**`FOOTAGE` lane, 14px** — `good` blocks on `#151412`, min-width 1px. **Gaps are literal.** A motion-recorded camera produces a comb of 80–120 segments a day totalling under an hour; the lane must show exactly that and never round short gaps away into a continuous bar.

**`MOTION` lane, 18px** — `accent` bars, min-width 2px, aligned to the same axis.

**Playhead** — 1px `ink` line, full height of both lanes, with a 9×7px triangular handle.

**Scrubbing respects §3.6.** Dragging the playhead **previews only**: the line follows the pointer, a mono 10px `ink`-on-`bg` chip above it reads `22:21:55 · release to seek`, and **exactly one seek is issued, on release.** A drag that seeks per pointer-move would issue 60 session re-opens a second against a p90 of 986 ms. The chip's second half is not decoration — it tells the operator why the picture has not moved yet.

**The events list and the motion lane are one selection model** (problem 5). A single `hover` id and a single `selected` id are shared:

| in the lane | in the list |
|---|---|
| bar hover → `ink` fill | row gets `panel2` |
| bar selected → white fill + `accent` ring | row gets `accentSoft` + `accent` left bar |
| bar click → select **and seek** | row click → select **and seek** |

The type chips filter both simultaneously. There is no state in which the two disagree, because there is only one state.

**The right rail is a column, not an overlay** — 296px, resizable, `panel`, and the stage shrinks around it.

This reverses the Groups rule deliberately. There, a panel overlaid the wall because a covered tile is still exactly where the operator left it; the objects are independent and findable. **A single continuous video frame is the opposite case.** Overlaid, the picture is larger but a third of it is hidden and the visible remainder is off-centre — and worse, everything centred *on the stage* (the §4 honest-state banners above all) centres on a stage the operator can only partly see, so `Could not open a playback session` sits visibly off to the right of the picture it is about. Smaller and whole beats larger and half-hidden, and it makes every centred element correct by construction rather than by a per-element offset.

Rows are 28px: 6px type dot · label · right-aligned mono 10px time. Newest first. Empty states distinguish *no events* from *none of the selected types* — the filter names itself.

### 2.7 · Export is a selection, not a drawer

Problem 8's fix is to stop hiding export behind a door and make **the range a visible object on the timeline**:

1. `[` or the mark-in cell sets the in-point at the playhead (default 30s out-point).
2. `]` or mark-out sets the out-point.
3. The range renders as an **amber bracket band across both lanes**, `accent` @13% fill with 1px `accent` edges and `[` / `]` end caps.
4. The header grows a `MARKED 4m 12s ✕` cell.
5. The export cell **carries the duration**: `↥ 4m 12s`, and is inert until a range exists.

Export is now discoverable because you can see the thing you would be exporting. The drawer still opens on click, for quality / destination / purpose — but it is a confirmation step for a decision already made and visible, not the place the decision is hidden.

---

## 3 · Keyboard

| key | action |
|---|---|
| `Space` | play / pause |
| `,` `.` | step one frame back / forward |
| `J` | **step down the rate ladder** |
| `K` | pause |
| `L` | play; pressed again, **step up the rate ladder** |
| `←` `→` | ∓10 s · with `Shift`, ∓1 min |
| `[` `]` | mark in / out at the playhead — **enters frame mode if it is not already on** |
| `1`–`5` | span 15M / 1H / 6H / 12H / 24H |
| `S` / `Shift S` | snapshot / snapshot with timestamp |
| `X` | export marked range |
| `F` | **frame-by-frame mode** — pauses, sets 1×, reveals mark/export |
| `Shift F` | fullscreen — chrome hides, the video fills the window; `Esc` leaves |
| `Esc` | **unwinds one layer, most-nested first:** fullscreen → open speed ladder → frame mode → selection and mark |

**`J` is not reverse shuttle, and this is deliberate.** The industry idiom is `J` = play backwards, and §3.6 forbids it: reverse playback means decoding from a keyframe for every frame delivered. Rather than ship a `J` that stutters and lies about the engine, `J` walks the rate ladder *down* — the honest neighbour of `L`. Say so in the tooltip (`Playback rate — J / L`) so the operator who expects Avid semantics learns the local rule in one hover.

Keys bind by **physical code** (`Comma`, `Period`, `KeyJ`, `BracketLeft`, `Digit1`), never by character — on a Russian layout the character keys emit Cyrillic and every one of these bindings would silently die.

---

## 4 · Honest states

All are prototype tweaks, so they can be reviewed rather than imagined.

| state | render |
|---|---|
| **no footage at this moment** | Picture dark; centred block: `FOOTAGE` tag · **"No footage recorded around this moment."** · "The archive has a gap here. The nearest recorded footage is below." · a **`Nearest footage 21:24:10 →`** button that seeks there. The nearest-footage offer is computed from the lane data the operator is already looking at — an honest empty state that also does the next thing for you. |
| **playback switched off** | `PLAYBACK` tag in accent · "Playback is switched off — recorded playback and export are paused." · "An operator turned this off in settings. Live view is unaffected." · `Open settings`. Transport disabled, navigator **still live** — the archive ribbon is still true. |
| **recording switched off** | Not a blocking banner: a `NOT RECORDING` chip under the camera name with "The archive below is everything this camera has. It will not grow while recording is off." Playback of existing footage is unaffected, so it must not be blocked. |
| **camera offline, archive intact** | `OFFLINE` chip (`bad`) + "Its archive is complete up to the moment it dropped, and is fully playable below." **Everything below the chip works.** Offline is a live-stream fact, not an archive fact — the one state the old screen was most likely to conflate. |
| **session failure** | `ERROR` tag in `bad` · "Could not open a playback session for this camera." · "The recording service did not answer. Nothing has been lost — this is a connection problem." · `Retry`. |
| **empty archive** | "This camera has no recorded footage in the last 35 days." · "Nothing to play back. The archive ribbon is empty because the archive is empty." The ribbon renders all 35 cells, all inert — the emptiness is shown, not hidden. |
| **`Coverage 0 segments`** | Header reads `no footage in this window` in `bad`; lane carries `NO FOOTAGE IN THIS WINDOW`. |

Every banner has three parts — **a tag, a fact, and a consequence** — and, where one exists, an action. None says "something went wrong".

---

## 5 · Edge cases

| case | behaviour |
|---|---|
| **No footage at all** | §4 empty archive. The ribbon is 35 inert cells; the span buttons still work and still say `no footage in this window`. Nothing is disabled that would leave the operator unable to confirm the emptiness. |
| **One 3-second clip in 35 days** | Ribbon: one cell with a 1px density bar. Clicking it loads 24H and puts the playhead at the clip. At 24H the segment is 0.003% of the width → **rendered at the 1px minimum**, so it can be seen and clicked; the coverage readout says `1 segment · 0% covered`, which is honest and not a contradiction — the percentage is rounded, the count is not. |
| **24H window, 200 events** | Motion lane bars collapse toward min-width 2px and visually merge into dense blocks — correct, that *is* the shape of the day. The list stays scrollable and stays the precise instrument; the lane is the overview. No decimation, no "+N more": the lane is a density plot, not a list. |
| **Playback switched off** | §4. Ribbon and lanes remain live and truthful. |
| **RU at 1200px** | Longest strings are the banners (flexible, 460px max, wrap) and `ПОСЛ. ДВИЖЕНИЕ 22:17:07 ›`. Cells are content-sized so the header absorbs it; the span buttons are digits. Ribbon cells carry Cyrillic weekday letters at the same 7px. No layout change. |
| **1200×900** | Video 1198×674 (width-constrained). Navigator identical — ribbon cells 30px, still above the 26px threshold, so nothing degrades. Timestamp drops to 16px. |
| **Camera offline but archive exists** | §4. |
| **Playhead dragged into a gap** | On release, the seek lands and the no-footage banner appears with its nearest-footage offer. It does **not** snap silently to the nearest segment — that would be the player deciding where the operator meant to look. |
| **Rate > 10× across a gap** | Scan jumps the playhead in steps; entering a gap shows the banner and **scan continues** (it is skipping frames anyway). Dropping back to ≤10× inside a gap pauses. |
| **Same day, two arrivals, different counts** | Legitimate and must stay legitimate. Every count on this screen — `N segments · X% covered`, the events list, the motion bars — is scoped to **the loaded window**, not the day, so a 1H window at 07:25 and a 1H window at 22:21 honestly hold different amounts. What must NOT differ is the window *size*: see below. The day's own total is stated once, in tier 1, and never changes with arrival. |
| **Window would cross midnight** | Clamped to the selected day — a day is a session boundary per §3.6. The ribbon's neighbouring cell is one click away, which is now a visible affordance rather than a hidden behaviour. |
| **Retention longer than 35 days** | §2.2 degradation ladder. |

---

## 6 · Strings

| id | EN | RU |
|---|---|---|
| `pb.chip` / `live.chip` / `scan.chip` | `PLAYBACK` / `LIVE` / `SCAN` | `ЗАПИСЬ` / `ЭФИР` / `ПЕРЕМОТКА` |
| `nav.archive` | `ARCHIVE` | `АРХИВ` |
| `nav.playhead` | `PLAYHEAD` | `ПОЗИЦИЯ` |
| `nav.footage` / `nav.motion` / `nav.events` | `FOOTAGE` / `MOTION` / `EVENTS` | `ЗАПИСЬ` / `ДВИЖЕНИЕ` / `СОБЫТИЯ` |
| `nav.lastN` | `last {n}d` | `посл. {n}д` |
| `nav.daysW` | `{n} day(s) w/ footage` | `{n} дней с записью` (3-form) |
| `cov.segs` | `{n} segment(s)` | `{n} фрагментов` (3-form) |
| `cov.covered` | `{p}% covered` | `{p}% заполнено` |
| `cov.none` | `no footage in this window` | `нет записи в этом окне` |
| `lane.none` | `NO FOOTAGE IN THIS WINDOW` | `НЕТ ЗАПИСИ В ЭТОМ ОКНЕ` |
| `nav.lastMotion` | `LAST MOTION {t} ›` | `ПОСЛ. ДВИЖЕНИЕ {t} ›` |
| `nav.marked` | `MARKED {d} ✕` | `ВЫДЕЛЕНО {d} ✕` |
| `scrub.hint` | `release to seek` | `отпустите для перехода` |
| `scan.divider` | `SCAN — frames skipped` | `ПЕРЕМОТКА — кадры пропускаются` |
| `tr.back10` / `tr.fwd10` | `Back 10 s ←` / `Forward 10 s →` | `Назад 10 с ←` / `Вперёд 10 с →` |
| `tr.stepB` / `tr.stepF` | `Step back one frame ,` / `Step forward one frame .` | `Кадр назад ,` / `Кадр вперёд .` |
| `tr.speed` | `Playback rate — J / L` | `Скорость — J / L` |
| `tr.markIn` / `tr.markOut` | `Mark in [` / `Mark out ]` | `Начало [` / `Конец ]` |
| `tr.snap` / `tr.snapT` | `Snapshot S` / `Snapshot with timestamp Shift S` | `Снимок S` / `Снимок с меткой времени Shift S` |
| `tr.export` | `Export marked range X` | `Экспорт выделения X` |
| `tr.live` | `Return to Live` | `К эфиру` |
| `ev.empty` | `No events in this window.` | `Нет событий в этом окне.` |
| `ev.emptyFiltered` | `No events of the selected types in this window.` | `Нет событий выбранных типов в этом окне.` |
| `st.noFootage` | `No footage recorded around this moment.` | `Нет записи в этот момент.` |
| `st.nearest` | `Nearest footage {t} →` | `Ближайшая запись {t} →` |
| `st.pbOff` | `Playback is switched off — recorded playback and export are paused.` | `Воспроизведение выключено — просмотр записи и экспорт приостановлены.` |
| `st.recOff` | `Recording is switched off — no new footage is being written.` | `Запись выключена — новые фрагменты не пишутся.` |
| `st.offline` | `This camera is offline right now.` | `Камера сейчас не в сети.` |
| `st.err` | `Could not open a playback session for this camera.` | `Не удалось открыть сессию воспроизведения.` |
| `st.emptyArch` | `This camera has no recorded footage in the last 35 days.` | `У этой камеры нет записи за последние 35 дней.` |

Weekday and month names are localised arrays, not `strftime` — the ribbon needs both a full form (`Thu`) and a single letter (`Ч`), and Russian's genitive month forms differ from nominative.

Every count string needs EN 2-form and **RU 3-form** plurals. Audit by extraction, not by eye (the Groups lesson): pull every text literal and every tooltip in the screen and diff against this table. Allow-list: brand names, key names, vendor model strings, `UTC+3`.

---

## 7 · Acceptance checklist

- [ ] **One navigator.** Ribbon (35 days) and lanes (the window) share one axis; the selected day carries an `accent` bracket showing where the window sits. No month-grid calendar anywhere.
- [ ] Ribbon cell width is `paneWidth / days` **with the remainder distributed** — no short ribbon, and the last cell's right edge aligns with the ruler's.
- [ ] The 120px label block **contains its own text at both languages, including the longest day in the fleet** (`1h 13m · 117 clips` / `1ч 13м · 117 клипов`) — it may not spill over the day cells and may not widen to fit.
- [ ] The block states the **selected day's footage total**, retargeting on every day click. It does not restate retention span or a count of days — both are already drawn by the ribbon itself.
- [ ] Navigator height and events-panel width both drag, clamp, and reset on double-click; the height grip costs **0px** of picture; only the lanes absorb the change.
- [ ] The video re-letterboxes on every resize **and stays inside the stage at every drag position** — never taller than its container, never flush to the top.
- [ ] The ribbon is **week-banded**: a divider before every Monday, alternate weeks tinted, so weekday position is readable by block rather than by counting. Verify Thursdays fall at a constant stride and the bands run in exact 7s.
- [ ] Days without footage are dimmed **and inert**; days with footage carry a density bar; today is ringed; the ribbon degrades per §2.2 at 26px and 15px.
- [ ] The info rail is gone. `Playhead`, `Quality` and `Window` are not rendered as rail rows anywhere.
- [ ] Video is **1246×701 at 1440×900** (+24% area vs today) and its geometry never changes when a panel opens.
- [ ] The ribbon has an explicit **42px** height, and the navigator has **no unallocated space**: the MOTION lane's bottom edge is the navigator's bottom edge at every drag position, including the 83px minimum.
- [ ] The millisecond timestamp is 20px mono with the `.mmm` field in `accent`, and is **never occluded** — the events panel pushes the timestamp and the transport's right groups, not the video.
- [ ] Transport has **three anchors**: a continuous left run (move · rate), the frame cluster pinned at the centre of the bar, and a right-anchored exit group. In frame mode the range cells join the centre cluster, which stays centred as a whole.
- [ ] Frame mode opens the **filmstrip**: 96px band, nine 40ms-spaced frames with ms captions, the current one ringed, neighbours clickable. Cells flex to fit at 1440 and 1200 with zero overflow and align under the picture, not the rail. **No legend inside the band** — the exit instruction is a chip in the video's mode row.
- [ ] **Every filmstrip cell actually renders a frame.** The frame primitive is styled on its own class, never through a host ancestor — verify a cell's inner box measures non-zero and is `absolute`/`block`.
- [ ] The exit group and the timestamp sit **11px inside the visible video's right edge** — clearing the events panel OR the letterbox margin, whichever is larger, never their sum.
- [ ] `F` enters frame mode: playback pauses, rate returns to 1×, and mark/export appear. The mode has a visible labelled cell so export is not re-hidden.
- [ ] `[` and `]` **enter frame mode themselves** — it must be impossible to create a marked range while its export control is hidden. Test: with frame mode off, press `[ → → ]` and confirm the export cell is present.
- [ ] `Shift F` and the `⛶` cell both enter fullscreen (chrome hides, video fills, `Esc` leaves). **No advertised shortcut is intercepted and then ignored.**
- [ ] Backward frame step shows its cache hairline; forward step never does; `,` key-repeat is rate-limited.
- [ ] Speed is a **ladder of all ten rates**, with a hairline break above 10×, those rates in `bad`, and a `bad` rate chip on the picture. **The words `SCAN` and `frames skipped` appear nowhere in the UI** — the boundary is disclosed by colour and by the rate cell's plain-language tooltip.
- [ ] `archive` preference switches between the 42px ribbon in tier 1 and a **persistent month grid in the right rail**, above the events list. The grid is never behind a button. Calendar mode collapses tier 1 (navigator 73px) and the rail cannot be dismissed.
- [ ] The right rail is a **column the stage shrinks around**, never an overlay: the video is fully visible and centred in the remaining space, and every honest-state banner centres on the picture rather than on a partly-hidden stage.
- [ ] **Dragging the playhead previews and issues exactly one seek, on release**, with a `release to seek` chip. Verify by counting session opens during a 3-second drag: it must be 1.
- [ ] `Coverage` is on the navigator header as `{n} segments · {p}% covered`, and turns `bad` with `no footage in this window` at zero, matched by the lane's own message.
- [ ] Events list and motion lane share **one** hover id and **one** selected id; the type chips filter both; no state exists where they disagree.
- [ ] Export: `[` `]` mark a range, the range renders as a bracket across both lanes, the header shows `MARKED {d} ✕`, and the export cell carries the duration and is inert without one.
- [ ] **Picking a day never changes the span.** Verify: note the span, click another day, click back — the span is identical at every step, and only the playhead and day have moved.
- [ ] Full keyboard map (§3) bound by **physical code**; `J` steps the rate ladder down and its tooltip says so.
- [ ] All seven honest states from §4 render with tag + fact + consequence; `recordingOff` and `offline` do **not** block playback of existing footage.
- [ ] A gap-seek offers `Nearest footage {t} →` and never silently snaps.
- [ ] Correct at 1440×900 and 1200×900, EN and RU, with 3-form plurals.
- [ ] **Success test:** from a cold open, "the lift at about quarter past ten last Thursday" is reachable in under 15 seconds — one click on the ribbon's Thursday, one span change, one click on the ruler — with no moment where the operator must choose between two navigators.
