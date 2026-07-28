# The Watch — guard progression & achievements (design)

_2026-07-28. Product design for the guard gamification feature: check-in identity,
rank ladder, a two-dimensional achievement matrix, badge art descriptions (for
image generation), UX, and the client/backend split. Backend ask:
`docs/letters/2026-07-28-guard-shift-achievements.md`._

## 0. Theme — "The Watch" (original, corvid + tower mythology)

The Game-of-Thrones flavor the operator liked (crows, watchers on walls) is kept
in SPIRIT but all names are ORIGINAL — corvids, towers, and light are public
domain; direct GoT names (Night's Watch, Crows as a faction) are HBO/GRRM IP and
must not ship in a commercial product. Our mythology: guards are keepers of a
watchtower; corvids are their emblem (rooks and ravens are the birds that live
on real watchtowers); rank is called **the Watch**. One collision deliberately
avoided: no rank named "Warden" — that's our supervisor software.

Design-language constraint: badges follow the app's visual system — orthogonal
(0-radius), warm graphite, stroke pictograms, ONE accent. Tier materials:
**Copper → Iron → Silver → Amber** (amber = the app's own accent = the top of
every ladder), plus **Obsidian** for a few near-mythical tiers.

## 1. Grounding (research, 2026-07-28)

- First badge on day zero: users who unlock an achievement on day 0 retain at
  56.9% vs 27.1% without — so **check-in itself mints the first rank**.
- Tiers must be scarce enough to mean something; visible partial progress
  (Zeigarnik) drives the next shift; bronze/silver/gold laddering is the norm.
- Guard shift reality: common pattern 4-on-4-off, ~15 twelve-hour shifts/month,
  40–48 h/week ⇒ **~180 h/month, ~2,100–2,500 h/year** full-time. All
  thresholds below are computed from these rates so every category's Amber tier
  costs roughly comparable REAL time (harder categories get smaller absolute
  numbers because their base rates are lower).

## 2. The rank ladder (dimension 0 — cumulative on-watch hours)

| # | Rank | Hours | Real time (full-time guard) | Emblem motif |
|---|---|---|---|---|
| 1 | **Fledgling** | first check-in | day zero (the retention hook) | small bird on a branch, tower behind |
| 2 | **Rook** | 120 h | ~2–3 weeks | young rook perched on a crenellation |
| 3 | **Keeper** | 500 h | ~3 months | a key crossed with a spyglass |
| 4 | **Raven** | 1,000 h | ~6 months | raven in flight over the tower |
| 5 | **Sentinel** | 2,000 h | ~1 year | figure with spear on the tower top |
| 6 | **Vigil** | 4,500 h | ~2 years | a lit brazier against a dark sky |
| 7 | **Highwatch** | 7,000 h | ~3.5 years | the tower's highest turret, banner flying |
| 8 | **Old Crow** | 10,000 h | ~5 years (the 10,000-hour mastery nod) | weathered crow with ONE AMBER EYE, perched on the tower spire |

Rank is the badge shown in the corner of the app; it never resets.

## 3. The achievement matrix (dimension 1 = category, dimension 2 = tier)

Tiers per cell: **Copper / Iron / Silver / Amber** (+ Obsidian where marked).
"Shift" = a checked-in session ≥ 6 h. "Night shift" = majority of the session
inside 22:00–06:00 local.

| Category (badge family) | Copper | Iron | Silver | Amber | Obsidian | Rationale |
|---|---|---|---|---|---|---|
| **Nightwatch** — night shifts | 10 | 40 | 120 | 365 | 1,000 | dedicated night guard ≈15/mo → Amber ≈ 2 years of nights; Obsidian is near-mythical (~5.5 y) |
| **Hollow Hours** — cumulative on-watch hours 00:00–04:00 | 40 h | 160 h | 500 h | 1,500 h | — | night guard accrues ~60 h/mo → same real-time curve as Nightwatch, rewards the deepest hours |
| **Winter Watch** (× Spring/Summer/Autumn Watch — 4 badges) | 15 shifts | 45 | 90 | 180 | — | a season ≈ 45 full-time shifts: Iron ≈ one whole season, Silver ≈ two winters, Amber ≈ four winters |
| **Incident Watch** — shifts during which ≥1 real event fired | 10 | 50 | 150 | 400 | — | rewards being ON WATCH through activity (v2: acknowledged events, once the ack endpoint exists) |
| **Storm Watch** — on-watch hours during rain | 30 h | 100 h | 300 h | 800 h | — | weather-fed; thresholds tuned per climate at deploy |
| **Snow Watch** — on-watch hours during snowfall | 20 h | 80 h | 240 h | 600 h | — | RU sites are snow-rich; still rarer than rain |
| **Deep Frost** — on-watch hours at ≤ −15 °C | 15 h | 60 h | 180 h | 500 h | — | severity-scaled: rarer condition, smaller numbers |
| **Heat Watch** — on-watch hours at ≥ +30 °C | 15 h | 60 h | 180 h | 500 h | — | mirror of Deep Frost for southern sites |
| **Dawn Keeper** — shifts spanning local sunrise | 10 | 40 | 120 | 365 | — | computable OFFLINE (solar math) — works on air-gapped sites |
| **Moonwatch** — night shifts under a full moon | 2 | 6 | 18 | 40 | — | ~13 full moons/yr, a night guard catches ~6–7 → Amber ≈ 6 years; deliberately the slowest, most conversation-worthy ladder |
| **Unbroken Weeks** — consecutive weeks with ≥3 shifts | 4 wk | 13 wk | 26 wk | 52 wk | — | streaks by WEEK, never by day — a streak must never punish rest (see §6) |
| **Yearkeeper** — on watch across midnight Dec 31 → Jan 1 | 1 | 3 | 5 | — | 10 | THE talking badge; Obsidian Yearkeeper = a decade of New Years on the wall |
| **Wayfarer** — distinct stations checked into | 2 | 4 | 8 | — | — | multi-site orgs only; auto-hidden on single-site installs (honest UI) |
| **Clean Handover** — consecutive proper check-outs | 25 | 100 | 365 | — | — | hygiene mechanic: the whole system's data quality rides on clean sessions |

≈ 17 badge families × 3–5 tiers ≈ **60 badges** — enough matrix to talk about
for years, few enough to know by name.

## 4. Badge art — the generation system

One GLOBAL style block + per-family emblem + per-tier modifier ⇒ every badge
description is `STYLE + EMBLEM + TIER`. This keeps 60 badges visually one set.

**STYLE (prepend to every prompt):**
> Square badge, sharp 90° corners, no rounding. Background: warm dark graphite
> (#221f1c) with a subtle vertical gradient to near-black. A thin double border
> inset from the edge. Centered emblem drawn as clean 1.5px-weight STROKE
> line-art (no fills except tiny accents), in the tier's metal color. Bottom
> edge: the badge name in small uppercase monospace letterpress. Top edge:
> tier pips (small squares, one per tier level). Flat, engraved-metal feel,
> no gloss, no 3D bevel, no photorealism. Mood: stoic, heraldic, slightly
> mythic — a military patch crossed with a chess piece.

**TIER modifiers:**
- *Copper:* border and emblem in matte copper (#b87333); one pip.
- *Iron:* dark forged iron (#8a8f98) with faint hammered texture; two pips.
- *Silver:* bright silver (#d8dce3), crisp; three pips.
- *Amber:* glowing amber (#e8a13a) — the only tier whose emblem faintly GLOWS;
  four pips; a hair-thin amber outer rim.
- *Obsidian:* near-black glassy emblem with a single amber glint; five pips;
  the badge field darkens to true black.

**EMBLEMS (per family):**
- *Rank badges:* see the motif column in §2 — same style block, emblem in amber
  regardless of rank, complexity growing with rank (Fledgling = 3 strokes;
  Old Crow = detailed weathered crow, one amber-filled eye, tower spire).
- *Nightwatch:* an owl's face composed of two crescent moons as its eyes, above
  three battlements.
- *Hollow Hours:* an hourglass whose lower bulb holds tiny stars instead of sand.
- *Winter Watch:* a six-pointed snowflake caged inside a shield outline.
  *Spring:* a sprouting branch over the shield. *Summer:* a high sun with
  straight rays over the shield. *Autumn:* a single falling leaf over the shield.
- *Incident Watch:* an alarm bell with three radiating motion strokes each side.
- *Storm Watch:* the tower struck by one diagonal lightning bolt, three slanted
  rain strokes.
- *Snow Watch:* the tower wearing a snow cap, one large snowflake beside it.
- *Deep Frost:* a thermometer entombed in an ice crystal.
- *Heat Watch:* a sun pressing down on a heat-wavered horizon line.
- *Dawn Keeper:* a half-risen sun exactly bisected by a battlement line.
- *Moonwatch:* a full moon behind the tower, a small crow silhouette perched on
  the tower top.
- *Unbroken Weeks:* a closed ring of chain links, no broken link.
- *Yearkeeper:* a clock face at midnight (XII) with a single firework starburst
  behind it.
- *Wayfarer:* three towers on a horizon joined by a dotted path.
- *Clean Handover:* two hands exchanging a key, drawn in four strokes.

## 5. UX (client)

- **Check-in, not login** (systems never restart): a chip in the TopBar right
  cluster. Nobody on watch → amber-outlined **"Check in"**; click → roster
  panel (names come from CV — admin-created, never invented, per product
  rules) → one tap. Checked in → chip reads `ON WATCH · <name>` with the rank
  mini-emblem; click → check-out / switch guard. Auto-checkout at 16 h with an
  honest `auto_closed` flag (nobody works 16 h by design — see §6).
- **The corner badge:** the guard's rank emblem, small, in the TopBar corner
  next to the clock. Click → the Achievements screen: the matrix as a grid,
  earned badges lit, locked ones as dim outlines **with progress bars and
  "N to go"** (the Zeigarnik hook the research says drives the next shift).
- **Unlock moment:** toast + a brief glint on the corner badge. No sounds by
  default (guard room discipline); honors the existing alert-sound preference.
- All strings EN+RU from day one.

## 6. Responsible-gamification rules (hard constraints)

Guards are a safety function; the system must never reward fatigue or wish for
trouble:
1. **No overtime badges** — nothing for marathon shifts, most-hours-in-a-week,
   or shortest gaps between shifts. The 16 h auto-checkout also caps accrual.
2. **Streaks count WEEKS (≥3 shifts), never consecutive days** — a badge must
   never make a guard skip rest.
3. **Incident badges reward presence and attention, never outcomes** — being on
   watch when events happen, later acknowledging them; never "most incidents"
   as a leaderboard, never response-time races.
4. **No public leaderboards in v1** — badges are personal + conversational;
   ranking guards against each other invites gaming and resentment. Revisit
   only if guards themselves ask.
5. **Honest availability** — weather badges on a site with no weather feed show
   "not available at this site", never fake-zero progress (no-silent-no-op rule).

## 7. Client/backend split

Backend (CV) is AUTHORITATIVE — accrual survives client reinstalls, works
across stations, and can't be gamed from a client. Client renders + performs
check-in/out. Full contract in the letter; summary: guard roster (admin-owned),
`POST check-in/out`, `GET state` (rank + matrix + progress + unlocks-since for
toasts), server-side classification (nights, seasons, hollow hours, sunrise,
moon phase, holidays — pure math server-side; weather via a free no-key API
like Open-Meteo where the backend has internet, gracefully absent otherwise),
event-overlap accrual from CV's own events store.

## 8. Rollout

P1: CV letter → contract. P2: client check-in chip + corner badge + toasts +
Achievements screen. P3: badge art generated from §4 (operator runs the image
generator; assets land in `assets/badges/`). P4: RU strings, self-test
(WT_WATCH_TEST), screenshot verification. Feature-flagged `WT_THE_WATCH` until
CV's endpoints are live (honest pending, per house rules).
