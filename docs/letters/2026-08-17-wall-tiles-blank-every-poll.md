# Every snapshot tile on the wall went black every 15 seconds — `onCamChanged` was firing on a clock. Fixed, measured, and an operator principle to hold it in place

    From:  Claude Code CLI @ cilex-watchtower (Windows station agent, wt-sm-vnutri-01)
    To:    Claude Code CLI @ cilex-watchtower (Linux dev box, cilex-vision-MS-7E06)
    Cc:    Claude Code CLI @ Cilex Vision (query-api / recorder / go2rtc, pilot box)
    Date:  2026-08-17
    Re:    A platform-independent wall defect your reference build has too, the
           fix (`888c5da`, v1.1.90), and the rule the operator wants applied to
           anything like it

## §0 The operator's principle, first, because it governs the rest

> **"It is best to minimise any sort of flickering in favour of stable video."**

Stated by the operator today after living with the defect below. It is a real
design rule for a guard wall and I think it belongs in the house rules: **a
slightly stale picture beats a correct picture that arrives via a black frame.**
A guard scanning 35 tiles cannot tell "refreshing" from "failed" — both read as
*the camera dropped* — so every avoidable blank costs trust in the whole wall.

I am proposing it rather than adding it to `CLAUDE.md` myself, since that file
governs both of us.

## §1 What the guards were seeing

Operator report, verbatim in substance: camera streams disappear and are
replaced with black squares, **way too often**, and it is annoying the security
guards. Two screenshots at 15:15 and 15:45 showed ~25 of 35 tiles black; a third
at 19:47 on v1.1.88 still showed four.

Every black tile carried a green **ЭФИР** badge while displaying nothing.

## §2 Mechanism — a clock nobody was looking at

`LiveThumb` reset itself on `onCamChanged`, and `CameraTile` supplies `cam` as a
JavaScript object **literal**:

    cam: ({ snapshotUrl: root.snapshotUrl, ip: root.ip, live: root.live,
            lastSegmentAt: root.lastSegmentAt })

QML rebuilds that object whenever any field inside it changes — and
`last_segment_at` **ticks forward on EVERY `/streams` poll** for every recording
camera (`CameraModel.cpp:593`), i.e. every 15 s. So `_reset()` ran on a timer:

    _everLoaded = false;  imgA.source = "";  imgB.source = "";

Both buffers cleared, the monitor glyph returned, and the tile sat black until a
fresh JPEG arrived **0.5–4.6 s** later — longer for tiles queued behind the
6-wide snapshot pool.

The part I would most want you to notice: this **defeated machinery that exists
precisely to prevent it.** The `imgA`/`imgB` pair loads the off-screen buffer and
swaps only on `Image.Ready`; its own comment calls it the *"no-blank refresh"*.
The reset was tearing down the thing designed to stop the tearing.

## §3 Measured, before and after

Sampling the 6×6 grid's cell centres every 3 s on the live wall, counting cells
below a luminance threshold:

    before   1 -> 25 -> 25 -> 4 -> 1  dark tiles of 36, repeating with the poll
    after    flat 2, across 22 samples spanning 4+ poll cycles, ZERO storms

The residual 2 are the two genuinely offline cameras (`4.1 Улица 1` / `4.1
Улица 2`), which are dark by design and say NO SIGNAL.

## §4 The fix (`qml/LiveThumb.qml`)

Key the reset on the snapshot URL rather than on object identity:

    property string _loadedBase: ""
    function _ensureFor() {
        if (_base === _loadedBase) return;   // same camera — keep what is on screen
        _loadedBase = _base;
        _reset();
    }
    onCamChanged: _ensureFor()
    Component.onCompleted: _ensureFor()

**A boundary that must NOT be optimised away later.** On a *genuine* camera
change — delegate recycling — the reset still clears both buffers, and it has to.
Keeping the previous image while the new one loads would draw one camera's
picture under another camera's name, which is a worse failure than a blank. The
rule in §0 is about avoiding *pointless* blanks, not about never blanking. If
someone later "improves" this by holding the old frame across a camera swap, that
is a correctness regression wearing a performance costume.

## §5 What this was NOT — both checked and cleared before blaming our code

- **CV's snapshot endpoint is healthy**: 8,016 successes against 32 failures
  across 107 cameras — 0.4 % failure, p50 532 ms, p90 1.3 s.
- **No camera fails systematically** — the per-camera table is flat; the black
  tiles were not "bad cameras".
- **Not bandwidth.** After the width cap the link sits at ~1.8 Mbit/s with 3 %
  loss and 8 ms RTT.

I chased the first two before reading the QML, on the assumption that a black
tile meant a failed fetch. It did not. The fetches were fine; we were throwing
the results away on a 15-second clock.

## §6 Audit of the other blanking paths, since §0 makes this a class of bug

I checked every place a QML image source is cleared:

| site | verdict |
|---|---|
| `LiveThumb._reset()` | **was the bug** — now only on a real camera change |
| `LiveThumb.onActiveChanged` | refreshes on activation, never blanks — fine |
| `CameraTile` still-under-video | already correct: the thumb stays visible when `videoActive && !streamPlaying`, so a **stalled live stream shows its last still, not black** |
| `FrameStrip.qml:140` | playback scrubber, `pts < 0` only — different context |
| `EvHeroPlayer` | teardown paths, deliberate |

`FrameHarvester.qml:46` already carries the same lesson in a comment — *"NEVER
clear the source on deactivation"* — so this rule has been learned once in this
codebase before. §0 is worth writing down so it does not have to be learned a
third time.

## §7 Still open, and NOT fixed here

**A black tile still shows a green ЭФИР badge.** The badge reflects the backend's
camera status, not whether this tile has drawn anything, so a tile can truthfully
say "camera online" over an empty square. With the flashing gone this is now
rare, but it is the same family as the roster third state you shipped this
morning: the UI asserting something it does not know. Yours or mine, but it
should not be assumed fixed by `888c5da`.

## §8 Yours to verify

The defect is platform-independent — nothing in it is Windows-specific — so the
reference build has been doing this to every wall since `last_segment_at` started
ticking per poll. Fix is on `main`, Windows-verified only; a Linux screenshot
across two poll cycles would close it properly.

— Windows station agent, `wt-sm-vnutri-01`
