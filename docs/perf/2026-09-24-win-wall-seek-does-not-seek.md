# The 16-camera wall plays but does not SEEK — every mosaic segment is a discontinuity

Measured 2026-09-24 02:00–02:45 on **wt-sm-vnutri-01** (guard booth, i5-12400, Win 11),
app `1.1.599 c87b1b44-dirty`, as a second instance beside the guard's live wall.

Found while setting up an overnight soak of the wall. The soak's own failures are what
exposed it, and two of my intermediate conclusions were wrong — both are recorded below,
because the wrong turns are the reusable part.

## The finding

**Playback works. Seeking does not.**

    plays        pixel diff over 30 s, video area only:  23.3% of sampled pixels changed
    seeks        every in-stream seek times out at 22 s; the picture never moves

On a seek the client sets `player.position` and the readout jumps to the target — the
harness logged `pos=4200000` and `pos=3600000`, exactly the 70 min and 60 min it asked
for — but the demuxer never fetches the target segment. It keeps walking forward from
wherever it was:

    segment opens during a run with two seeks issued:  63 opens, min=0, max=62
    strictly sequential, MAX JUMP BETWEEN CONSECUTIVE OPENS = 1

A seek to ~70 minutes should land near segment 700. It never left the sixties.

## Why: the playlist has one discontinuity per segment, and that is UPSTREAM

Counted off the live proxy for a 6-hour session:

    #EXTINF          3591
    .ts segments     3591
    #EXT-X-DISCONTINUITY   3590        <- one before every segment
    #EXT-X-GAP          0
    #EXT-X-ENDLIST      1              <- VOD

This is **not** our injector. `HlsProxy::rewritePlaylist` injects a discontinuity before
every segment on Windows/Linux, so the obvious suspicion was that we were doing it to
ourselves. `WT_HLS_TRUST_DISC=1` takes the other branch, which only dedupes and drops
leading tags and **never injects** — so the count in that mode is upstream's own:

    trust mode (= what cilex-vision sends):  .ts=3594   DISCONTINUITY=3593

So the backend genuinely marks all 3,593 segment boundaries as timeline breaks. That is
defensible on its face — the HlsProxy header records that every review/mosaic segment is
encoded independently and RESETS its PTS, and a PTS reset is exactly what
`#EXT-X-DISCONTINUITY` is for. The consequence is that the playlist is 3,594 independent
timelines rather than one, and FFmpeg's HLS demuxer will not seek across them.

## Two wrong turns, recorded

**1. "The wall freezes after ~23 s."** It does not. That came from reading `frames=` in
the `[MEMTEL]`/`[WT-MEM]` lines, which is `RtspVideoSource::totalFramesDelivered()` — the
LIVE decode path. During wall playback `live_pipelines=0` and that counter cannot move.
It is the wrong instrument for this screen, and it sat still for exactly the reason it
should have. The demuxer opening `seg/45…62` while the counter was "frozen" is what gave
it away.

**2. "Our discontinuity injector is the cause."** Plausible, cheap to test, and wrong.
A/B'd with the lever the code itself provides for this question:

    injector ON  (Windows default)   240 frames (~20 s) in 100 s
    WT_HLS_TRUST_DISC=1              144 frames (~12 s) in 100 s

Both behave the same, because upstream already emits one per segment either way.

**3. A near-miss worth keeping.** The first frozen-vs-moving test ran in a 600x340
window and reported "FROZEN, 0.5% of pixels differ". At that size the wall renders no
grid at all — only chrome and the scrubber — so it measured the toolbar. Re-run at
1280x720 sampling only the grid interior: 23.3% differ, MOVING. **A soak window must be
big enough to draw the thing being soaked**, which is also why the runner uses 1280x720.

## What this means for the wall

The wall is for reviewing recorded footage, and navigating it is the point. Today the
only navigation that moves the picture is a **re-open** (a new mosaic session centred on
the target), which is why the perf harness separates `seek` from `reopen` at all. The
in-stream seek path updates the clock and leaves the video where it was — a silent no-op
control in the CLAUDE.md sense.

The client cannot fix this in the playlist: strip the discontinuities and the PTS resets
break playback, which is the failure the injector exists to prevent. It needs either
continuously-timestamped segments or a seekable index from the backend. Raised with
cilex-vision.

## Rig

`C:\wt\soak-runner.ps1`, isolated app at `C:\wt\soak-app` (1,564 hardlinks + a real
`watchtower.exe`), own flight recorder at `C:\wt\soak-flightrec`, 16 continuously-recorded
street cameras (`WT_WALLPERF_CAMS=102,105,…,130`). Runs as a second instance so the
guard's live wall keeps running; `wt-window-geometry` is paused for the duration because
it grabs the newest watchtower process and would move the soak window onto the guard's.
