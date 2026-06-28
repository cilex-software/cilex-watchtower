# Re: continuous-timeline manifest + the span cap — confirmations, a validation pack, three follow-ups

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-28
**Re:** your 2026-06-28 reply on `2026-06-27-playback-seek-discontinuities-and-session-span`

This is exactly the shape we hoped for. The PTS=0 root cause, the route-B-then-A split, and especially the
honest "continuous *within a run*, discontinuity only at *genuine* boundaries" framing are the right contract
for us. Below: one correction that makes your spike easier, the validation pack you asked for, answers to
your two questions, and three small follow-ups so both halves land cleanly. **Take the 48 h cap and start
the spike whenever — nothing here blocks you;** the one thing we actively need back is §4(ii).

## 1. It's FFmpeg, not GStreamer hlsdemux2 — which makes your validation a one-liner

You refer to "your hlsdemux2." We're actually on **Qt 6.8's default FFmpeg backend → libavformat's `hls`
demuxer (`hls.c`)**, not GStreamer's `hlsdemux2`. Proof, straight from our player's av_log on a normal motion
clip (attached, `2026-06-28-ffmpeg-hls-discontinuity-sample.log`):

```
[hls @ 0x…] Skip ('#EXT-X-PROGRAM-DATE-TIME:2026-06-26T14:36:51…')
[hls @ 0x…] Skip ('#EXT-X-DISCONTINUITY')
[hls @ 0x…] Skip ('#EXT-X-PROGRAM-DATE-TIME:2026-06-26T14:36:55…')
[hls @ 0x…] Skip ('#EXT-X-DISCONTINUITY')
…
```

The `[hls @ …]` prefix is libavformat. **Why this helps you:** the `ffmpeg`/`ffprobe` CLI use that *same*
`hls.c`, so a one-line ffmpeg seek faithfully reproduces what stalls in our player — you can validate the
continuous-timeline build **without touching Watchtower at all**. (We'll still run our end-to-end Qt harness
against your build to confirm the full pipeline — §2b.)

## 2. Validation pack (what you asked for)

**(a) The faithful demuxer reproducer** — committed: `docs/letters/2026-06-28-hlsseek-repro.sh`. Core:

```
for T in 5 30 60 120 300 600; do
  ffmpeg -nostdin -loglevel warning -ss "$T" -i "<review playlist .m3u8>" -frames:v 1 -y /tmp/seek_$T.png
done            # -ss BEFORE -i = a demuxer-level input seek — exactly the path that stalls
```
**Today:** seeks past the first fragment FAIL/HANG. **Continuous build:** a frame decodes at every `T`, until
a genuine boundary. Run it against your current build first to confirm you're reproducing the stall, then the
spike build. Camera `.108` (HEVC 1440p main), a normal 1 h span, a motion clip with no `no_recording` gap
inside it.

**(b) The end-to-end Qt harness (faithful to the operator experience).** Our client has `WT_SEEK_TEST` (the
Playback wall) and `WT_HERO_TEST` (the Triage hero); both drive random seeks across ±1 s…±5 m and measure
**seek command → first actually-rendered frame** off the video sink, reporting per-jump-size frozen% +
latency. Our backend base URL is configurable, so **just send us your spike build's URL and we'll run the
full harness against it and return the per-step table** — that's the real "does the Qt pipeline seek land"
proof on top of your ffmpeg check.

**(c) The current-stall baseline to reproduce** — committed `docs/perf/2026-06-28-triage-hero-latency.before.*`
(camera `.106`): seeks ≥ 10 s froze **58–79 %** (no frame in 1.8 s); our re-open workaround took that to 0 %.
A continuous timeline should reproduce the 0 % **without** re-opening.

**(d) The attached av_log** is `.106`, but the per-fragment-discontinuity pattern is camera-independent (it's
the PTS=0 rebasing you traced), so `.108` behaves identically.

## 3. Your questions, answered

**"Confirm the target span you want operators to have."**

- **Take the 48 h bump now — yes please.** It covers the overwhelming majority of review (a recent incident +
  its lead-up), and as you note it stays within one PTS-wrap so it composes with Ask 1. **No client change
  needed:** we don't enforce a window cap — the client requests whatever span the operator navigates to and
  relies on your guard — so a 48 h ceiling lifts us automatically. We'll re-test at 48 h once you land it.
- **True multi-day is desirable but not a launch blocker.** The natural target is **"match retention"** — so
  an operator can review anything still on disk. We've only *measured* ≥ 4 days; **what is the configured
  retention?** We'd scope the multi-day follow-up (your manifest parse-cache / windowing) to exactly that.
  So: **48 h now; multi-day = retention, as a later follow-up** we'd value for investigations.

## 4. Three follow-ups from us

**(i) Route B — does the per-fragment *manifest* stay identical?** Our playhead↔wall mapping, the scrubber,
the timeline markers, Coverage, and export windows are all built from the manifest's per-fragment
`compact_start` / `compact_end` / `wall_start` / `wall_end` (your `review.py:271` values). If route B only
changes the **delivered** PTS (`-output_ts_offset`) and leaves those fields byte-identical, it is completely
transparent to us — ship it and we change nothing. If `compact_start/end` instead shift to express the new
continuous timeline, just say so and we adjust the mapping (a small change, but we need to know it's coming).

**(ii) Please MARK the discontinuities you keep — this is the one thing we need back.** Your caveat is the key
client contract: across a genuine boundary (real gap / `media_epoch` change / codec / profile, plus the
route-A ~26.5 h PTS-wrap) the seek still stalls, and there our re-open is the right tool. To fire the re-open
**only** at those boundaries — instead of every-far-seek (today) or never-and-stall — the client must know
**where they are, from the manifest.** Can you expose them per-fragment — e.g. `discontinuity: true`, or
better `boundary: "gap" | "epoch" | "codec" | "profile" | "pts_wrap"` on the fragment that starts each new
continuous run? We already read `media_epoch` and the gap markers; if codec/profile/pts-wrap are also
derivable per-fragment we'll detect boundaries ourselves, but a single explicit flag is cleaner and
future-proofs us against new boundary kinds. **What would you prefer to expose?**

**(iii) Mosaic path — same issue, later (nothing to do now).** Route B is scoped to the single-camera review
playlist, which is exactly our two seek surfaces (the Triage hero + the Playback wall both use
`/review/sessions`) — so it covers everything we scrub today; thank you. The multicam wall uses
`/review/mosaic-sessions`, which we don't scrub yet — but when we add that, does the mosaic HLS carry the same
per-segment discontinuity? Purely forward-looking.

## 5. What we're doing on our side

- **Now:** the validation pack (reproducer + harness hook + the `.106` baseline + the av_log) is committed and
  ready. Send your spike build URL and we'll run the full Qt harness against it.
- **When you land the 48 h cap:** we re-test review at 48 h (no client change expected).
- **When you ship continuous-HLS:** we relax the re-open to fire **only** across the boundaries you mark
  (§4-ii), so the scrubbing-driven leak drops to near-nothing exactly as you predicted — keeping the re-open
  as the fallback for those boundaries.

So: grab the 48 h cap, run the spike from §2 (or hand us the build URL), and tell us how you'll mark the kept
discontinuities (§4-ii) — that unblocks the client half. Everything here is under `docs/letters/` + `docs/perf/`.

— Watchtower client team
