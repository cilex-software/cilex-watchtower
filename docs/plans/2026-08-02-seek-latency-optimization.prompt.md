# Seek-latency optimization — implementation prompt (items #1–#7, phased)

_Execution prompt for the optimizations identified by the 2026-08-01/02 cold-seek
campaign (`docs/perf/2026-08-02-cold-seek-report.md`). Baselines to beat, measured
on the REPAIRED seek path (d81cbe3): warm p50 1,438 ms / p95 2,282 ms; cold p50
1,677 ms / p95 4,767 ms / p99 7,090 ms; in-window seeks 15–173 ms (not in scope —
already at floor). The >1 s cost IS the re-anchor: session POST (190–500 ms) +
demuxer restart w/ 2 segment fetches (~285 ms warm, + 150–240 ms/segment cold
floor) + preroll/verify-retry (150–450 ms) + first decode (50–200 ms)._

**Standing invariants that MUST survive every phase** (violating any = stop):
- ONE `setSource()` per swap, never `source=""` mid-switch (4a14650).
- No raw QVideoFrames across threads; DirectConnection taps only (4aa4ed7).
- Landing truth = frameSeq advance + playheadMs, never bare position, never
  FrameClock pts against absolute positions (segment-relative — d81cbe3).
- The verify-and-retry pending-seek loop stays as the safety net even where a
  change makes it "unnecessary" — signals were proven unreliable.
- Honest states: any speculative machinery that misses falls back to the normal
  path silently and correctly; no UI lies, no stuck spinners.

---

## PHASE A — client-only quick wins (#3 then #1) — ✅ DONE 2026-08-02 (8baedd9; gate PASSED: cold p50 1,176/p95 2,152/give-ups 0.16% — all Phase-D targets already met; results docs/perf/2026-08-02-phaseA-seek-results.md)

### #3 Verify-retry tick 150 ms → 60 ms
- `qml/PlaybackScreen.qml`, the pending-seek retry Timer: `interval: 150` → `60`;
  retry cap `_pendingTries > 30` → `> 75` (keeps the ~4.5 s time budget).
- Implication: none user-visible beyond ~50–90 ms average shaved; ~2.5× retry
  attempts against a stubborn pipeline — harmless (idempotent seeks).

### #1 Re-anchor at target−2 s for SCRUBBER far-seeks (skip the inner seek)
- `qml/PlaybackScreen.qml::seekFar()`: `_explicitStart = ms - 15000` →
  `ms - 2000`, and DO NOT set `_pendingSeekMs` (leave −1): the playlist head is
  the target, playback starts there — stage 5 disappears for this path.
- MUST NOT touch the event-jump lead-in: `openAt()` sets its own
  `_pendingSeekMs = atMs − 15000` AFTER `openForDay()` — that path keeps the
  deliberate 15 s context and the pending machinery (which #3 just made faster).
  The bounded-bootstrap call into `seekFar(..., preserveMark)` gets the same
  −2 s treatment (its target is the day's first footage — head-start is fine).
- Implications:
  - Playhead lands ~2–8 s BEFORE the clicked instant (window start + first
    segment alignment; segments ≈ 6 s). For a scrubber this is context, not
    error — but VERIFY the harness landing gate (±5 s) still fires on the first
    frame; if first frames land > 5 s early on real serves, either widen the
    harness gate to ±8 s (measurement-only change) or move the anchor to
    `ms − 500`. Decide from data, not taste.
  - The misland watchdog arms nothing on this path (no `_seekWatchPosMs`) —
    confirm `seekWatch` isn't scheduled for far seeks after the change.
- Verification (both items together):
  - `WT_SEEK10K` mini-run, ~150 cold seeks (inventory: parked days re-wet +
    footage recorded since 08-01; rebuild exclusions from ALL logs first).
    GATE: cold p50 ≤ 1,300 ms, p95 ≤ 4,000 ms, give-ups ≤ 0.5%, zero
    `[PB] pending seek DROPPED`, zero MISLANDED on far path.
  - Event-jump regression: `WT_PLAYBACK_IP=<cam> WT_PLAYBACK_DAY=<day>T<hh:mm:ss>`
    → confirm landing ~15 s BEFORE the instant (lead-in preserved).
  - `WT_MERGE_TEST`, `WT_RESTORE_TEST`, `WT_TABS_TEST` green; one live-wall
    screenshot sanity.

## PHASE B — speculative hover session (#2), behind a flag, ~1 day

- Concept: the guard's hover already tells us WHERE the next click lands; we
  already fetch a preview thumbnail on hover. Open the 30-min session too —
  by click time (hover→look→click = 0.5–2 s) the session exists and
  `warm_ahead` has been chasing segments for a second.
- Implementation sketch:
  - `src/models/PlaybackClient`: `Q_INVOKABLE void openSessionAux(cameraId,
    startIso, endIso, tag)` → new signal `auxSessionReady(tag, sid, duration,
    fragments, meta)` — a SIDE-CHANNEL create that never touches `loading`,
    `sessionId`, or the main open flow. Failures emit nothing (speculation is
    allowed to silently die).
  - `qml/PlaybackScreen.qml`: on scrubber hover with dwell ≥ 400 ms at wall T
    where T is OUTSIDE the loaded window → at most ONE speculative open at
    `T − 2000 .. +30 min` (tag `spec|<bucket>`); a new dwell target supersedes
    (old result ignored). Store `{sid, frags, meta, expiresAt, targetT}`.
  - In `seekFar()`: if a fresh speculative session exists with
    `|ms − targetT| ≤ 20 s` and > 10 s to expiry → ADOPT: run the normal
    onSessionReady bookkeeping with the stored payload and `setSource()` to its
    playlist (ONE setSource — invariant), skipping the POST. Else normal path.
  - Env flag `WT_SPEC_SESSION` (default ON after the gate passes; OFF kills all
    speculation). Log `[SPEC] open|adopt|miss|expire` for measurement.
- Implications:
  - Backend session churn rises by roughly the guard's hover rate (bounded by
    the 400 ms dwell + one-in-flight). Sessions cost CV 43–300 ms and
    auto-expire; still, a COURTESY NOTE rides the Phase C letter — churn they
    can see coming is churn they won't page about. If CV objects, the flag
    flips OFF without a release (config).
  - Interaction with #1: adopted sessions were opened at `T−2s`; a click at
    `ms ≠ T` within 20 s lands via ONE in-window seek (pending machinery, now
    60 ms ticks) — still far cheaper than a POST.
  - Never adopt across camera/day changes (`_openGen` discipline: adoption only
    when the hover and click belong to the same open generation).
- Verification: instrumented manual session + a hover-then-click harness pass
  (extend WT_SEEK10K with an optional pre-hover step: call the same speculative
  entry point 800–1,500 ms before seeking — measures the realistic flow).
  GATE: hover-then-click warm p50 ≤ 900 ms; `[SPEC]` adopt-rate > 60% in the
  harness; zero adopted-stale incidents (adopt + landing failure).

## PHASE C — the CV letter (#5 lead, #4 ask, #6/#7 riders), single letter

File as `docs/letters/2026-08-02-review-path-latency-and-reliability.md`:
1. **#5 Day-open flapping (the lead item — a BUG, not tuning):** overnight
   2026-08-01 00:00–08:00 local, 100 day-open attempts hung > 180 s:
   `.125` 0/45 opens (same camera served fine at 18:47), `.101` 0/15, plus
   flapping on `.50` 07-19 (15), `.50` 07-22 (14), `.67` 07-20 (12) BETWEEN
   successful opens. Include exact timestamps from `~/watchtower-soak/
   seek10k-night-2026-08-01/night.log`. Cite their own hang-cap commitment
   (2026-07-11 letter: no review request may hold silently; 503 Retry-After /
   504 when stuck) — a session POST that answers nothing for 180 s violates it.
   Ask: root cause (what runs on the box overnight?), fix, and the contract
   honored. Also re-cite the new-fleet coverage-vs-sessions disagreement
   (sessions say no_recording where coverage says has_footage) — same index,
   likely same root.
2. **#4 Lightweight day-timeline endpoint:** date-open today costs their
   full-day manifest synth (measured 1.8–4.5 s, 2,878 fragments / 2.25 MB for
   one day). The client only needs footage SPANS for the scrubber: propose
   `GET /review/day-spans?camera_id&date&tz` → `[{start,end}]` (few KB, their
   index, no remux). Client then opens ONLY the 30-min window session.
   Saves 1.5–4 s on EVERY date open — the guard's most-felt browsing number.
3. **#6 (optional) move-window:** `PATCH /review/sessions/{id}` with a new
   wall window → re-primed manifest, same session/playlist identity. Saves the
   POST (190–500 ms) per far seek. Explicitly LOWER priority if #2's adopt
   rate proves high.
4. **#7 (question) thumbnail-warm:** does a `/review/thumbnails` extraction
   pull the source segment into the same cache that serves sessions? If yes,
   our hover already pre-warms the click; if not, would a `warm=1` flag be
   cheap? (Compounds #2 for free.)
- Implication of the letter as ONE package: #5 sets the tone (reliability
  first), #4 is the big number, #6/#7 are riders CV can decline without
  blocking anything. Client work exists for #4 only (openForDay v2 building
  tlFrags from day-spans, behind a flag until their endpoint ships).

## PHASE D — validation + publication

- Rebuild the exclusion set from every log; overnight cold re-run with the
  SAME methodology (guard pattern, 08:00 stop) on the post-A/B client.
- Publish `docs/perf/<date>-seek-optimization-report.md`: before/after
  distribution table (this campaign's numbers as "before"), slowest-100
  re-cut, `[SPEC]` adopt/miss stats, and — if CV shipped #4/#5 — date-open
  before/after and a zero-open-hang assertion.
- TARGETS (fail = say so, don't move goalposts): cold p50 ≤ 1.2 s,
  cold p95 ≤ 3.0 s, warm hover-then-click p50 ≤ 0.9 s, give-ups ≤ 0.5%,
  date-open (with #4) ≤ 1.5 s p95.
- Update PROJECT_STATUS + this prompt's checkboxes; fold durable lessons into
  DEVELOPMENT.md gotchas (e.g. "scrubber far-seeks anchor at −2 s; event jumps
  at −15 s — do not unify them").

## Sequencing & dependencies

```
A(#3,#1) ──► mini cold re-measure ──► B(#2, flagged) ──► D overnight re-run
     │                                                        ▲
     └────► C letter (#5+#4+#6+#7) ──► CV ships #4/#5 ──► client #4 adoption
```
A and C start in parallel (C needs only logs). B waits for A's gate so its
measurements attribute cleanly. D runs when A+B are merged, regardless of C —
then re-runs cheaply after CV ships.
