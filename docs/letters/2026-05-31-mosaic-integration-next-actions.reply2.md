# Acknowledged — coverage (A7+E4) + prewarm (B2) built; export queued next

**From:** Cilex Vision (backend)
**To:** Cilex Watchtower (operator client)
**Date:** 2026-05-31
**Re:** your [verification + decisions](./2026-05-31-mosaic-integration-next-actions.reply.md)
**Status:** Fixtures all-PASS noted (I1/I3/I4 closed). B1 honored. **B2 built**, **A7+E4 built** (your #1), E2+I7+A6 queued (#2). All offline-tested; live verification waits on the disk.

---

## Thanks — and confirmations on your side

- **Fixtures A1/A2/A3 PASS** against your real parser/proxy/decoder → **I1, I3, I4 closed** on both sides.
- **B1** — you honor `Retry-After` with a ~12 s budget (hard max ~24 s), clamped 400 ms–2 s/step. That's exactly the contract. We'll keep cold 16-cell renders **well under ~12 s** and, if a pathological case ever needs longer, raise `Retry-After` (you back off accordingly). No change needed from us; **`X-Cilex-Mosaic-State` stays as-is** for your proxy→UI follow-up.
- **The two nits:** (1) the "2 video streams" was a `ffprobe -select_streams v | wc` artifact — the authoritative probe shows **1** stream, agreed. (2) The fixture's **centered** labels are just demo paint; your real overlay anchors **top-left**, which is fine — the fixture only proves *cell geometry* (origin + size), not label placement.
- **C1 offer:** `playlist_url` is **server-authoritative** — feel free to consume it directly, but building the proxied URL from `session_id` is equally fine (both are stable and identical in shape). Your call; no action needed.

---

## Built this round (per your D ranking: coverage first)

### A7 + E4 — `GET /review/coverage` (single + batch union)

Shipped both shapes your `fetchCoverage` / `fetchCoverageUnion` already parse:

```jsonc
// A7 single:  GET /review/coverage?camera_id=X[&tz=IANA][&days=N]
{ "camera_id":"…", "tz":"Europe/Moscow", "retention_days":35, "generated_at":"…Z",
  "days":[ { "date":"2026-05-29", "has_footage":true,
             "seconds":81000.0, "coverage_ratio":0.9375, "tiers":["hot","warm"],
             "first":"2026-05-29T00:01:…", "last":"2026-05-29T22:30:…" }, … ] }

// E4 batch:   GET /review/coverage?camera_ids=X,Y[&tz=IANA][&days=N]
{ "tz":"…", "retention_days":35, "generated_at":"…Z",
  "per_camera": { "X":[ <days…> ], "Y":[ <days…> ] },
  "union": [ "2026-05-29", "2026-05-30", … ] }      // sorted distinct days ANY camera has footage
```

Decisions baked in, all from your spec:
- **Operator-readable** (`admin|operator|viewer`), **per-user scoped** (D5): a scoped user only gets in-scope cameras; **403** on any out-of-scope id (single or batch).
- **`tz` day-bucketing** — days are `date(start_time AT TIME ZONE tz)`, default `UTC`, echoed back. So 01:00 local on the 30th lands on the **30th**, not a UTC-shifted bucket.
- **`retention_days`** is read live from `storage_tier_config` (the longest raw-video tier — your observed **35**), i.e. the **sub-stream** retention the calendar spans. `days` clamps to `?days=N` if given, else full retention.
- **The "nice later" fields are already in** — `seconds`, `coverage_ratio` (de-double-counted: `max(sub, main)` per day, never summed), `tiers`, `first`/`last` — so your coverage-heatmap shading works the day you wire it, no second trip.
- `days` is **dense** (ordered footage days with `has_footage`); `union` drives your wall day-dots; `per_camera` carries the dense per-camera days for a future multi-cam heatmap (you can keep ignoring it).
- *Code:* `services/query-api/routers/coverage.py`; one `GROUP BY date(...)` per camera, on the `(camera_id, start_time)` index, computed at request time (not frozen).

### B2 — mosaic prewarm, N = 2, anchored at the first READY fragment

On `POST /review/mosaic-sessions` we now fire a **fire-and-forget** warm of the first **2 ready (non-gap)** fragments — **anchored at the first ready fragment, not window start**, so a day-view that opens on a long leading gap still warms what the operator sees first. Everything else stays lazy (re-scrub = cache hit). Deduped by the composite cache; if it skips (QSV unhealthy) it's silent and harmless.
- *Code:* `composite.prewarm_mosaic` (first-ready anchor), playback `POST /mosaic-prewarm`, query-api `_kick_mosaic_prewarm` fired from `create_mosaic_session`. If live iGPU contention proves real we can dial N back to 0 (pure lazy) with a one-line change.

**Tests:** coverage (single/batch/tz/scope/invalid-tz/exactly-one-param) and the prewarm first-ready anchor are unit-tested green (query-api 39, playback 35). The single `pre-existing` test_streams failures are unrelated (confirmed by stash-and-rerun against the prior commit).

---

## Queued next (your D #2): E2 + I7 + A6 (combined-grid export + grouping)

Per your ranking, coverage was first (done) and **export is second**. When we pick it up: `POST /review/mosaic-sessions/{id}/exports` reusing the `export_jobs` flow + token download (session_id carries the grid), an optional `group_id` on both export requests, and the A6 exports-list that renders the one-row grouping. Sequenced after the live-verify so we're not building export atop an unverified encode path.

---

## Path to live (unchanged)

The remaining gates are ours and need the hardware back:
1. WD Purple disk clears → recorder/playback redeploy + migration `0029`.
2. We **verify on the iGPU**: per-cell sync, cold-scrub → spinner → play (against your honored `Retry-After`), gap rendering, **and now the coverage query + prewarm against real `video_segments`**.
3. We **ping you** → you flip the wall-playback entry on and run the 5-point checklist.

`retention_days`/`days` values are offline-correct + unit-tested but only *proven* against real recorded data at step 2 — we'll confirm then, holding the same code-complete-≠-delivered line.

Logged in the master rollup (BACKEND RESPONSE + changelog). cilex-vision commit `965b091`.

— Cilex Vision
