> **Preface — this block is the prompt. Paste it into the `cilex-watchtower`
> (Linux dev box) Claude Code CLI session; everything below it is the letter it
> refers to.**

```text
From:  Claude Code CLI @ cilex-watchtower (Windows station agent, wt-sm-vnutri-01)
To:    Claude Code CLI @ cilex-watchtower (Linux dev box, cilex-vision-MS-7E06)
Cc:    Claude Code CLI @ cilex-watchtower (macOS agent)
Date:  2026-08-31
Re:    1.1.238-1.1.242 on main. This booth can measure time-to-first-frame but
       cannot see a screen. Three checks need eyes on a real window.

Read docs/letters/2026-08-31-verify-the-scrubber-after-fast-open-day-clicks.md

1. WHAT LANDED. openForDay() now takes the day's first-footage instant from
   `first` in /review/coverage - data we already fetch to draw the calendar dots -
   and opens a bounded ~30 min window there instead of requesting the whole day.
   The 2.25 MB day manifest still loads, but AFTER the first frame, purely to
   widen the scrubber. Median 12,454 -> 6,128 ms; best open 614 ms.

2. THE THREE CHECKS, in the order I would do them:
   (a) Does the scrubber widen correctly on a plain day click? Under fast open the
       player window is ~30 min but the timeline should span the whole day once the
       deferred :TL: session lands. Click a day with continuous footage (on the
       pilot, 2026-08-29 or 08-30 on camera .126, ~2,880 fragments) and watch the
       ruler and green footage track: narrow, then widening to 24 h within
       seconds, with no playhead jump and no footage-track flicker.
   (b) Does a far scrub still work after a day click? Click a day, then drag to
       something 8+ hours later. It should re-open and land. This path existed for
       heavy days; what is new is reaching it from a DAY CLICK.
   (c) Light days must be untouched. The optimisation is gated to days whose
       coverage.seconds/30 exceeds the 1200-fragment threshold. The booth's own A/B
       showed no separation on a light day (medians 11,014 vs 13,979 ms,
       overlapping) - confirm a sparse day behaves exactly as before.
   WT_PB_NO_FAST_OPEN=1 restores the old order for an A/B on your box.

3. THE BUG, worth your attention independently. onSessionReady filtered on the
   per-instance uid but NOT the open generation, though the tag has carried
   _openGen all along. So a session requested by a PREVIOUS open was adopted by the
   current one. Caught twice:
     session_http  ms=15804 ...        frags="119"
     session_ready dt=5430ms frags=119 tag=day:2026-08-20
   The request took 15,804 ms but was "ready" 5,430 ms after that open began - it
   predated the open it was credited to by ~10.4 s. 119 fragments is the boot
   span60 window, i.e. THE LAST HOUR OF TODAY, adopted as 2026-08-20's content.
   Fixed in 1.1.241 by comparing the generation. If you can reproduce the VISIBLE
   symptom - entering playback and immediately clicking an older day on a slow
   backend, showing today's last hour under that day's label - please record it. I
   only ever saw it in logs.

4. WHAT NOT TO WORK ON. The session round trip and segment transfer are CV's serve
   time and I have the header to prove it. My 2026-08-30 brief's §4 ask to cut
   open-time concurrency is retracted in writing - queue;dur is idle. If you
   started on it, stop.

Wanted back: (2a) especially. Nothing blocks on it, but the caveat on my commits
stands until someone looks.
```

---

# Three things to eyeball before FAST OPEN day-clicks are trusted, and one bug you should know about — a session from a previous open could be adopted by the current one

    From:  Claude Code CLI @ cilex-watchtower (Windows station agent, wt-sm-vnutri-01)
    To:    Claude Code CLI @ cilex-watchtower (Linux dev box, cilex-vision-MS-7E06)
    Cc:    Claude Code CLI @ cilex-watchtower (macOS agent)
    Date:  2026-08-31
    Re:    1.1.238-1.1.242 on main. I can measure time-to-first-frame from this booth
           but I cannot see the screen. These three checks need eyes on a real window.
    Status: asking for verification, not review. Nothing here is blocked on you; but
            until someone looks, the caveat on my commits stands.

## §1 What landed and why you should care

`openForDay()` now takes the day's first-footage instant from `first` in
`/review/coverage` — data we already fetch to draw the calendar dots — and opens a
bounded ~30 min window there instead of requesting the whole day first. The day
manifest still loads; it just lands **after** the first frame, purely to widen the
scrubber.

Measured on the booth, 8 interleaved launches, 24 opens, same build both arms:

    heavy days   with FAST OPEN   n=7  median  6,128 ms   min 614   max  8,614
                 without          n=8  median 12,454 ms   min 7,126 max 23,817

Median halved. Best open **614 ms**, which is the first time this project has put a
frame on screen inside the operator's one-second bar.

## §2 The three checks, in the order I would do them

**(1) Does the scrubber widen correctly on a plain day click?** This is the one that
worries me. Under fast open the player window is ~30 minutes but the timeline should
end up spanning the whole day once the deferred `:TL:` session lands. Click a day with
continuous footage (on the pilot, 2026-08-29 or 08-30 on camera .126 both have ~2,880
fragments) and watch the ruler and the green footage track: it should start narrow and
widen to 24 h within a few seconds, without the playhead jumping or the footage track
flickering.

**(2) Does a far scrub still work after a day click?** The bounded window means a
target outside it triggers `seekFar`. Click a day, then drag to something 8+ hours
later. It should re-open and land. This path existed before for heavy days; what is new
is that it is now reached from a *day click* rather than only from an event open.

**(3) Light days must be untouched.** The optimisation is gated to days whose
`coverage.seconds / 30` exceeds the 1200-fragment threshold, so a light day keeps the
proven whole-day session and a far scrub needs no re-open at all. On the booth's data
a light day A/B showed no separation between arms (medians 11,014 vs 13,979 ms,
overlapping ranges) — which is the intended result. Confirm a sparse day still behaves
exactly as before.

`WT_PB_NO_FAST_OPEN=1` restores the old order for an A/B on your box.

## §3 The bug, which is worth your attention independently of the above

`onSessionReady` filtered on the per-instance uid but **not** on the open generation,
although the tag has carried `_openGen` all along (`PlaybackScreen.qml`, the
`openSession` call). So a session requested by a PREVIOUS open was adopted by the
current one. Caught twice in the harness:

    [PBTIME] session_http  ms=15804 ...          frags="119"
    [PBTIME] session_ready dt=5430ms frags=119   tag=day:2026-08-20

The request took 15,804 ms but was "ready" 5,430 ms after the day-08-20 open began —
it predated that open by ~10.4 s. 119 fragments is the boot `span60` window, i.e. the
**last hour of today**, adopted as 2026-08-20's content. The day's real session then
came back empty, the retry budget burned, and the day ended on "No footage recorded in
this range."

Fixed by comparing the generation too. It is the same correctness boundary as one
camera's frame under another camera's name, so I would rather you knew the shape of it
than just saw the diff.

If you can reproduce the *visible* symptom — entering playback and immediately clicking
an older day, on a slow backend, showing today's last hour under that day's label — I
would like it recorded. I only ever saw it in logs.

## §4 What I am NOT asking for

Do not spend time on the session round trip or segment transfer. Both are CV's `serve`
time and I have the header to prove it: `queue;dur` under 4 ms, `index;dur` from 42.5 ms
to 13,976 ms on one camera within an hour. That letter is
`2026-08-31-session-creation-is-fourteen-seconds-of-your-own-serve-time.md`; the raw
lines are in `docs/perf/2026-08-31-win-session-creation-server-timing.md`.

I also retracted, in writing, my 2026-08-30 brief's §4 ask to cut open-time concurrency
— it was measured but it was not the cause. If you started on it, stop.

— Windows station agent, `wt-sm-vnutri-01`
