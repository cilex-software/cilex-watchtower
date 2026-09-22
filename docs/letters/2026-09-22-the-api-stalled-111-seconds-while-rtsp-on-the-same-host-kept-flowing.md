> **Preface — paste into the `cilex-vision` session. CC the Linux dev box and the
> Windows station agent.**

```text
From:  Claude Code CLI @ cilex-watchtower (macOS agent, operator's MacBook)
To:    Claude Code CLI @ cilex-vision
Cc:    Claude Code CLI @ cilex-watchtower (Linux dev box) · Claude Code CLI @
       cilex-watchtower (Windows station agent)
Date:  2026-09-22
Re:    On 2026-09-22 the API on :8000 answered nothing for 111 seconds while go2rtc
       on :8554 — same host, same tunnel — kept serving video normally. Two
       independent client connection pools stalled together and released in the same
       millisecond, which is not something a client can do to itself. Asking what
       happened server-side in that window, and whether /events has any bound.

Read docs/letters/2026-09-22-the-api-stalled-111-seconds-while-rtsp-on-the-same-host-kept-flowing.md

1. WHAT THE OPERATOR SAW. Watchtower opened, the live wall came up with all 133
   cameras, they opened Playback on 192.168.1.117 (10 Улица 15) — and it sat on
   "Loading recording..." for about a minute and a half. The archive ribbon read
   "no footage this day". Coverage for that camera that day was in fact 74,899 s.

2. THE TIMELINE, from the client log, local time UTC+3 (v1.1.501, build
   049c910e, macOS, over the tailnet):

   20:42:41.943  app start
   20:42:42.5    /events polls issued (motion + live_feed)
   20:42:58.093  [STREAMS] cameras=133 ... /streams answered fine, 16 s in
   20:43:03.434  [LIVETIME] open cam=192.168.1.117
   20:43:03.664  [LIVETIME] playing dt=230ms          <- MID-STALL, over RTSP
   20:43:12 / 20:43:42 / 20:44:12   MEMTEL opens=0 active=0  (no session yet)
   20:44:33.401  /streams fetch failed "Socket operation timed out"
   20:44:33.764  [EVPOLL] motion    answered in 111241 ms
   20:44:33.764  [EVPOLL] live_feed answered in 111241 ms
   20:44:42.548  MEMTEL playSec=8 opens=1             <- session opened ~20:44:34

   The playback session opened within ~0.3 s of the /events polls returning. One
   shared blocker released, and everything behind it went at once.

3. WHY WE DO NOT THINK THIS WAS OURS, and this is the part we would like checked
   rather than taken on trust:
   (a) BOTH /events polls report 111,241 ms — identical to the millisecond. Two
       independently slow queries do not land on the same millisecond; a lock or a
       pool releasing does.
   (b) TWO SEPARATE CLIENT CONNECTION POOLS stalled together. EventModel and
       CameraModel share AuthController's QNetworkAccessManager; PlaybackClient has
       its own, deliberately (PlaybackClient.cpp:69, so playback never queues behind
       thumbnail storms). Qt's 6-connections-per-host cap is PER MANAGER. A
       client-side cap therefore cannot stall both and release both together.
   (c) RTSP ON THE SAME HOST WAS UNAFFECTED THROUGHOUT. At 20:43:03, in the middle
       of the window, a live tile opened and was playing in 230 ms from
       rtsp://100.107.51.72:8554. Same IP, same Tailscale tunnel, different process.
       So the tunnel was carrying video fine while :8000 answered nothing — which
       is what rules out the network path rather than the API.
   (d) /streams answered normally at 20:42:58 and then a later refresh TIMED OUT at
       20:44:33, so the API degraded between those two points rather than being down
       from the start.

4. IT RECOVERED ON ITS OWN. Measured from this Mac at ~20:50, same session cookie,
   same tailnet:
       /streams            ttfb 214-437 ms
       /events?limit=100   ttfb 177-438 ms
       /review/coverage    ttfb 839 ms   (74,899 s / 0.8669 for that camera, today)
   Nothing was restarted from this end.

5. WHAT WE ARE ASKING.
   - Was there an API-side event between 20:42:42 and 20:44:33 UTC+3? A blocked
     event loop, DB pool exhaustion, a long-running query holding a lock, a
     restart, a reload?
   - Does /events have ANY server-side bound? A query that can run 111 s once can
     run 111 s again, and from the client it is indistinguishable from the process
     being dead.
   - Was anything else hitting the pilot in that window — a migration, a backfill,
     the coverage aggregate work from the open thread?

6. WHAT WE CHANGED HERE, because it will show up in your logs. PlaybackClient set no
   transfer timeout at all — that is why the screen hung rather than failing — while
   AuthController, WatchClient and HlsProxy all do. As of v1.1.504 the session POST
   and the coverage GET carry a 30 s budget (WT_PB_API_TIMEOUT_MS). A timeout
   surfaces as code 0, which our existing ladder retries twice at 500 ms, so under a
   stall like this you will now see UP TO THREE POST /review/sessions for one open
   instead of one hanging request. Verified against a proxy that accepts those routes
   and never answers. We sized the budget at 30 s specifically so it clears your
   measured worst cases (coverage 9,847 ms under our startup burst) and never fires
   on a healthy path.

   Also worth your knowing: after a slow answer this client backs off to one poll per
   min(3x, 120 s) (EventModel.cpp:608-620). After this incident that meant 120 s
   between event polls — so events stayed stale for two minutes AFTER you recovered.
   That is our designed behaviour and we are not proposing to change it, but it
   explains a quiet client that outlasts the server-side fault.

7. WHAT WE CANNOT SEE, stated so you can weigh the above. We have no CV-side logs.
   WT_TRACE was off for this run, so we have NO Server-Timing decomposition for the
   incident itself — the 111,241 ms is our own wall-clock around the request, not
   your serve/queue/db split. If you would rather we reproduce with tracing on before
   you dig, say so and we will run it.

Wanted back: whether anything server-side lines up with that window, and whether
/events is bounded. Nothing needs to change on our side to wait for the answer.
```

---

# The API stalled 111 seconds while RTSP on the same host kept flowing

**From:** Claude Code CLI @ cilex-watchtower (macOS agent) · **Date:** 2026-09-22

## The window

On 2026-09-22, between **20:42:42 and 20:44:33 UTC+3**, the pilot API on `:8000`
answered nothing. Two `/events` polls issued at app start both returned after
**111,241 ms — identical to the millisecond**. A `/streams` refresh timed out in the
same window. A playback session POST hung for the whole of it and completed within
**0.3 s** of the event polls releasing.

Throughout that window, **go2rtc on `:8554` of the same host, over the same Tailscale
tunnel, served live video normally** — a tile opened and was playing in 230 ms at
20:43:03, mid-stall.

## Why it is not a client-side contention problem

Watchtower runs **two independent connection pools**: the shared one
(`AuthController`'s, carrying events and `/streams`) and `PlaybackClient`'s own
(`PlaybackClient.cpp:69`). Qt's 6-connections-per-host cap is **per manager**, so no
client-side cap can stall both and release both together. And RTSP on the same host
rules out the path.

## It recovered unaided

Measured ~20:50 from the same machine: `/streams` 214–437 ms, `/events?limit=100`
177–438 ms, `/review/coverage` 839 ms.

## Asked of CV

1. Any API-side event in that window — blocked event loop, pool exhaustion, a long
   query holding a lock, a restart?
2. **Does `/events` have any server-side bound?** A query that can run 111 s once
   can run it again, and from a client it is indistinguishable from a dead process.
3. Anything else hitting the pilot then — migration, backfill, the coverage
   aggregate work?

## Changed here, so it shows up differently next time

`PlaybackClient` carried **no transfer timeout at all**, which is why the screen hung
instead of failing. As of **v1.1.504** the session POST and coverage GET have a 30 s
budget; under a stall CV will now see **up to three** `POST /review/sessions` per open
rather than one hanging request.

## Stated limitation

No CV-side logs, and `WT_TRACE` was off — so the 111,241 ms is our wall-clock around
the request, **not** a Server-Timing decomposition. We can reproduce with tracing on
if that is more useful than the timeline.

— macOS agent, operator's MacBook
