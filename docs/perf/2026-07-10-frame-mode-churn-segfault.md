# P0 postmortem: frame-mode SIGSEGV under session churn (2026-07-10)

**Report (operator):** opening today's `.201` footage in frame mode showed an
all-black filmstrip; Jul 8 footage worked; switching back to today froze the
app, further fragment clicks froze it again, then SIGSEGV.

**Verdict: three distinct faults presenting as one report — all fixed, all
gdb/soak-verified the same day.**

## The crash, caught live

No core dump existed (`coredumpctl` empty), so a churn repro harness was built
(`WT_CHURNTEST`, below) and run under gdb. It reproduced the operator's crash
within the first minute — with a full backtrace:

```
[hls] Packet corrupt (stream = 0, dts = 6776010).           ← session churn interrupts segment IO
[AVHWFramesContext] Failed to sync surface 0x9a: 1          ← VA-API surface of a dead decoder
Error transferring the data to system memory: -5
Cannot map a video frame in ReadOnly mode!

Thread 1 "watchtower" received signal SIGSEGV
#2  qImageFromVideoFrame(QVideoFrame const&, ...)            libQt6Multimedia
#3  QVideoFrame::toImage() const
#4  FrameCache::captureFrame(QVideoFrame const&, bool)       ← our capture tap
#5  QObject::event                                           ← QUEUED delivery
```

## Root causes and fixes

### 1. SIGSEGV — frame-level use-after-free in the capture taps (the crash)

`FrameCache` connected to `QVideoSink::videoFrameChanged` with the default
`AutoConnection`. The FFmpeg backend emits from its delivery thread, so raw
`QVideoFrame`s were **queued to the GUI thread**. A session swap (fragment
click / day switch) destroys the old decoder and its `AVHWFramesContext`
between emission and delivery; `toImage()` on the stale frame then walks freed
memory. Corrupt-packet frames from interrupted segment IO made poison frames
frequent under churn — SIGSEGV followed within a few switches.

**Fix (`FrameCache.cpp`):** connect both taps with `Qt::DirectConnection` and
convert **at emission, on the delivery thread, while the decoder still owns
the surface**. Capture gates and `rev` became atomics; `isValid()`/null-image
guards drop corrupt frames gracefully. Side benefit: GPU readback + JPEG
encode moved off the GUI thread.

**Also removed the render-thread flavor of the same UAF:** harvest frames are
no longer rendered anywhere. `FrameCache` owns a render-less `QVideoSink`
(`FrameCache.harvestSink`), which the harvester `MediaPlayer` uses as
`videoOutput` — replacing the hidden `VideoOutput` + `attachHarvest` tap, and
with it the scene-graph texture import of churning-session frames and the
pointless GPU uploads at 2× decode rate.

### 2. Freezes — harvester violated both churn rules (the hangs)

The gappy day's session (284 fragments, **19 kept discontinuities**) exposed
two `FrameHarvester` faults:

- **Raw seeks across kept discontinuities** in `_fillAhead`/`_fillBehind` —
  the exact operation `seekToWall` exists to avoid, because it stalls the
  FFmpeg HLS demuxer. Jul 8's continuous session never triggered it.
- **The 4a14650 churn-UAF pattern on a second player**: `active` flaps on
  every session switch (frags empty transiently), and deactivation did
  `player.stop(); player.source = ""` on a mid-flight (often stalled)
  pipeline.

**Fix (`FrameHarvester.qml` + host):** churn-safe lifecycle — deactivate is
`pause()` + capture-off with the **source kept**; activation/source change is
a **single `setSource` swap**; `active` additionally gated on `!root.loading`.
New `crossesDisc` host bridge (same `_crossesBoundary` the stepper uses):
ahead-fill **rolls through** boundaries at 2× instead of seeking across;
behind-fill across a gap parks (cross-gap moves belong to the stepper's edge
fallback).

### 3. Blank strip on today's footage (the first symptom)

Today's footage opens at the **live edge**. There, `_fillAhead` parked
"at end" and the eval loop early-returned — every 300 ms, forever. The
behind-fill branch was unreachable, so nothing was ever cached: black
filmstrip, even though 48 frames of history sat on disk. Jul 8 opens at day
start → ahead-fill worked → "frames loaded fine".

**Fix:** at-end is computed in the eval loop and **falls through to
behind-fill** — at the live edge the strip fills from history.

## Verification — `WT_CHURNTEST`

New harness (inert unless set): `WT_CHURNTEST=<N>` + `WT_CHURN_ALT=<day>`
(+ `WT_PLAYBACK_IP`/`WT_PLAYBACK_DAY`/`WT_FRAME_MODE=1`) alternates
`openForDay` between the gappy day and a continuous day every 4.5 s with a
mid-fill fragment poke 2.6 s after each switch — the operator's crash gesture.

| Run | Build | Result |
|---|---|---|
| 1 | pre-fix (churn-safe source + disc-aware only) | `cache=0f harv=idle` on every 07-10 open (live-edge starvation visible); **SIGSEGV** in the first minute — backtrace above |
| 2 | full fix stack | **20/20 switches + 20 pokes, 0 crashes**; harvester filling on every switch; **146 corrupt packets absorbed** with zero `Cannot map` drops; final settle on the gappy day: `cache=228f/116.7MB` → **PASS** |

Soak command shape:

```
WT_PLAYBACK_IP=192.168.1.201 WT_PLAYBACK_DAY=2026-07-10 \
WT_CHURN_ALT=2026-07-08 WT_CHURNTEST=20 WT_FRAME_MODE=1 WT_TRACE=1 \
gdb -batch -return-child-result -ex run -ex "thread apply all bt" \
    --args build/watchtower
```

## Durable lessons

- **Never queue a raw `QVideoFrame` across threads.** Its hw surface belongs
  to the decoder; convert (`toImage`) synchronously inside the
  `videoFrameChanged` emission or accept a UAF window on every session swap.
- A second `MediaPlayer` inherits **all** the first one's churn rules
  (4a14650's keep-source protocol, never seek across kept discontinuities) —
  and adds one: don't render frames you only capture.
- "At end" is a state, not an error — a fill controller that early-returns on
  it starves every other branch.
