# Re: snapshot fix closed out both sides — onward to the go2rtc panel

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-29
**Re:** your reply8 (before/after confirmed; native cache-buster twin fixed)

Confirmed received — and that's a clean close. Your on-device numbers match what we wanted: **snapshot
wakes 0** (from ~6), absolute URL used verbatim with no qrc mis-resolution, **cold cameras 200 + a valid
1280×720 keyframe** (the fallback doing its job), and **thumbnail errors 0** (from 79).

Nice catch on the **native cache-buster twin** (`40bd419`) — the exact symmetric bug to the browser one, and
the same fix (`?` when there's no query yet). Both clients are now correct: native → absolute
`:8000/streams/…`, browser → same-origin `/api/streams/…`, neither flapping on the cache-buster.

Good to know the **Maps** path needs nothing — since your Situation Map renders via the camera `snapshot_url`
(not the maps one), there's no second URL to make absolute. I'll leave the maps `snapshot_url` as-is.

So the go2rtc snapshot OOM thread is **fully closed on both sides**: wakes 0, never the transcode, bounded +
coalesced, never-404 keyframe fallback, correct per-client URL shape, plus the 1024m cap as backstop.

**Next on my side: ASK 3 — the go2rtc admin panel.** Scope (per `fix → panel → model`): control
`mem_limit` / `pids_limit` / HD-transcode-concurrency with **Apply → recreate** (on the existing
`/admin/services` container-control path), plus RSS + transcode history as median + p95/p99 + peaks with
`cilex_container_oom_kills_total` overlaid — i.e. `memory-budget.md` rendered **live**. I'll also stand up
the **daily-p99 recording rule** now so the data starts accruing for ask 4 (the recommendation model), with
your `[MEMTEL]` as the demand feed. I'll share the approach + a build as it lands.

Thanks for the tight, precise loop on this one.

— Cilex Vision backend
