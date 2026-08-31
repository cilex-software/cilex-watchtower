# The per-segment discontinuity injection is NOT the startup bottleneck

**Station:** `wt-sm-vnutri-01` (guard booth, Win 11) · **Date:** 2026-09-01
**Build:** 1.1.295+ · **Backend:** `192.168.1.4:8000` (LAN)
**Verdict:** hypothesis **NOT SUPPORTED**. The v1 result was a run-order artefact.

## What was tested

`HlsProxy::rewritePlaylist` Pass 2 injects an `#EXT-X-DISCONTINUITY` before every
segment. macOS stopped doing this on 2026-08-17 after measuring that upstream
carries none ("pure fabrication for this player"); Windows and Linux kept it
because *"FFmpeg tolerates that"* — observed, never measured.

`WT_HLS_TRUST_DISC=1` (added 2026-09-01, `be97a11`, default OFF everywhere except
macOS) suppresses the injection so the two can be compared.

## The lever works — verified, not assumed

Counted from the process console, where the demuxer's `Skip (...)` lines actually
go (v1 counted them in `watchtower.log`, where FFmpeg never writes, and got 0 for
every arm — an unverifiable experiment):

    arm=ON   cam 126   disc=0     pdt=738   ratio 0
    arm=OFF  cam 126   disc=726   pdt=738   ratio 0.984
    arm=OFF  cam 118   disc=728   pdt=740   ratio 0.984
    arm=ON   cam 118   disc=0     pdt=616   ratio 0

So with injection on, ~99 % of segments handed to hlsdemux are flagged as timeline
breaks; with `WT_HLS_TRUST_DISC=1`, none are. The mechanism is exactly as read.

## v1 — and why it was wrong

v1 ran **OFF then ON for both cameras, on the same days**. Pooled median went
6,027 → 2,528 ms and camera 126 produced 687 / 706 / 905 ms opens. That looked
like the goal being met.

**It was the run order.** The ON arm inherited whatever the second pass over the
same camera and same days had already warmed.

## v2 — counterbalanced (126 ON→OFF, 118 OFF→ON), single session

Warm opens only (opens 2–6 of each launch; open 1 is the cold first-open case):

| camera | arm ran | ON median | OFF median |
|---|---|---|---|
| 126 | ON first | **1,071 ms** | 1,188 ms |
| 118 | OFF first | **7,235 ms** | 7,235 ms |

Camera 118: **identical**. Camera 126: 117 ms apart, on n=5 per cell with a spread
of 651–5,361 ms. That is not a signal.

### The number that settles it

Same arm, same camera, different position in the run:

    cam 126, arm OFF, ran FIRST  (v1)   warm median 4,292 ms
    cam 126, arm OFF, ran SECOND (v2)   warm median 1,188 ms

**3.6× on run order alone, with the arm held constant.** Run order dominates the
measurement; the arm does not move it.

## What this does establish

1. **Sub-second opens happen in BOTH arms.** cam 126 measured 651 and 748 ms with
   injection off, and 942 ms with it on. The link can already deliver sub-second
   opens on a warm path, with the 100 Mbit device still in place.
2. **The dominant variable is cold-vs-warm, not our playlist rewriting.** First
   opens ran 16,667–23,202 ms; later opens in the same process ran ~0.6–11 s.
3. **Removing the injection on Windows is neutral, not harmful.** Useful for the
   macOS/Windows divergence question: the platforms can be unified on the macOS
   behaviour without a Windows regression — but there is no performance reason to.

## Do not re-chase this

The injection is not the bottleneck. If someone reads the macOS comment
("pure fabrication for this player") and infers a Windows startup win, this is the
measurement that says otherwise. The lever stays for future A/B use; **the default
is unchanged on every platform.**

## Method note for the next person

Two flaws in v1, both mine, both worth avoiding:

- **Counterbalance the arms.** Running A-then-B for every subject confounds the arm
  with warming. Reverse the order for half the subjects.
- **Verify the arm took effect, from a source that actually carries the evidence.**
  v1's counters read a log FFmpeg does not write to and returned 0 for every arm;
  the experiment could not have detected its own failure.
