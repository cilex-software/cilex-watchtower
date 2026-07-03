# Transient EMPTY manifest (200 OK, 0 fragments) from POST /review/sessions under load

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-03
**Re:** one problem: a review session can return a valid-looking empty manifest for a range that has thousands of ready fragments

## What we observed (today, reproduced in logs)

During a client soak that kept ~5–8 review sessions churning (session POSTs were taking
6.5–8.3 s at the time — the backend was clearly under load), a full-day session open for
`hiwatch-083bc14eff9a` (.106), day **2026-06-22**, returned **200 with 0 fragments**:

```
[PBTIME] session_ready dt=1333ms frags=0 tag=day:2026-06-22
```

Minutes later, the **identical request** (same camera, same day span, both
`hevc_capable` values) returned **4873 fragments, 4760 `ready` / `('main','warm')`**.
So the range was never empty — the session build transiently produced an empty manifest
and presented it as a normal result.

## Why it matters

The client can't distinguish "this range truly has no footage" from "the backend blinked":
both arrive as a well-formed manifest with zero fragments. The operator saw a terminal
**"No footage recorded in this range."** over a footage-bearing day (user report + screenshot
today) — which reads as data loss, the worst kind of false alarm a VMS can raise.

## Client mitigation (shipped today, but it's a band-aid)

On a fresh open whose manifest is empty, the client now silently **retries once after
~1.5 s** before showing the honest empty-state. That covers a blip, not a burst; and a
retry-until-truth loop client-side would just hammer you harder exactly when you're loaded.

## The ask

When a session build can't actually enumerate the range's fragments (timeout against the
store, queue pressure, whatever the internal cause is), prefer **failing loudly or
retryably** over succeeding emptily — any of:
- a 5xx / 503 + `Retry-After` (the client already backs off and retries transport errors), or
- an explicit manifest flag (`"degraded": true` / `"complete": false`) so the client can
  distinguish "empty because empty" from "empty because I couldn't look", or
- an internal single retry before responding, if the failure window is short.

Happy to run the reproduction load against a build with more session-path logging if the
trigger isn't obvious server-side — the client harness can generate the exact concurrency
pattern on demand.

— Watchtower
