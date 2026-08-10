# Cilex Watchtower — "Wall playback" (16-camera synchronized playback): full UI specification + redesign brief

**Audience:** Claude Design (no codebase access — this document is the complete
source of truth; anything not written here does not exist for you).
**Date:** 2026-08-10.
**Mandate:** redesign the synchronized 16-camera playback wall in the density
language you built and we shipped — Triage "Lanes", Groups "Wall", Playback
"One Axis" (single camera). This screen is the multi-camera sibling of "One
Axis" and has not been touched since it was first built.

---

## 1 · Product context

Native Qt/QML desktop VMS for security guards at a residential development.
Dark theme only. 1440×900 default, often 1200×900, 1920×1080 on the booth PC.
Mouse-first. EN + RU (RU ~30 % longer, 3-form plurals). Fleet: 39 cameras,
heading to 80+, spoken about by last IP octet (".151").

Honesty rules are product law: never invent data, never render unknown as
healthy, every empty state names its cause, no silent no-op controls, nothing
stamped before the server answers.

**What this screen is for.** The operator is on the Live wall, something
happened, and they press **"Go back in time"**. This screen replays **the same
set of cameras, in the same grid, in lock-step** — one moment in time across
the whole site. The jobs are: *find the moment*, *watch the site as a whole
rather than one camera at a time*, and *take the moment out as evidence across
every camera at once*.

### 1.1 · The one architectural fact that governs everything

**This is not 16 video players. It is ONE video.** The backend composites all
16 cameras into a single H.264 stream and the client plays that one stream;
everything you see per-cell — the camera name, the timestamp chip, the drag
highlight — is a **client-drawn overlay positioned over a cell of that single
picture**, using a `cells[]` map the server returns (`{index, camera_id, row,
col}`).

We tried client-side N-way sync first and measured it dead: ~2–3 concurrent
streams was the ceiling. So a server mosaic it is, and the consequences are
design constraints:

- **Grid geometry is fixed by the server**: 4×4, **1920×1080 @ 12 fps h264**,
  each cell **480×270**. A tile is 480×270 of real pixels no matter how large
  you draw it.
- **Every cell is the same instant by construction** — millisecond-synced. That
  is the feature. Fourteen identical timestamp chips are how it is currently
  *proved*, which is arguably fourteen times more proof than anyone needs.
- **Changing which cameras are on the wall re-composites the whole thing** —
  server-side work, not a client re-layout.
- **Measured performance** (2026-08-10, 16 cams, 6 h window, against the pilot
  backend): session create **191–643 ms**; first segment at the window head
  **0.69 s**; prewarm → segment served **1.2–2.4 s**. It is fast. An older
  in-code comment claiming 4–6 s was stale and has been corrected.
- **The compositor renders in order.** Requesting a segment at a random offset
  returns **HTTP 503** until a `prewarm` call tells the renderer to go there —
  measured 14 of 14 attempts. The client prewarms on seek; the design must not
  imply instant random access.

### 1.2 · The other fact: most cells are legitimately black

14 of the 16 cameras on a typical wall are **motion-triggered recorders**. At
any given instant they have no recorded video, so the composited frame carries
**3–4 lit cells out of 16** and the rest are black. Verified: sampled at the
instant each camera has its own segment, 7 of 7 lit their own cell — the
compositor is not dropping anything.

**And the client cannot currently say so per cell.** The manifest reports
availability per **fragment** (whole grid), never per camera. So a cell that
recorded nothing looks exactly like a cell the compositor failed on: black,
with a camera name and a ticking timestamp over it, which reads as "still
loading". **This is the single worst honesty failure on the screen** and the
operator has reported it. A per-cell availability field is being requested from
the backend team; design as if you will have it, and specify what the cell
shows when you do.

---

## 2 · Design tokens (exact)

bg `#1a1816` · panel `#221f1c` · panel2 `#2a2722` · panel3 `#322e28` ·
line `#34302a` · line2 `#443f37` · ink `#f0ece4` · ink2 `#a89f90` ·
ink3 `#6e6657` · accent `#e8a13a` · accentSoft = accent @8 % · accentDim
`#5a3f15` · bad `#d96649` · good `#8eb96b` · info `#6f9bc4` · violet `#9a7bd0`.
Screen-specific: player letterbox `#121110`, scrubber trough `#16140f`, footage
"ready" `#3f5a2a`, footage "warming" `#4a4327`, cell time chip `#cc16140f`.

Fonts: **Space Grotesk** (labels, names, buttons), **JetBrains Mono** (all
numbers, times, IPs, ALL-CAPS micro-labels 9–11 px, letter-spacing 0.6–1.6).
Square corners, hairline borders, no shadows.

---

## 3 · Screen anatomy (current, code-truth)

Four regions: the shared chrome above, the **composited grid** (left, fluid),
the **info aside** (right, fixed 320 px), and the **transport + scrubber**
(bottom, full width).

### 3.0 · Shared chrome above (do not redesign, but know it)

24 px window title bar (`WATCHTOWER · Live wall` — note it still says *Live
wall* on this screen, which is wrong), then the 52 px top bar: brand + build
hash · global search with a `CTRL K` chip · **three fleet-status pills**
(`ONLINE 39` / `OFFLINE 0` / `NOT REC 0`) · `Check in` · clock + UTC offset ·
alerts bell · avatar. Left of everything, the 72 px nav rail: Live · Groups ·
Views · Events (count badge) · Health.

> ⚠️ **The three pills are a live defect on this screen.** They are counted
> fleet-wide and clicking one only sets the **Live wall's** status filter — it
> does not navigate and it changes nothing you can see from here. Pressing
> `OFFLINE` on this screen appears to do nothing. Either they should act on
> this wall, navigate to Live, or be absent here.

### 3.1 · The composited grid (left, fluid)

One `VideoOutput` showing the composited stream, letterboxed
(`PreserveAspectFit`) on `#121110`, with the cell overlays positioned from the
server's `cells[]` map.

**Per cell, drawn by us over the video:**
- **Top-left**: camera name + IP, e.g. `HiWatch DS-I456Z(B) (192.168.1.151)`,
  9 px mono on a scrim.
- **Bottom-left**: a **time chip** — `08:47:58.372`, mono 9 px, on
  `#cc16140f`. **Identical in every cell**, because the wall is one stream.
  **It shows time only — no date.** On any window that crosses midnight (which
  the rolling presets always do) this is ambiguous with "now", and an operator
  has already been caught by it.
- **Drag feedback**: the source cell dims to 45 % black; the cell under the
  cursor gets an accent frame.

**Interactions on the grid:**
- **Right-click a cell → "Choose camera for this tile"** (§3.5).
- **Press and drag a cell onto another → swap the two cameras.** The cursor
  becomes a closed hand, a **ghost label with the camera's name rides the
  cursor**, and releasing swaps and re-composites. Cancelling restores.
- There is no click-to-open-single-camera here (unlike the Live wall).

### 3.2 · Info aside (right, fixed 320 px)

Top to bottom:

- **Title `Wall playback`**, and under it **`14 cameras · synchronized`** —
  the count is however many cameras are actually on the wall (≤16).
- **`EDIT CAMERAS`** button — opens the multi-select camera assignment modal
  (§3.6).
- **`GROUP` dropdown** — `All cameras` plus every backend camera group, each
  **with its camera count** (`All cameras 39 · Inside 22 · Лифты 3 ·
  Снаружи 14`). Counts come from the client's own roster. A group with **0
  cameras is dimmed and inert** with a *"No cameras in this group"* tooltip,
  because a wall cannot be composited from nothing. Choosing a group loads its
  **first 16** cameras onto the wall and re-composites. When the wall holds an
  arbitrary set rather than a group, the control reads **`Custom selection`**.
- **Hint line**: *"Right-click a tile to swap its camera · drag a tile to
  rearrange"* — the only place those two gestures are advertised.
- **`STATUS`** — two rows:
  - **`Playhead`** — the instant being shown, **time only** (`08:47:58`).
  - **`Window`** — the loaded span. Reads a **date** (`Mon 10 Aug`) when a
    calendar day is loaded, otherwise a **duration** (`24 hours`, `12 hours`,
    `6 hours`, `1 hour`, `N min`).
- **`FOOTAGE`** — the calendar (§3.4).

### 3.3 · Transport bar (bottom, above the scrubber)

A single row of chips, left group:

| control | behaviour |
|---|---|
| `❚❚` / `▶` | play / pause the composited stream (also `Space`) |
| `−10s` | playhead −10 s within the loaded stream |
| `+10s` | playhead +10 s |
| `Last hour` | re-scope the view to the last 60 minutes |
| `Last 15 min` | re-scope the view to the last 15 minutes |
| date + time readout | `Mon 10 Aug 2026 · 08:47:58` — **the only place on the whole screen that carries the date** |

Right group:

| control | behaviour |
|---|---|
| `15m` `1h` `6h` `12h` `24h` | **view span presets**, radio-style. The active one is accent-filled |
| `<span>` + `Fit` | appear only after a free-form wheel-zoom: the first shows the custom span, either returns to the full window |
| `Events` | toggles the per-camera motion lanes in the scrubber on/off (persisted preference) |
| `Export selection` | appears only while an In→Out range is marked (§3.7) |
| `Return to live` | leaves playback and returns to the Live wall |

> ⚠️ **Two different windows share one label, and it has already confused an
> operator.** The `15m/1h/6h/12h/24h` chips are **rolling windows ending now** —
> `24h` means "the last 24 hours", so with the playhead hard-left the time is
> *yesterday at this hour*, not midnight. A **calendar day click** loads
> **00:00 → 24 h**. Both are described as "24 hours" in `STATUS › Window`.
> Combined with the date being absent from the playhead readout and from all 14
> cell chips, the operator reasonably read "playhead at the far left of 24H" as
> "just past midnight". Fix the communication, and tell us if you think the
> semantics should change too.

### 3.4 · The FOOTAGE calendar (in the aside)

- Header: `7 Jul – 10 Aug 2026 · last 35d` and `9 days w/ footage`.
- A **Mon–Sun grid** covering the retention window (35 days).
- **A day with recorded footage carries a dot**; days outside retention and
  future days are dimmed and inert. **Today is ringed.** The **selected day is
  filled amber.**
- Legend: `• has footage` / `▫ today`.
- **Clicking a day loads that whole day** (00:00 → 24 h, clamped to now) and
  re-composites. Rapid clicks are debounced into a single composite.
- While coverage has not been answered by the backend, the calendar renders a
  **pending** state rather than implying "no footage".

### 3.5 · Per-cell camera picker — right-click (screenshot B)

A modal, ~460 px:
- Title **`Choose camera for this tile`**, subtitle **`Replaces <camera name> ·
  the wall re-composites`** — it names the cost of the action before you take
  it.
- A focused **`Search name, IP or group…`** field.
- A scrolling list of every roster camera: **name in bold**, then
  `IP · group` beneath. Cameras already on the wall carry an **`ON WALL`**
  badge.
- **`Cancel`**; `Esc` also closes.

### 3.6 · `EDIT CAMERAS` — the multi-select picker

A modal titled **`Assign cameras`**, subtitle *"The wall re-composites at the
current moment"*: a search field, a checkbox list of the roster, and three
actions — **`Use live wall`** (adopt whatever the Live wall is currently
showing), **`Cancel`**, and **`Apply · N cameras`**. **Hard cap 16.**

### 3.7 · The scrubber (bottom, full width, 88 px)

The densest element on the screen. It represents the **view window**, which is
a zoomable subset of the loaded session window.

- **Footage coverage strip** — the top band (11 px when lanes are on, the full
  88 px when they are off). Green blocks where composited footage exists, in
  **two colours**: `ready` and `warming` (the compositor has not rendered that
  stretch yet). Gaps are literal.
- **Per-camera motion lanes** — one thin lane per camera on the wall, in **grid
  reading order** (top-left cell = top lane), zebra-striped, each carrying that
  camera's motion spans as accent bars whose **opacity encodes intensity**.
  Spans closer than ~2 px are merged so a busy lane reads as a band rather than
  a thousand hairlines. The hovered lane highlights.
- **Playhead** — a 2 px white stick with a diamond knob at the top, full height.
- **Hover guide** — a 1 px vertical line plus a **tooltip showing the exact
  wall-clock time under the cursor**, prefixed with the **camera name** when the
  cursor is over a specific lane (`Снаружи 151 · 08:47:58`).
- **In→Out selection** — an accent-tinted region with a border, plus a readout
  chip at the bottom-left: `IN 08:47:58 → OUT 08:49:12`.

**Scrubber interactions:**
- **Click** = seek to that instant.
- **Drag** = mark an In→Out selection (a drag under ~4 px counts as a click).
- **Wheel** = zoom **at the cursor**; the view never escapes the loaded window.
- **Shift + wheel** = pan.
- Any free-form zoom sets a **custom span**, which de-highlights the preset
  chips and reveals `Fit`.

### 3.8 · Export

With an In→Out range marked, **`Export selection`** creates a **dual-archive**
export: one clip **per camera** on the wall **plus** one **combined
synchronized-grid clip**, all tied together by a shared group id so the exports
list renders them as a single wall moment. The grid clip depends on a backend
endpoint that is not shipped yet and **fails honestly** when absent.

### 3.9 · Keyboard map (complete)

| Key | Action |
|---|---|
| `Space` | play / pause |
| `←` / `→` | ∓10 s |
| `Shift ←` / `Shift →` | ∓60 s |
| `0` or `Home` | Fit — drop a custom wheel-zoom back to the full window |
| `Esc` | close whichever picker is open |

That is the entire map. There is no keyboard route to the span presets, the
calendar, marking In/Out, or export.

### 3.10 · States the screen must express honestly

- **Compositing pending** — the backend mosaic endpoint is absent: *"Synchronized
  wall playback — backend compositing pending"* plus *"The server-composited
  grid stream (E1) isn't live yet. Live tiles are unaffected — use Return to
  live."*
- **Composite failed to produce frames** — after a generous budget:
  *"Couldn't composite the synchronized grid for this window — the server didn't
  return frames in time. Try a different time, or Return to live."*
- **No footage in this range** — the window holds nothing at all.
- **Group with no cameras** — *"'X' has no cameras to play back."*
- **Warming** — footage that exists but has not been composited yet, shown as a
  distinct colour on the coverage strip, never as a gap.
- **A cell with no recording at this instant** — *the state we cannot yet
  express*, see §1.2. Specify it.

---

## 4 · The problems, ranked (what the redesign should solve)

1. **A black cell says nothing.** With 3–4 of 16 lit as the normal case, twelve
   cells wearing a name and a ticking clock over pure black is the operator's
   dominant experience of this screen, and it reads as broken software rather
   than as "nothing was recorded here". This is the redesign's central problem.
2. **The date is missing everywhere it matters.** Fourteen cell chips and the
   `Playhead` row show time only; only the transport readout carries the date.
   On windows that always cross midnight, this actively misleads.
3. **Two window models, one vocabulary** (§3.3) — rolling presets and calendar
   days both present as "24 hours".
4. **Fourteen identical timestamps.** They exist to prove synchronisation. One
   authoritative clock plus a quieter per-cell treatment would prove the same
   thing and give the pixels back to the picture.
5. **The scrubber does five jobs in 88 px** — coverage, per-camera motion,
   playhead, hover inspection, and range selection — with no visual hierarchy
   between them. At 14 lanes each lane is ~5 px.
6. **The two best gestures are advertised in one 11 px sentence.** Right-click
   to swap and drag to rearrange are the whole composition model.
7. **Nothing distinguishes "this camera is on the wall" from "this camera
   matters right now".** With 14 lanes of motion data, the wall could lead the
   operator to the cell that is doing something.
8. **The top-bar pills do nothing visible here** (§3.0).
9. **The keyboard map is four keys** on a screen whose whole job is scrubbing
   time.
10. **The window title still says "Live wall"** while you are in playback.

---

## 5 · Non-negotiables

- **One composited stream, server-defined 4×4 geometry, 480×270 cells.** Do not
  design per-cell independent playback, per-cell pause, per-cell zoom-to-fill,
  or per-cell speed. None of it is possible.
- **Random access needs a prewarm round-trip** — a design implying instant
  scrub-anywhere response is writing a cheque the compositor cannot cash.
  Scrub previews must be honest about warming.
- **≤16 cameras.** The cap is the composite's, not a UI choice.
- **Millisecond synchronisation is the product** — whatever replaces the 14
  chips must still let an operator *prove* every cell is the same instant.
- Honesty rules from §1 and every state in §3.10.
- Every existing capability survives: group scoping with counts, edit-cameras,
  right-click swap, drag rearrange, all five span presets, wheel zoom + pan +
  Fit, the motion lanes toggle, calendar day loading, In→Out selection,
  dual-archive export, return to live, and the keyboard map in §3.9.
- Dark theme, §2 tokens, square corners, hairline borders, no shadows.
- EN + RU, 3-form plurals; 1440×900, 1200×900 and 1920×1080.
- QML primitives only (Rectangle / Text / MouseArea / Repeater / ListView — no
  Popup for large panels, no web views).

---

## 6 · Deliverables

Same package as the last four handoffs: a spec `.md` (sizes, tokens, states,
interactions, edge cases — including: 16 cameras with only 2 lit; a wall of 4
cameras; a 24 h window versus a calendar day; a window with a large warming
stretch; 14 motion lanes at 1200 px; an In→Out selection spanning a gap;
compositing-pending; RU at 1200 px), a self-contained HTML prototype with a
tweaks panel (camera count, lit-cell ratio, window span, motion density,
EN/RU, window width), and a README with your variant decision **already made**
plus the implementation prompt for the Watchtower builder, traps included.

**Success test:** an operator watching a 16-camera wall at 03:00 can tell, at a
glance, which cells are showing recorded video and which had nothing to record;
can say what moment they are looking at *including the day*; and can put an
In→Out range around an incident and export the whole site's view of it without
leaving the keyboard-and-mouse flow they are already in.
