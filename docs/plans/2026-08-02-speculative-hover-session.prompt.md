# Speculative hover session (#2, Phase B) — implementation prompt

_The next client-side seek-latency lever after Phase A (8baedd9, results
`docs/perf/2026-08-02-phaseA-seek-results.md`). Baselines to beat, measured on
the Phase-A client: cold far-seek p50 1,188 ms / p95 2,167 ms (n=1,218). The
remaining floor is serial: session POST (190–500 ms measured) + demuxer restart
with 2 segment fetches (~285 ms warm, +150–240 ms/segment cold) + first decode.
The guard telegraphs every scrubber seek: hover → look at the preview thumbnail
→ click, a 0.5–2 s gap. This feature spends that gap: open the 30-min session
at hover time; by click time it exists and the backend's `warm_ahead` has been
chasing segments. TARGET (gate, not hope): hover-then-click p50 ≤ 900 ms cold._

**Standing invariants (violating any = stop):**
- ONE `setSource()` per swap, never `source=""` mid-switch (4a14650).
- Landing truth = frameSeq advance + playheadMs (d81cbe3); the verify-and-retry
  pending-seek loop stays untouched as the safety net.
- Speculation must be INVISIBLE when it misses: no `loading` flicker, no state
  mutation, no UI hint of its existence. A dead speculation costs nothing but a
  backend session that expires on its own.
- Event-jump lead-in (`openAt` → −15 s pending) stays untouched.
- Honest logging: every speculation outcome is one `[SPEC]` line; no silent paths.

---

## PHASE B0 — the side-channel session create (C++, ~2 h)

`src/models/PlaybackClient` (API surface at `PlaybackClient.h:58` —
`openSession(cameraId, wallStartIso, wallEndIso, …)` and the `sessionReady`
signal at `:141` are the shapes to mirror):
- Add `Q_INVOKABLE void openSessionAux(const QString &cameraId,
  const QString &startIso, const QString &endIso, const QString &tag)` — same
  POST, same auth, same retry policy as `openSession`, but it must NOT touch
  `m_loading`, `m_sessionId`, or any property the main flow observes.
- New signal `auxSessionReady(QString tag, QString sessionId, double duration,
  QVariant fragments, QVariant meta)` — emitted on success only. On ANY failure
  emit `auxSessionFailed(tag)` (one signal, no retries beyond the normal HTTP
  policy — speculation is allowed to die; the QML side only uses it to clear
  its in-flight marker so the next dwell can try again).
- The resulting session must be playable through the existing
  `playlistUrl(sessionId)` (`PlaybackClient.h:62`) — verify the proxy path does
  not special-case the main session id.
- Implications: none for existing flows (pure addition). Backend sees one extra
  POST per adopted-or-wasted speculation; sessions auto-expire server-side.
  A courtesy note about the added churn rides the Phase C letter — do not skip
  it, bounded churn CV can see coming is churn they won't page about.

## PHASE B1 — dwell → speculate (QML, ~3 h)

`qml/PlaybackScreen.qml`. The hover dwell mechanism ALREADY exists: the scrubber
hover sets `_hoverWallMs` (`:601,616`) and a dwell timer fires the preview
thumbnail fetch (`:625-628`, tag `hover|<minuteBucket>`). Speculation hooks the
SAME trigger point — one new call next to `fetchThumbnails`:
- `function speculateAt(wallMs)`: no-op unless ALL of — `wtSpecSession` on;
  playback screen active; `camId !== ""`; `wallMs` is OUTSIDE the currently
  loaded window (in-window seeks measure 15–173 ms — speculating there is pure
  churn); no speculation already in flight; and `wallMs` differs from the live
  speculation's target by > 20 s (else it's the same click-to-be).
- On fire: `client.openSessionAux(camId, iso(wallMs − 2000),
  iso(min(wallMs − 2000 + 1800000, Date.now())), "spec|" + camId + "|" + _openGen)`
  — the SAME −2 s anchor Phase A gave `seekFar`, so an adopted session is
  byte-identical to the one the click would have created.
- Bookkeeping on `auxSessionReady`: store `_spec = { tag, sid, dur, frags, meta,
  targetT, camId, gen: _openGen, bornMs: Date.now() }`. A newer dwell target
  SUPERSEDES: mark the in-flight tag stale; when its result lands, log
  `[SPEC] supersede` and drop it (do NOT adopt a stale target).
- Expiry: adopt only while `Date.now() − bornMs < SPEC_ADOPT_MS`. Set
  `SPEC_ADOPT_MS` conservatively to 120000 UNLESS the S06 contract's session
  idle-TTL (check `docs/letters/watchtower-to-cilex-vision-api-requests.md` and
  the playback letters) says sessions die sooner — the adoptable window must end
  ≥ 10 s before the earliest possible server expiry. Decide from the contract,
  not from taste, and write the chosen value + source in a comment.
- Implications: hover spam is self-limiting (dwell threshold + single-flight +
  20 s dedup). No pipeline, no decode, no memory cost client-side — a
  speculation is just JSON bookkeeping until adopted.

## PHASE B2 — adoption in seekFar (QML, ~2 h, the risky one)

In `seekFar(ms, preserveMark)` (`:263`), BEFORE the normal open path:
- Adopt iff ALL of: flag on; `_spec` exists and not superseded;
  `_spec.camId === camId && _spec.gen === _openGen` (the epoch discipline at
  `:322` — a camera/day switch bumped the gen and voids every prior
  speculation); `Math.abs(ms − _spec.targetT) ≤ 20000`; age within
  `SPEC_ADOPT_MS`.
- On adopt: consume `_spec` (null it first — adoption is one-shot), log
  `[SPEC] adopt dtHover=<ms since born> dTarget=<|ms−targetT|>`, then run the
  EXACT bookkeeping `onSessionReady` (`:924`) runs for a fresh far-seek open —
  same `_explicitStart/_explicitEnd` (the spec's window), same gen bumps, same
  seekWatch arming, ONE `setSource(playlistUrl(sid))`. If `ms !== targetT`, the
  landing point is in-window: set `_pendingSeekMs` per the normal in-window
  rules (Phase A removed the inner seek only for window-head landings; a ±20 s
  adoption lands via one in-window seek on the 60 ms verify-retry loop — still
  no POST, which is the point).
  Implementation shape: factor the body of `onSessionReady` into
  `function _applySession(sid, dur, frags, meta, pendingMs)` called by BOTH the
  signal handler and the adoption path — do not duplicate the logic, it has
  earned its scar tissue.
- On any non-adopt: `[SPEC] miss reason=<flag|gen|cam|dist|age|none>` and the
  unchanged normal path. A user must never be able to tell a miss happened.
- Implications: the ONLY new failure mode is adopting a session the server
  already expired → the source 404s → the existing open-fail path runs. The
  age gate makes this rare; the gate metric "adopted-stale" (adopt followed by
  open-fail or MISLANDED) must be ZERO in verification — if it is not, shrink
  `SPEC_ADOPT_MS`, do not add retries.

## PHASE B3 — flag, plumbing, logging (~1 h)

- `src/main.cpp`: context property `wtSpecSession` from `WT_SPEC_SESSION`
  (pattern at `main.cpp:509-513`). SHIP DEFAULT **OFF** (`unset/0` = off; `1` =
  on). The default flips to ON in a separate one-line commit AFTER the B4 gate
  passes — rollback is then one env var or one revert, never a code surgery.
- `[SPEC]` lines: `open tgt= win=`, `ready dt=`, `adopt dtHover= dTarget=`,
  `miss reason=`, `supersede`, `expire` — grep-friendly, one per event, enough
  to compute adopt-rate and staleness offline from any log.
- RU translations: none (no user-facing strings — verify with lupdate that the
  diff adds zero entries).

## PHASE B4 — verification + gate (harness night)

- Harness: `WT_SEEK10K_HOVER=1` — in the Main.qml driver's seek step, call
  `speculateAt(target)` then wait a jittered 800–1,500 ms before `seekFar`
  (mirrors real hover→look→click). Everything else identical to the cold
  methodology (session-verified plans, exclusion set rebuilt from ALL logs,
  ≥120 s separation, guard pattern, deadline mode).
- One overnight A/B: hover-flow cold seeks (treated) vs same-night non-hover
  cold seeks (control, `WT_SEEK10K_HOVER` off for a matched slice) — the
  control guards against backend drift, which burned us before (A/A caveat in
  the Phase A report).
- GATES (fail = report the failure, do not move them):
  - hover-then-click cold p50 ≤ 900 ms; p95 reported with CIs either way
  - `[SPEC]` adopt-rate > 60% in the hover flow
  - adopted-stale incidents = 0
  - give-ups ≤ 0.5%; zero `pending seek DROPPED`; zero MISLANDED on adopted path
  - control slice statistically indistinguishable from Phase A's after-numbers
    (Mann-Whitney p > 0.05) — proves speculation didn't regress the normal path
- Regressions: event-jump lead-in (−15 s) intact; `WT_MERGE_TEST`,
  `WT_RESTORE_TEST`, `WT_TABS_TEST` green; one live-wall screenshot; MEMTEL
  RSS flat across the night (speculation must not leak sessions client-side).
- Then: flip the default ON (one-line commit), update
  `docs/plans/2026-08-02-seek-latency-optimization.prompt.md` Phase B header
  with the gate numbers, publish the A/B table to `docs/perf/`, and fold the
  hover-then-click number into the Phase D targets table.

## Sequencing

```
B0 (C++ side-channel) → B1 (dwell+spec) → B2 (adopt) → B3 (flag+logs)
        → build + manual instrumented pass ([SPEC] lines sane, misses invisible)
        → B4 overnight A/B → gate → default-ON commit → Phase D re-run
```
B0 is committable alone (inert addition). B1–B3 land together behind the OFF
flag — every commit ships a wall that behaves identically until the flag flips.
The Phase C letter's churn courtesy note goes out before the default flips.
