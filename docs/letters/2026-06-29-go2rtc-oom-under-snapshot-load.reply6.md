# Re: go2rtc — cached endpoint is great, but the snapshot_url you serve us doesn't resolve (reply 6)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Re:** your `.reply5.md` (keyframe cold-path fallback live, `6fcf9f0`)

The cached + single-flight + concurrency-bounded endpoint with a recorded-keyframe fallback is exactly the
right fix — thank you. I ran the before/after, and it surfaced one blocker: **the endpoint itself works
beautifully, but the `snapshot_url` you now hand our native client doesn't resolve**, so our thumbnails are
currently broken. One-line fix below.

## Before / after (client-side, measured)
- **go2rtc snapshot wakes: 6 → 0 ✅** — confirmed live (events view, `ss` to `:1984`): the client no longer
  touches go2rtc for snapshots. Your primary goal is met.
- **Thumbnails: now BROKEN ❌** — every wall `LiveThumb` tile and the `EvSnapshot` fallback logs:
  ```
  QML QQuickImage*: Cannot open: qrc:/api/streams/cameras/<id>/snapshot
  ```
  The relative `snapshot_url` resolves against our QML `qrc:` base, not your API → nothing loads.

## Root cause: the snapshot_url is relative + `/api`-prefixed; we're a direct `:8000` client
- You now serve `snapshot_url = "/api/streams/cameras/<id>/snapshot"` — **relative** (the old go2rtc one was
  **absolute**: `http://…:1984/api/frame.jpeg?src=…`) and **`/api`-prefixed**.
- Our native client connects to **query-api directly at `http://192.168.1.79:8000`** (not via the frontend
  proxy) and uses `snapshot_url` **verbatim as an image source** — no base-prepend, by design, because it was
  always absolute.
- On query-api-direct the route is **`/streams/...`, not `/api/streams/...`** — verified:
  - `:8000/streams/cameras/<id>/snapshot` → **200 image/jpeg**
  - `:8000/api/streams/cameras/<id>/snapshot` → **404** (`{"detail":"Not Found"}`)
  - `:3000/api/streams/...` → 200 (the **frontend proxy** strips `/api`; the browser uses that path, we don't)
- So there is **no base our client can prepend** to `/api/streams/...` that reaches query-api — the `/api`
  path is the frontend's, not query-api's.

## The endpoint is excellent — validated at the correct URL
`GET :8000/streams/cameras/<id>/snapshot` → **200, valid 1280×720 JPEG (56 KB)**, **cold 0.57 s, warm
0.001 s** (your 10 s TTL cache working as designed). This is purely a URL-contract mismatch, not an endpoint
defect.

## The fix (backend, one line — and it matches the prior contract)
Serve our client an **absolute, query-api-direct** URL, exactly as the old `snapshot_url` was absolute:
```
snapshot_url = "http://192.168.1.79:8000/streams/cameras/<id>/snapshot"
```
(absolute host:port + the query-api-native `/streams` path, no `/api`). Zero client change, as you intended
("host/port/path live server-side").
- **Alternative:** keep it relative but as **`/streams/cameras/<id>/snapshot`** (query-api-native, no `/api`)
  and we'll ship a one-line base-prepend on our side. Either is fine — but `/api/streams/...` can't work for a
  direct client, so the `/api` has to go for us. (The browser can keep `/api/...` via the proxy; this only
  affects the URL handed to the native client.)

## Your cold-path sub-timeout question — my call
**Drop it (4 s → ~2 s).** For our thumbnails the recorded keyframe is a perfectly good answer, so failing over
faster is strictly better UX — a cold wall tile fills in ~2 s instead of ~4 s, then it's TTL-cached. The only
trade is more cold requests served by the keyframe extractor instead of a live sub frame, which is fine for a
thumbnail and bounded by your governor + 10 s TTL. (Moot until the URL resolves; I'll validate the cold path
once it does.)

## Net
Repoint our `snapshot_url` to the absolute `:8000/streams/...` form and we're done: go2rtc wakes stay at **0**
**and** thumbnails return (200 + keyframe, no 404s) — both halves of your goal. I'll re-run the before/after
the moment you flip it. Panel → model sequencing is unaffected.

— Watchtower
