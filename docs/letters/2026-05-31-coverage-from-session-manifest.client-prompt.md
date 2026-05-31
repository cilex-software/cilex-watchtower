# Prompt — Footage calendar: derive day-coverage from the session manifest (interim, real data, no waiting on `/review/coverage`)

## Goal

Make the footage calendar show **real** green day-dots **now**, without waiting on the backend `GET /review/coverage` (A7) endpoint — by deriving day-level coverage from the **same `/review/sessions` manifest** that already paints the seek bar green. Keep `/review/coverage` as the preferred fast path the moment it ships, with automatic, zero-config switchover.

## Why this is possible (and honest)

Selecting a day + **24H** fills the timeline solid green; that green is `fragments[].wall_start/wall_end` from the session manifest. A session over a *wider* window yields the footage map for that window. Bucketing those **real** fragments into local-tz days is real data — it complies with the standing no-fabricated-content rule. The honest "availability pending" state was chosen only because we had no multi-day source; the manifest **is** one.

## Grounding (read these first)

- **`src/models/PlaybackClient.cpp:171` `fetchCoverage()`** — `GET /review/coverage?camera_id=`; on non-200 it emits `coverageReady(id, false, 0, {})` (the "pending" trigger, lines 192–195). Login-gated; retried on `camerasResolved`.
- **`qml/PlaybackScreen.qml` `onCoverageReady` (~line 171)** — sets `coveragePending`, `footageDays`, `retentionDays`. **`qml/PlaybackCalendar.qml`** renders "availability pending" when `pending`, and amber day-dots from `footageDays`.
- **`PlaybackClient::openSession()` / `sessionReady(sid, dur, fragments, meta)`** — the manifest path. Fragment fields: `compact_start/end`, `wall_start/end`, `codec`, `tier`, `resolution`, `availability`. `meta`: `wall_start/end`, `clipped_to_finalized`, `live_gap_s`. **Note the existing `availability !== "ready"` filter drops `hydrating` fragments — for *coverage* we must count `ready` **and** `hydrating` (cold footage still exists); only exclude genuine no-recording gaps.**
- **`qml/WallPlayback.qml`** shows the same calendar via `fetchCoverageUnion` — keep both single + union paths consistent (union = derive per camera, OR the wider mosaic-coverage answer; single-camera first).
- Day labels render in the operator's **local tz** (pilot = UTC+3). Derivation MUST bucket in the same local tz so dots line up with the day the operator clicks.

## Approach

1. **Prefer the endpoint.** Keep calling `GET /review/coverage` first. On `200` → use it, unchanged. This makes the interim self-retiring.
2. **On `404`, derive — don't immediately fall to pending.** Add `PlaybackClient::deriveCoverageFromManifest(cameraId)`:
   - `POST /review/sessions { camera_id, wall_start: now − retentionDays, wall_end: now, hevc_capable }` as a **manifest-only** call: parse the response, then **stop**. Do **not** set a player source, do **not** emit `sessionReady`, do **not** touch the active playback session/`m_session` state.
   - Bucket each returned fragment's `[wall_start, wall_end]` into **local-tz** calendar days; any day intersected by ≥1 fragment → `has_footage: true`.
   - Emit `coverageReady(cameraId, true, retentionDays, derivedDays)` (`retentionDays` = 35 default until A7 returns the real value).
3. **Stay honest on failure.** If the POST errors, the window is rejected, the response looks clipped/capped, or zero fragments come back where we can't distinguish "no footage" from "truncated" → emit `coverageReady(cameraId, false, …)` (keep "availability pending"). Never fabricate, never silently show a partial day-set as if complete.
4. **Bound the cost.** One derive request per camera-open; **cache** the derived result per `cameraId` for the view's lifetime; debounce rapid camera switches and cancel any in-flight derive on switch. If the backend caps the window (per the companion letter's question (d)), chunk into the confirmed max (e.g., 7-day pages) and merge — but only if a single wide call isn't allowed.

## Constraints / working agreements (non-negotiable)

- **No fabricated coverage** — derived dots come from real fragments only; otherwise honest "pending."
- **Don't regress single-camera playback** — derivation is a separate, side-effect-free request; the active session and `MediaPlayer` are untouched; no hidden session is ever played.
- **tz correctness** — bucket in the operator's local tz (UTC+3 pilot), matching the calendar's day labels.
- **Mock only behind `WT_DEMO`.**
- **No UI change** — this only changes what feeds `footageDays`/`coveragePending`; the calendar visuals stay exactly as designed.

## Acceptance criteria

- With `/review/coverage` returning 404, the calendar shows **real** amber dots for days that have footage (cross-check: a 24H session on a dotted day shows green; an undotted in-window day shows "No footage recorded in this range"), instead of "availability pending."
- Days with no footage stay unmarked; if derivation fails entirely, the calendar falls back to the honest "availability pending" state.
- Selecting a derived-footage day loads its 24h exactly as today (no change to the load path).
- The active playback session/player is untouched; no auto-played hidden session; **one** derive request per camera-open (cached, debounced).
- The moment `/review/coverage` (A7) returns 200, the client uses it directly and **skips** derivation — no code change, no flag flip needed.
- Offscreen smoke (`QT_QPA_PLATFORM=offscreen`) and `WT_SCREENSHOT` load clean; no new QML warnings.

## Dependencies / open questions (tracked in the companion letter)

`2026-05-31-coverage-from-session-manifest.md` asks the backend: does `POST /review/sessions` accept a ~35-day window and return the **complete, uncapped** fragment list cheaply (manifest-only)? If yes → single wide-window derive. If it caps the window → use the recommended max and chunk. If wide windows are disallowed and A7 isn't ready → keep "pending" (don't force it).

## Decisions to confirm

1. **Gate behind a flag** (e.g. `WT_DERIVE_COVERAGE`) for staged rollout, or on by default? *(Recommend: on by default, since it always falls back to the honest pending state on any failure.)*
2. **Single wide-window derive vs. chunked pages** — decide once the backend answers the window-limit question.
3. **Keep or remove the interim once A7 ships** — *(Recommend: keep it as a guarded fallback for offline / legacy-backend / pre-A7 deployments; A7's 200 response naturally takes precedence.)*
4. **Wall (`WallPlayback`) union calendar** — derive union client-side from per-camera manifests in the interim, or leave the wall calendar pending until the batch endpoint (E4)? *(Recommend: single-camera first; wall union follows the mosaic/E4 work.)*
