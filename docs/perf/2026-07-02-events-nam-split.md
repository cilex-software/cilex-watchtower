# Events screens on a private thumbnail pool — the playback NAM fix, applied wider (2026-07-02)

Follow-up to `2026-07-02-playback-ttff-fix.md`, which ended with: "the Events screens' own
queries still share the auth NAM with the thumbnail storm — the same split applies there."
Applied here, measured the same way (10-min offscreen `WT_GUARD_SOAK` slices against the real
degraded backend — all cameras unplugged but .201).

## Change

`CvImageProvider` (event stills + live-frame fallbacks — the app's bulk HTTP traffic) now fetches
on its **own `QNetworkAccessManager`** with the session cookie attached **per request** (the login
lands on AuthController's NAM, so a private jar would never see it; a per-request header is always
current across relogins). Evicting the storm un-starves every shared-NAM consumer at once —
`EventModel`, `CameraModel`, `StorageHealth`, `SiteMapModel` — so the events screens' queries did
NOT need their own NAM (kept on the now-quiet shared pool; re-check with `[EVTIME]` if that ever
changes).

Diagnostics kept (WT_TRACE-gated): `[EVTIME]` events-query dispatch/inflight/latency,
`[EVIMG]` per-thumbnail code+latency.

## Before (shared NAM, 10-min churn slice)

- Shared pool at events-query dispatch: **inflight 110–112** (p50 110).
- **7 event-list queries dispatched, only 2 completed inside the slice** — the rest sat queued
  behind thumbnails for minutes (the 2 completions were early-boot at low occupancy: 351/486 ms).
- Thumbnails starving each other: fetch p50 1.0 s, **p90 36 s, p99 97 s, max 101 s**;
  783 of 1228 fetches ended code=0 (aborted while still queued — scrolled-away delegates).

## After (private thumbnail NAM, same slice)

- Shared pool at events-query dispatch: **inflight 0–5** (was 110–112).
- **7 of 7 event-list queries completed, 27–495 ms (p50 153 ms)** — none stuck (was 2 of 7).
- Thumbnails: same self-queueing profile, now confined to their own pool (p50 1.0 s, p90 34 s
  tail under churn) — they only delay each other, never the control plane. **0 × 401** (the
  per-request cookie header authorizes correctly); the 200/404 mix matches the before-run.
- Playback in the same slice (regression check): single day-open POST 159–653 ms, first frame
  0.9–2.1 s under churn — the playback fix holds alongside this one.
- 0 `[GUARD] ERR`, no crash, both builds (Qt 6.4.2 `build/`, Qt 6.8.3 `build68`) compile.

(If thumbnail latency itself ever matters, the lever is prioritizing visible rows or a second
image pool — NOT re-merging with the control plane; and mind go2rtc's OOM history before adding
snapshot parallelism in the degraded state.)

## Follow-up (same day): visible/focal thumbnails prioritized within the pool

Within the private thumbnail pool, requests are now priority-ordered so the frames the operator is
actually looking at win the 6 connection slots:

- `CvImageProvider` parses an optional stable `wtp<N>/` id prefix → `QNetworkRequest` priority
  (2=High, 0=Low; absent=Normal). Qt's HTTP stack dispatches higher-priority requests first when
  the per-host pool is saturated. The token is stripped before the backend path (verified: real
  paths like `events/<id>/snapshot` are never falsely matched) and kept in QML's cache key, so it
  is **stable per instance — no refetch churn on scroll**.
- `EvSnapshot.netPriority` defaults `mini ? Normal : High`: large/focal frames (hero, selected
  event, player, map current) load ahead of the many mini list thumbnails. The **live-frame
  fallback** fetches one tier *lower* than its still (mini fallback = Low), so a visible row's real
  still always beats another row's go2rtc fallback — and the fallback storm (each wakes a VA-API
  transcode) yields to everything real.

Verified: Normal (no-prefix) path unchanged in-app (0×401, real 404 mix intact); prefix parse
covered by a unit test (High/Low/Normal, invalid prefixes and real paths untouched → all pass).

## Why the queue explodes in the degraded state

Each visible event row wants a stored still (`events/<id>/snapshot`, many 404 on motion-only
events) and then a live-frame fallback; with the cameras unplugged the fallbacks fail slowly and
retry (×3, cache-busted), so tab switches pile hundreds of image requests into one 6-lane pool.
Anything control-plane behind them — event pages, playback session POSTs (before their own fix),
health polls — waits minutes. Two private pools (playback control-plane; thumbnails) mean the
worst case is now "some thumbnails arrive late", never "the UI's data calls hang".
