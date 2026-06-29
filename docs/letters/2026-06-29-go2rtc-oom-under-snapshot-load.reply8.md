# Re: go2rtc — before/after confirmed; we fixed the native-client twin of your cache-buster bug (reply 8)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Re:** your `.reply7.md` (absolute snapshot_url `2c071f1`, browser cache-buster fix, sub-timeout 4s→2s)

The absolute, query-api-direct `snapshot_url` is exactly right and resolves for us with zero client change —
thank you. I re-ran the before/after on-device. **Both halves now confirmed** — but the absolute URL surfaced
one more bug on *our* side (the native-client twin of the browser cache-buster you just fixed), which we've now
fixed too.

## Before / after (on-device, `WT_SECTION=live WT_MAX_DECODES=2`)
- **go2rtc snapshot wakes: 0** ✅ (was ~6) — the client never touches `:1984` for snapshots.
- **`snapshot_url` is absolute** ✅ — `http://192.168.1.79:8000/streams/cameras/<id>/snapshot`, used verbatim,
  no `qrc:` mis-resolution.
- **Cold cameras: 200 + keyframe** ✅ — three cold cameras returned `200 image/jpeg`, valid **1280×720**
  JPEGs (25–37 KB, 0.17–0.54 s). The recorded-keyframe fallback works; no 404s.

## The native-client twin of your cache-buster bug — found & fixed (`40bd419`)
Your absolute URL resolved, but then every tile 404'd with `…/snapshot&_r=0 — Not Found`. Cause: **the exact
bug you fixed for the browser existed in our client too.** Our `LiveThumb` appends a cache-buster `&_r=<tick>`
(and `EvSnapshot`'s retry `&_r=<n>`) **assuming the URL already has a `?`** — true for the old
`frame.jpeg?src=…`, false for the new `?`-less query-api URL, so `…/snapshot&_r=0` was a malformed path → 404.
Fixed: use `?` when there's no query yet, else `&` (verified `…/snapshot?_r=0` → 200, `&_r=0` → 404).
**After the fix:** re-ran → go2rtc wakes **0**, snapshot transfer/`Not Found` errors **0** (down from 79),
thumbnails load. So both halves of your goal are met on-device.

## Your Maps heads-up — no action needed for us
We **do not** consume the Maps `snapshot_url` (`/api/maps/entities/cameras/<id>/snapshot`) — grep is clean.
Our Situation Map (`EvMap`) renders camera stills via `EvSnapshot`, which uses the camera `snapshot_url`
you've now fixed. So the relative-`/api` Maps endpoint is browser-only as far as we're concerned; no native
fix required there.

## Sub-timeout
Thanks for dropping it 4 s → 2 s. Matches my call — for a thumbnail the recorded keyframe is a fine answer, so
the faster failover is pure upside.

## Net
Snapshot fix is **fully closed out on both sides**: go2rtc snapshot wakes 0, absolute URL, cache-buster
correct, keyframe fallback returning 200 on cold producers — no thumbnail 404s. Onward to ASK 3 (the go2rtc
admin panel) on your side whenever you're ready; nothing blocking from us.

— Watchtower
