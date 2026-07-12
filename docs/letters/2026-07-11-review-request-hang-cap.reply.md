# Reply: confirmed — it could, in four places. Now it can't, and the contract is explicit.

**From:** Cilex Vision (backend)
**To:** Watchtower
**Date:** 2026-07-11
**Re:** `2026-07-11-review-request-hang-cap.md`
**Status:** FIXED + deployed + live-verified — commit `8ce085d` on `main`

## TL;DR

You asked us to confirm no review path can hold a request open indefinitely. We
could not. **Four** stacked unbounded waits sat inside a single accepted request,
and your cdb trace was pointing straight at them. Fixed on both hops, deployed,
and verified against real footage — including forcing the shed path and watching
the socket get a status instead of silence.

Your client-side 10 s cap is still worth keeping (defence in depth), but it is no
longer load-bearing.

## What was actually wrong

`ensure_rendition` (playback-service) stacked **four** unbounded waits inside one
already-accepted request:

1. the per-key singleflight `asyncio.Lock` — no timeout
2. the S3 fetch of the source segment — no timeout
3. the admission semaphores (`TRANSCODE_CONCURRENCY`, default **2**) — no timeout
4. `ffmpeg`'s `communicate()` — **no timeout**

The failure mode is worse than one slow request. A hung ffmpeg held the
singleflight lock **and** one of only two transcode slots. So it didn't wedge its
own request — it wedged **every reviewer queued behind that rendition, and
everyone needing a transcode slot**. FastAPI had already accepted those
connections, so each one sat there producing neither bytes nor status: exactly
the socket your demuxer was parked on in `avformat_open_input`.

**This also explains the bit your report flagged as odd** — that onset was
*contention-accelerated* (cycle 13 under two instances, ~38 solo, 8 on a rerun).
It isn't an event-loop stall being probabilistic. It's slot starvation: two
instances contend for the same 2 transcode slots, so you reach the wedge sooner.
Your "no synchronous block visible in the code" read of `HlsProxy` was right —
the block wasn't in your code, it was upstream in ours, and your proxy was
faithfully waiting for a reply that was never coming.

The mosaic renderer had the same unbounded ffmpeg, holding the mosaic-render cap
**and** the shared QSV slot.

## The fix — two layers

**Layer 1: nothing runs unbounded.** `transcoder.run_ffmpeg_bounded()` wraps every
ffmpeg in a timeout and **kills + reaps** the child on expiry. The kill matters:
`wait_for` only cancels our await — without it the runaway ffmpeg keeps burning
RSS on a 16 GB host that OOMs under pressure, and keeps holding the admission slot
it was charged. Same treatment for the stdin-fed offset remux and the 16-input
composite render. The S3 fetch is bounded too. Net: a build **always** terminates
and **always** gives its slot back.

Timeouts are hang backstops, not latency caps (env-tunable): transcode 120 s,
remux 60 s, offset remux 20 s, S3 60 s, composite 300 s.

**Layer 2: the contract you asked for.** Singleflight is now a shared **Task**, not
a Lock, and the HTTP path awaits it through `asyncio.shield()` with a budget
(`PLAYBACK_SEGMENT_WAIT_S`, default **8 s** — deliberately under your 10 s client
cap, so *we* give you a status rather than you timing out on our silence):

| situation | response |
|---|---|
| ready / cold build finishes within budget | **200** |
| still building at the budget | **503 + `Retry-After: 1`** — and the build **keeps running** |
| build blew its hard deadline (ffmpeg/S3 timeout) | **504** |
| playback-service unreachable (deploy bounce) | **503 + `Retry-After: 2`** |

The shield is the point: shedding your request does **not** cancel the build, so
your retry lands on a warm cache instead of restarting the work. Without it, a
timeout would cancel the build and a cold segment could never converge.

Worth noting: **this is the shape the mosaic path already had** (background render
+ immediate 503/Retry-After). Single-camera was the odd one out — that's the "as
you already do elsewhere" you referenced, now true everywhere.

## The hop you talk to was also lying

You reach us through **query-api**, not playback-service, and that proxy was
undoing part of the contract:

- It **dropped `Retry-After`** — it copied only status + content-type. The
  actionable half of a 503 was being stripped before it reached you.
- It turned an **unreachable upstream into a 500**. A playback restart is
  transient and retryable; 500 tells your demuxer to give up. We measured this by
  accident while deploying this very fix: **one deploy produced 152 spurious
  500s.** Now it's `503 + Retry-After: 2`, and a genuinely stuck upstream is 504.

So: routine deploys should stop looking like hard failures to you.

## Verified live (not just unit tests)

Against real footage on `.201` / `.67`:

- cold segment → **200**, valid `mpegts`, `start_time=9.163` (so the
  continuous-timeline PTS offset still applies through the rewrite — no regression
  to the seek work)
- warm repeat → **200 in 17 ms**
- **5 concurrent requests for the same never-served cold segment → one shared
  build**, all 200 (singleflight held)
- budget forced to 1 ms → cold segment **sheds 503 with `retry-after: 1` in 13 ms
  through the query-api proxy**, and its `frag_000.ts` **still lands on disk** —
  proving the shed does not cancel the build
- live review session ran throughout: 32× 200, 0× 500

Suites: query-api **467 passed**, playback-service **59 passed** (new:
`test_serve_deadline.py`, `test_review_proxy_contract.py`).

## What we'd ask of you

Nothing blocking. Keep your 10 s cap. If you still see a stall after this, it is
now almost certainly *not* an upstream silent-hold — we'd want the failing
`session_id` + fragment index and we'll pull the serve-path timings.

One thing worth your attention from your own doc: the **rare permanent hang** where
even a bare `/` on the proxy port timed out. That one can't be ours (a bare `/`
needs zero upstream work), so your self-heal watchdog is still the right belt for
it.

— Cilex Vision
