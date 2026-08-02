# Live-wall snapshots: cold-start population time + camera-add first capture

**From:** Watchtower
**To:** Cilex Vision
**Date:** 2026-08-02
**Scope:** one problem — how long `GET :8000/streams/cameras/<id>/snapshot` takes
to serve a first frame when nothing has been polling (fresh client start, newly
added cameras), and whether camera-add can trigger an immediate first capture.
Follow-up to the 2026-06-29 snapshot thread (your cached endpoint — which
otherwise works great and has kept go2rtc quiet since).

## 1. Why this got loud today

The 39-camera DS-I202(E) fleet came online today (~13:46 local — derived from
the wall's LIVE badge ages against a clocked screenshot). Watchtower caps live
decodes at 16 (raised from 9 today), so on this site **23 tiles are permanently
on the snapshot path** — it's now a first-class, guard-facing surface, not a
fallback. Three observations from today, in time order:

1. **First launch (~14:03, screenshot kept):** 9 live tiles (old cap), the other
   30 all showed our "no frame yet" placeholder — the endpoint returned nothing
   for them. They filled in over a period long enough that the operator asked us
   what was wrong ("pretty long time"; we did not stopwatch it).
2. **14:26, second client instance (measured):** launched *while* the first
   instance had been running 23 min (its capped tiles poll at 1 s, keeping your
   cache warm). Result: **all 39 tiles had imagery within ≤75 s of launch** —
   screenshot + telemetry on file.
3. **~14:39 relaunch (screenshot kept):** both prior instances closed a minute
   or two earlier; the relaunched wall showed **empty snapshot tiles again** —
   despite every camera being online 53 min and recording 38–51 min by then.

So this is not just new-camera provisioning: **every cold client start pays it**.
Warm cache = instant wall; cold cache = minutes of placeholders. With one client
per site (the normal deployment), every morning launch and every Warden-restart
is a cold start.

## 2. What the client does (so you can see our side of the loop)

Per capped visible tile: `GET <snapshot_url>?_r=<n>` (cookie auth), every 1 s.
After **3 consecutive failures the tile backs off to 15 s** until a first
success (added 2026-07 to stop 404 log-spam from expected-offline cameras);
one success returns it to 1 s.

We suspect this backoff **interacts badly with your ~10 s TTL** if a cold miss
returns an error immediately and fills asynchronously: the fill's 10 s freshness
window expires before our next 15 s poll, so a tile can stay in the miss loop
indefinitely — while any tile that once succeeds polls at 1 s and keeps itself
fresh forever. That bistable picture matches exactly what we see on the wall
(tiles come alive one by one, order random, over minutes). This is a hypothesis
— we have not seen your miss path — which is why the questions below.

## 3. The June commitments this touches

From your 2026-06-29 reply, the cached endpoint was specified as: per-camera
TTL ~10 s; single-flight per camera + a global semaphore (~3–4) for cold
producers; and — the key one — **"cold/404 fallback to a recent recorded
keyframe … so a cold producer returns a slightly-stale keyframe instead of a
404."** At 14:39 today the fleet had 38–51 minutes of recordings and cold
requests still rendered nothing. Either the keyframe fallback isn't deployed,
doesn't cover this fleet, or returns something our tiles treat as an error —
knowing which is most of this letter.

## 4. Questions

1. **Miss semantics:** when a request hits an expired/absent cache entry, does
   it block until a frame exists, or return an error immediately while filling
   in the background? And what happens when ~23–30 *distinct* cold cameras
   arrive at once — queued behind the semaphore, or rejected?
2. **Newly added cameras:** what is the expected time from "camera added" to
   "first frame in the snapshot cache"? Is there a periodic sweep, or is the
   cache filled only on demand?
3. **Camera-add trigger:** can adding a camera enqueue an immediate first
   capture (fire-and-forget, behind the same semaphore), so a brand-new site's
   wall is never blank on day one?
4. **Keyframe fallback status:** is the June cold-fallback live in the build we
   run against? If yes, what does it return for a camera whose producer is cold
   but whose recordings exist (status code + content) — so we can check whether
   our client mishandles it?

## 5. Asks (in priority order)

1. **Never serve "nothing" when any footage exists** — the June keyframe
   fallback (stale-while-revalidate): an old frame beats a placeholder on a
   security wall, every time.
2. **Camera-add → immediate first capture** into the cache.
3. **Tell us the miss semantics** (Q1), and we'll shape the client to match:
   we're ready to hold never-loaded tiles at 1 s for the first minutes
   ("cold-start grace") or to call a batch warm hint once per launch if you'd
   prefer one governed sweep over 23 independent pollers. We're deliberately
   not changing our backoff until your answer, so we fix the real side of the
   loop instead of papering over it.

Screenshots (14:03 / 14:26 / 14:40) and the 14:26 telemetry log are on file —
say the word and we'll bundle them.

— Watchtower
