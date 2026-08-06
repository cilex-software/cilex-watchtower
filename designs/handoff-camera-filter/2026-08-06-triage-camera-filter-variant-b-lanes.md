# Variant B — "Lanes" · a density-first alternative

**Companion to** `2026-08-06-triage-camera-filter-spec.md` (variant A, "MRU chips + palette").
**Prototype:** `designs/triage-camera-filter-prototype-B-lanes.html`
This is an *alternative*, not a revision. Variant A stands unchanged. Pick one.

---

## 1 · The premise

Variant A spends space to solve the filter: a 36px chip bar, a 22px ribbon, a 368×384 overlay, and a flexible spacer that is by definition empty. Variant B asks the opposite question — **what if filtering cost no space at all?**

The answer is to stop treating the camera filter as a *control* and make it the **structure of the list**. Group the queue by camera, and the group headers are the filter.

That unlocks the real density win, which has nothing to do with the filter: today the camera name — `HiWatch DS-I202(E) (192.168.1.144)`, 34 characters — is repeated on **every one of 130 rows**, and it is what forces the row to 67px. Say it once per lane and the row collapses to 44px.

### Space accounting, 130 events / 22 cameras

| | variant A | variant B |
|---|---|---|
| filter chrome | 36px bar + 22px ribbon | **0** |
| per row | 67px | **44px** |
| per camera | — | 26px lane header |
| **total scroll height** | 8,746px | **6,292px** |
| **rows on screen at 900px** | 9.3 | **14.5** |

**28% less scrolling and 56% more events per screen**, and the filter became free. On the `ultra` density tweak (36px rows, 22px headers) it is 17.5 rows — 88% more than A.

---

## 2 · Anatomy

**No filter bar. No ribbon. No overlay.** The queue column is: status tabs → lanes. That is all.

### 2.1 Status tab row — 32px (was 45)

Gapless: three tabs sharing 1px `line` dividers, active tab gets `panel` fill + a 2px amber inset underline. The right side of this row is dead space in variant A; here it carries the **scope readout**, right-aligned in a bordered cell:

- unfiltered: `130 · 22 cam` (mono 10px `ink3`)
- soloed: `**12** of 130 · .146` with a trailing amber `✕`

That readout replaces A's entire 22px ribbon, at zero height cost.

### 2.2 Lane header — 26px, sticky

`▾` caret (8px `ink3`) · **`.144`** (mono 12px DemiBold `ink`) · offline dot (5px `bad`, only if offline) · model name (10.5px `ink3`, ellipsized) · **severity mix bar** · count (mono 11px `ink2`).

The **severity mix** is a 38×3px bar segmented by the lane's severity makeup — how much of this camera's backlog is critical vs. low, read at a glance, in 38 pixels. It is the densest honest thing that fits and it is information variant A does not show at all.

States: idle `panel` · hover `panel2` · **soloed** `#2b2318` + 2px amber inset left bar + amber octet and count · **muted** (something else is soloed) 60% opacity, full opacity on hover. 60% is the floor — it keeps the 12px octet above 4.5:1 on `panel`, which a heavier de-emphasis does not.

Sticky within the scroll, so the camera you are reading is always named at the top of the viewport. (Tweakable off.)

### 2.3 Event row — 44px (`compact` 48 / `dense` 44 / `ultra` 36)

7px severity dot · thumbnail (`58×33` at dense, scaled with row height, duration badge bottom-right) · `11:07:04` (mono 11px `ink`) · `2m` (mono 9px `ink3`) · flexible gap · `◇ MOTION` (mono 8.5px, bordered) · 6px state dot.

**No camera name** — the lane owns it. That single deletion is the whole density gain.

Selected: `panel2` + 3px amber inset left bar. Handled: 45% opacity.

### 2.4 Zero-count strip

One 30px row at the bottom of the list: `NO EVENTS IN TAB  .173 .180 .183 .190` — every camera in scope with nothing in this tab, as tiny clickable octet buttons. The honesty rule satisfied in **one row** rather than a scrolling section, and still one click to reach any of them.

### 2.5 Group segmented control

Same band as variant A but gapless: cells sharing 1px hairlines, active cell `accentSoft` + amber inset underline. Identical fit logic to A §2.6 — measured in one pass from a ghost row, active group always promoted so it can never hide inside `+M ▾`.

---

## 3 · Interaction

| action | result |
|---|---|
| **click lane header** | **solo** that camera — every other lane collapses to its header (never disappears), and the scope readout names it. Click again → all lanes expand. This is the filter. |
| **ctrl/⌘ + click header** | add to the solo set — entrance pairs, exactly A's multi-select, no separate control. Works because collapsed lanes keep their headers on screen. |
| **alt + click header** | fold just that lane to its header (keep the others expanded) |
| **type digits** | live type-ahead: the echo chip shows `.14` and how many cameras still match. It commits **as soon as the prefix is unambiguous**, or at the third digit. `.146` is three keystrokes (`.14` still matches `.140` `.143` `.144` `.145` `.146`); a camera with a distinctive octet like `.9…` commits on the first. No panel to open, no confirm keystroke. |

**Soloed lanes sort to the top of the list.** The jump is *positional*, not a scroll — nothing has to be measured, so nothing can be measured against the wrong layout. A scroll-based jump reads the target's offset before the other lanes collapse, then lands against a scroll height that no longer exists; at 80 cameras that puts the guard on a screen of muted headers with the amber lane somewhere else. Ordering sidesteps the whole class of bug: the soloed lane is row one by construction, and the list scrolls to 0.
| **Backspace** | delete a digit from the buffer |
| **Esc** | clear solo and buffer |
| `E`, `Ctrl-K` | untouched — B has no text field to steal them |

The type-ahead buffer clears itself after 1.4s of no typing, and the **echo chip** (mono 13px amber, top-right of the list) is the only feedback needed — there is no field, no cursor, no dropdown. It never commits on an ambiguous prefix: jumping to `.140` when the guard is typing `.146` would be worse than waiting one more keystroke.

**Against A on the ≤2s test:** both are three keystrokes for `.146`. A is `1` `4` `6` `Enter` into a search field inside a panel that had to open first (four keystrokes, one of them a commit); B is `1` `4` `6` with the lane already on screen — no panel, no commit, and the roster stays visible around it the whole time.

**Soloing never hides the roster.** Non-soloed lanes collapse to their 26px headers at 45% opacity, so the index of every camera and its live count stays on screen — which is what keeps ctrl-click multi-select reachable and keeps the list working as its own filter after the first click.

**What B gives up:** the flat priority-then-recency ordering across the whole queue. Lanes sort busiest-first and events sort by priority *within* a lane, so the single most critical event in the building is not guaranteed to be the first row on screen. For a **backlog sweep** that is fine — arguably better, since working one camera at a time is how the clip context stays warm. For **alarm response** it is worse than A. If the Critical tab is the alarm-response surface, it can render flat (no lanes) while Open queue renders lanes; that is a one-line rule, not a redesign.

---

## 4 · Density language

Variant A separates controls with 6px gaps and borders each one. B **shares hairlines**: every control is a cell in a table, 1px `line` between neighbours, no gaps anywhere. Applied throughout:

- **Top bar** 64 → 52px, cells divided by hairlines, avatar flush to the right edge with no padding.
- **Tab strip** 36 → 30px. **Sub-nav** 58 → 38px: the mode buttons become one segmented control, the groups another.
- **Detail pane:** the 52px transport and the 44px tool row **merge into one 40px control bar** — transport, scrubber, speed, then export / assign / bookmark as icon cells. Body padding 22 → 14px. The facts grid goes 2-col → **3-col**. The video stage keeps its 21:9 shape but is **capped at 372px** so the recovered height goes to the body rather than to letterbox — the player already letterboxes on black, so a shorter stage costs nothing.

Net: **62px of chrome recovered above the list**, and at 1440×900 on the default density the detail pane shows the facts grid, the response procedure and the disposition bar without scrolling — where variant A pushes the procedure below the fold. On a shorter window, or at `compact` density, the body scrolls; the claim is a fit at the design size, not a guarantee at every size.

---

## 5 · Tweaks

The prototype ships six, in two groups: **Density** (rows compact/dense/ultra, thumbnails on/off, sticky headers on/off) and a **review harness** (language EN/RU, window 1440/1200, groups 2/6). Density and thumbnails are the ones worth arguing about — `ultra` + thumbnails off is 17.5 rows per screen and is genuinely usable, but it loses the visual pre-classification a thumbnail gives.

---

## 6 · Edge cases

| case | behaviour |
|---|---|
| **1 camera** | One lane, header sticky at top, effectively the flat list — with a permanent header naming the camera. Degrades to something better than A. |
| **80+ cameras** | Lanes are the roster: 80 headers × 26px is one scroll, each with a live count and severity mix — and they stay on screen while soloed. This *is* A's palette, with no panel and no search step. |
| **All 130 on one camera** | One lane, 130 rows. Header pins at the top the whole way down. |
| **Zero events in tab** | No lanes; the zero strip lists the whole roster as octet buttons. Never blank. |
| **Russian** | Lane content is octets, times and counts — digits. Only the tabs, groups and procedure translate; the lane header's model name is a vendor string, untranslated in both. |
| **1200px window** | Left column fixed 384px → detail 744px, clears the 700px floor. The group segment sheds cells into `+M ▾`. |
| **Soloed camera drops to 0** | Its lane stays, showing the honest inline empty state `No events on .146 in Open queue.` — the lane is the filter, so the filter cannot silently vanish. |

---

## 7 · Choosing between A and B

Take **A** if flat priority ordering across the whole queue is non-negotiable, or if lanes are too big a change to the shipped triage model to absorb now. A is the conservative answer: it keeps today's list exactly as it is and fixes only the filter.

Take **B** if screen real estate is the scarce resource — 130-event mornings on a 1440×900 window, guards scrolling all shift. B is the bigger change and the bigger payoff, and it deletes a control surface rather than adding one.

They are not mergeable: A's chip bar exists because the list is flat, and B's lanes exist because the list is not.
