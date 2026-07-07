# Frame-by-frame stepping (Step Forward / Step Backward) — implementation plan

**Date:** 2026-07-08
**Status:** PLAN — ready to execute (P0 first; each phase lands independently).
**Research input:** `docs/research/2026-07-07-frame-by-frame-playback-vms.md` (25 sources, 23 verified claims — all citations below refer to it).
**Scope:** single-frame Step Forward/Backward on the playback review surfaces (PlaybackScreen first, events hero player second), plus the supporting review UX (paused-only gating, keyboard conventions, fractional slow-motion). Jog/shuttle hardware, true reverse *play*, and mosaic-wall stepping are explicitly deferred (P5).

---

## 1. What we're building (operator view)

When reviewing footage, the operator can pause and advance/rewind **exactly one frame per click/keypress** to catch a face, a plate, or the exact instant of an event — the standard forensic control every professional VMS ships (Genetec `N`/`M`, Wisenet `Ctrl+←/→`, Milestone's bidirectional step). Frame stepping is **paused-only** (the cross-vendor invariant); pressing step while playing pauses first. Fractional speeds (¼×, ½×) cover "slow motion analysis without clicking."

---

## 2. Ground truth (what our stack gives us — verified in code)

| Fact | Where | Consequence |
|---|---|---|
| `_frameSeq` increments on **every rendered frame** via `vout.videoSink.videoFrameChanged` | `PlaybackScreen.qml:282-293`, `EvHeroPlayer.qml:84-98` | We already have the frame-arrival signal a stepper needs — no new plumbing |
| **Paused seeks render nothing** on our Qt/FFmpeg backend | `EvHeroPlayer.qml:55,67` (workaround: `play()` before seek) | Every step must end with a play→pause-on-frame flush; a bare `setPosition` while paused won't paint |
| In-window continuous seeks are direct (`player.position = pd`), far/boundary seeks re-open via `seekFar` | `PlaybackScreen.qml:177-236` | Steps use the direct path; window-edge/`disc`-boundary steps fall back to `seekToWall` (slow but correct) |
| Playback time is **compact** (gaps removed); `posToWall`/`wallToPos` map to wall clock | `PlaybackScreen.qml` frag machinery | A back-step across a recording gap lands on the previous island's **last recorded frame** automatically — exactly the VMS-correct behavior, for free |
| Speed machinery exists: `playSpeed` ∈ [1..200], `playbackRate` carries ≤10×, `scanTimer` above | `PlaybackScreen.qml:328-355` | Fractional speeds are a 1-line `speeds` array change; no new transport code |
| Keys `+ - 0 Home` are bound (zoom); **arrows, `,`/`.`, Space are free** | `PlaybackScreen.qml:887-892` | The industry key map fits with zero conflicts |
| 6-s freeze-watchdog + `seekFar` recovery + far-seek coalescing | `PlaybackScreen.qml:240-281` | Step-time hangs/expired sessions already self-heal; the stepper must only *not fight* it (busy-guard) |
| Icons are inline SVG paths in `Icon.qml` `_icons` | `Icon.qml:42-43` | `stepBack`/`stepFwd` glyphs = 2 added lines |
| Qt 6.12 FFmpeg backend, HLS with **`.ts` segments**, HW decode (VA-API/D3D11) | toolchain notes | The research's MPEG-TS seek-imprecision caveat **applies** — design must verify-after-seek, never trust one seek |

**Codec/camera matrix to validate against:** `.106` H.264 1080p and `.201` HEVC 1440p (the decoder-heavy case).

---

## 3. Design decisions (resolved now, so phases don't re-litigate)

### D1 — Build on the existing `QMediaPlayer` stack. Do NOT adopt QtAVPlayer.
The research's "clean answer" (QtAVPlayer's `stepForward()`/`stepBackward()`) would mean swapping the media engine under a playback stack we've spent months hardening (churn use-after-free fix, freeze watchdogs, continuous-timeline seek machinery, TTFF tuning, RSS bounding) — and vendoring + building a third-party lib on the Windows CI. Enormous regression surface for one feature. Our primitives (frame-arrival signal + direct in-window seeks + play/pause) compose into stepping without an engine change. **QtAVPlayer remains the documented fallback** if P0 disproves seek accuracy on our streams.

### D2 — The step primitive: *(optional seek) → play → pause on first frame arrival*.
Because paused seeks render nothing:
- **Forward step** = no seek at all: `play()` → on next `videoFrameChanged` → `pause()`. Frame-exact by construction (the decoder emits the *next* frame in the stream), decoder already warm, expected latency ≈ one frame time (40–70 ms at 15–25 fps). Overshoot risk (a 2nd frame slipping out before `pause()` lands) is measured in P0; if material, correct via a back-step (which P2 gives us anyway).
- **Backward step** = seek to `currentPos − 1.5 × frameDur` (i.e. the **middle of the previous frame's display interval** — mid-interval targeting sidesteps the seek-rounding trap the W3C documents) → `play()` → `pause()` on first frame. The FFmpeg backend internally does exactly the research's canonical reconstruction (keyframe + decode-forward through the GOP), so back-step latency is GOP-bound: ~100–300 ms expected on HW decode (P0 measures GOP length).
- **Verify-after-step, bounded retry (≤3):** per the confirmed TS-seek unreliability, never trust one seek. If frame PTS is readable (P0), compare landed PTS to the pre-step PTS; a non-backward landing retries with one more `frameDur` of over-seek. If PTS is not readable, mid-interval targeting alone carries v1 (error budget: a mis-estimated fps drifts ~1 frame per ~20 steps at 5 % error — acceptable; PTS upgrade path noted in P5).

### D3 — Frame duration source: metadata → measured → default.
`player.metaData` `VideoFrameRate` when present; else the **median inter-frame arrival interval** measured over the sink during steady 1× play (QML-side, cheap, continuously refreshed); else 25 fps. VFR cameras degrade gracefully to nearest-frame stepping. A C++ `FrameClock` QObject reading `QVideoFrame::startTime()` off the sink (exact PTS + exact per-frame duration) is added **only if P0 shows startTime is valid over our HLS-TS** (the research flags it can be −1) — registered via `qmlRegisterType`, ~60 lines.

### D4 — Paused-only gating, industry key map, no J-K-L in v1.
Step is enabled only when paused; step-while-playing pauses first (Genetec model). Keys: **`,` / `.`** = step back/fwd; **`←` / `→`** = the same *when paused* (they stay unbound while playing — no future conflict); **`Shift+←/→`** = ±5 frames (Premiere convention); **Space** = play/pause. J-K-L shuttle is **omitted**: `J` (reverse play) is unimplementable without reverse playback (P5), and shipping a half-JKL confuses the editors who'd reach for it. Auto-repeat on held keys is naturally rate-limited by a **busy-guard**: a step in flight drops incoming repeats (no queue explosion; matches how held-key stepping feels in Genetec).

### D5 — Observability first-class, like every playback feature before it.
`[WT-STEP] dir=back target=12345 landed=12305 d=-40ms retries=0 lat=180ms` behind `WT_TRACE`, and a `WT_STEPTEST=<N>` harness (pattern: `WT_HERO_TEST`/`WT_SMOOTHTEST`) that scripts N alternating steps and reports p50/p95 latency + stall/no-move counts — the acceptance gate runs unattended.

---

## 4. Phases

### P0 — Spike: measure the five unknowns (~½ day) — GATES D2/D3
On real footage, both cameras, via a temporary `WT_TRACE` probe:
1. **`QVideoFrame.startTime()/endTime()` validity** over our HLS-TS (drives: PTS-verified stepping vs mid-interval-only).
2. **Paused-seek rendering** on Qt 6.12 (re-confirm the `EvHeroPlayer` comment still holds; if 6.12 now renders paused seeks, the primitive simplifies — keep it anyway for 6.8 fallback parity).
3. **Seek landing accuracy**: request `pos−Δ` for Δ ∈ {½, 1, 1.5, 5} × frameDur; log rendered-frame PTS/position deltas.
4. **GOP length** of both cameras' recordings (`ffprobe` on fetched segments) → expected back-step latency envelope.
5. **Forward-step overshoot rate**: 100 × (play → pause-on-first-frame) cycles; count 2-frame advances.

**Output:** `docs/perf/2026-07-XX-frame-step-spike.md` + go decision on `FrameClock` (C++) and retry policy. **Abort criterion:** if direct seeks can't land within ±1 frame even with over-seek+retry, stop and reassess against QtAVPlayer (D1 fallback) before writing feature code.

### P1 — Step engine + Forward step + UI (~1 day)
- `FrameStepper.qml` (new, shared component): takes `player`, `videoSink`, callbacks into the host's seek machinery; implements D2's primitive, D3's frameDur estimation, the busy-guard, `[WT-STEP]` trace. (Component, not inline — P4 reuses it on the hero player.)
- Forward step wired into `PlaybackScreen`: pause-if-playing → play-until-next-frame.
- **UI:** `stepBack`/`stepFwd` glyphs in `Icon.qml`; two `Ctl` buttons flanking play/pause in the left transport cluster (`|◀` `▶|`), enabled when `frags.length > 0`, tooltips `qsTr("Step back one frame")` / `qsTr("Step forward one frame")`.
- **Keys:** `,`/`.` + paused-gated `←`/`→` in `Keys.onPressed` (zoom keys untouched); Space = `togglePlay()`.
- **i18n:** lupdate + RU translations for the new strings (ride-along: wrap the existing transport tooltips — "Back 10s", "Play / pause", "Forward 10s", "Snapshot", "Fullscreen" — in `qsTr()` while touching this file).
- Acceptance: 100 scripted forward steps → 100 distinct frames (or ≤1 % overshoot with correction noted), p95 < 150 ms, no watchdog trips.

### P2 — Backward step (~1–2 days, the hard one)
- Mid-interval targeting + play-flush + verify/retry per D2/D3; clamp ≥ 0; EOS headroom respected (no forward step past `compactDuration − 0.4 s`).
- **Edges:** target < window start, or the step crosses a `disc` boundary (`_crossesBoundary`) → route via `seekToWall(playheadWallMs − wallFrameDur)` (the far/re-open slow path; the step completes on the pending-seek-after-session-ready path; traced as `path=far`).
- Cross-gap semantics documented + asserted in test: back-step at an island head lands on the previous island's tail frame.
- `WT_STEPTEST` harness: N alternating fwd/back steps → monotonic-alternation check (every back-step must move strictly back, every fwd strictly forward — by PTS when readable, by `player.position` else), stall count 0, p95 back < 500 ms (GOP-bound; re-baseline against P0's GOP finding).
- Acceptance: 200-step alternating soak clean on **both** cameras (H.264 + HEVC), plus a manual eyes-on pass (step through a motion event; verify no black flashes, no watchdog re-opens, session survives 5 min of paused stepping).

### P3 — Review-UX polish (~½–1 day)
- **Fractional speeds:** prepend ¼× and ½× to `speeds` (`playbackRate` carries them natively; `scanTimer` path untouched; the popup renders "¼×" style labels).
- **Shift+←/→** = ±5 frames (loop of the step primitive with the busy-guard).
- **Milliseconds readout while paused:** the primary playhead readout gains `.mmm` when `paused` (steps must be *visibly* counted; playing keeps the calm HH:MM:SS).
- Step buttons: pressed-flash on step-complete (the operator feels the frame land).
- i18n for anything new; RU check.

### P4 — Events hero player reuse (~½ day)
- Mount `FrameStepper` in `EvHeroPlayer` (it already has `_frameSeq`, the sink connection, `seekToWall`, `_speed`); step buttons in its control row; same keys when the hero has focus. Event clips are short single-fragment sessions — the simple path throughout (no window-edge cases).
- Acceptance: step through a motion clip frame-by-frame both directions; `WT_HERO_TEST` unaffected.

### P5 — Deferred (documented, not scheduled)
- **GOP decoded-frame ring cache** (C++): bounded (~24–48 frames, sysmem copies — never retain HW-pool frames), LRU, repaint via `QVideoSink::setVideoFrame()` → instant repeated back-steps + smooth reverse-jog. This is the mpv `reverse_queue`/patent-LRU design; only worth it if P2's seek-per-back-step latency annoys in practice.
- **True reverse playback** (`J`, −1×…−8×): needs the cache above + sustained reverse pipelines; substantial.
- **Jog/shuttle UI + hardware jog** (Contour-class devices): jog = step, shuttle = speed — maps 1:1 onto `FrameStepper` + `setSpeed()` when wanted.
- **Mosaic wall stepping** (`WallPlayback`): the composite is one HLS stream so the primitive applies, but frame semantics (composite fps vs per-camera fps) and sync-UX need their own think + likely a backend (E1) conversation.
- **PTS-exact upgrade** (`FrameClock` everywhere) if P0 deferred it and VFR cameras appear.

---

## 5. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Paused-seek behavior differs across Qt versions (6.8 fallback vs 6.12) | The primitive never relies on paused-seek rendering — it always play-flushes; works under both behaviors |
| MPEG-TS seek imprecision (confirmed, research §2) | Mid-interval targeting + verify-after-step + bounded over-seek retry; never trust a single seek |
| Forward-step overshoot (pause races the next frame) | P0 measures; correction = one back-step; if rate is high, an interim `playbackRate = 0.25` during the flush stretches the race window 4× |
| VFR camera streams | Continuous re-measure of frameDur; degrade to nearest-frame stepping (still monotonic); PTS upgrade path in P5 |
| Session idle-expiry during long paused review | Existing `seekToWall` unseekable-player recovery + freeze-watchdog already re-open on demand; `WT_STEPTEST` includes a 5-min-pause case to prove it |
| HW decoder frame-pool exhaustion | Only relevant to the P5 cache (which mandates sysmem copies); v1 never retains frames |
| Windows parity | Same FFmpeg-backend code path; no per-OS code; add a step check to the W2 eyes-on runbook |

## 6. Touch list

- `qml/PlaybackScreen.qml` — step wiring, buttons, keys, ms-readout, speeds
- `qml/FrameStepper.qml` — **new** shared step engine
- `qml/Icon.qml` — `stepBack`/`stepFwd` glyphs
- `qml/EvHeroPlayer.qml` — P4 mount
- `src/models/FrameClock.{h,cpp}` + `main.cpp` + `CMakeLists.txt` — **only if** P0 green-lights PTS
- `i18n/watchtower_en.ts` / `i18n/watchtower_ru.ts` — new strings + RU
- `docs/perf/2026-07-XX-frame-step-spike.md` (P0), `docs/perf/...-frame-step-soak.md` (P2 acceptance)

## 7. Keyboard map (end state)

| Key | Action | Gate |
|---|---|---|
| `Space` | Play / pause | — |
| `.` / `,` | Step forward / back one frame | pauses first if playing |
| `→` / `←` | Step forward / back one frame | **paused only** |
| `Shift+→` / `Shift+←` | Step ±5 frames | paused only |
| `+` `-` `0` `Home` | Timeline zoom (existing) | unchanged |
| Speed popup | ¼× ½× 1× 2× 4× 10× 20×… (≤10× decode, above scans) | existing + fractional |

**Total estimate:** P0–P4 ≈ 3–4 dev-days elapsed, each phase shippable alone. First commit-worthy slice: P0+P1 (forward stepping usable same day).
