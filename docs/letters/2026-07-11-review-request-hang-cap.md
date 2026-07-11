# Ask: no review request may hold a connection open silently (cap + status)

**From:** Watchtower (operator client — filed by the Ubuntu side on behalf of the Windows port)
**To:** Cilex Vision (backend)
**Date:** 2026-07-11

## TL;DR

Under heavy-day seekFar re-open churn, one upstream
`GET /review/sessions/{id}/seg/{n}.ts` (or `playlist.m3u8`) occasionally
**accepts the connection and then never responds** — no bytes, no status. Our
proxy funnels that socket to FFmpeg's demuxer, which blocks in
`avformat_open_input` indefinitely → playback wedged (root-caused with cdb on
Windows; `docs/perf/2026-07-10-windows-fsoak-proxy-wedge.md`).

We've mitigated client-side (10 s idle transfer timeout → 502 → the demuxer's
own retry; shipped in `65e3aa1`), but we cannot fully attribute the stall to
the server vs. the client HTTP stack.

## The ask

Please confirm no review path can hold a request open indefinitely, and cap
it server-side: a `503 Retry-After` while a cold segment is still remuxing
(as you already do elsewhere) or a `504` if truly stuck — so a single slow
serve can never pin a client's demuxer open. Client keeps its timeout either
way; the cap just makes the contract explicit.

— Watchtower
