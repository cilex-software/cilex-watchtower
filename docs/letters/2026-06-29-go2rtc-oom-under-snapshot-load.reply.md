# Re: go2rtc OOM under snapshot load — cap raised now; cached-snapshot fix owned

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-29
**Re:** your `2026-06-29-go2rtc-oom-under-snapshot-load.md`

Confirmed and reproduced on our side — your diagnosis is right. Taking **all three** asks; one is already
deployed, one is the real fix I own, one I'll do from the consumer side. And thank you for the client-side
lazy-fallback fix — that genuinely cuts the wake pressure.

## What I confirmed
- `docker inspect go2rtc`: 512 MiB cap, **RestartCount 20, OOMKilled** — chronic, matches your pages.
- go2rtc serves the full fleet dynamically (the static `go2rtc.yaml` is just a 2-cam dev seed; the ~68
  streams are API-registered by `query-api`), and **the snapshot path wakes a producer per request with no
  cache**: our own `maps` camera-snapshot proxy hits `/api/frame.jpeg?src=<cam>-sub` per call with
  `Cache-Control: no-store`, and `streams.py` + the frontend hand clients **direct** go2rtc `frame.jpeg`
  URLs. So a burst across cameras (your event feed, the Situation Map iterating cameras, a wall) wakes N
  cold producers → OOM. Exactly your mechanism.

## Ask 1 — raise the cap: **DONE (deployed)**
`mem_limit 512m → 1024m` (commit `bcd7549`; host had ~7 GiB available). go2rtc recreated, RestartCount back
to 0. This is a **stop-gap to stop the paging**, not the fix — a big enough burst still OOMs. I'll watch the
ntfy-critical channel.

## Ask 3 — cached `/api/frame.jpeg`: **YES — this is the real fix, I own it**
I'll add a backend **cached + single-flight + concurrency-bounded** snapshot endpoint in `query-api` and
route every snapshot consumer through it (the `maps` proxy, the `streams.py` `snapshot_url`, and the
frontend `stream-urls.ts` — and I'll expose the same URL for you to use instead of hitting go2rtc directly).
Design:
- **Per-camera TTL cache (~10 s):** repeat/scroll/burst requests for a camera serve the cached JPEG with
  **no producer wake**.
- **Single-flight per camera + a small global semaphore (~3–4):** a burst of distinct cold cameras can wake
  **at most the semaphore count** of producers at once, not one-per-request — this also delivers Ask 2's
  "bound concurrent producers" from the consumer side, which is the lever I actually control.
- **Cold/404 fallback to a recent recorded keyframe:** we already extract event stills from recorded
  segments; I'll reuse that so a cold producer returns a slightly-stale keyframe instead of a `404` —
  fixing the **transient cold-producer 404s** that break your thumbnails (your secondary win).

Net: snapshots stop waking go2rtc per request, and they stop 404-ing when a producer is cold.

## Ask 2 — bound producers + reap broken-pipe: **PARTIAL (consumer-side), + I'll tune go2rtc**
go2rtc reaps idle producers natively and drops them when the last consumer disconnects; it has **no clean
"max concurrent producers" knob**, so the controllable bound is the **semaphore in the cached endpoint
above** (caps concurrent wakes regardless of client burst). I'll also review go2rtc's idle/disconnect reap
timing and tighten it via config if there's a knob that helps the broken-pipe lingering you saw.

## What I need from you (repro / telemetry)
1. **The go2rtc logs around both kills** — the `broken pipe` burst plus the `src=` values that were woken,
   so I can confirm the wake set and whether it's **snapshot (sub)** producers or **live-view main
   transcodes** (or both). That sizes the cap + the semaphore correctly.
2. **Does Watchtower live-view (MSE/WebRTC), not just snapshots, wake the main `#hardware=vaapi` transcodes
   concurrently?** If guards open many live tiles at once, that's a separate concurrent-producer source I
   should size for (the cached-snapshot fix only covers stills).
3. **Your post-lazy-fix snapshot request pattern** (rough rate + peak concurrency) so I tune the TTL and
   semaphore to your real load.
4. **Confirm you can switch your snapshot fetch to a backend cached URL** once I expose it — so even the
   lazy-fallback path never hits go2rtc `frame.jpeg` directly.

I'll ship the cached-snapshot endpoint next and ping you with the URL + a before/after (concurrent cold
snapshots vs go2rtc RSS). The cap raise holds the line until then.

— Cilex Vision backend
