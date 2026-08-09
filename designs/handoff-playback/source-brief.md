# Cilex Watchtower — "Playback" screen: full UI specification + redesign brief

**Audience:** Claude Design (no codebase access — this document is the complete
source of truth; anything not written here does not exist for you).
**Date:** 2026-08-09.
**Mandate:** redesign Playback in the density language you built and we shipped
— Triage "Lanes", Verify "Strips" (queued), Groups "Wall" (shipped 2026-08-09).
This is the biggest and oldest screen in the product and the last one in the
pre-density idiom.

## 1 · Product context

Native Qt/QML desktop VMS for security guards; dark theme only; 1440×900
default, often 1200×900; mouse-first; EN + RU (RU ~30% longer, 3-form plurals).
Fleet: 39 cameras (→80+), spoken about by IP octet (".160"). Honesty rules are
product law: never invent data, never render unknown as healthy, every empty
state names its filter, no silent no-op controls, nothing stamped before the
server answers.

**What Playback is for:** one camera, its recorded past. A guard arrives here
from a triage event ("show me that moment"), from a live tile ("what happened
ten minutes ago"), or from the calendar ("what happened Thursday"). The three
jobs are *find the moment*, *examine it frame by frame*, and *take evidence
out* (snapshot or exported clip).

## 2 · Design tokens (exact)

bg `#1a1816` · panel `#221f1c` · panel2 `#2a2722` · panel3 `#322e28` ·
line `#34302a` · line2 `#443f37` · ink `#f0ece4` · ink2 `#a89f90` ·
ink3 `#6e6657` · accent `#e8a13a` · accentSoft = accent @8% · accentDim
`#5a3f15` · bad `#d96649` · badSoft @10% · good `#8eb96b` · info `#6f9bc4` ·
violet `#9a7bd0` (bookmarks). Fonts: **Space Grotesk** (labels), **JetBrains
Mono** (all numbers, times, octets, ALL-CAPS micro-labels 8–11px,
letter-spacing 1.2–1.6). Square corners, hairline borders, no shadows.

## 3 · Screen anatomy (current, code-truth)

Three regions below the shared chrome: **video stage + transport** (left,
fluid), **info rail** (right, fixed), **timeline** (bottom, full width).

### 3.0 · Shared chrome above (do not redesign, but know it)
52px top bar: brand block · global search (`Ctrl K`) · **three fleet-status
pills — `ONLINE 39` (good) · `OFFLINE 0` (bad) · `NOT REC 0` (accent)** — these
are *fleet-wide quick filters*: clicking one jumps to the Live wall filtered to
that status. They are **not** playback controls and are counted from the whole
roster, not this camera. Then `Check in` (shift check-in), clock + UTC offset,
alert bell, avatar. Below it a 30px tab strip when camera tabs are open.

### 3.1 · Video stage

Fills the space left by the rail and the timeline. Letterboxed black; the frame
is drawn at its own aspect (cameras are 16:9 HEVC/H.264, 1920×1080 typical).

**Top-left overlay:** a `‹` back chevron (leaves playback, returns to the
screen that opened it) · a `PLAYBACK` chip (mono, amber-dot) that reads
`LIVE` when the operator has returned to live · the camera's full name with IP.
**Top-right overlay:** the burned-in **date + time of the displayed frame** to
millisecond precision (`Sun 9 Aug 2026 · 21:38:32.736`) — the evidentiary
timestamp, and the single most-read element on the screen.

### 3.2 · Transport bar (bottom-left of the stage, over the video)

Left group, in order, all icon cells with tooltips:

| control | tooltip | behaviour |
|---|---|---|
| `‹` | **Back 10s** | playhead −10 s |
| `|‹` | **Step back one frame** | pauses first, then steps exactly one frame back. Backward stepping is expensive (inter-frame compression: the player must decode forward from the previous keyframe), so this path is served by a frame cache — see §3.6 |
| `▶ / ❚❚` | **Play / pause** | space bar also |
| `›|` | **Step forward one frame** | one frame forward from the paused position |
| `›` | **Forward 10s** | playhead +10 s |
| `1×` | (speed) | cycles the **speed ladder: ¼× · ½× · 1× · 2× · 4× · 10× · 20× · 50× · 100× · 200×**. ¼/½ are slow-motion review; up to 10× the decoder keeps every frame; **above 10× the client switches to "scan"** — the player keeps rendering while the playhead is jumped forward in steps, because this hardware cannot decode HEVC-1440p faster than ~14× realtime. The label shows `¼×`, `½×`, `2×`… |

Right group:

| control | tooltip | behaviour |
|---|---|---|
| 📷 | **Snapshot** | saves the current frame as PNG to `Pictures/Watchtower` |
| 📷+ | **Snapshot with timestamp** | same, with the frame time + camera name burned into the image — the evidence variant |
| ⛶ | **Fullscreen** | video fills the window; chrome hides |
| `● Return to Live` | — | leaves the archive and shows the live stream (accent-outlined, the only labelled button in the bar) |

Also present but **not** in the screenshot's visible state: an **Export Clip**
action opening an export drawer (range, quality, destination, purpose), and a
`FRAME-BY-FRAME` affordance.

### 3.3 · Info rail (right, fixed width)

Header: camera name + IP; the group name beneath (`Лифты`); two badges —
`LIVE · 7d` (live state + how long it has held it) and `ARMED · 12m` (recording
mode + age of the last motion event).

**`STATUS`** — a key/value block, mono values, right-aligned:
- `Playhead` — the time the playhead sits at.
- `Last motion` — timestamp of the newest motion event, rendered in **accent
  with a `›` affordance: clicking it jumps the playhead there.**
- `Quality` — resolution + codec of the loaded stream (`1920x1080 (HEVC)`).
- `Coverage` — how many recorded segments the loaded window contains
  (`231 segments`). This is the honesty readout: it says how much real footage
  exists behind the scrubber, and it can be 0.
- `Window` — the loaded span (`1 hour`), i.e. the zoom level below.

**`FOOTAGE`** — a **month calendar** for this camera:
- Header line: the retention range and how much of it has footage
  (`6 Jul – 9 Aug 2026 · last 35d`, and `4 days w/ footage`).
- A Mon–Sun grid. **A day with recorded footage carries a dot; days without are
  dimmed and inert.** Today is ringed. The selected day is filled amber.
  Clicking a day loads that whole day (the zoom jumps to 24H).
- Legend: `• has footage` / `▫ today`.
- This grid is fed by a per-camera coverage query, so it is truthful about a
  fleet where most days have nothing — the dots are the answer to "is it even
  worth scrubbing here?"

**`EVENTS`** — for the loaded window:
- Two **type filter chips** (`Motion`, `Motion detected`) — one per event type
  present, colour-dotted, toggling that type in the list and on the scrubber's
  motion lane.
- A scrolling list of events, newest first: coloured dot · type label ·
  right-aligned time (mono). Clicking an event **seeks the playhead to it**.
- Empty state: `No events in this range.`

### 3.4 · Timeline (bottom, full width) — the heart of the screen

A left label block (`PLAYHEAD · Sun 21:38:32`) then the scrubber itself.

**Zoom / window buttons (right of the timeline header):** `EVENTS` toggle
(shows/hides the motion lane) then **`15M` · `1H` · `6H` · `12H` · `24H`** —
the span of time the scrubber represents. The active one is amber-filled. This
is *the* navigation control: 15M for frame work, 24H for "when did anything
happen today". Changing it reloads the session for that span.

**Two stacked lanes, sharing one horizontal time axis with a tick ruler
(labelled every 5 min at 1H):**
- **`FOOTAGE`** (green blocks) — where recorded video actually exists. Gaps are
  literal gaps: a motion-recorded fleet produces a sparse comb, and the design
  must never imply continuity that is not there.
- **`MOTION`** (amber bars) — motion events/episodes, aligned to the same axis
  under the footage they belong to.

**Playhead:** a vertical line with a handle at the top, dragged to scrub.
Clicking anywhere on the axis seeks there. Seeking into a gap is honest — the
player states there is no footage rather than hanging.

### 3.5 · States the screen must express honestly

- **Playback switched off** (an operator setting, not a fault):
  `Playback is switched off — recorded playback and export are paused.`
- **Recording switched off**: `Recording is switched off — no new footage…`
- **No footage at the requested moment**: `No footage recorded around this
  moment.` with the transport showing `00:00 / 00:00`.
- **Session failure / backend unreachable**: an honest error with tap-to-retry.
- **Unstable build warning** (dev builds only).
- `Coverage 0 segments` — the window genuinely holds nothing.

### 3.6 · Engine constraints a redesign must respect

- **Frame-by-frame is asymmetric.** Forward stepping is cheap; backward
  stepping requires decoding from the preceding keyframe, so it is served from
  a small frame cache and can briefly lag. Any redesign that implies symmetric
  cost (e.g. a jog wheel scrubbing backwards frame-perfectly at speed) is
  writing a cheque the decoder cannot cash.
- **Seeking is expensive.** Every seek beyond a small in-buffer nudge may
  re-open a server session (measured: p50 198 ms, p90 986 ms, worst 6.4 s on
  short windows). A design that seeks on every pointer move during a drag will
  melt; scrub previews must be throttled or served from thumbnails.
- **Above 10× is scan, not playback** (§3.2) — frames are skipped by design.
- **Sessions are per-camera and per-window**; changing the zoom or the day is a
  new session, not a client-side crop.

## 4 · The problems, ranked (what the redesign should solve)

1. **Chrome-vs-video balance.** The rail is a fixed column and the timeline a
   fixed band, so the video — the actual subject — gets what is left. Neither
   is resizable, and at 1200×900 the picture is small while the rail still
   shows six key/value rows.
2. **Two competing navigators.** The calendar (days) and the zoom buttons
   (spans) both answer "when", in different idioms, in different corners, with
   no visible relationship. A guard asked "yesterday 3pm" must use both.
3. **The transport is 8 icon cells with no grouping** — destructive-adjacent
   actions (snapshot, export) sit beside frame stepping with equal weight, and
   `Return to Live` is the only labelled control.
4. **Speed cycling through ten values by clicking one button** is slow and
   unguessable; there is no indication that >10× behaves differently (scan).
5. **The events list and the motion lane are the same data twice**, unlinked:
   selecting in one does not highlight the other.
6. **Density**: the rail's `STATUS` block spends five rows on values that are
   mostly static, while `Coverage 231 segments` — the one number that predicts
   whether scrubbing is worth it — reads like trivia.
7. **No keyboard story** beyond space/arrows; a frame-accurate review tool
   should have one (`,`/`.` stepping, `J K L` shuttle are the industry idiom).
8. **Export is hidden** behind a drawer most operators never open, despite
   being one of the three jobs this screen exists for.

## 5 · Non-negotiables

Honesty rules from §1 and the states in §3.5; dark theme, §2 tokens, square
corners, hairline borders, no shadows; EN + RU with 3-form plurals; QML
primitives only (Rectangle/Text/MouseArea/ListView — no Popup for large
panels, no web views); works at 1440×900 and 1200×900; the millisecond
timestamp and the FOOTAGE/MOTION lane distinction must survive any redesign —
they are the evidentiary core.

## 6 · Deliverables

Same package as the last three handoffs: spec .md (sizes, tokens, states,
interactions, edge cases — including: no footage at all; one 3-second clip;
a 24H window with 200 events; playback switched off; RU at 1200px; a camera
that is offline right now but has an archive), a self-contained HTML prototype
with a tweaks panel (density, EN/RU, window width, footage density, event
count), and a README with your variant decision made plus the implementation
prompt for the Watchtower builder, traps included.

Success test: a guard given "check the lift at about quarter past ten last
Thursday" gets there in under fifteen seconds, steps through the moment frame
by frame, and leaves with a timestamped snapshot — without once wondering
which of two navigators to use.
