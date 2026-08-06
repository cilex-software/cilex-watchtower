# Cilex Watchtower — Triage Queue UI specification + camera quick-filter redesign brief

**Audience:** Claude Design (no codebase access — this document is the complete
source of truth; anything not written here does not exist for you).
**Date:** 2026-08-06.
**The task in one line:** the Triage Queue's new per-camera quick filter is a
single horizontal chip row that fits ~5 chips; the fleet is heading to 80+
cameras; redesign the filter so any camera is reachable fast, without breaking
the rest of the queue — full current-state spec below.

---

## 1 · Product context

Cilex Watchtower is a **native desktop video-surveillance client** (Qt/QML,
Linux; not a web app — no CSS, no web components; every control is custom-drawn
rectangles and text). Users are **security guards** at a residential complex:
long shifts, dark rooms, 1440×900 default window (resizable, often smaller),
mouse-first interaction, modest technical skill. UI language is currently
English for this screen with Russian localization present app-wide (nav rail
is already Russian: СОБЫТИЯ, ГРУППЫ…) — assume every label you introduce must
work in BOTH English and Russian (Russian strings run ~30% longer).

Non-negotiable product rule (**honesty**): the UI never invents data and never
goes silently blank — a filter with no matches must SAY "no events match";
unknown states render as unknown, not as healthy defaults.

Fleet reality: 39 cameras today across two sites, growing to **80+**. Guards
refer to cameras by the **last IP octet** — ".146", ".104" — that is the
spoken name of a camera. Full names are long and near-identical:
"HiWatch DS-I202(E) (192.168.1.146)" (vendor model + IP). Cameras belong to
named groups ("Inside", "Снаружи" = Outside); a **separate group dropdown
already exists** at the Events-section level (see §3) — the camera filter is a
finer cut *within* whatever group scope is active.

Event volume: a normal morning produces a queue of **100–130 open motion
events**; each event belongs to exactly one camera. Distribution is uneven —
a handful of busy cameras produce most events, with a long tail of cameras
having 1–3.

## 2 · Design language (exact tokens)

Dark, warm, utilitarian "control-room" aesthetic. **All corners are square**
(0 radius) except circular status dots. Hairline borders, no shadows, no
gradients except video-overlay scrims. Hover states swap background fills;
active states use the amber accent. Everything is compact and dense.

Colors (hex, exact):

| token | hex | used for |
|---|---|---|
| bg | `#1a1816` | window background, sub-bars |
| panel | `#221f1c` | cards, top bar |
| panel2 | `#2a2722` | hover fills, count pills |
| panel3 | `#322e28` | raised surfaces, scrubber groove |
| line | `#34302a` | subtle hairline dividers |
| line2 | `#443f37` | component borders |
| ink | `#f0ece4` | primary text |
| ink2 | `#a89f90` | secondary text |
| ink3 | `#6e6657` | tertiary text/labels |
| accent | `#e8a13a` | amber — active, focus, primary |
| accentSoft | accent @ 8% alpha | active chip/selection wash |
| accentDim | `#5a3f15` | amber badge background |
| bad | `#d96649` | critical, offline, REC |
| badSoft | bad @ 10% alpha | critical halo |
| good | `#8eb96b` | LIVE/healthy (olive) |
| info | `#6f9bc4` | in-progress (blue) |
| violet | `#9a7bd0` | bookmarks |

Typography: **Space Grotesk** (sans) for labels/body; **JetBrains Mono** for
numbers, timestamps, octets, counters, and ALL-CAPS micro-labels (letter-
spacing ~1.2–1.6, sizes 9–11px). Body sizes are small: 11–13px; section
headers 10px mono caps in ink3.

Severity color mapping (used by the queue's dot): critical → bad `#d96649`
(with a 14px badSoft halo), high → accent, medium → ink2, low → ink3.

## 3 · Events section chrome (what surrounds the Triage Queue)

Top-to-bottom of the window:

1. **OS title bar** (dark) — app name + current context.
2. **App top bar**: brand block left ("CILEX VISION / Watchtower" + station
   id), global search field ("Поиск камер, групп, видов, клипов, событий…",
   Ctrl K), fleet health pills (ОНЛАЙН 33 · НЕ В СЕТИ 6 · НЕТ ЗАПИСИ 0),
   right side: "Заступить" (shift check-in) button, clock "11:09 · UTC+3",
   alarm bell, avatar "AD".
3. **Tab strip**: "События" (home tab) + any opened camera tabs.
4. **Events sub-nav row**: four numbered sub-view tabs — **01 Triage Queue**
   (active = amber filled button), 02 Verify, 03 Activity Timeline,
   04 Situation Map — then the **"All groups" dropdown** (group scope for the
   whole Events section), then helper copy ("CLEAR THE BACKLOG / Inbox
   triage…" in ink3, amber heading), then right-aligned totals:
   **130 OPEN · 0 CRITICAL · 0 CLEARED** (mono, color-coded dots).

Below that, the Triage Queue view fills the rest.

## 4 · Triage Queue view — current anatomy

Two columns.

### 4a · LEFT — the queue (fixed 384px wide, full height, 1px right border `line`)

Stacked top to bottom:

**Row 1 — status tabs** (45px tall, bottom hairline): three text tabs —
"Open queue", "Critical", "All" — each with a count pill (panel2 fill, mono
10px; count text amber when tab active, ink3 otherwise). Active tab: ink text
+ 2px amber underline at the bottom edge. Inactive: ink2. Click switches the
queue's population: Open = events with status new/ack/in-progress; Critical =
priority critical only; All = everything loaded. These counts are GLOBAL for
the tab populations (deliberately NOT affected by the camera filter).

**Row 2 — camera quick-filter chip row** (36px tall, bottom hairline) — THE
SUBJECT OF THIS BRIEF, full spec in §5.

**Row 3 — event list** (fills remaining height, vertical scrollbar):
rows are 67px tall, bottom hairline each, containing left-to-right:
- 8px **severity dot** (color per severity mapping; critical adds a 14px
  halo at 10% bad);
- 74×42px **thumbnail** (mid-incident video still; bottom-left corner holds
  a tiny duration badge — mono 9px on 70% black, e.g. "48s", "1m 31s");
- text block: line 1 = type chip "◇ MOTION" (mono 10px, bordered) ;
  line 2 = camera display name 12px ink ("HiWatch DS-I202(E)
  (192.168.1.144)"), ellipsized; line 3 = "11:07:04 · 2m ago" (mono/ink3);
- right edge: small **unread dot** (amber/bad) for unacknowledged events.
Selected row: 3px amber bar on the left edge + slightly darker fill.
Clicking a row selects the event → right pane loads it.
Empty state (possible when a camera chip zeroes a tab): centered ink3 text
"No events match this filter."

### 4b · RIGHT — detail pane (fluid width)

- Header strip over the video: "▶ PLAYBACK" micro-chip + camera name (mono).
- **Video player** (16:9, letterboxed on black): plays the event's recording
  incl. pre/post-roll; camera's own burned OSD may show in-frame; big center
  play circle when paused.
- **Transport bar** (below video): |< prev-frame, play/pause, next-frame >|,
  "−10", "+10" (seconds), position counter "00:00 / 01:14" (mono — total =
  clip WITH ±15s padding), the **scrubber**: 5px groove (panel3), amber
  progress fill, 3×16px playhead thumb, and a **2px amber underline floating
  7px below the groove marking motion start→finish** inside the padded clip;
  far right a speed toggle "1×" (cycles 1/2/4).
- **Action row**: "Export clip", "Assign" (left), "Bookmark" (right) — ghost
  buttons, 12px.
- **Event card**: type title "Motion" (18px), subtitle "Motion detected",
  severity tag right ("LOW" mono ink3).
- **Disposition bar** (bottom): "✓ Authorized" (green-outlined), "× False
  alarm" (neutral), "⇱ Dispatch guard" (red-outlined) and right-aligned
  primary "✓ Acknowledge (E)" (amber filled, dark text; E = keyboard
  shortcut).

## 5 · The camera quick filter — exact current behavior and THE PROBLEM

Current implementation (shipped yesterday as a first cut):

- A single **horizontal, scrollable chip row**, 36px tall, sitting between
  the status tabs and the event list. No scrollbar, no overflow indicator —
  content simply clips at the right edge.
- Chips, left to right: **"All"** (resets; count-less), then one chip per
  camera **present in the ACTIVE status tab's events**, ordered
  **busiest-first** (event count desc, then label). Cameras with zero events
  in the tab have no chip at all.
- Chip = 22px tall bordered rectangle (square corners): label = IP octet
  (mono 10px DemiBold, e.g. ".104") + count (mono 9px ink3, e.g. "15").
  States: idle = transparent fill, `line2` border, ink2 label; hover =
  panel2 fill; **active** = accentSoft fill, amber border, amber label.
  Tooltip on hover = full camera name (500ms delay).
- Click toggles: click chip → queue shows only that camera; click again or
  click "All" → clear. Single-select only. Filter state is queue-local (it
  does NOT touch the tab counts, the section totals, or other sub-views).
- Chips recompute when the status tab changes (counts are per-tab).

**Why it fails at fleet scale (the operator's screenshot, 130-event morning):**
1. **Capacity:** 384px minus margins fits ~5 chips; with 15–20 active
   cameras (and 80+ soon) >75% of chips are invisible off-screen.
2. **Zero discoverability of overflow:** nothing indicates more chips exist;
   horizontal wheel-scrolling a chip row is not a gesture guards know.
3. **Ordering instability:** busiest-first means chips REORDER as events
   arrive; a camera you saw at position 2 may be position 7 a minute later —
   muscle memory is impossible.
4. **No search path:** with 80 cameras there is no way to type/jump to
   ".146"; the octet is known — the UI can't receive it.
5. **Single-select only:** guards sometimes watch an entrance pair (two
   cameras covering one door) — can't.
6. (Kept virtue: one-click access to the busiest cameras — whatever replaces
   the row should not lose this.)

## 6 · Contract any redesign must respect

- **Population rule:** offer exactly the cameras that have ≥1 event in the
  active status tab (a camera with zero events in scope must not be
  selectable INTO an empty list silently — if you choose to show the full
  fleet roster anyway, zero-count entries must be visibly zero and selecting
  one must produce the honest empty state, never a blank).
- **Counts are live** and per-tab; they change as events arrive.
- **Octet is the primary label**; full name available on demand (hover or
  secondary line). Two sites may eventually collide on octets — design may
  assume octets unique for now, but a duplicate-safe variant is a plus.
- **Filter state must stay visible at all times** while active (the guard
  must never wonder why the queue looks short). A cleared/`All` state must
  be one obvious click away.
- **Queue-local:** does not alter tab counts, section totals, group
  dropdown, or the other three sub-views.
- **Keyboard:** the view already uses single-key shortcuts (E =
  acknowledge); type-to-find is welcome but must not steal the E key or
  Ctrl-K (global search).
- Left column is 384px today; you MAY propose widening to ~420px or adding
  a second row/panel, but the event list must keep ≥8 visible rows at
  900px window height. The right pane must not shrink below a 16:9 player
  at ~700px width on a 1440px window.
- Dark theme only, tokens from §2, square corners, both languages, mouse
  primary + keyboard assist. Native QML: any pattern you draw must be
  buildable from rectangles/text/lists — no OS-native widgets, no web.

## 7 · The ask

Redesign the camera quick filter for 8→80+ cameras. Deliverables wanted:
1. Chosen pattern with rationale (e.g. searchable dropdown-panel anchored to
   a filter button; top-N chips + "+27 ▾" overflow palette; two-row wrap
   with expand; type-ahead field with chip results — your call, or better).
2. Exact layout spec in this document's vocabulary (sizes, tokens, states:
   idle/hover/active/disabled, overflow, empty, loading).
3. Interaction spec: select, multi-select (if you include it), clear, search,
   keyboard behavior, what persists across status-tab switches.
4. The active-filter indication when the picker is closed.
5. Edge cases: 1 camera, 80 cameras, all events on one camera, Russian
   labels, narrow window (1200px).

Success test: a guard who hears "check .146" reaches a .146-only queue in
≤2 seconds without scrolling hunts; a guard clearing the morning backlog can
hop between the three busiest cameras in one click each.
