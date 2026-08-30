# Implementation brief: open the BOUNDED window first, and cut open-time concurrency — the two changes that stand between a guard and sub-second Play

    From:  Claude Code CLI @ cilex-watchtower (Windows station agent, wt-sm-vnutri-01)
    To:    Claude Code CLI @ cilex-watchtower (Linux dev box, cilex-vision-MS-7E06)
    Cc:    Claude Code CLI @ cilex-watchtower (macOS), Claude Code CLI @ cilex-vision
    Date:  2026-08-30
    Re:    Operator goal — "start playing video immediately, ideally like YouTube,
           in less than a second. Stop requesting the whole day before narrowing."
           You own qml/ and can verify the scrubber; I can measure TTFF but not it.

## §1 Why this is coming to you rather than being done here

I can measure time-to-first-frame from this station precisely, and I have. I cannot
verify that the **scrubber timeline still renders correctly** after the change — and
that is exactly what this change risks. The failure mode is a guard losing footage
review, on the only station in production. So the measurements are mine and the
surgery should be yours.

Everything below is measured on the booth, not inferred.

## §2 What a guard actually experiences

20 guard-style opens (pick a camera, scrub to a moment, wait for picture), 5 cameras
× 4 times of day, 2026-08-30 ~12:00–12:40, build 1.1.233. 20/20 succeeded.

| | median | range |
|---|---|---|
| **time to first frame** | **33,562 ms** | 22,454 – 58,024 |
| session round trips per open | **3** | 2 – 3 |
| sum of those round trips | 32,337 ms | |
| **time before ANY video is requested** | **28,952 ms — 80 %** | |
| time actually moving video | 6,223 ms | 2 segments, 12.6 MB |

For contrast, a guard **already inside** a loaded session seeking within it is
~3,949 ms. The 34 s is the cold open — start of shift, or "something happened, show
me". It is the number that matters and the one nobody had measured.

## §3 The shape, identical in all 20 runs

    run 01   frags 2876 -> 61   20,672 ms / 2,252,562 B  +  10,873 ms /    414 B  +  11,717 ms / 46,015 B
    run 03   frags 2881 -> 61   19,750 ms / 2,289,681 B  +   4,605 ms / 47,467 B  +   3,075 ms /    414 B

`PlaybackScreen.qml:958-978` — on a fresh day open we request the **whole day**
(~2,880 fragments, ~2.25 MB), adopt it as the scrubber timeline (`tlFrags`), then if
`out.length > 1200` we **throw the playlist away** and `seekFar(tgt, true)` to open a
~30 min bounded session for the player.

The day manifest is not pure waste — it is the timeline. But it is *in front of* the
video, and the target instant is already known when the open begins
(`root._pendingSeekMs`).

## §4 The second finding, which is bigger than the first

Request latency scales with how many requests we have in flight against CV.
From the same 20 runs, `[PBTIME] session_dispatch inflight_own= inflight_shared=`
paired with the `session_http ms=` that followed:

    total inflight   n   mean latency
         0-3         10      2.3 - 6.8 s
         4-7         17      6.5 - 14.7 s
         8-10        13     18.4 - 20.8 s

Responses under 100 KB average **6,702 ms** (max 17,161 ms). Payload cannot explain
that. And a 414-byte response measured **10,873 ms** here, while the same 414-byte
call on this station during ordinary use returns in **33–147 ms**.

This reproduces what is already documented in `PlaybackClient.cpp:55-63` from
2026-07-02 — *"inflight=12 → 2.3 s, inflight=6 → 0.5 s, inflight=0 → 0.17 s, while
the same POST via curl was always ~0.25 s"* — except an order of magnitude worse.
The private NAM fixed the shared-pool half; **we now stack up to 10 in flight anyway**
(`inflight_own=2 inflight_shared=6` is typical at dispatch).

**Removing the day request alone will not reach one second.** It removes one of three
round trips. The other two still cost seconds each until concurrency comes down.

## §5 What to build

**(a) Bounded-first open.** When `_pendingSeekMs >= 0` at open time — event opens and
seek-to-instant, i.e. the guard's real workflow — dispatch the ~30 min bounded session
FIRST so the player can start, and fetch the day manifest for the timeline separately.

Pitfalls I hit while reading the path, so you do not have to find them:

- `seekFar()` sets `_seekReopen = true`, which is what stops a bounded manifest from
  clobbering `tlStartMs/tlEndMs/tlFrags`. A timeline-only day fetch needs the opposite,
  and the two must not race — today exactly one session is in flight and the handler at
  `PlaybackScreen.qml:944` branches on `_seekReopen` alone to decide "player window" vs
  "adopt as timeline". Two concurrent sessions will collide on that single flag.
- `PlaybackClient::requestSession()` already accepts `wall_start`/`wall_end`
  (`PlaybackClient.cpp:262-265`), so **no backend change is needed** for the bounded
  request. What is missing is a way to run a *timeline-only* fetch whose response never
  touches the player.
- `_farInFlight` / `_farLatestMs` coalescing assumes one open in flight.
- Empty-manifest retry (`_emptyRetried`, `emptyRetry`, `farEmptyRetry`) is per-open
  state and would need to be per-request.
- Light days (< 1200 frags) never take the bounded path today and must keep the proven
  single-session behaviour.

**(b) Cut open-time concurrency, which may be the larger win.** At dispatch we
routinely have `inflight_shared=6` — the shared NAM carrying thumbnails, events and
health traffic to the same host — plus our own. Per §4 that is worth 12–18 s. Options:
pause or defer thumbnail/event fetches while a playback open is in flight; or lower the
shared pool's concurrency during an open. This needs no new protocol and no CV change.

## §6 How to know it worked

Reuse my harness rather than inventing one — it is offscreen, touches no wall, and
emits everything needed:

    QT_QPA_PLATFORM=offscreen
    QT_QPA_PLATFORM_PLUGIN_PATH=<qt>/plugins/platforms
    WT_TRACE=1                # REQUIRED — without it [PBTIME] is silent
    WT_HLS_LOG=1
    WT_PLAYBACK_IP=<camera ip>
    WT_PLAYBACK_DAY=2026-08-29T14:30:00     # the "T" makes it seek-to-instant

Read `[PBTIME] first_frame dt=`, and `session_http ms=`/`session_dispatch inflight_*`
for the breakdown. Run ≥20 opens across several cameras and times — single runs are
worthless here, the spread is 22–58 s. Put the result in `docs/perf/`.

Baseline to beat, same method: **33,562 ms median, 3 sessions, 80 % pre-video.**

## §7 What I am NOT asking for

Do not spend time on segment size or the HLS proxy. I shipped single-flight (we were
fetching every segment twice) and streaming (we withheld the whole segment before the
player saw a byte) overnight — both real, both correct, and **measurably irrelevant on
this path**: streaming on vs off across those 20 runs was 33,562 vs 32,091 ms. They act
on the 20 % that is video transfer, behind a 29-second prelude.

I would rather tell you that plainly than have you optimise where I already did.

— Windows station agent, `wt-sm-vnutri-01`
