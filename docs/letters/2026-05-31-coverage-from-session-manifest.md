# Cilex Vision — coverage is already in the manifest: ship A7, and meanwhile we'll derive it from `/review/sessions`

**From:** Watchtower (operator client)
**Date:** 2026-05-31
**Priority:** MEDIUM-HIGH — the footage calendar shows **"availability pending"** on *every* playback open (single-camera `PlaybackScreen` **and** the `WallPlayback` aside). It is the most-visible un-lit feature in playback.
**Scope:** No new contract required to *unblock*. This is (1) a priority nudge on **A7** with new evidence, and (2) a few questions about `/review/sessions` window limits so we can derive coverage client-side in the interim.
**Master-letter code:** **A7** follow-up — see `2026-05-30-footage-coverage-calendar-api.md` (the canonical spec; unchanged).

---

## New evidence: the coverage data is already present and already served

Open a playback session on a day and pick **24H** — the seek bar fills **solid green, end to end**. That green is drawn straight from the **`/review/sessions` manifest fragments** (`wall_start` / `wall_end` per fragment). The screenshot in front of the operator right now reads `Coverage · 283 segments` for the loaded window.

So the facts the calendar needs are **not missing data** — they are the *same* `video_segments` rows you already aggregate into every manifest, simply bucketed **by day** instead of laid on a timeline.

That reframes A7. It is not "collect new data." It is a `GROUP BY date(start_time AT TIME ZONE :tz)` over the table that already backs the green bar the operator is looking at. The data is proven present, queryable, and operator-readable through the session path today.

---

## Two things we'd like

### 1) Ship A7 — same data, one aggregation away

A7 is fully specced (`2026-05-30-footage-coverage-calendar-api.md`) and the response shapes are already agreed and fixtured (`docs/letters/fixtures/2026-05-31-coverage/`). The new evidence above is just to make the effort/priority call easy: turning the on-screen **"availability pending"** into real day-dots is the **highest-visibility, lowest-effort** item in the review family — the client (`fetchCoverage` + `fetchCoverageUnion`) is shipped and waiting, and the query is a daily roll-up of data you already serve.

### 2) Until A7 lands, can we derive coverage from a wide-window `/review/sessions` manifest?

Because the manifest already enumerates footage for a window, we can populate the calendar **client-side this week** by opening **one manifest-only session** over the retention window and bucketing its fragments into local days — **real data, no fabrication**. Before we ship that, please confirm:

- **(a) Window width.** Does `POST /review/sessions` accept a ~**35-day** window (`wall_start = now − retention`, `wall_end = now`)? The A7 letter ruled out `/recording/segments` for multi-day because `limit ≤ 1000` with no cursor (`limit=2000 → 422`). Does `/review/sessions` have a similar cap, or does it return the **complete** fragment list for whatever window we ask?
- **(b) Create cost.** Is creating such a session cheap (manifest assembly only), or does it kick off remux / HLS prep we'd be wasting? We would read the manifest JSON and **discard** — never fetch the playlist or any segment.
- **(c) Lifecycle.** Anything we should clean up for an open-and-discard session, or do they expire on their own? We don't want to leak sessions.
- **(d) If wide windows are discouraged**, what's the **max window** you'd recommend, so we chunk responsibly (e.g., 7-day pages) instead of guessing?

If (a)+(b) are "yes, fine," we light the calendar up with **zero contract change**, and A7 then makes it instant and lets us drop the wide-session workaround entirely. If there's a reason not to, tell us and we'll simply keep the honest pending state until A7.

---

## What stays honest either way

The calendar **never fabricates coverage** (standing product rule). We mark a day **only** if real fragments land on it — whether those come from A7 or from a derived manifest. If derivation is unavailable, a window is rejected, or a response looks clipped/untrustworthy, we keep the current honest **"availability pending"** — no guessed dots, no silent fallback to fiction.

One correctness note we'll honor on our side: **day boundaries are local-tz** (pilot operator is UTC+3). We bucket fragment `wall_start`/`wall_end` into the operator's local calendar day so the dots line up with the day the operator actually clicks — same `tz` concern called out in the A7 spec.

---

## Cross-reference

- **Spec + schema (unchanged):** A7 — `2026-05-30-footage-coverage-calendar-api.md`.
- **Agreed response shapes / fixtures:** `docs/letters/fixtures/2026-05-31-coverage/` (`coverage-single`, `coverage-batch-union`).
- **Intra-day load path is unchanged and already works:** click a day → `POST /review/sessions` over `[local-day 00:00, +24h]` → exactly the green bar you're seeing. This letter only concerns *populating the day-marks*, not loading a day.
- **Companion client implementation plan:** `2026-05-31-coverage-from-session-manifest.client-prompt.md` (how Watchtower will derive coverage client-side in the interim — gated, honest).

Thank you — happy to adjust the window strategy to whatever is kindest to the recorder.
