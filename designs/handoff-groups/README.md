# Groups — density redesign · implementation handoff

**Decision: build "Wall".** Big 16:9 tiles, **4 or 6 per row, butting edge to edge with no gutter, no card inset and no border between frames** — and every piece of chrome moved onto the frame as an overlay.

| file | what it is |
|---|---|
| `2026-08-07-groups-redesign-spec.md` | **the spec to build** — anatomy, sizes, states, interactions, fetch discipline, edge cases |
| `groups-redesign-prototype.html` | **the reference build** — open in a browser; every behaviour is live |
| `tweaks-panel.jsx` | required by the prototype |
| `source-brief.md` | the original brief |
| `reference-triage-lanes-spec.md` | the SHIPPED Triage language this continues. Reference only. |
| `reference-verify-strips-spec.md` | the queued Verify redesign — same language, and the source of the in-place-arming and computed-fit patterns. Reference only. |

Open the prototype before writing code. Tweaks: **per row** (4 / 6), **thumbnails** (live / off), **role** (admin / operator / **viewer** — read-only is designed, not assumed), **cameras** (39 / 59 / 80 — 59 and 80 add the newly-provisioned unnamed-and-ungrouped batch), EN/RU, 1440/1200.

**Why Wall.** The constraint drives the design: *if there are no gaps between videos, the metadata cannot live in a footer — because the footer would **be** the gap.* So the octet, the name, the status and the group chip all move **onto** the picture as overlays, and every state (fault, warn, selected) becomes an **inset ring** so it never opens a seam. Deleting the gutter, the 5px card inset, the 1px border and the 64px footer is what buys the density: **41 cameras on screen at 6-per-row against today's ~15 (2.7×)**, with tiles still 184px wide. 4-per-row gives 276px tiles — larger than anything on the screen today — as the deliberate *identify* gear (1.2×, does not clear the density bar, and is not meant to). Filing 14 cameras becomes one drag or one click instead of fourteen popups.

**The left pane.** At three groups the old pane spent 102px of its 788 and left ~600px of black. The chosen fix is the **attention console**: compact group rows on top, then a `NEEDS ATTENTION` summary (`13 not recording` · `23 still unnamed` · `0 ungrouped` · `2 offline` · `2 unknown`, each one click from being that filter), a stacked fleet bar, and a **`WORK QUEUE`** of the actual cameras behind those counts — worst first, click to open. The queue is the child that grows into the remainder, and it is long exactly when the fleet has problems. Two alternatives are in the prototype and documented in §2.1b: `cards` (groups preview their own cameras — costs 78 extra thumbnail fetches) and `bar` (delete the pane, tiles go 277 → 343px). Neither is the build target.

**Opening a camera.** Four behaviours were prototyped (docked rail, expand-in-place, pane takeover, modal lightbox); **the modal lightbox is the chosen one** and the only one still in the file. The wall blurs behind a scrim and one camera is presented over it, so opening never resizes or reflows the wall — the defect in today's behaviour is that a click loads the live stream *into* the Groups tab and destroys the screen the operator was in. Navigation is the design's second idea: `←`/`→` and two on-image **preview plates** that show the adjacent camera's thumbnail, octet, name and fault bar, because at the moment of clicking the operator's question is "which camera am I about to see" and a bare chevron cannot answer it.

---

## The implementation prompt

Paste the block below into the Claude Code console from the repo root, with this folder dropped in at `designs/`.

---

Build the **Groups screen density redesign, "Wall"** into the Qt6/QML Watchtower client.

**Source of truth**, in this order:
1. `designs/handoff-groups/2026-08-07-groups-redesign-spec.md` — the spec. Every size, token, state and edge case is in here.
2. `designs/handoff-groups/groups-redesign-prototype.html` — the working reference. When the spec is ambiguous, match the prototype.
3. `designs/handoff-groups/source-brief.md` — product context, exact tokens, current-state anatomy, permissions, badge semantics.
4. `designs/handoff-groups/reference-triage-lanes-spec.md` and `reference-verify-strips-spec.md` — the shipped/queued density language this continues. Reuse the computed-fit math, the in-place arming pattern and the inset-ring state vocabulary. Do not rebuild those screens.

The prototype is React/HTML **as a drawing, not as an architecture**. Translate to native QML: `Rectangle` + `Text` + `MouseArea` + `ListView` / `GridView`. No `Popup` for the group list or the magnifier, no OS-native widgets, no web views. Lift exact px and hex from the spec — do not re-derive spacing.

Do not touch the shared chrome above the screen (52px top bar → 30px tab strip). Groups still has no sub-nav.

### What changes

The right pane's 250px card grid becomes a **two-column roster of 34px camera rows**. The vendor model name appears only when the camera has no operator-chosen name (with an `UNNAMED` chip); the thumbnail shrinks to a 44×27 identity chip with a hover magnifier. The left pane narrows 320 → **264px** and every group row gains a **34×3px health bar** plus an `EMPTY` marker, with a conditional **`Ungrouped N`** row pinned above the group list. The 58px header becomes **34px**; the permanent 30px hint strip is **deleted** and replaced by a **30px filter bar** (camera search + `All` / `Unnamed` / `Faults` facets + a permanent `N not recording` readout). Multi-select arrives with a sticky **selection bar** and **drag-to-group**. `+ New group` takes a name before creating; `Delete group` arms in place and states its blast radius.

Target: **42 cameras on screen at 1440×900** in `roster` against today's ~15.

### Build order

1. **Left pane** — 264px, group search, `All cameras`, conditional `Ungrouped N`, divider, group rows with health bars and `EMPTY` markers. Then the **attention console** below it (spec §2.1b B): `NEEDS ATTENTION` summary rows → fleet bar → `WORK QUEUE`. The console is the chosen layout; `cards` and `bar` remain in the prototype as documented alternatives — **do not build them**.
2. **Right header 34px** + **filter bar 30px** (search, three facets counted against scope, `N not recording`, `N of M`).
3. **Camera tile** — gapless 16:9 grid, `gap: 0`, tile width `floor(paneWidth / cols)`. Overlays: bottom scrim (octet + name/model fallback + `UNNAMED` chip), top row (checkbox + status marker + online dot), hover row (full badge + group chip). Inset rings for fault / warn / selected.
4. **Badge** — all states from §2.5, with only the two fault families boxed.
5. **Selection** — click, shift-click range, ⌘-click, ⌘A, checkbox.
6. **Assignment** — sticky selection bar (`MOVE TO` + one cell per group) and drag-onto-group-row.
7. **Safe destructive actions** — inline `+ New group` field, in-place armed `Delete group` with camera count, double-click rename with `SAVED` flash.
8. **Thumbnail fetch discipline** (§3) — viewport-only, reading-order, 4 concurrent, cancel on scroll-out and filter change, never for offline cameras.
9. **Opening a camera** (§2.7 — the modal lightbox and its preview-plate navigation), **read-only role** (§2.8), **4-per-row density** (§0).

### Traps — every one of these was hit and fixed while prototyping. Do not rediscover them.

- **The range-select anchor must be an interaction pointer, not render state.** Stored as reactive state, two clicks landing in the same event tick read a stale anchor and the range silently collapses to a single row — it looks like shift-click "sometimes doesn't work". Keep it in a plain field/ref and write it synchronously.
- **"No gaps" means the metadata cannot live in a footer.** A footer strip under each tile *is* a gap, and it reintroduces the repeated-text band the brief ranked #1. Everything goes on the frame: bottom scrim, top row, hover row. If you find yourself adding a text band under a tile, the design has been misread.
- **Every tile state must be an INSET ring, never a border or an outline.** A 2px border adds 4px to the box and opens visible seams across the wall the moment anything is selected or faulty; `outline` misaligns at the pane edges. Inset only.
- **Never size tiles with `floor(paneWidth / cols)`.** It discards `paneWidth % cols` pixels and leaves a lighter strip of page background down the right edge — a visible seam on a wall whose premise is that there are none, and the one place a rounding error shows. Let the layout engine distribute the remainder (`1fr` columns / `Layout.fillWidth`, or hand the first `paneWidth % cols` tiles one extra pixel). Row height is one shared `round(paneWidth / cols × 9/16)`.
- **The thumbnail queue order is row-major, derived from the layout, never from the model index.** A queue ordered by index jumps around the visible wall and feels broken at identical throughput.
- **Style the scroll gutter.** The pane's scrollbar track sits between the wall and the pane edge; left at its default lighter colour it reads as exactly the vertical seam this design exists to remove. Give it the tile colour.
- **Derive EVERY fault count from one shared predicate — this screen answers one question and must not give three answers.** The data has two axes: recording (`notrec`/`stalled`) and detector (`notready`). The `N not recording` readout and the top-bar pill count the **recording** axis only; the red ring and the `Faults` facet share a **single** `FAULT = REC_BROKEN or DET_BROKEN` predicate. Writing an ad-hoc filter at any call site is how the facet ends up saying 21 while only 13 tiles wear the ring.
- **Never assert `REC ?` (unknown) as a fault.** Counting unknown as broken is the exact mirror of the brief's "never render unknown as healthy" — both are lies. Warn ring, own marker, own small `N unknown` readout.
- **Marker precedence puts recording before detector.** A camera that is both not-recording and detector-faulted must still display `NOT REC`, or the wall's red tiles undercount the header's number. Carry the compound state in the hover badge (`NOT RECORDING + NOT READY`), not by dropping half of it.
- **A healthy tile gets no status marker.** Marking every tile makes the faults invisible; only exceptions get ink.
- **Audit localization by extraction, not by eye.** Untranslated strings hid three times here — the nav rail, the tile status marker, the `EMPTY` group marker — because each lives inside a component rather than a header, and some only render in states you have to construct (`EMPTY` needs a group with zero cameras). Extract every text literal and every `title`/`placeholder` in the screen and diff against the string table. Allow-list: brand names, key names, vendor model strings.
- **The status marker is the most prominent new string in the design — localize it.** It is the only status text visible without hovering, and it is easy to leave hardcoded because it lives inside the tile component rather than in a header. RU short forms must stay short enough for the 7.5px pill at a 184px tile: `ВЫКЛ` · `НЕ ГОТОВА` · `НЕ ПИШЕТ` · `СБОЙ` · `ЗАПИСЬ ?` · `НЕТ ДВИЖ.` · `ТИХО` · `ПРОБЕЛ`.
- **The column count is a COMPUTED value, not a converging loop.** Read the pane's measured width once, divide by the minimum row width, write the answer in one assignment; recompute on `onWidthChanged`. Reset-then-decrement needs a repaint per step and silently no-ops when the reset writes the value it already holds. (Same trap as the Triage group strip and the Verify strip.)
- **A shared visual primitive must not be styled through an ancestor.** The camera-frame renderer is used in three hosts (tile, modal frame, nav plate); its rules were scoped `.tile .im`, so in the modal and the plates the element computed `display:inline; position:static` and measured **0×0** — every frame a flat black box, with the gradient set correctly and simply no box to paint into. Style the primitive on its own class and let each host provide only `position:relative` + `overflow:hidden`. Applies equally to the placeholder.
- **Deleting a component does not delete its CSS.** A grep for the component's identifiers came back clean while its entire rule block sat orphaned in the stylesheet. Sweep the stylesheet by class name too.
- **Watch for style-class collisions between the shared chrome and the new screen.** A generic utility name reused for the group row silently restyled the top bar's search cell (it inherited a 34px height in a 52px bar). Namespace anything new.
- **Never show the vendor model name and the IP and the operator name at once.** That repetition is the density bug the brief ranked #1. One identity line: operator name if it exists, otherwise the model. The octet is always there separately; the full IP belongs in the magnifier caption and the search index, not the row.
- **Rename must be double-click, never single.** It is an immediate server write with no undo that also relabels Live, Events and the map. Single click is selection. Escape cancels, empty is refused silently, and a `SAVED` flash is the receipt.
- **Destructive confirmation must state the blast radius, in place.** `Delete "Inside"? 22 cameras become ungrouped.` — not a modal, not a generic "Are you sure?". Arm the same cell the click landed on; Escape cancels.
- **`+ New group` must not create anything until a name is committed.** Creating first and renaming after is how the current build ends up with groups literally named "New group", and two of them.
- **Read-only roles get controls ABSENT, not disabled** — and nothing may shift as a result: the tile checkbox is an overlay, so removing it just leaves clean video. Add one 22px strip that says why. Do not grey anything out.
- **The `Ungrouped` row renders only when the count is non-zero**, and it is not a group: dropping a selection on `All cameras` is a no-op, and `Ungrouped` is a valid drop target that clears the group.
- **Never request a thumbnail for an offline camera** — there is no frame. Render a flat `#191817` field plus the red dot. And cancel in-flight requests on scroll-out AND on filter change; a queue full of filtered-out rows starves the visible ones.
- **There is no hover-triggered panel in this design — do not add one.** A surface that appears because the pointer paused covers the wall it is explaining, fires unasked, and cannot hold an action. Opening a camera is an explicit click (spec §2.7).
- **Separate SELECTING from OPENING.** Plain click selects and opens; ⌘-click and shift-click select without opening. If a modified click opens, assembling a batch to file keeps tearing the operator out of the batch.
- **Read-only roles must still be able to OPEN a camera, and to arrow between cameras.** Both were gated behind the edit-permission check at different points in the prototype; either one leaves viewers and engineers with a screen they cannot inspect — which is their entire job, and is non-destructive. Gate the affordances *inside* the opened surface (rename, group caret, checkbox), never the opening or the navigation.
- **An open camera must not outlive its filter.** Resolve the open camera against the FILTERED list, not the full fleet, and close it when scope, facet or search changes.
- **Modal Prev/Next index the FILTERED list, never the full fleet, and never wrap.** Indexing the fleet walks the operator into cameras their filter excludes; wrapping teleports them from camera 39 to camera 1 and loses their place. Show the position (`7 / 39`), and at the ends keep the plate's footprint with a `START OF LIST` / `END OF LIST` label — a control that vanishes relocates its neighbour.
- **Size the modal from the window, not from a pixel constant.** `min(paneWidth − 140, 760)` caps the picture at 760px forever: on a 1440 window that is half the available width spent on scrim. Use fractions (0.84 width, 0.86 height less chrome) so a bigger window buys a bigger picture.
- **The two nav plates are ONE control layer sharing one visibility state — never two independent hover targets.** Gated separately, the operator can never see both at once and will not learn the second exists. Show on open, on every camera change, and on any pointer movement over the frame; hide after 2.6s of stillness and immediately on leaving the frame. Stillness is the signal that the operator is looking rather than navigating — pointer *position* is not, which is why an edge-zone gate is the wrong instrument.
- **A flexible container with only fixed children does not fill space — it relocates the void.** The attention panel took `flex: 1` while every child stayed `flex: none`, so 43% of the pane became trailing whitespace inside the panel instead of below it, in a marginally lighter colour. Exactly one child must be allowed to grow (here the work queue) and it must be the one whose content genuinely scales with the fleet.
- **Keep an inventory of transient controls (spec §2.7b) and justify each.** This design has exactly three. The modal's plates are chrome and share a layer; the tile checkbox and tile hover row are per-object and must not — revealing them across 41 tiles repaints the wall with text nobody asked for. Any fourth transient control added later needs the same justification or it becomes undiscoverable UI by accident.
- **No chevrons on the nav plates.** Direction is already carried by the `PREV`/`NEXT` label, the edge the plate is anchored to, and the mirrored internal order; an arrow glyph is pure redundancy and the most over-used mark in the language. Spend the width on the camera name instead.
- **The nav plates carry the adjacent camera's thumbnail, octet, name and fault bar — they are not chevrons.** The question at the moment of clicking is "which camera am I about to see", and a chevron cannot answer it. Fixed 168×58 regardless of contents, anchored to the image and vertically centred, so the target never migrates as names change length; ellipsize the name inside it. Footer-mounted arrows shift horizontally with name length and this control is clicked dozens of times in a row.
- **Derive the adjacent cameras AFTER the index they depend on.** In the prototype `prevCam`/`nextCam` were computed one line above `fIdx`; the transpiler turns `const` into `var`, so the forward reference read `undefined` and both comparisons quietly went false — every camera reported itself as both the start AND the end of the list, with nothing in the console. Order derived values by their dependencies, and treat a boundary state appearing on both sides at once as a data bug, never a display one.
- **A row of nowrap cells at fixed padding cannot shrink.** In the modal footer that means it overruns the card the instant a string grows (RU, a long model). Metadata cells need `min-width: 0` + ellipsis; action cells and key hints stay fixed. The card must clip its own children — a panel that lets a child paint onto the scrim has the wrong overflow.
- **Pause thumbnail polling while the modal is open.** The wall behind it is blurred and unreadable; fetching frames nobody can see burns the extraction budget the whole screen depends on. Resume on close.
- **The scrim is a child of the pane frame like every other panel** — not a `Popup`, not a `Window`. Blur the wall layer beneath it; do not re-render the wall per frame. Same rule for the group-chip popup: anchoring to the window double-counts the scroll and breaks the clamp that keeps it inside.
- **Never position a panel from an assumed height.** The group-chip popup's height is `(groups + 1) × 28 + 2` and grows with the group count; clamping it by subtracting a constant from the frame height holds for three groups and silently breaks at seven. Compute the height, flip above when it would overflow, and clamp both axes with a lower bound as well as an upper one.
- **Group rows are listed in configured order, never sorted by count or health.** Sorting them by a changing number reintroduces the Triage failure-mode-3 muscle-memory bug one pane over.
- **Russian needs three plural forms** (1 / 2–4 / 5+) for every count-bearing string. Do not hand-build `n + " камер"`.

### Non-negotiables from the brief

- **Honesty:** never invent a camera name; never render unknown as healthy; every empty state names its filter or scope; no silent no-op controls. The two fault badge families must be impossible to mistake for normal.
- Renaming and grouping are **immediate server writes with no undo** — the design makes accidental edits hard rather than promising an undo that does not exist. (See §6 for what a real undo would cost the backend; do not implement one client-side.)
- **Read-only mode must be a coherent screen** for viewers and engineers.
- Thumbnails are **live camera frames** fetched per visible tile. Groups must not become a second video wall — viewport-only fetching is mandatory (see §3 for the pixel budget: 1.5× the pixels for 2.7× the cameras, and only if every rule holds).
- Camera identity: the octet is the spoken name, the vendor name is the formal one, **the operator-chosen name dominates when set**.
- Groups are backend entities shared with Live / Events / Map; renaming one relabels those screens.
- Dark theme only, tokens from the brief's §2, square corners, hairline borders, no shadows.
- EN + RU, RU ~30% longer, 3-form plurals.
- 1440×900 and 1200×900.

### Done when

Every box in the spec's §7 checklist passes at 1440×900 **and** 1200×900, in **both** languages, and in **all three roles**:

- ≥2.5× more cameras on screen than today at 6-per-row (41 vs ~15); measured horizontal AND vertical gaps between tiles are exactly 0; no sliver at the right edge.
- A freshly provisioned batch of 20 is findable (`Ungrouped` row appears by itself), nameable (double-click, Enter, next) and filable (⌘A + one click) in a couple of minutes.
- Which cameras are not recording is visible without leaving the screen — badge, group health bar, the permanent `N not recording` readout, and the console's `NEEDS ATTENTION` summary. All of them resolve from the §2.5 predicates and agree.
- The left pane has **no empty region at any group count**: the work queue fills the remainder and scrolls, and its clean-fleet state is a centred sentence, not a void.
- Filing 14 cameras is one drag or one click, not fourteen popups.
- Opening a camera never resizes the wall; `←`/`→` and the preview plates walk the filtered list showing which camera is next; `Esc`, `✕` and a click in the blur all close.
- No group is ever created named "New group"; `Delete group` always states how many cameras it will orphan.
- Shift-click ranges work every time, including two clicks in rapid succession.
- Read-only role reads as an inspection screen: nothing greyed, nothing misaligned, and opening + arrowing through cameras both work.
- Thumbnails never fetch off-screen or offline; nothing goes blank.
