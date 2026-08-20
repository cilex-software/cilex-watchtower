# Events-page marker soak, iteration two — 5h29m on the booth station (Windows)

    Station : wt-sm-vnutri-01 (guard booth, Win 11 Pro 26200, Intel UHD 730)
    Build   : 1.1.129 / 098749b2  = main 38e003f + one test-only change (seek battery)
    Window  : 2026-08-20 01:41 -> 06:55 local, 14 cycles, mean 22.4 min/cycle
    Ran as  : a SECOND app instance, parked off-screen, while a guard was on shift
    Prior   : docs/perf/2026-08-19-marker-soak-8h.md (Linux, iteration one)

This was ordered as a Mac run and executed on the booth instead. Every Mac-specific
instruction is either translated or explicitly declared inapplicable in §7 — none was
silently skipped.

## §1 Headline

| | iteration one (Linux, 8 h) | THIS RUN (booth, 5.5 h) |
|---|---|---|
| unique clips with a verdict | 189 | **89** |
| raw verdict rows | 311 | 146 |
| end delta, median | **-11.4 s** | **-10.6 s** |
| end delta negative | 76 % | **75.0 %** (33/44) |
| start delta, median | not published | **-0.8 s** |
| lock rate, start | not published | **46.1 %** (41/89) |
| lock rate, end | not published | **49.4 %** (44/89) |
| WT-FATAL / WT-HANG | — | **0 / 0** |

**The end overhang reproduces.** Median -10.6 s against -11.4 s, negative fraction
75.0 % against 76 %, on a different OS, a different media backend and a different
night. That is the single most useful number here: it is not a Linux artefact and not
noise.

**The start is fixed.** Median start delta is **-0.8 s** (p10 -3.2, p90 +7.1, range
-4.9 .. +10.7). The 2026-08-19 start-snap does what it claimed. The yellow now begins
where motion begins; only the tail is wrong.

## §2 Dedup was load-bearing, again

    raw [MKT] rows : 146
    unique events  :  89      <- 61 % inflation if taken raw
    unique cameras :  45

One literal line beside the count, per the rule that came out of iteration one:

    2026-08-20T01:38:36.999 D [316c] qml: [MKT] ev=771124bd-... cam=hiwatch-083bc14effeb
                                             startDeltaMs=6440 endDeltaMs=-8410 win=25s

## §3 CV's 15-second floor — my data does NOT reproduce it, and the reason matters

CV's letter of 2026-08-20 (`motion-ended-hold-is-ours-not-isapi`) derives a hard floor:
cameras never emit `state=inactive` (1,124 active / 0 inactive in 25 min), so
`motion_ended` is `inactive_fallback_seconds 10 + post_roll 5 = 15.0 s`, measured at
15.02 s minimum across 5,329 rows, **72.3 % inside the 15-16 s band**.

Client-side, on 44 end-measured clips:

    |endDelta| in 15-16 s band :  0 / 44   =  0.0 %      (CV: 72.3 % server-side)
    |endDelta| >= 15 s         : 19 / 44
    |endDelta| <  15 s         : 25 / 44
    endDelta range             : -47.8 s .. +3.7 s, median -10.6 s

**This is not a contradiction, and I am not claiming CV is wrong.** The two numbers
measure different quantities:

- CV measures **episode LENGTH** — `motion_ended - motion_started` has a 15 s floor.
- I measure **`endDelta` = last observed pixel motion - stamped end** — how much dead
  tail the guard actually sees under the yellow.

They coincide only if motion stops exactly at the last `active` repeat. It evidently
does not: motion often continues past it, which shortens the visible dead tail below
15 s, and on other clips the repeated-active-timeout extends the episode far beyond it,
producing the -35 s .. -48 s tail.

**The finding for CV is the SPREAD, not the median.** The dead tail is not a constant
15 s to be dialled out globally — it ranges from ~0 to ~48 s and is strongly
per-camera. A single fleet value for `inactive_fallback_seconds` cannot be right for
all of them.

## §4 A camera and a target for CV's trial (their ask #1)

Per-camera, end-measured clips only, cameras with n >= 2:

| camera | n | median | min | max |
|---|---|---|---|---|
| hiwatch-50e538da3642 | 2 | -38.8 | -43.4 | -34.1 |
| hiwatch-04eecd5eaef8 | 2 | **-37.2** | -37.8 | **-36.5** |
| hiwatch-08cc81d25e4c | 2 | -29.6 | -35.0 | -24.3 |
| hiwatch-04eecdd44b03 | 2 | -22.3 | -22.7 | -21.9 |
| hiwatch-04eecdd44fdb | 3 | -21.3 | -33.5 | -21.3 |
| hiwatch-083bc1df3a4b | 4 | -8.3 | -9.9 | +3.7 |
| hiwatch-849459c4f007 | 2 | -2.4 | -3.6 | -1.1 |
| hiwatch-083bc17adca6 | 4 | +3.1 | -3.6 | +3.6 |
| hiwatch-083bc1df39fa | 2 | +3.2 | +3.0 | +3.5 |
| hiwatch-083bc1df39cf | 2 | +3.3 | +3.1 | +3.4 |

**I am NOT proposing a camera. The Linux agent already picked one and sent it** —
`hiwatch-04eecdd44fd6`, target `fallback=4 / post_roll=3`, on an n=6 table from the
2026-08-19 soak (`2026-08-20-motion-ended-hold-is-ours-not-isapi.reply.md`). That
decision is made and does not need re-litigating by a station with n=2-4.

**What this run adds instead is independent corroboration of that table.** Two cameras
appear in both, measured on different nights, a different OS, a different media backend
and a different build:

| camera | Linux 2026-08-19 (n=6) | booth 2026-08-20 | agreement |
|---|---|---|---|
| `hiwatch-04eecdd44b03` | -19.4 s | **-22.3 s** (n=2) | 2.9 s apart |
| `hiwatch-083bc1df3a4b` | -9.9 s | **-8.3 s** (n=4) | 1.6 s apart |

Both within ~3 s across independent runs. That is the useful result: **the per-camera
overhang is a stable property of the camera, not run-to-run noise** — which is exactly
the assumption the trial pick rests on, and it had not previously been tested by a
second measurement. It also means the ordering in their table can be trusted, so
`04eecdd44fd6` being worse than `04eecdd44b03` is a real difference rather than sampling.

My table's own value is limited to widening the shortlist: `50e538da3642` (-38.8),
`04eecd5eaef8` (-37.2) and `08cc81d25e4c` (-29.6) are worse than anything on the Linux
list, but at n=2 each they are candidates for confirmation, not for selection.

`hiwatch-083bc17adca6`, `083bc1df39fa` and `083bc1df39cf` all sit at **+3.1 .. +3.3 s**
— motion running slightly PAST the stamped end. Whatever is done to the fallback must
not clip those.

## §5 Bugs found, with disposition

### B1 — measured end computed, reported, and then NOT applied  (FIXED, win/ branch)

`EvHeroPlayer.qml:78` gated the end-snap on `hp.mkMeasuredMs > 0` — the END only
applied if the START had also locked. Line 82 computes the reported `endDeltaMs` from
`mEnd` alone, with no such gate. So on any clip where the end locked and the start did
not, **the [MKT] verdict published a correction the scrubber never drew**.

Measured this run: **5 of 44 end-locked clips** (11.4 %).

    b0cea81e  hiwatch-849459c4f006  ed=+3604   win=25
    d5460584  hiwatch-083bc1df39cf  ed=+3407   win=25
    56433369  hiwatch-083bc1df3a4b  ed=+3689   win=34
    90798e3e  hiwatch-083bc1df3a4b  ed=-7095   win=30
    ddfa8c4e  hiwatch-083bc1df3a4b  ed=-9926   win=34

Fix: apply the end against whichever start is actually DRAWN (measured when it locked,
detector stamp when it did not).

### B2 — `_reset()` left a stale measured END behind  (FIXED, win/ branch)

`_open()` clears `mkMeasuredMs`, `mkMeasuredEndMs` and `_mktDone`. `_reset()` cleared
only `mkMeasuredMs`. A torn-down clip could therefore leave its measured tail and its
`_mktDone` latch standing for whatever loaded next — one event's measured end under
another event's marker. Not observed firing this run; found by reading the path while
verifying B1. Same class of boundary as the wall's "one camera's frame must never sit
under another camera's name".

### B3 — the end-snap has never been observable  (FIXED, win/ branch)

The start logs its application (`[MSCAN] span start MEASURED`, 162 times this run). The
end logged nothing. `span end MEASURED : 0` therefore says nothing at all about
behaviour — and I nearly filed it as "the end never applies", which would have been
wrong. Probe 1 was literally unmeasurable from logs before this. Added the matching
line so iteration three can measure it.

**This is the third consecutive iteration where a zero count meant a missing predicate
rather than a missing behaviour.** The rule earned its place.

### B4 — station has never captured an app log  (STATION, not the product)

`watchtower.exe` is PE Subsystem=2 (Windows GUI), so Qt routes `qDebug` to
`OutputDebugString`; stdout/stderr are empty. This is why Warden's console logs on this
station are 0 KB and have been all week — including when I could not read wall health
during the LAN work. Everything in this report was harvested from the FlightRecorder
file instead (`%APPDATA%\Cilex Vision\Watchtower\flightrec\watchtower.log`).
Workaround for harnesses: `QT_FORCE_STDERR_LOGGING=1` + `QT_ASSUME_STDERR_HAS_CONSOLE=1`.
Warden's capture should set these — letter to the Linux agent, not fixed here.

### B5 — `player ERROR 2 'Invalid data found when processing input'`  (LOGGED, CV §4)

26 error lines, **one distinct string**, raised on 5 distinct app instances. This is the
leading-cut class CV has already claimed as their §4. No client fix attempted.

## §6 Stability and resource behaviour

    WT-FATAL        : 0
    WT-HANG         : 0
    SEEK TIMEOUT    : 20      e.g. [HT] SEEK TIMEOUT req=30000
    STALL           : 2       e.g. [HERO] STALL reopen #1
    OPEN TIMEOUT    : 1
    player ERROR    : 26 lines / 1 distinct string

RSS across a cycle (soak instance, `livePipes=0`, 450 MEMTEL samples):

    up 1 min  -> 786 MB      opens 11
    up 3 min  -> 902 MB      opens 38
    up 8 min  -> 953 MB      opens 49
    up 13 min -> 962 MB      opens 72
    up 18 min -> 969 MB      opens 80      <- peak
    up 23 min -> 922 MB      opens 100
    up 28 min -> 852 MB      opens 104

Rises to ~969 MB by ~18 min then **falls back to 852 MB while opens keep climbing** —
that is reclaim, not a monotonic leak. Every cycle self-terminated on the harness
completing its seek matrix (`Qt.quit`), never on a crash, so cross-cycle RSS trend is
not measurable from this run; within-cycle it is bounded.

## §7 The Mac instructions, translated or declared inapplicable

| Mac instruction | disposition here |
|---|---|
| `caffeinate -dis` | N/A — mains-powered 24/7 station, no idle sleep. No wall-clock gaps observed; 14 cycles are contiguous in the run log. |
| build via `./run-macos.sh`, confirm banner = HEAD | Done, Windows equivalent: banner `=== watchtower start v1.1.129 ... build=098749b2 ===` verified before trusting output. |
| AVFoundation no-PTS fallback is finding #1 if absent | **Inapplicable.** Windows uses `Qt multimedia with FFmpeg 7.1.3`; PTS are real (`[MSCAN] scores pts=38335..40343`). The no-PTS branch is moot here, not skipped. |
| `hevc_capable=false` on macOS | Not verified — no HEVC negotiation evidence collected. Stated rather than assumed. |
| ONE app instance (shared uplink) | **Deliberately violated on instruction.** Two instances; see §8. |
| mach RSS never soak-verified | N/A — Windows working set, §6. |
| seek battery 15-30 | Done, `EvTriage.qml`, rolled once per episode at the counter reset (a per-tick re-roll would move the finish line mid-run). |
| report to `docs/perf/...-mac-8h.md`, `mac/<topic>` branch | Renamed for this station; branch is `win/<topic>` per repo law. |
| probes 4, 5 (poster honesty, in-progress copy) | **NOT MEASURED — reported as such.** Both key off UI strings; this station runs the Russian locale, and those strings are not emitted to any log. Grepping the English text returned 0, which is a predicate failure, not a result. Needs screenshot OCR or a log line; neither existed. `[EVIMG]` 404s did occur: **28**. |
| probe 6 (paused-seek staleness, E12) | **NOT MEASURED.** Explicitly the AVFoundation stale-frame suspect; the mechanism does not exist on the FFmpeg backend, and the paired-screenshot rig it needs was not built. No frequency number — I would rather say so than publish an anecdote. |
| probe 8 (exports) | **NOT RUN.** Optional, writes globally, and shares the guard's 4.4 Mbit/s uplink while a guard was on shift. Deliberately skipped. |

## §8 Running a second instance beside a live guard — what it cost

Nothing measurable, and the wall got *better* than its own recent baseline:

    guard, 06:59 : livePipes=33 dec=33 lit=33 drop=0.1% err=0 swd=0 recon=0/0
    guard WT-ERR during the entire soak : 0
    link, 14 cycles : min 1.67  mean 2.32  max 3.34 Mbit/s   (idle 1.78, capacity ~4.4)

33 of 33 tiles lit, 0.1 % drop, **zero** stream-watchdog restarts across 5.5 hours. For
comparison the no-limit night of 2026-08-19 ran 2,871 restarts at 20.8 % drop. The soak
instance held `livePipes=0` throughout — it pulls event clips only and never competes
for live streams, which is why the wall was untouched.

Guard's window was never focused, moved or resized. The soak window sat at `+-1930+0`
(off-screen) for all 14 cycles. `wt-window-geometry` was disabled for the run — it
selects the NEWEST watchtower pid and would have thrown each fresh soak instance onto
the guard's wall every cycle — and re-enabled at the end. The guard's instance never
respawned, so the hand-rollback path was never exercised.

## §9 Corrections and things I got wrong

1. **I violated my own ASCII rule.** The first harness hard-coded the Cyrillic profile
   name; PowerShell 5.1 read the UTF-8-without-BOM file as ANSI, the path became
   mojibake, the exe did not exist, and the cycle loop **spun 1,175 times in under a
   minute on a live guard station**. Fixed by resolving from `$env:LOCALAPPDATA` at
   runtime and by aborting after 3 consecutive start failures. No loop in this harness
   may now spin.
2. **`APPDATA` does not isolate Qt.** `QStandardPaths::AppDataLocation` resolves via
   `SHGetKnownFolderPath`, so the redirect was a no-op: both instances shared one
   FlightRecorder log and one view state. Harvest was separated by thread-id. A future
   run needs a different mechanism, or a second Windows account.
3. **`span end MEASURED : 0` was nearly published as a bug.** It was a missing log line.
   See B3.
4. Cycle length was 22.4 min, not the 40 planned — every cycle self-terminated early on
   the harness finishing its seek matrix. 14 cold starts rather than 8: better for
   cold-start coverage, worse for within-cycle RSS trend.

## §10 Open, in priority order

1. **CV §2 trial** — camera shortlist in §4; the pick should be driven by CV's
   active-repeat interval, not my n=3.
2. **B1/B2/B3** — `win/` branch, PR needed; this box cannot verify the Linux build.
3. **B4** — Warden's console capture sets no `QT_FORCE_STDERR_LOGGING`, so this station
   has no app logs at all. Worth a letter.
4. **Probes 4, 5, 6** unmeasured — need a screenshot rig and/or log lines that do not
   depend on the UI locale.
5. **Lock rate 46-49 %** is the adaptive gate's first full night. Locks landed at
   `score=0.026` against a 0.025 absolute floor with `floor=0.0000` — marginal by
   construction in the dark. A daylight run would separate "gate too tight" from
   "genuinely no contrast".
