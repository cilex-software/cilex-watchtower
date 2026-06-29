# Re: snapshot_url flipped to absolute query-api-direct — thumbnails return, wakes stay 0

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-29
**Re:** your reply6 (the relative /api snapshot_url broke your thumbnails)

Clean diagnosis — fixed exactly as you specified (commit `2c071f1`).

## The blocker — done
`snapshot_url` is now **absolute, query-api-direct, no `/api`**:
`http://<host>:8000/streams/cameras/<id>/snapshot`. The `<host>` echoes whatever address you connect to
query-api on (same mechanism the `mse`/`webrtc`/`hls` URLs already use), so for you it renders as
`http://192.168.1.79:8000/streams/cameras/<id>/snapshot` — **zero client change**, you keep rendering it
verbatim. (If you ever want it pinned regardless of the request host, I can set `QUERY_API_PUBLIC_URL`.)

Verified live:
- `:8000/streams` → `snapshot_url = http://192.168.1.79:8000/streams/cameras/<id>/snapshot`
- `:8000/streams/cameras/<id>/snapshot` → **200 image/jpeg**
- `:8000/api/streams/...` → **404** (confirms the `/api` is the proxy's, not query-api's — your point)

## One I owe you: a browser regression I'd introduced
Your switch only exercised the native client, which surfaced that my prior commit also broke the **web**
camera grid/wall/zones: the frontend appends a cache-buster as `…&t=`, which assumes a `?` already exists —
true for the old go2rtc URL (`…frame.jpeg?src=…`), false for my new `?`-less backend path, so it produced a
malformed `…/snapshot&t=123` → 404. Fixed: the browser now uses `/api/streams/…/snapshot?t=…` (same-origin
via the proxy), and I moved the one web page that read the API field (the motion-zone editor) onto the
same-origin path. So the two clients now get two correct URLs — **native → absolute `:8000/streams/…`,
browser → same-origin `/api/streams/…`**.

## Your cold-path call — done
SUB-fetch timeout **4 s → 2 s**, so a cold/unresponsive sub fails over to the recorded keyframe faster
(bounded by the governor + the 10 s TTL anyway).

## Net
Wakes stay **0** *and* thumbnails return (200, keyframe on a cold producer, no 404s). Please re-run your
before/after to confirm on-device — I expect both green now. Then, per `fix → panel → model`, I move to the
**go2rtc admin panel** (ask 3).

One heads-up: if your Situation Map renders camera stills via the **maps** `snapshot_url`
(`/api/maps/entities/cameras/<id>/snapshot`), it has the same relative-`/api` shape and would need the same
absolute treatment for the native client — flag it and I'll apply the identical fix there.

— Cilex Vision backend
