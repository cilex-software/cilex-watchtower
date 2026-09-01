# The guard's first open is our own concurrency, not CV

**Station:** `wt-sm-vnutri-01` (guard booth, Win 11) · **Date:** 2026-09-01
**Builds:** 1.1.294 → 1.1.310 · **Backend:** `192.168.1.4:8000` (LAN)

## The finding, in one comparison

The same 62-fragment session request, in the same launch, minutes apart:

    our in-flight = 6     CV serve = 19,839 ms
    our in-flight = 1     CV serve =     35 ms

**567×, same request, same process.** Across every session measured tonight:

    inflight shared=6-7   ->  serve   7,091 / 11,538 / 12,035 / 19,839 / 21,690 ms
    inflight shared=2-3   ->  serve     476 /  2,204 /  2,619 /  6,637 / 16,983 ms
    inflight shared=0-1   ->  serve      35 /    388 /    555 /  3,771 /  4,988 ms

CV's `serve;dur` tracks **our concurrency** and essentially nothing else.

## What it explains, and what it killed

It explains every earlier reading, including the ones that contradicted each other:

- The 2,702-fragment / 2 MB manifest served in **388 ms** — it ran at `shared=0`.
- The 11-fragment / 9 KB manifest that took **12,035 ms** — `shared=7`.
- Coverage at 14,825–24,062 ms on the first call and 1,030–3,479 ms later — the
  first call lands inside the startup burst.

And it killed three of my own conclusions, in order: that the delay was CV's
database; that a smaller manifest would help; that it was a first-request warm-up
penalty. **Size and request-order were both proxies for how loaded we had made CV
at that instant.**

## Why the client is louder than its own counter suggests

Two independent 6-connection pools point at one server:

- the shared `AuthController` NAM — playback sessions, coverage, `/streams`, events
- `CvImageProvider`'s **private** NAM — snapshots and thumbnails
  (`CvImageProvider.h:21`)

`inflight_shared` counts only the first. The client can therefore have up to **12**
requests against CV while reporting 6.

The private pool exists for a good reason and was widened deliberately: at width 2 a
39-camera Groups grid drained serially and settled at p90 2.3–3.9 s
(`CvImageProvider.cpp:35-38`). That tuning was correct for thumbnails against a
backend that was fast at the time. It is now charged to the guard's first open.

## The remaining work is a TRADE, not a bug

Narrowing startup concurrency, or holding the critical path
(`/streams` → coverage → session) ahead of cosmetic traffic, should let the guard's
first session run at `shared=0-1`. The evidence that this reaches the goal is
already in hand: **second opens in a warm, quiet app measured 561 / 801 / 975 /
1,175 / 1,205 ms** — at or near sub-second, on this link, with the 100 Mbit device
still in place.

But it costs what the widening bought: the events rail and Groups grid populate more
slowly in the first seconds. **That is a product decision about what a guard should
see first, and it belongs to the operator, not to this agent.**

## Client-side work already shipped or committed

| change | status | effect |
|---|---|---|
| coverage single-flight + HighPriority | deployed 1.1.303 | first open 17,076 → 6,273 ms median |
| `/streams` single-flight + HighPriority | committed | head of the chain |
| coverage + ip-map persisted to disk | committed | FAST OPEN on first open 0/4 → **5/5** |
| `WT_PB_WINDOW_MS` | committed, default off | aimed at size; size is not the term |

The whole-day manifest is gone from the first open. What remains in front of the
guard is latency we are inflicting on ourselves.

## For whoever picks this up

Do not re-measure CV's endpoints without recording `inflight` alongside. Every
"CV is slow" number in this repo from 2026-09-01 was taken with our own boot storm
in flight, and CV has been told so. `serve;dur` alone cannot distinguish a slow
server from a server we are shouting at — their header and our in-flight counter
were each useless alone and conclusive together.
