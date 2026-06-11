# POST /review/sessions with `hevc_capable: true` → 500 after ~32 s

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-11
**Severity:** HIGH — every single-camera playback open in the operator client hits this path.

---

## Symptom

`POST /review/sessions` fails with **HTTP 500 after ~32 seconds** when the body
contains `hevc_capable: true` — which Watchtower always sends (the client decodes
HEVC). The identical request with `hevc_capable: false` succeeds in ~2.5 s.

For the operator this is: click a day in the playback calendar → ~32 s spinner →
"Session error (500)". It presents as "playback is extremely slow", but it is a
hard failure on your side.

## Repro (measured 2026-06-11, camera `hiwatch-083bc14effc1` / .108)

```bash
# 500 after ~32 s
curl -X POST http://192.168.1.79:8000/review/sessions \
  -H 'Content-Type: application/json' -b "access_token=$TOKEN" \
  -d '{"camera_id":"hiwatch-083bc14effc1","wall_start":"2026-06-10T00:00:00+03:00",
       "wall_end":"2026-06-11T00:00:00+03:00","hevc_capable":true}'
# → code=500 total=31.7s  body: Internal Server Error

# same request, hevc_capable:false → 200 in 2.5 s, 2892-fragment manifest
```

Both days we tried (06-10, 06-03) reproduce it; it does not depend on the window.

## Likely related observation

Every fragment both days reports `tier=warm / codec=h264 / 1280x720` — including
**yesterday's** footage. The hot HEVC 1440p tier seems to have disappeared from
session manifests entirely (we used to get hot HEVC for recent days). If the
`hevc_capable: true` branch tries to assemble the (now missing) HEVC variant and
times out into the 500, that would explain both observations at once. Is the
all-warm tiering intended?

## Client-side workaround (deployed, temporary)

Watchtower now sends `hevc_capable: false` so playback works at all. Today this
costs nothing visible (all served footage is h264 anyway), but it must not stay:
when tiering returns, we'd silently lose the 1440p hot variant. We will restore
`true` as soon as you confirm the fix.

## Asks

1. Fix the `hevc_capable: true` path (or tell us the field is deprecated and
   what replaces it).
2. Confirm whether all-warm/h264-only manifests are intended now — this also
   blocks our mixed-codec switch verification (the HEVC↔H.264 discontinuity
   test needs a hot region to exist).

— Watchtower
