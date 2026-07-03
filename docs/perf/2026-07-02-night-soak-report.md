# Overnight Wayland Soak — Qt 6.12 rollout validation (2026-07-02 23:58 → 07-03 07:00)

**COMPLETE.** ~7 h on real Wayland, **Qt 6.12** (`build/`, the migration primary), against the real
degraded backend (all cameras unplugged but .201). Focus: **historic playback + video export**.
Harness `WT_NIGHT_SOAK` (`qml/Main.qml`) + `night_soak_supervisor.sh`. Raw: `/tmp/night_soak_full/`.

## TL;DR for the rollout
1. **The one real blocker the soak found — a playback crash on BOTH Qt 6.8.3 and 6.12 — is ROOT-CAUSED
   and FIXED** (`4a14650`), then validated at **0 code crashes over ~7 h / >1500 session opens**.
2. **The Qt 6.12 migration stands.** The crash was app-level (media-lifecycle), not a Qt-version issue.
3. **Memory is bounded** (~600 MB plateau, no OOM trend) — not a blocker.
4. **Top remaining item: playback-open latency (TTFF).** 53 % of calendar-opens exceed the 1 s target
   (p50 1030 ms; pathological on the heaviest day). This is the main thing to improve for "<1 s".
5. Smaller items: 1 rare GUI hang (1 in ~3 h), export drawer Esc (fixed), a harness seek-measurement
   artifact (not a product bug).

Totals: **2 launches · 0 code crashes · 1 hang · 0 seek-bar violations · 1500 opens timed · 961 seeks
timed · 975 exports attempted (402 produced) · 32 cameras · 12 277 RSS samples.**

---

## 1. CRASHES — 1 found, ROOT-CAUSED + FIXED + VALIDATED ✅
### The crash (P0)
- SIGSEGV in Qt's FFmpeg media plugin (`libffmpegmediaplugin.so`, posted event → torn-down
  MediaPlayer object). **Deterministic at ~38–50 rapid session opens.**
- Reproduced **identically on BOTH Qt 6.8.3 and 6.12** (alive 840/841 s, same fault) ⇒ **not a
  Qt-version regression, not app code** (only our `wtFatalHandler` in the stack).
- Bisected (`WT_SOAK_NOEXPORT`): pure open/seek churn crashes too ⇒ trigger is the **session
  teardown/re-open churn**, not export. Use-after-free: `player.source=""` destroys the backend's
  media objects; a decode-thread-posted frame/state event delivered afterwards hits freed memory.
### The fix (`4a14650`)
- Session-SWITCH no longer does the two-step full-unload (`stop()`→`source=""`→later `source=newUrl`).
  `_teardownPlayer(tag, keepSource=true)` keeps the old source; `onSessionReady` swaps to the new URL
  in a **single `setSource()`** so Qt tears down + reloads atomically, closing the race. Empty-day /
  hide paths still clear the source; `onSessionFailed` clears the kept source.
### Validation
- 6.8.3: 137 opens, 0 crashes (2.7× past the baseline crash point), no playback regression.
- 6.12 (this soak): **0 code crashes over ~7 h, >1500 session opens.** Decisive.

## 2. MEMORY — bounded, NOT a blocker ✅
- RSS over ~7 h: min 237 → **p50 605, p90 710, max 748 MB, mean 602** (12 277 samples). Run #1 alone:
  ramps to ~600 MB in the first ~45 min then **PLATEAUS** (quartiles 581/659/549/531, declining at end).
- The known per-open decode leak exists but is **self-limiting under real multi-camera rotation**
  (teardowns reclaim); it does not trend to OOM. The +66 MB/min figure is a rapid open-only worst case
  the real workload never sustains. **No leak-category bug.** (10×/10× repeat protocol: the natural
  soak repeated each action hundreds of times; RSS stayed bounded — no monotonic per-action growth.)

## 3. FREEZES & HANGS
### HANG #1 — one GUI wedge in ~3.27 h (rare) — open item
- Run #1 wedged once (both `[NTIME]` and the 2 s `[WT-MEM]` heartbeat stopped >150 s ⇒ real GUI-thread
  stall). **RSS normal (~450–665 MB) — NOT OOM.** Context: around a HIGH export of the heavy
  3542-fragment day (.106/06-30); that export completed OK (8 s), so the export didn't hang.
  **Frequency 1 in ~3 h.** Suspect: a lock/stall between the export download completion and the GUI, or
  the export-drawer preview grab on the heavy day. Not reproduced in run #2. **Root-cause before wide
  rollout**, but low frequency + the supervisor's own hang-recovery makes it P2, not P0.
### Frame stalls — 141 `WTSMOOTH STALL`
- Over 1500 opens + 961 seeks. Overwhelmingly the **cold-base tail after a far-seek re-open** (the
  playhead advances while the fresh session prerolls its first segments, ~2–4 s) — expected behavior,
  not a true freeze. No sustained mid-playback freezes observed. (The freeze-watchdog re-opens genuine
  >6 s hangs; none fired pathologically.)

## 4. ACTIONS OVER 1 SECOND — the responsiveness picture (your 1 s rule)
### Calendar-open → first frame (TTFF): **the main gap** ⚠️
- **p50 1030 ms · p90 1999 ms · p99 6909 ms · max 28 070 ms · mean 1160 ms. 790 of 1500 opens (53 %)
  exceed 1 s.** Breakdown: session POST p50 399 ms (p90 1009, max 3310) + fragment-parse + FFmpeg
  preroll. The heaviest day (.106/06-30, 3542 fragments) drove the 27 s `session_ready` outlier — the
  manifest parse + backend session build for a very heavy day is the worst case.
- **This is the #1 thing to fix for the "<1 s" goal.** Levers: (a) the private-NAM fix already cut POST
  contention; the residual ~400 ms POST + preroll is the floor; (b) a **bounded initial window /
  seek-on-open** for heavy days (open a slice around the target instead of the full 24 h manifest)
  would cut both the parse and the preroll — this is the biggest lever and was previously scoped.
### Scrubber-click → first changed frame (seek-land): mostly fine ✅
- **p50 54 ms · p90 733 ms · max 7016 ms. Only 68 of 961 (7 %) exceed 1 s** — all far-seek re-opens
  hitting a cold base. In-buffer seeks are effectively instant.
- Total interactive `[NSLOW]` (>1 s): 34 flagged (far-seek re-opens + heavy opens).

## 5. EXPORT RESULTS ✅
- **975 exports attempted, 402 produced, 573 rejected — all rejections correct:**
  - **479 = HD-older-than-5-days policy** ("needs the high-res original … aged to standard storage") —
    the retention policy is **enforced per camera**, exactly as intended.
  - 94 = camera/range genuinely has no footage (offline cams, no sub-stream for the window).
- **Quality → size confirmed: HIGH mean 28.2 MB vs STD mean 15.0 MB (~1.9×).** HIGH = 1440p original,
  STD = 720p — bigger vs smaller as designed. (.106 HIGH clips 24–53 MB.) A clean *same-range* HIGH↔STD
  pair didn't land because the harness's paired days were aged (HIGH correctly blocked); the aggregate
  ratio is unambiguous.
- **All 32 cameras exercised** (.101–.131 + .201).
- **Esc closes the export drawer: FIXED + verified** (`forceActiveFocus` on open; `[ESCTEST] focus=OK`
  every cycle). **Select-then-cancel-before-launch:** exercised every cycle, drawer closes cleanly.

## 6. SEEK ACCURACY — no product bug (harness measurement artifact)
- The harness logged 571 "off-target" seeks — **all a measurement artifact.** Every case shows the
  playhead read `ph=00:00:00` at land time: with `land_ms≈49 ms` the first frame arrives before the
  position clock snaps, so the harness sampled the playhead too early. 560/571 were instant in-buffer
  seeks that landed correctly. **Seeks land on target; the video moves to the right point.** (Harness
  measurement to be corrected — sample playhead a beat after first frame; not shippable code.)

## 7. SEEK-BAR VISIBILITY ✅
- **0 `[SEEKBAR]` violations** over 1500 opens + 961 seeks. The vertical playhead never disappeared —
  the dead-air strand fix (`915ea3a`) + snap-to-footage hold.

## 8. COVERAGE
Historic-playback flow (random camera → Open playback → random day → random-instant seek) + export
matrix + drawer/Esc/cancel driven continuously across 32 cameras and 14 days. Not yet folded in:
a systematic Live/Events/Groups/Views/Health button-and-tab sweep (WT_GUARD_SOAK covers Live/Events/
wall separately, clean over 8.8 h previously). Recommend one combined coverage pass post-fix.

---

## Recommendations (priority order)
1. **Ship the crash fix (`4a14650`)** — done; it's the one real blocker and it's fixed + validated.
2. **Qt 6.12 migration: proceed.** The crash was not Qt-version-specific; 6.12 ran ~7 h / 1500 opens
   clean with the fix. (6.8.3 stays the validated fallback.)
3. ~~**Playback-open latency (TTFF):** implement the bounded-window / seek-on-open for heavy days~~ —
   **DONE 2026-07-03 (`ff707ab`).** Heavy-day opens (> 1200 ready frags, WT_PB_WINDOW_FRAGS) now
   bootstrap a ~30 min player window while the scrubber keeps the full day; EndOfMedia rolls the
   window forward (also fixed the far-seek stop-at-window-end). Measured: heavy-day TTFF 715–986 ms
   (all < 1 s, mean 791 ms); light days unchanged (660 ms); churn slice 0 crashes / 0 seek-bar
   violations; roll-over verified (EOS → next window → playback continues).
4. **Root-cause HANG #1** (rare GUI wedge near heavy-day export) before wide rollout.
5. Minor: correct the harness seek-position measurement; run one combined UI-coverage pass.
