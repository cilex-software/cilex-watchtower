# Playback soak — 6 hours on the booth station (Windows)

    Station : wt-sm-vnutri-01 (guard booth, Win 11 Pro 26200, Intel UHD 730)
    Build   : 1.1.141 / win/pb-soak  = main 6713080 + the WT_PB_SOAK driver
    Window  : 2026-08-21 01:00 -> 06:57 local, 8 cold-start cycles of 45 min
    Ran as  : a SECOND app instance from a PRIVATE copy of the app, parked off-screen,
              while a guard was on shift. The guard's app was NEVER restarted.
    Driver  : WT_PB_SOAK (new) — camera -> day -> scale -> random jump -> play -> repeat

Operator order: exercise the whole playback surface — open a camera, pick a random date
and time, change the scale (15M/1H/6H/12H/24H), jump to a random time, let it play, jump
again, a random number of times, then move to another camera.

## §1 Headline

**Half of all playback jumps never produced moving video, and not one of them reported
an error.**

    jumps (verdicts)          584        across 55 cameras, 6 days, all 5 scales
    played (playhead moved)   297        50.9 %
    did NOT play              287        49.1 %
      ... window was empty      8         2.8 % of failures — HONEST, nothing to play
      ... FOOTAGE WAS PRESENT 279        97.2 % of failures = 47.8 % of ALL jumps
      ... of those, frozen at exactly 0 ms advance : 268
    err=none on all 584 rows  584        every single failure was silent

One literal row, per the rule:

    [PBSOAK] VERDICT cam=hiwatch-04eecdd44f5c day=2026-08-19 span=720m target=05:56:24
             ttffMs=17979 frags=15 played=no advancedMs=0 err=none

`frags=15` says the backend delivered a manifest with fifteen fragments for that moment.
The footage exists. The picture never moved, and the UI said nothing was wrong.

## §2 Where it actually stalls — it is not the client and not the video

The app already stages every open ([PBTIME]); this is what those stages measured:

| stage | n | p50 | p90 | max |
|---|---|---|---|---|
| `session_ready` (HTTP session open) | 1337 | **9 913 ms** | 22 445 ms | 44 498 ms |
| `source_set` (hand the URL to the player) | 1191 | 9 945 ms | 21 964 ms | 44 500 ms |
| `first_frame` (rendered picture) | 338 | 16 275 ms | 29 444 ms | 48 046 ms |

`source_set` lands 32 ms after `session_ready` (`marshal=3ms`), so **the client does
nothing slow**. The ~10 s median is spent waiting for the session-open request to come
back, before a single byte of video is fetched.

    opens=1226   first_frame=338   ->  72.4 % of opens never rendered a frame

## §3 It is NOT manifest size — the request is waiting, not working

The obvious theory is that a 24-hour window marshals thousands of fragments. The data
refuses it:

| fragments returned | n | session_ready p50 |
|---|---|---|
| 0 | 80 | 5 937 ms |
| 1–50 | 804 | **10 042 ms** |
| 51–500 | 308 | 10 022 ms |
| 501–2 000 | 113 | **9 113 ms** |
| 2 001+ | 32 | 14 139 ms |

A 1–50 fragment manifest is *slower* than a 501–2 000 one. And the single most useful
row in the whole run:

    frags=3844  dt=1130 ms  tag=day:2026-08-18     <- 3 844 fragments in 1.1 seconds
    frags=3941  dt=20190 ms tag=day:2026-08-16     <- 3 941 fragments in 20.2 seconds

Same class of work, **18× apart**. The backend can clearly answer a huge manifest in
about a second. Most of the time it does not. That is a queue, not a computation.

**Where the queue is, I cannot tell from this end** — it is either the network path or
the session endpoint, and a client stopwatch cannot separate them. CV can, and that is
the letter that goes with this report.

## §4 Per-scale, since the order named all five

| scale | jumps | played | empty | did-not-play with footage | played % |
|---|---|---|---|---|---|
| 15M | 112 | 49 | 1 | 62 | 43.8 % |
| 1H | 114 | 63 | 0 | 51 | **55.3 %** |
| 6H | 112 | 61 | 1 | 50 | 54.5 % |
| 12H | 141 | 74 | 2 | 65 | 52.5 % |
| 24H | 105 | 50 | 4 | 51 | 47.6 % |

**No scale is safe and no scale is the culprit** — the spread is 43.8–55.3 %, and 15M,
the *smallest* window, is the worst. That is consistent with §3: the cost is not
proportional to how much you ask for.

## §5 The contrast that frames everything

A 4-minute smoke run at 00:24, on the same build and same station, with the link
otherwise **idle**:

    10 jumps, 10 played=yes, ttff 835 ms .. 6 984 ms, every scale exercised

Against the 6-hour run with the soak's own traffic on the link:

    584 jumps, 50.9 % played, ttff p50 16 147 ms on the jumps that DID play

**Same code, ~12× slower to first frame.** The difference is load on the path between
this booth and Cilex Vision.

## §6 A correction I owe: this link is roughly twice as fast as I have been saying

Every cycle sustained far more than the figure I have quoted repeatedly in letters and
analyses:

    per-cycle link rx : min 7.89  mean 8.48  max 9.28 Mbit/s   (8 cycles)

I have been reporting **~4.4 Mbit/s** as this link's capacity, from a single-stream
`iperf3`. That number was a single TCP stream, not the link ceiling — parallel HTTP
fetches reached **9.28 Mbit/s**. Anywhere I used 4.4 as "capacity" (the LAN-path
letters, the mosaic-proposal analysis) the headroom was understated by about half.
The measurement was right; the label on it was wrong.

This does not rescue §2: the wall's own 1.8 Mbit/s plus the soak's ~8.5 leaves the path
saturated, which is exactly when a 3 844-fragment manifest takes 20 s instead of 1.1 s.

## §7 What it is NOT — hypotheses killed

- **Not a leak or degradation.** played% by jump position is flat from jump 11 onward
  (40.3 / 53.4 / 51.4 / 46.6 / 54.2 / 50.0 / 52.4 / 57.1 %). Cycle 1 opened at 62.9 %
  and the rest sat at 45–54 %.
- **Not specific cameras.** Of 39 cameras with ≥6 jumps, **none** was at 0 % and **none**
  at 100 %. The worst sat near 29 %. It is probabilistic, fleet-wide.
- **Not client crashes.** 8 cycles, zero self-exits, zero `WT-FATAL`, zero
  `player ERROR`, one `STALL`, zero mislanded seeks.
- **Not RSS.** Cycle-end working set 1 120–1 326 MB across 8 cycles, no upward trend.

## §8 Coverage observations worth a second look

- **86 of 195 camera picks (44 %) never produced coverage within 30 s** and were skipped
  (`NO-COVERAGE`). The soak moved on, so this cost coverage, not correctness — but a
  guard opening those cameras waits on the same call.
- **Only 6 distinct days held footage** across 55 cameras, against a 35-day retention
  contract. Whether that is real retention or the same slow coverage call failing to
  report older days, this run cannot say — the two look identical from the client.
- **80 of 1 337 sessions returned an empty manifest** (`frags=0`). The app has silent
  single-retry paths for exactly this; they were not observed to be exhausted.

## §9 Honest limits of this run

1. **The 40-second budget truncates a real tail.** A jump was called `played=no` if
   nothing moved within 40 s. Successful first frames reached **48 046 ms**, so some
   failures would have started at 41–48 s. The finding is therefore
   *"did not start within 40 seconds"*, not *"never would"*. For a guard scrubbing an
   incident, 40 s is already a failure — but the distinction belongs on the record.
2. **`played` is measured as playhead advance over a 6–14 s dwell.** That is deliberate
   — a frozen picture and a healthy session are identical in every other signal — but it
   cannot distinguish "still buffering" from "wedged".
3. **The soak generated the load it then measured.** ~8.5 Mbit/s of its own traffic is
   heavier than one guard scrubbing. It is a stress test, not a typical shift. The
   idle-link smoke run in §5 is the control.
4. Both instances share one FlightRecorder log (`AppDataLocation` resolves via
   `SHGetKnownFolderPath`, so an `APPDATA` redirect is a no-op — carried over from
   2026-08-20). Harvest used the soak's own redirected stderr, which the
   `QT_FORCE_STDERR_LOGGING` pair makes non-empty on this GUI-subsystem binary.

## §10 The guard was not affected

    guard, 07:00 : livePipes=33 dec=33 lit=33 drop=0.2% err=0
    guard process: pid 20144, up 29.5 h, NEVER restarted for this run
    guard binary : still 1.1.129 — the soak ran 1.1.141 from C:\wt\pb-app

Windows locks a running executable, so staging the test build over the install would
have forced a restart. The soak got a **private copy of the whole application** instead:
zero downtime, against the ~20 s the 2026-08-20 run cost. The soak window sat at
`+-1930+0` for all 8 cycles and their window was never focused, moved or resized.
`wt-window-geometry` was parked for the run and restored after; the guard's wall never
respawned, so the hand-rollback path was not exercised.

## §11 Open

1. **CV: where does the ~10 s in session-open go?** §3 shows it is not payload size.
   Server-side timings on `/review/session` would separate backend queue from network
   queue in one measurement. Letter accompanies this report.
2. **The silent failure is a client bug regardless of the cause.** A window that holds
   fragments and renders nothing shows the guard a still picture with no indication that
   anything is wrong. Whatever CV finds, the app should say "still loading" — this is the
   same "absent data must never render as healthy" rule the wall lives by.
3. **44 % of cameras had no coverage within 30 s** (§8) — worth its own measurement.
