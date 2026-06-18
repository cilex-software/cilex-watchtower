# Triage Queue — implementation spec

> **For claude-cli.** This is the authoritative description of the **Triage Queue** screen
> (mode `01`, `view-triage.jsx` / `TriageView`) of the Cilex Watchtower Events area. It describes
> every element: what it is, where it sits, how it looks (exact sizes, colors, type), and what it does.
> Implement to this. Do not invent elements not listed here, and do not restyle shared primitives
> or other screens. All colors are the CSS variables defined in `styles.css` — never hard-code hex
> except where a literal is given below (those literals are already what the tokens resolve to / are
> intentional one-offs).

---

## 0. Purpose & placement

The Triage Queue is the **backlog-clearing inbox**: one operator works unhandled camera events
top-down by priority, watches each event's clip inline, runs a response procedure, and records a
disposition. It is selected by the **`01 · Triage Queue`** button in the top mode switcher (`app.jsx`).

It renders inside the fixed app shell: a **1440 × 900** window → 72px nav rail on the left, then the
main column (64px top bar, ~58px mode bar + rationale, then the screen `.stage`). The Triage screen
fills the `.stage` and **never scrolls as a whole** — only the list and the detail body scroll
internally.

Root element: `<div class="triage">`.

---

## 1. Overall layout

`.triage` is a **2-column CSS grid**, full height of the stage:

```
grid-template-columns: 384px 1fr;   /* fixed list | fluid detail */
min-height: 0;                       /* allow children to scroll */
```

- **Left (384px fixed):** `.tq-list` — the event queue. Right border `1px solid var(--line)`.
- **Right (fluid):** `.tq-detail` — the selected event, or `.tq-empty` if the queue is clear.

Both columns are vertical flex containers (`display:flex; flex-direction:column; min-height:0`).

---

## 2. LEFT COLUMN — the queue (`.tq-list`)

A vertical stack: a fixed **filter tab bar** on top, then a **scrolling list** of event rows.

### 2.1 Filter tabs (`.tq-tabs`)
- Row of 3 text tabs, `padding: 12px 14px 0; gap: 4px;` bottom border `1px solid var(--line)`.
- Tabs (in order), each `<button>` `padding: 8px 12px; font-size:12px; font-weight:600; color:var(--ink-2)`:
  1. **Open queue** — events with status `new | ack | progress`.
  2. **Critical** — events with `priority === 'critical'`.
  3. **All** — every event.
- Each tab carries a **count chip** (`.n`): JetBrains Mono 10px, `color:var(--ink-3)`,
  `background:var(--panel-2)`, `padding:1px 6px`, sitting 7px to the right of the label.
- **Active tab:** label turns `var(--ink)`, a **2px bottom border in `var(--accent)`** (amber)
  via `border-bottom-color`, and its count chip turns `var(--accent)`. Inactive tabs have a
  transparent 2px bottom border (so there is no layout shift). Default active = **Open queue**.

### 2.2 List scroll area (`.tq-scroll`)
- `overflow-y:auto; flex:1`. Holds the rows. **Sort order: priority first** (critical→high→medium→low
  via `SEV_RANK`), then **most-recent first** within a priority.

### 2.3 Event row (`.tq-row`) — a full-width `<button>`
Horizontal flex, `align-items:center; gap:11px; padding:12px 16px;` bottom border
`1px solid var(--line)`. `position:relative`. Left→right it contains 4 things:

1. **Severity dot** (`.sevdot.<priority>`): 8px circle.
   - critical = `var(--bad)` **with a 3px `var(--bad-soft)` halo** (`box-shadow:0 0 0 3px`).
   - high = `var(--accent)`, medium = `var(--ink-2)`, low = `var(--ink-3)`.
2. **Thumbnail** (`.tq-thumb`): **74 × 42px**, `border:1px solid var(--line)`, `overflow:hidden`,
   `position:relative`. Contains:
   - A procedural CCTV still — `<Snapshot ev mini showOsd={false}>`. `mini` strips the burned-in
     overlay labels so the tiny frame stays clean; the AI bounding box still shows.
   - A **clip-length badge** (`.tq-thumb-dur`, only when `durationSec > 0`): bottom-right
     (`bottom:2px; right:2px`), JetBrains Mono **8px**, white text on `rgba(0,0,0,0.7)`,
     `padding:0 3px`. Text = humanized duration (e.g. `38s`, `3m 34s`).
3. **Meta block** (`.tq-meta`): flex column, `gap:4px`, `min-width:0` (so it can ellipsize):
   - **Type pill** (`.tpill.<type>`): height 22px, `border:1px solid`, JetBrains Mono 10px UPPERCASE,
     `gap:6px`, with a 12px type icon. Color-coded: person = amber, vehicle = `--info` blue,
     tamper/line_cross = `--bad` red, others = neutral. Label text e.g. "Person detected".
   - **Camera name** (`.tq-cam`): 13/12px `var(--ink)`, single line, ellipsis on overflow
     (e.g. "Server Room — Rack A").
   - **Time** (`.tq-time`): JetBrains Mono 10px `var(--ink-3)` — `HH:MM:SS · {n}m ago`.
4. **State dot** (`.statetag.<status>` with a single 7px `.d` dot, no text in the row):
   new = `--bad`, ack = `--accent`, progress = `--info`, resolved = `--good`, dismissed = `--ink-3`.

**Row states**
- **Hover:** background `var(--panel)`.
- **Selected** (`.on`): background `var(--panel-2)` **plus a 3px amber bar** down the left edge
  (`.tq-row.on::before`, `var(--accent)`, full row height).
- **Handled** (`.done`, any status ≠ `new`): whole row `opacity:0.5` (de-emphasized but still visible).

**Behavior:** clicking a row sets it as the selected event (`setSel(e.id)`), which drives the
right-hand detail pane. If nothing is explicitly selected, the **first row in the sorted list** is
shown by default.

---

## 3. RIGHT COLUMN — the detail pane (`.tq-detail`)

Vertical flex, 3 stacked regions: **hero player** (fixed) → **scrolling body** → **action bar**
(fixed at the bottom). If there is no current event, render `.tq-empty` instead: a centered
`var(--ink-3)` line "Queue clear — no open events."

### 3.1 Hero — inline player (`.tq-hero` → `<Player>`)
Black backdrop (`#000`). This is the headline change vs. a static snapshot: **the event clip plays
in place**, no "open playback" step.

**3.1.1 Video surface (`.pl-surface`)** — `position:relative`, **21:9** aspect CCTV frame
(`<Snapshot ev playing={playing}>`). The Snapshot's own animated playhead is hidden here
(`.pl-surface .snap .playhead{display:none}`) — the transport below owns the scrub.
- **Playback state chip** (`.pl-state`): top-right (`top:8px; right:10px`), JetBrains Mono 9px,
  `background:rgba(0,0,0,0.55); padding:2px 7px`, `color:rgba(255,255,255,0.7)`. Shows
  `▶ PLAYBACK` while playing / `❚❚ PLAYBACK` while paused. When the playhead is **inside the event
  window** it switches to **`EVENT`** and turns amber (`.hot` → `var(--accent)`).

**3.1.2 Transport bar (`.pl-transport`)** — horizontal flex, `gap:9px; padding:9px 12px;`
`background:var(--panel)`, top border `1px solid var(--line)`. Left→right:
- **Play/Pause** (`.pl-btn`, **34×34**, `border:1px solid var(--line-2)`, `background:var(--panel-2)`;
  hover → border `--ink-3`, bg `--panel-3`). Icon: two 4×14 bars when playing, a play triangle when
  paused. Toggles playback.
- **−10** and **+10** (`.pl-btn.sm`, width 38): JetBrains Mono 10px `var(--ink-2)`. Jump the playhead
  back / forward 10 seconds (clamped to clip bounds).
- **Time readout** (`.pl-time`): JetBrains Mono 11px `var(--ink)`, format `MM:SS / MM:SS`; the slash
  `<i>` is `var(--ink-3)`. Left value = current head position, right = total timeline length.
- **Scrubber** (`.pl-scrub`, `flex:1; height:30px; cursor:pointer`), a layered track:
  - `.pl-track`: full-width 5px rail, `var(--panel-3)`.
  - `.pl-event`: the **event window** segment, `var(--accent-dim)` (dim amber), positioned/sized to
    the in/out points (pre-roll … pre-roll+clip).
  - `.pl-fill`: progress fill from the left, **solid `var(--accent)`**, width = current progress.
  - `.pl-head`: 3×16px **`var(--ink)`** playhead handle, centered on the current position.
  - Clicking anywhere on the scrubber seeks to that position.
- **Speed** (`.pl-speed`, 38×34, JetBrains Mono 11px `var(--ink-2)`): cycles **1× → 2× → 4× → 1×**.

**Timeline model:** total = 6s pre-roll + clip + 6s post-roll, where `clip = max(durationSec, 14)`.
Playback **auto-starts** and begins at the event in-point (after the pre-roll). It loops when it
reaches the end. Selecting a different event resets the player (`key={cur.id}` remounts it).

**3.1.3 Tool row (`.tq-toolrow`)** — directly under the transport: horizontal flex, `gap:8px;`
`padding:9px 14px;` `background:var(--panel)`, top border `1px solid var(--line)`. Buttons are
`.btn.sm.ghost` (transparent, `var(--ink-2)`, hover fills `var(--panel)`):
- **Export clip** (left) — download/export icon. Exports the event clip (evidence).
- **Assign** (left) — assign-to-operator icon.
- *(spacer)*
- **Bookmark** (right) — outline bookmark → toggles to a **filled amber icon + "Saved"** and the
  button gains `.is-on` (amber) when `cur.bookmarked`. Calls `act.bookmark(cur.id)`.

### 3.2 Body (`.tq-body`) — scrolls (`overflow-y:auto; padding:18px 22px`)

**3.2.1 Headline (`.tq-headline`)** — space-between row:
- **Left:** title `.tq-ttl` (20px, weight 600) = the event type label (e.g. "Person detected").
  If the event is in a restricted zone, append a **`RESTRICTED ZONE`** tag (`.restricted`:
  JetBrains Mono 9px, `color:var(--bad)`, `border:1px solid var(--bad-dim)`, `padding:2px 6px`).
  Below it, subtitle `.tq-subttl` (13px `var(--ink-2)`) = the event note, or `—`.
- **Right:** severity label `.sev.<priority>` — JetBrains Mono 10px UPPERCASE with a 3×12px color
  bar; colors match the row dots (critical red / high amber / medium / low).

**3.2.2 Facts grid (`.tq-facts`)** — a **2-column** grid of key/value cells, 1px gridlines
(`gap:1px; background:var(--line); border:1px solid var(--line)`), `margin:18px 0`. Each cell
(`> div`) is `background:var(--bg); padding:10px 13px`, flex column:
- key `.k`: JetBrains Mono 10px UPPERCASE `var(--ink-3)`.
- value `.v`: 13px `var(--ink)` (add `.mono` where it's an ID/number).
- The six cells, in order: **Camera** (name), **Device** (mono id), **Zone**, **Time**
  (mono `HH:MM:SS · Wkd DD Mon`), **Clip length** (mono duration or `—`), **AI confidence**
  (mono `NN%` or `n/a`).

**3.2.3 Response procedure (`.tq-sop`)** — `margin-bottom:16px`:
- Section header `.tq-sec-h`: JetBrains Mono 10px UPPERCASE `var(--ink-3)`, text "Response procedure".
- A **per-event-type SOP checklist** (source `SOPS[type]`, fallback `SOPS._default`). Each item is a
  `<label class="sop-item">`: flex, `gap:10px; padding:7px 0; font-size:13px; color:var(--ink-2)`.
  - Checkbox `.cbx`: **18×18**, `border:1px solid var(--line-2)`. When checked it fills
    `var(--good)` (olive) with a white check glyph, and the label text turns `var(--ink-3)` with a
    **strike-through**. Toggling is local (operator ticking off steps); it does not change event state.
- SOP content is type-specific (person, vehicle, line_cross, tamper, loiter, offline, motion) —
  e.g. for **person**: "Watch playback at event time" → "Confirm person vs. authorized staff (check
  badge log)" → "If unauthorized after-hours → dispatch / call keyholder" → "Record disposition + notes".

**3.2.4 Disposition note (`.tq-notebox`)** — a single full-width text input (`height:40px;`
`background:var(--panel); border:1px solid var(--line-2); padding:0 12px`), focus border
`var(--accent)`. Placeholder: "Add disposition note (what happened, who responded)…". The typed note
is passed into the disposition actions below.

### 3.3 Action bar (`.tq-actions`) — fixed footer
Top border `1px solid var(--line)`, `padding:12px 18px`, `background:var(--panel)`, flex `gap:8px`.
Left group = disposition buttons; right (after a spacer) = acknowledge / state.

- **Authorized** (`.btn.good`, olive): records disposition `authorized` → resolves the event.
- **False alarm** (`.btn`, neutral): records `false_alarm` → resolves the event.
- **Dispatch guard** (`.btn.danger`, red-tinted): records `dispatched` → moves event to `progress`.
- *(spacer)*
- If status is **`new`** → **Acknowledge** (`.btn.pri`, solid amber) with a trailing **`E`** `kbd`
  hint. Calls `act.ack(cur.id)` → status `ack`.
- If status is **not new** → a `.statetag.<status>` showing the current status and, if set,
  `· {disposition label}` (e.g. "resolved · False alarm").

All disposition buttons pass the current note text. Actions mutate the **shared event state** in
`app.jsx`, so the top-bar OPEN / CRITICAL / CLEARED counts and the list row's state dot update
immediately, and the row dims (`.done`).

---

## 4. Data, state & behavior summary

- **Selection** is owned by `app.jsx` (`sel` / `setSel`) so deep-links and cross-view jumps work;
  Triage falls back to the first sorted row when `sel` is empty.
- **Local UI state** in `TriageView`: `filter` (tab), `note` (disposition text), `done` (SOP ticks).
  `note` and `done` **reset whenever the selected event changes** (`useEffect` on `sel`).
- **Player state** is internal to `<Player>` and remounts per event (`key={cur.id}`): `prog`
  (0–1 position), `playing`, `speed`.
- **Actions** (`act`, from `app.jsx`): `ack(id)`, `bookmark(id)` (toggle), `dispose(id, dispo, note)`.
  `dispose` → `progress` for `dispatched`/`verified`, otherwise `resolved`, and stamps the disposition.

### Keyboard (intended)
`E` acknowledges the current event (hint shown on the button). `↑/↓` to move selection and
`Space` to play/pause are natural extensions for the QML build (not yet wired in the prototype).

---

## 5. Token reference (what the variables resolve to)

| Token | Value | Used for |
|-------|-------|----------|
| `--bg` | `#1a1816` | screen background, fact cells |
| `--panel` | `#221f1c` | transport, tool row, action bar, inputs |
| `--panel-2` | `#2a2722` | selected row, player buttons, count chips |
| `--panel-3` | `#322e28` | scrub track, button hover |
| `--line` | `#34302a` | hairline borders / gridlines |
| `--line-2` | `#443f37` | control borders |
| `--ink` | `#f0ece4` | primary text, playhead |
| `--ink-2` | `#a89f90` | secondary text |
| `--ink-3` | `#6e6657` | muted labels, low severity |
| `--accent` | `#e8a13a` | amber: selection, active tab, primary action, progress fill |
| `--accent-dim` | `#5a3f15` | event-window segment on scrubber |
| `--bad` | `#d96649` | critical/new, dispatch, restricted |
| `--good` | `#8eb96b` | authorized, checked SOP, resolved |
| `--info` | `#6f9bc4` | in-progress, vehicle pill |

Type: **Space Grotesk** for UI text; **JetBrains Mono** (`.mono`) for IDs, times, codes, counts,
durations, and all-caps labels.

---

## 6. Acceptance checklist

- [ ] 2-column grid, **384px** list + fluid detail; only list and body scroll.
- [ ] Three filter tabs with live counts; **Open queue** default; active tab underlined amber.
- [ ] Rows sorted **priority → recency**; show sev dot, 74×42 thumbnail with duration badge,
      type pill, camera, mono time, and a state dot. Hover/selected/handled states correct.
- [ ] Detail hero **plays the clip inline** (21:9) with play/pause, −10/+10, `MM:SS / MM:SS`,
      seekable scrubber showing the **event window** + amber progress + ink playhead, and a
      1×/2×/4× speed cycle. **No "open playback" button anywhere.**
- [ ] `EVENT`/`PLAYBACK` state chip flips and turns amber inside the event window.
- [ ] Tool row: Export clip, Assign, Bookmark (toggles to filled "Saved").
- [ ] Headline (type + optional RESTRICTED ZONE + note + severity), 2-col facts grid (6 cells),
      type-specific SOP checklist (tickable, strike-through), disposition note input.
- [ ] Footer: Authorized / False alarm / Dispatch guard + Acknowledge (`E`); after handling, shows
      the resulting status + disposition. Counts and row dimming update via shared state.
