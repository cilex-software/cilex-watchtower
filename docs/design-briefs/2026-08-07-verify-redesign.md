# Cilex Watchtower — "Events › Verify" full UI specification + density-redesign brief

**Audience:** Claude Design (no codebase access — this document is the complete
source of truth; anything not written here does not exist for you).
**Date:** 2026-08-07.
**Mandate in one line:** redesign the Verify page in the **density language you
built for the Triage Queue** (your variant B "Lanes", now SHIPPED verbatim) —
today Verify is still the old spacious idiom: 102 px of toolbar chrome, ~350×335 px
cards, ~10 cards visible against a 276-event morning.

Your own prior deliverables apply and are shipped product now:
`2026-08-06-triage-camera-filter-variant-b-lanes.md` (density language: gapless
hairline cells, 26 px lane headers, 44 px rows, shared-hairline segmented
controls, zero-pixel filter chrome) and its §2.5 group strip. Verify renders
BELOW the same shared chrome you already densified: 52 px top bar → 30 px tab
strip → 38 px sub-nav (mode cells · group strip · totals). Do not redesign
those. Everything below the sub-nav is yours.

## 1 · Product context (unchanged from the camera-filter brief)

Native Qt/QML desktop VMS for security guards; dark theme only; 1440×900
default, often 1200×900; mouse-first; every label ships EN + RU (RU ~30%
longer, counts need 3 plural forms); honesty rule: no silent blanks, no
invented data, fallback states must declare themselves. Fleet: 39 cameras
(→80+), 100–276 open motion events on a normal morning, camera spoken name =
IP octet (".146").

## 2 · Design tokens (exact, same as the shipped Triage)

bg `#1a1816` · panel `#221f1c` · panel2 `#2a2722` · panel3 `#322e28` ·
line `#34302a` · line2 `#443f37` · ink `#f0ece4` · ink2 `#a89f90` ·
ink3 `#6e6657` · accent `#e8a13a` · accentSoft = accent @8% · accentDim
`#5a3f15` · bad `#d96649` · badSoft @10% · good `#8eb96b` · info `#6f9bc4` ·
violet `#9a7bd0`. Fonts: Space Grotesk (sans), JetBrains Mono (numbers/times/
octets/micro-caps). Square corners everywhere; hairline borders; no shadows.
Severity → color: critical=bad(+halo), high=accent, medium=ink2, low=ink3.

## 3 · What Verify IS (product intent)

The queue's **second surface**: fast VISUAL confirmation at scale — look at
many event stills at once, mark each "real threat" or "false alarm" without
opening anything. Complements Triage (one-event-deep) with breadth. Two
layouts under one toggle:

- **Verification Wall** — a card grid of events (the screenshot you received).
- **Smart Sessions** — zone-grouped rows with checkboxes and bulk actions
  ("collapse the noise, ack in batches").

## 4 · Current anatomy, pixel-exact (from code)

### 4a · Verify toolbar — 57 px row, bottom hairline
Left: **segmented layout toggle** (40 px tall, panel fill, 1 px line2 border):
cells "👤 Verification Wall" / "≋ Smart Sessions", 13 px DemiBold sans + 14 px
icon, active cell = accent fill with dark text. Right: contextual control —
label `Size` (mono 11 ink3) + **S/M/L** 30×30 mono cells (active accent) on
Wall; label `Sort` + **Priority/Recent** segmented on Sessions. Each layout
remembers its own control value. All of this is the OLD pre-density idiom
(bordered pills, gaps) — candidate for a 30–38 px gapless band.

### 4b · Wall sub-bar — 45 px row, bottom hairline
Filter chips (30 px tall, accentSoft+accent border when active):
**To verify** (status new|ack) · **AI detections** (types person/vehicle/
line_cross/loiter — with today's fleet these are ZERO; only "motion" exists
until ANPR/AI cameras land) · **All**. Then a helper line: "👤 Verify what you
see — confirm a real threat or dismiss a false alarm without leaving the
grid." (12 px ink2).

### 4c · The card grid
Columns by size: **S=5 · M=4 · L=3**; grid margins 12/10; cell width =
floor((width−24)/cols); cell height = round((cellW−16)·9/16)+**136** — i.e.
a 16:9 media area plus 136 px of card chrome. Card = 8 px inset, panel fill,
1 px hairline (line→line2 on hover).

Card internals, top to bottom:
- **Media (16:9):** the event-moment still, requested per event
  (`/events/{id}/snapshot`, a governed server-side ffmpeg extraction — only
  ~2 run concurrently, so offscreen prefetch is deliberately OFF:
  `cacheBuffer: 0`, viewport-only fetches). Overlays: faint camera name
  top-left + `CH nnn` bottom-left (procedural OSD dressing), severity tag
  top-right (mono 9 bold on 60% black), **duration badge** bottom-right
  ("▶ 48s" on 72% black; "no clip" for offline events), and bottom-right
  date+time of the still **or `● LIVE`** — CRITICAL HONESTY DETAIL: when the
  event-frame extraction isn't available yet, the card falls back to the
  camera's LIVE snapshot and marks itself `● LIVE`. In the operator's
  screenshot nearly every card is in that fallback — which is why seven
  `.146` cards look identical and "verify what you see" collapses into
  guesswork. Any redesign must make "event frame" vs "live fallback"
  unmistakable and cheap to scan.
- **Hover:** the still animates a slow pan (a fake "preview", 2.4 s drift) —
  not real video; undiscoverable; clicking the media opens the event in
  Triage (now lands soloed on its camera lane).
- **Info block:** type pill (`◇ Motion · 87%` when AI confidence exists —
  today `n/a`), camera FULL name 12 px ("HiWatch DS-I202(E)
  (192.168.1.146)" — 34 chars repeated on every card; the exact disease your
  lanes cured in Triage), time `hh:mm:ss · 2m ago` mono 10 ink3.
- **Action row** (hidden once verified): three small buttons — **Threat**
  (good-green, disposes the event as "verified"), **Dismiss** (neutral,
  disposes as "false_alarm"), bookmark toggle. Buttons disable while a
  disposition request is in flight.
- **Verified state:** the card STAYS in place at 62% opacity with a 55%-black
  overlay stamp `CLEARED` (good) or `DISMISSED` (ink2), mono 13, tracking
  2.6. Done work keeps full footprint.

### 4d · Smart Sessions layout
- **Stat header 56 px:** three big numbers (26 px bold + two mono-caps lines):
  motion-fragment count "collapsed into sessions", high-priority "need
  action" (bad), handled "this shift" (good).
- **Zone sections:** 43 px zone header (severity dot 8 px + critical halo,
  zone name, count pill, collapse caret) over **58 px event rows** (mini
  snapshot, type pill, time, per-row Ack + Bookmark, checkbox), plus a
  floating **bulk bar** when any are picked: Ack N · Dismiss N.
- Zones sort by Priority (worst severity first) or Recent. Row data is the
  same events as the Wall.

### 4e · Data semantics the redesign must keep
- Filters/tab predicates as in 4b; counts change live (poll-refreshed feed).
- Threat→dispose("verified"), Dismiss→dispose("false_alarm"),
  Ack→acknowledge; all server round-trips with a global in-flight lock
  (buttons disable; no optimistic lying).
- Click-through target: Triage, which now solos that camera's lane.
- Verified events remain visible in "All", drop out of "To verify" on the
  next feed refresh (the stamp bridges the gap honestly).

## 5 · The problems, ranked (what the redesign must actually solve)

1. **Density.** M-size at 1440: ~350 px cards, 2.5 rows on screen ≈ 10 of 276
   events. The lanes math applies: the camera name alone costs each card a
   line; 136 px of chrome per card is variant-A thinking. Target: ≥2.5× more
   events per screen at equal glanceability, by whatever structure wins —
   smaller cards, lane-grouped strips, a filmstrip per camera, your call.
2. **Same-camera bursts.** A corridor camera fires every 90 s all morning →
   dozens of near-identical cards (screenshot: 7× `.146`). Some form of
   burst-collapse ("​.146 × 7 in 40 min" expanding on demand, or verify-the-
   burst-as-one) is the single biggest noise win. Bulk disposition exists
   only in Sessions today; the Wall has none.
3. **The LIVE-fallback ambiguity.** When most cards show the same live frame,
   scanning is meaningless. Make the fallback state loud (and make the
   eventual arrival of the real event frame visible), or design the card to
   still be verifiable without its still (time + duration + camera + jump).
4. **Chrome spend:** 57 px toolbar + 45 px sub-bar = 102 px of controls in the
   old idiom vs. your 32 px gapless tab row in Triage. Fold layout toggle,
   filters, size/sort into one dense band (S/M/L may not even survive — if
   the new geometry has one right density, kill the control; the tweaks
   panel can carry alternatives for review instead).
5. **Verified cards** keep full footprint. Collapse, shrink, or sweep them to
   a strip — done work should cost almost nothing.
6. **Keyboard.** Zero today. Digits are taken by Triage's lane type-ahead —
   fine to reuse HERE for camera-jump if you keep semantics identical.
   `E` (acknowledge) and `Ctrl-K` (global search) stay reserved. A
   roving-focus + one-key Threat/Dismiss sweep is the obvious pro move;
   pick keys that don't collide with the above.
7. **AI detections tab** is an empty promise on this fleet until ANPR cameras
   land (they're being certified now — plate events will eventually arrive
   as a new type). Design the tab to earn its place or fold it away until
   the data exists; an always-zero tab violates the spirit of honesty.

## 6 · Non-negotiables

Honesty (fallback marking, no optimistic state, empty states name their
filter); EN+RU with 3-form plurals; square corners, tokens from §2, no
shadows; QML primitives only (Rectangle/Text/MouseArea/ListView/GridView —
no Popup, no web); `E`/`Ctrl-K` reserved; media stills are EXPENSIVE
(governed 2-wide server extraction — viewport-only fetching must survive any
redesign; a design that wants 60 stills on screen must degrade gracefully
while they trickle in); 384 px is not sacred here (full-width page), but the
shared sub-nav above is fixed; works at 1440×900 and 1200×900.

## 7 · Deliverables — same package as the camera-filter handoff

1. Spec .md (anatomy, sizes, tokens, states, interactions, edge cases —
   including: 276 events/21 cameras; one camera = 90% of events; zero events;
   all stills in LIVE-fallback; RU at 1200 px).
2. Self-contained HTML prototype (React-as-drawing is fine) with the tweaks
   panel (density variants, EN/RU, 1440/1200, burst-collapse on/off).
3. README with your variant decision made (pick one, like last time) and the
   implementation prompt addressed to the Watchtower builder agent, traps
   included — your lanes traps ("computed fit, not converging loops",
   "octet is one text run", "60% mute floor") all still apply; add what you
   hit while prototyping this one.

Success test: a guard sweeping a 276-event morning sees ≥2.5× more events
per screen than today's M grid, disposes a same-camera burst in one action,
and can always tell a real event frame from a live fallback at a glance.
