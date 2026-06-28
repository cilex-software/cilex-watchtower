# Re: Playback seeks stall across HLS fragment discontinuities + the review-session span cap

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-28
**Re:** your 2026-06-27 letter (`2026-06-27-playback-seek-discontinuities-and-session-span.md`)

Thanks — this is a good piece of work, and the bisection in the 2026-06-28 update is exactly right.
Both asks are **feasible and entirely backend-side**, and I traced each to specific, intentional code.
Short version up front:

- **Ask 1 is real and the root cause is on our side.** The per-fragment `EXT-X-DISCONTINUITY` is
  deliberate — it's a consequence of every rendition `.ts` being rebased to **PTS=0**. The fix is to
  give a contiguous run **continuous PTS** so we can drop the discontinuities *within the run* and the
  span becomes one seekable timeline. Worth doing; ~1 week with a 2-day validation spike first.
- **I agree the ~8 MB/open leak is client/Qt, not us, and `DELETE` wouldn't touch it.** Your framing is
  correct: the only backend lever is *fewer source-changes*, which the continuous manifest delivers. So
  Ask 1 buys both the seek fix and the scrubbing-leak relief, as you say.
- **Ask 2 is not a bug, a fragment-count limit, or retention.** It's a hard `MAX_WINDOW_HOURS = 24`
  guard in `create_session` — a 36 h request gets an HTTP **400 "Window exceeds 24h maximum"** (which is
  surfacing to you as "empty"). Multi-day is on the table; details + the real scaling limiter below.

---

## Ask 1 — continuous-timeline manifest for contiguous spans

### Root cause (confirmed, with line refs)

Every review fragment is an independently-produced rendition (`playback-service/transcoder.py`
`transcode_segment` / `remux_segment`), and **both rebase timestamps to start at PTS=0**
(`-avoid_negative_ts make_zero` + `-fflags +genpts+igndts`, plus `setpts=PTS-STARTPTS` on the transcode
path — transcoder.py:82, 100, 163). That was done to strip the source recorder's ~1.4 s MPEG-TS preroll
that otherwise broke HLS.js seeking.

Because **each segment restarts at PTS 0**, consecutive segments jump backwards in PTS at every
boundary. An HLS demuxer only tolerates that if a `#EXT-X-DISCONTINUITY` precedes each segment — so we
emit one before **every** fragment (`playback-service/main.py:306`, the 2026-06-14 fix; without it even
*continuous playback* of a motion clip stalls on the seg→seg PTS jump-back). That per-segment
discontinuity is precisely what your hlsdemux2 cannot seek across. So: **PTS-zeroed renditions →
mandatory per-segment discontinuity → seek stall.** Your diagnosis is spot on.

### The fix

Make a **contiguous run carry continuous, monotonic PTS**, and emit `#EXT-X-DISCONTINUITY` **only at
genuine boundaries** — a real recording gap (`no_recording`), a `media_epoch` change, a codec change, or
a delivery-profile/resolution change. The manifest already tracks `media_epoch` and gaps, and codec +
profile are per-fragment, so boundary detection is essentially free. Within a contiguous, single-epoch,
single-profile run there are then **zero discontinuities** → one continuous VOD timeline → seeks land
anywhere without a re-open. We keep the 2026-06-14 anti-stall guarantee because the continuity is *real*
(continuous PTS), not assumed.

Two ways to produce the continuous PTS, and I'd ship them in this order:

- **(B) Serve-time offset — recommended first ship, low blast radius.** Keep cached segments PTS-0 as
  today, but apply `-output_ts_offset` per fragment on delivery, set to the fragment's timeline offset —
  which `build_manifest` *already computes* as `compact_start` (review.py:271). It's a stream-copy remux
  (no decode), scoped to the review-playlist path only, and touches **nothing** the mosaic/export share.
- **(A) Cache-native absolute-wall PTS — the end state.** Bake each rendition's first PTS from its
  absolute wall start (90 kHz) at transcode time. Deterministic per segment, so the per-
  `(segment_id, profile)` cache stays valid and shared. Caveat: MPEG-TS PTS is 33-bit @ 90 kHz →
  **wraps every ~26.5 h**, so we'd insert a discontinuity at each wrap, and it changes the rendition the
  mosaic + exporter also read (so it needs a regression pass on those).

**Honest caveat:** a continuous manifest fixes seeks *within a contiguous run*. A seek that crosses a
**genuine** boundary we keep (a real gap / epoch / codec change) will still hit a discontinuity and may
still stall hlsdemux2 — there, your re-open trick is still the right tool. But those boundaries are rare
and semantically meaningful (re-centring across a true recording gap is acceptable), versus today's
"every 30 s." Net effect for you: the re-open path goes from *every far scrub* to *only across true
discontinuities* — which is also where the scrubbing leak shrinks to near-nothing.

### What I need from you to commit it
Your instrumented seek harness + the exact camera/spans + the FFmpeg discontinuity log you offered — I
want to validate a continuous-timeline build against **hlsdemux2 specifically** before locking the
approach, since the whole value is "does the seek land." Camera `.108` (HEVC 1440p main) and a normal
1 h span is a fine first target.

---

## Ask 2 — the session-span cap

**It's an intentional guard, not retention and not fragment count.** `create_session` rejects any window
longer than `MAX_WINDOW_HOURS = 24` with a 400 (`services/query-api/routers/review.py:22, 376`). Your
36 h/48 h/72 h/240 h calls are getting that 400; the 1 h-window-96 h-ago calls succeed because the
*window* is 1 h. Retention is independent (you confirmed ≥ 4 days) and there's no fragment-count cap.

**Supported maximum today: 24 h.** Multi-day is feasible — but the real limiter isn't retention, it's the
**manifest itself**: 24 h ≈ 2,879 fragments ≈ ~1 MB of JSON, stored in `playback_sessions.manifest_jsonb`
and **re-parsed from JSONB on every playlist and every `/seg/{idx}.ts` request** (playback-service
`_load_session`, main.py:253). A 7-day span is ~20 k fragments / ~8 MB parsed per request — that's what
needs hardening before we offer true multi-day, not a bigger number.

My recommendation:
- I can raise the cap to **48 h** cheaply and safely now (one constant + a manifest-size check). That
  also stays under the ~26.5 h-per-timeline PTS-wrap with at most one wrap boundary, so it composes
  cleanly with the Ask 1 work.
- **True multi-day review (e.g. 7 days)** I'd do as a small follow-up: cache the parsed manifest on the
  session (skip the per-request JSONB re-parse) and/or window the manifest, plus the per-wrap
  discontinuity handling from Ask 1(A). Happy to scope it if multi-day is a product goal — just confirm
  the target span you actually want operators to have.

---

## Effort / timeline

| Item | Effort |
|---|---|
| **Ask 2 — raise cap to 48 h** (constant + manifest-size guard + test) | ~half a day |
| **Ask 1 — validation spike** (continuous-PTS + boundary-only discontinuity, proven against your hlsdemux2 seek harness) | ~2 days |
| **Ask 1 — productionize (route B)** (serve-time offset, boundary detection in the playlist, tests) | ~1 week incl. the spike |
| **Ask 1 — route A (cache-native) + mosaic/export regression + PTS-wrap** | +2–3 days, only if we want it cache-native |
| **Ask 2 — true multi-day** (manifest parse-cache / windowing) | ~2–3 days, on request |

Since none of this is blocking you, I'd suggest: I land the **48 h cap bump** this week, then run the
**Ask 1 spike with your harness** before committing route B. If the spike confirms hlsdemux2 seeks land
on a continuous timeline (I expect it will — it's the normal VOD case once the discontinuities are gone),
we schedule the ~1 week.

Send the harness + camera/spans + the FFmpeg log whenever — I'll start the spike from there.

— Cilex Vision backend
