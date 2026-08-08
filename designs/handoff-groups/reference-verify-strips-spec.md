# Events › Verify — density redesign · "Strips"

**Reply to** `docs/design-briefs/2026-08-07-verify-redesign.md`
**Date:** 2026-08-07 · **Status:** ready to build
**Prototype:** `verify-redesign-prototype.html` — 276 events / 21 cameras, live tweaks for density, stills, fleet shape, ANPR, EN/RU, 1440/1200. Where this document and the prototype disagree, **this document wins.**

**Language:** continues the shipped Triage variant B. Gapless hairline cells, sticky camera lanes, computed fits, 60% mute floor. Nothing above the sub-nav is touched.

---

## 0 · The decision

**Camera lanes, filmstrips instead of rows.** The Wall's card grid becomes the same lane structure that shipped in Triage — one sticky 26px header per camera — with the events laid out as a **horizontal strip of 16:9 tiles** under it rather than a vertical list of rows.

This is the only structure that solves four of the seven ranked problems with one move:

| brief problem | how the strip structure answers it |
|---|---|
| **1 · density** | The 34-character camera name and the 136px of card chrome leave the event entirely — the lane owns the name, the tile owns nothing but the picture. **210×118 tile vs ~350×335 card** at `dense`. |
| **2 · same-camera bursts** | A burst *is* a lane. `.146 × 7` is one strip with one header, and the header carries one-gesture disposition for the whole thing. Nothing to group — the grouping is the layout. |
| **4 · chrome spend** | 102px of toolbar collapses to **one 32px band**. S/M/L dies (see §2.1). |
| **5 · verified footprint** | A disposed tile shrinks in place to a **26px stub** — position kept, honesty kept, footprint gone. |

### Density arithmetic, 1440×900, `dense` (6 per row)

```
chrome above the page:  30 os + 52 top + 30 tabs + 38 sub-nav + 32 band = 182
page height:            900 − 182 = 718
tile:                   (1366 − 2 − 12) / 6.42 = 210 wide → 118 tall (16:9)
lane:                   26 header + 124 strip (118 tile + 6) + 1 rule = 151
lanes visible:          718 / 151 = 4.75
────────────────────────────────────────────────────────────
events on screen:       4.75 × 6 = 28        (today's M grid: ~10)
```

**2.8×**, against a 2.5× target. `dense` is the **shipping default**.

`compact` (4 per row, 306×172) reaches 14 events on screen — **1.4×, which does not clear the 2.5× bar.** Stated rather than hidden: `compact` is an *inspect* mode for judging a scene without reaching for the magnifier, not a sweep mode. Ship `dense` as the default and let `compact` be the deliberate slow gear.

### What this gives up

Strict global recency. Tiles are time-ordered *within* a lane and lanes are ordered busiest-first, so the newest event in the building is not guaranteed to be top-left. Verify is a **sweep** surface, not an alarm surface — Triage owns alarm response, and the shared sub-nav totals still carry the critical count. If that trade ever bites, the fix is a `Recent` lane-order toggle in the band, not a return to the grid.

---

## 1 · Why not the alternatives

**Smaller cards.** Shrinking a 350px card to 200px keeps the repeated camera name, keeps the per-card action row, keeps the burst problem, and keeps the verified footprint. It buys ~2.5× and solves exactly one of seven problems. Rejected as the answer, kept as the `compact` tweak.

**A pure grid with a camera filter.** That is Triage's job. Verify's value is *breadth* — many stills at once — and a filter narrows breadth.

**Sessions-only (kill the Wall).** Sessions is text rows with 44×25 thumbs; it is dense but it is not *visual verification*. The mandate is to look at pictures at scale.

---

## 2 · Anatomy

### 2.1 · The band — 32px, gapless, replaces 57 + 45

Cells sharing 1px `line` hairlines, no gaps, no bordered pills:

`▦ Verification Wall` · `≋ Smart Sessions` ‖ `To verify 276` · `All 276` ‖ *spacer* ‖ `14 live fallbacks` · `38 done` · `⌨ hint`

- **Layout cells** (2): active = `accent` fill, `#241a08` text, 700 weight — the same active treatment as the sub-nav mode cells.
- **Filter cells**: active = `accentSoft` + 2px `accent` inset underline + `accent` text. Counts mono 10px.
- **Right-hand statistics** are read-only cells, `border-left` only: the **live-fallback count** in `bad` and the **done count** in `good`. These replace the deleted helper sentence with something that changes.

**`Size` S/M/L is deleted.** The geometry has one right answer per fleet, not three per user; the old control existed because the card had no natural size. Density survives as a **preference in settings** — two values, `compact` (4 per row) and `dense` (6 per row), seeded to `dense` — and as a tweak for this review. If it must ship as a control, it belongs next to the density preference, not in the scan path.

**`AI detections` is conditional.** The cell renders **only when the feed contains a non-`motion` type**. On today's fleet it is absent, and its absence is honest; the day the first ANPR plate event arrives the cell appears with a real count. An always-zero tab is a promise the product cannot keep. (Prototype: the `ANPR landed` tweak simulates the arrival.)

### 2.2 · Lane header — 26px, sticky

`▸` caret · **`.146`** (mono 12px DemiBold) · offline dot · model name (10.5px `ink3`, max 190px, ellipsized) · **burst chip** · severity mix (38×3px) · *spacer* · **`4 live`** · count (mono 11px) · **action cells**.

- **Burst chip** — `× 7 in 40m`, mono 9px `accent` on `accentSoft` with an `accentDim` border. Shown when the lane holds **≥4 events spanning ≤90 minutes**. It is a *label*, not a state: the strip is already the collapse.
- **`N live`** — how many tiles in this lane are still showing a live fallback, in `bad`. This is the number that tells a guard whether the strip is worth scanning yet. It counts down as extractions land.
- **Action cells** — `THREAT` / `DISMISS`, mono 9.5px, revealed on lane hover or when the lane holds focus (`opacity 0 → 1`, never a layout shift). See §3.2.
- States: idle `panel` · hover `panel2` · **focused lane** `#2b2318` + 2px `accent` inset left bar.

### 2.3 · Tile — sized by column count

**Density is a column count, not a pixel size.** The strip always shows exactly `cols` events per camera and the tile is *derived* to fit the measured page width, so the wall keeps the same rhythm at any window size instead of reflowing to a ragged number of columns.

```
tileW = floor((pageWidth − 8 − 2 − 2·cols) / (cols + 0.42))     tileH = round(tileW · 9/16)
```

(the `0.42` reserves the `+N more` chip, which is 42% of a tile wide.)

| density | cols | tile @1440 | header | lanes @900 | events on screen |
|---|---|---|---|---|---|
| `compact` | **4** | 306×172 | 28 | 3.5 | 14 (1.4×) |
| **`dense`** | **6** | **210×118** | **26** | **4.75** | **28 (2.8×)** |

At 1200px the columns hold and the tiles shrink (`dense` → 173×97), which *raises* the count to 33 — the narrow window is denser, not poorer.

Contents, all overlaid on the still — **the tile has no chrome band**:

- **severity spine** — 3px, full width, bottom edge, severity colour; `critical` adds the `badSoft` halo. Bottom edge rather than a corner tag because a row of spines reads as a *sparkline of severity across the burst*.
- **time** — mono 9px `hh:mm`, bottom-left, 2px black text-shadow. Seconds are in the magnifier and in Sessions; on a tile they are noise.
- **duration** — mono 9px on 62% black, bottom-right; `no clip` for offline events.
- **no camera name, no `CH nnn`, no type pill.** The lane owns the camera; `CH nnn` was procedural dressing; every event is `motion` until ANPR lands, and when it lands the type belongs on the tile only for non-motion (see §5).
- **hover** — two 20px action cells slide over the bottom edge: `T` (`good`) / `✕` (`bad`). One click, no travel, no hidden affordance. **The fake 2.4s pan is deleted** — it was undiscoverable and it was not evidence.
- **selected** 2px `accent` ring · **keyboard focus** 2px `ink` ring · both = `accent` ring + 4px translucent halo.
- **in-flight** 50% opacity, pointer-events off, until the server answers. No optimistic stamping.

### 2.4 · Live fallback — the honesty state

When the event-frame extraction has not landed, the tile is **not** allowed to look like an event frame. Four simultaneous signals:

1. The still renders at **42% opacity, 50% desaturated** — present enough to show the scene, obviously not the evidence.
2. A **diagonal red hatch** across the whole tile (`bad` @16%, 5px/10px, 135°) plus a 1px inset `bad` border.
3. A **`● LIVE` badge** welded to the top-left corner, `bad` fill, white mono 8.5px 700, always in the same place so a strip of fallbacks reads as a row of red corners.
4. The **`N live` counter** in the lane header, and the **`14 live fallbacks`** cell in the band.

**Arrival is visible.** When the real frame lands the tile **crossfades over 340ms** from hatched to clean, and the two counters decrement. The guard sees the wall becoming verifiable.

This is the difference between the current screenshot — seven identical `.146` cards where scanning is guesswork — and a strip where the fallbacks are visibly *not yet evidence* and the real frames stand out clean.

**A fallback tile is still fully verifiable without its picture:** time, duration, severity spine, lane camera, and click-through to Triage are all present, which satisfies the brief's alternative requirement as well as its primary one.

### 2.5 · Magnifier — replaces the fake pan

Hovering a tile for **520ms** opens a **2.6× magnifier** (546×329 at `dense`) anchored below the tile, flipped above when it would leave the page, clamped 6px inside the frame. It is a `Rectangle` child of the frame — never a `Popup`, never outside the window.

Caption strip, 22px: **`.146`** · `02:44:07` · `48s` · *spacer* · **`event frame`** (`ink2`) or **`LIVE — not the event frame`** (`bad`). A fallback keeps its hatch in the magnifier.

The magnifier is the answer to "can you really verify at 210px": you scan at 210, you confirm at 546, and you never leave the grid. It is also why `compact` is optional rather than necessary.

### 2.6 · Overflow and expansion

A strip shows what fits; the remainder collapses to a **`+12 / more`** chip at the end of the strip (42% of tile width). Clicking it, the caret, or pressing `Space` **expands the lane** — the strip becomes a wrapped grid of every event on that camera, lane height auto. Collapse restores the single row.

This is what keeps `.146 × 41` honest and cheap: one row by default, everything on demand, and **the collapsed tiles are never fetched** (§4).

### 2.7 · Disposed tile — 26px stub

A verified or dismissed tile **shrinks in place** to a `Math.round(tileW × 0.16)`-wide stub (34px at `dense`, floor 22px), full tile height, `panel2` fill, 1px `line`: a `✓` (`good`) or `✕` (`ink2`) over the event time in 7px vertical mono.

Position is preserved, so the guard's sense of "where I am in this burst" survives; footprint drops **83%**; the strip refills with tiles that still need work.

**The stub survives the active filter.** A disposed event does **not** leave `To verify` at the moment of disposal — it stays as a stub and is carried away by the **next feed refresh**, exactly as the card does today. Filtering it out immediately would reflow the strip under a working guard (every disposition pulls the next overflow tile in and shifts the whole row left) and would delete the honest bridge between "I acted" and "the server agrees". The event remains visible in `All` permanently.

**Disposed tiles leave the extraction queue.** A stub has nothing to fetch; its pending request is cancelled so the 2 concurrent slots go to work that is still open. The lane's `N live` and the band's fallback count exclude stubs for the same reason.

---

## 3 · Interaction

### 3.1 Tile

| action | result |
|---|---|
| hover | action cells appear; 520ms → magnifier |
| click | focus the tile (keyboard anchor) |
| shift / ctrl-click | add to selection |
| `T` cell / `✕` cell | dispose as `verified` / `false_alarm` — one click |
| click the still | open in Triage, which solos that camera's lane |

### 3.2 Lane — one-gesture burst disposition

`THREAT` / `DISMISS` in the lane header apply to **every undisposed event in the lane**.

- **≤3 events** — fires immediately. Bulk-confirming three clicks is theatre.
- **≥4 events** — the cells are replaced **in place** by `Dismiss all 7?` `✓` `✕`. No dialog, no scrim, no travel; the confirm sits exactly where the click landed. Escape or `✕` cancels.

That is the brief's "dispose a same-camera burst in one action" — one gesture on the burst, with a proportionate guard on genuinely destructive bulk.

Disposal is a real round-trip under the existing global in-flight lock: tiles go 50% and inert, then stub. Nothing is stamped before the server answers.

### 3.3 Keyboard

Roving focus, seeded to the first tile.

| key | action |
|---|---|
| `←` `→` | previous / next tile in reading order (crosses lanes) |
| `↑` `↓` | first tile of the previous / next lane, scrolling it into view |
| `T` | dispose focused tile as **threat**, focus advances |
| `D` | dispose focused tile as **dismiss**, focus advances |
| `⇧T` `⇧D` | the focused tile's **whole lane** (same confirm rule as §3.2) |
| `B` | bookmark |
| `Space` | expand / collapse the focused lane |
| `0`–`9` | camera jump — identical semantics to Triage: commits on an unambiguous prefix or the third digit, echo chip shows the remaining match count |
| `Esc` | clear selection, cancel an armed confirm, close the magnifier |
| `E`, `Ctrl-K` | **reserved, untouched** |

**Bind by physical key code, not by character.** On a Russian layout the `T` key emits `е` and `D` emits `в`; matching on the character would collide with the reserved `E` (acknowledge) the moment a guard switches layout. Match `KeyT` / `KeyD` / `KeyB` / `Digit0-9`.

`T` and `D` were chosen because they are the two initials that survive both layouts under a code-based binding and collide with nothing reserved.

---

## 4 · Stills: surviving the 2-wide governed extraction

The whole redesign wants 47 pictures on screen where the old grid wanted 10. That is fine **only** if the fetch discipline is right, and it is the single most likely thing to be built wrong.

1. **Viewport-only, unchanged.** Only tiles in mounted, visible lanes request. `cacheBuffer: 0` stays. Collapsed overflow (`+12`) and collapsed lanes request nothing.
2. **Reading-order queue.** Requests are enqueued **by visual position — lane order, then left-to-right — not by event id or arrival**. Two drain at a time. The strip fills the way the eye moves, so the guard is always looking at the part that is filling. A hash-ordered queue with the same throughput feels broken.

   **The queue is owned by the tiles, not by the page.** Tag it with a generation (fleet / filter-scope / extraction-mode) and let the first registrant of a new generation clear it; never clear it from a page-level lifecycle hook. Tile-level initialisation runs *before* page-level initialisation, so a page-side wipe lands after every tile has already enqueued and empties the queue permanently — silently, with no error, and no still ever arrives.
3. **The placeholder is the fallback**, not a spinner. There is never an empty tile: the live frame is already there, hatched and marked, and it upgrades in place.
4. **Cancel on scroll-out.** A tile leaving the viewport drops its pending request before it reaches the server; the slot goes to what is on screen now.
5. **Bounded retry.** A tile still in fallback re-requests at most every **20s**, and never for offline events (`no clip` — there is no frame to extract).
6. **Never prefetch on expand-all.** Expanding `.146 × 41` enqueues only the tiles that are actually in the viewport after the reflow.

Degradation is therefore graceful by construction: at `dense`, 28 honest fallbacks that resolve at whatever rate the extractor allows, top-left first — and an expanded `.146 × 41` is still bounded by the viewport, not by the lane.

---

## 5 · Smart Sessions — same language, retained

Kept as the second layout, redensified rather than redesigned:

- **The 56px three-big-numbers stat header is deleted.** Those counts now live in the band (`276` / `14 live fallbacks` / `38 done`) where they are visible in both layouts.
- **Zone header 43 → 26px**, matching the lane header exactly: severity dot, zone name, severity mix, event count, `SELECT ALL`.
- **Event row 58 → 32px**: checkbox · 44×25 thumb (hatched when fallback) · `.146` · type chip · `02:44:07` · ago · `● LIVE` when fallback · hover `ACK` / `✕`.
- **Bulk bar** stays sticky at the bottom, 34px, gapless cells: `12 picked` · `THREAT 12` · `DISMISS 12` · `✕`.

Zone rows show seconds and a type chip because they have the width; tiles do not because they do not.

**Flag, not a decision:** with lane-level disposition on the Wall, Sessions' remaining unique value is *zone* grouping and cross-camera multi-select. If telemetry shows the Wall absorbing it, Sessions is a candidate for retirement — do not act on that yet.

---

## 6 · Edge cases

| case | behaviour |
|---|---|
| **276 events / 21 cameras** | 21 lanes, busiest first. `.146` opens with 41 events → 6 tiles + `+35 more`. 4.75 lanes on screen. |
| **One camera = 90% of events** (`skew` tweak) | One lane of 248 with a `× 248 in …` burst chip and `+242 more`; the other 11 lanes sit below it in one screen. The page does **not** become a single scrolling strip unless the guard expands it. |
| **Zero events** (`empty` tweak) | No lanes; the page shows `No events in "To verify".` naming the active filter, with a `Clear filter` cell. The zero-camera strip is suppressed (nothing to contrast against). Never blank, never a spinner. |
| **All stills in LIVE fallback** (`stills: none`) | Every tile hatched, `276 live fallbacks` in the band, every lane showing its own `N live`. The wall is still fully workable: time, duration, severity, camera and click-through are all real. This is the state in the operator's screenshot, and it now *says so*. |
| **RU at 1200px** | Band cells grow ~30%; `Стена проверки` + `Умные сессии` + two filters + stats = 612px of 1136 — fits with the spacer absorbing the rest. Tiles are digits and glyphs, so the strip geometry is language-invariant. Lane model names ellipsize at 190px in both languages. |
| **1200×900** | Page 1126 wide → the column count holds (6 at `dense`) and the tile shrinks to 173×97, so the lane is 130px and 5.5 lanes fit: **33 events**. The narrow window is denser, not poorer. |
| **Offline camera** | Lane header shows the 5px `bad` dot; its tiles read `no clip` and never enter the extraction queue. Their events are still real and still disposable. |
| **A burst disposed while extractions are pending** | Pending requests for stubbed tiles are cancelled — done work must not consume extractor slots. The stubs stay in place until the next poll. |
| **New events arrive mid-sweep** | They insert into their lane in time order. Focus follows the *event*, not the index. Lane order does not re-sort while a lane is focused or expanded — re-sorting under a working guard is the Triage failure-mode-3 lesson. |
| **ANPR lands** | `AI detections` appears in the band with a real count; plate/person tiles gain a 8.5px type chip top-right (motion tiles never do — the chip marks the exception, not the rule). |

---

## 7 · Strings

| id | EN | RU |
|---|---|---|
| `verify.wall` | `Verification Wall` | `Стена проверки` |
| `verify.sessions` | `Smart Sessions` | `Умные сессии` |
| `verify.toverify` | `To verify` | `На проверку` |
| `verify.all` | `All` | `Все` |
| `verify.ai` | `AI detections` | `ИИ-детекции` |
| `verify.liveN` | `{n} live fallback` / `fallbacks` | `{n} live-заглушка / заглушки / заглушек` |
| `verify.doneN` | `{n} done` | `готово {n}` |
| `verify.threat` | `THREAT` | `УГРОЗА` |
| `verify.dismiss` | `DISMISS` | `ОТКЛОНИТЬ` |
| `verify.threatAll` | `Threat all {n}?` | `Угроза, все {n}?` |
| `verify.dismissAll` | `Dismiss all {n}?` | `Отклонить все {n}?` |
| `verify.burst` | `× {n} in {m}m` | `× {n} за {m}м` |
| `verify.more` | `+{n}` / `more` | `+{n}` / `ещё` |
| `verify.fbCap` | `LIVE — not the event frame` | `LIVE — не кадр события` |
| `verify.evCap` | `event frame` | `кадр события` |
| `verify.noClip` | `no clip` | `нет клипа` |
| `verify.empty` | `No events in “{filter}”.` | `Нет событий: «{filter}».` |
| `verify.clear` | `Clear filter` | `Сбросить фильтр` |
| `verify.picked` | `{n} picked` | `выбрано {n}` |

Every count-bearing string needs EN 2-form and **RU 3-form** plurals (`n%100` 11–14 → genitive plural; else `n%10`: 1 → nominative singular, 2–4 → genitive singular, otherwise genitive plural).

---

## 8 · Acceptance checklist

- [ ] Band is **32px**, gapless, and carries layout · filters · live-fallback count · done count. No S/M/L, no helper sentence.
- [ ] `AI detections` renders **only** when a non-motion type exists in the feed.
- [ ] Lane header 26px sticky: caret, octet, offline dot, model, burst chip, severity mix, `N live`, count, THREAT/DISMISS.
- [ ] Tile is **derived from the column count** (4 at `compact`, 6 at `dense`) with spine, time, duration, hover actions — **no camera name anywhere on a tile**.
- [ ] Live fallback is unmistakable: 42% opacity + hatch + `bad` border + corner `● LIVE` badge, and it **crossfades to clean when the frame arrives**.
- [ ] ≥2.5× events on screen vs the old M grid at `dense`, the shipping default.
- [ ] Tile width is **computed in one pass** from the measured page width and recomputed on `onWidthChanged`; the column count never changes with window width. Never a reset-and-decrement loop.
- [ ] `+N more` expands the lane in place; collapsed tiles are never fetched.
- [ ] Disposed tiles become 26px stubs **in place**; order preserved; the stub **survives the active filter** and is evicted only by the next feed refresh. Disposing must never reflow the strip.
- [ ] Stubs are excluded from the extraction queue and from both fallback counters.
- [ ] Lane THREAT/DISMISS disposes the burst in one gesture; ≥4 arms an in-place confirm; no dialogs.
- [ ] Keyboard: arrows, `T`, `D`, `⇧T`, `⇧D`, `B`, `Space`, digits, `Esc` — all bound by **physical key code**; `E` and `Ctrl-K` untouched.
- [ ] Stills: viewport-only, reading-order queue, 2 concurrent, cancel on scroll-out, 20s bounded retry, never for offline events.
- [ ] No optimistic state: in-flight tiles are inert at 50% until the server answers.
- [ ] Correct at 1440×900 and 1200×900, EN and RU, with 3-form RU plurals.
- [ ] Every empty state names its filter; nothing ever goes silently blank.
