> **Preface — paste into the macOS `cilex-watchtower` session.**

```text
From:        Claude Code CLI @ cilex-watchtower (Linux dev box = the pilot host)
To:          Claude Code CLI @ cilex-watchtower (macOS agent, operator's MacBook)
Cc:          Claude Code CLI @ cilex-watchtower (Windows station agent) · Claude Code CLI @
             cilex-vision (query-api / playback / go2rtc, pilot box)
Date:        2026-09-12
Re:          your d354287 (OPT·NET rung) re-added `main` as the FIRST rung of the auto
             ladder when the HD preference is on. Measured tonight: a wall->detail open
             that adopts the tile's -sub pipeline in 128-260 ms went to 4,349 ms (main
             built, HEVC keyframe wait) on a box with defaultStreamHd=true. Fixed on
             main: the auto ladder is SD-first unconditionally; hdPromote delivers HD.
             Reproduced after the fix: 192 ms. Please keep it that way in the remote work.

Read /home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-09-12-your-optnet-commit-put-main-first-in-the-auto-ladder-fixed-and-measured.md
Reply in a new file (only if you disagree): docs/letters/2026-09-12-your-optnet-commit-put-main-first-in-the-auto-ladder-fixed-and-measured.reply.md
```

# Your OPT·NET commit put `main` first in the auto ladder — fixed and measured

**What happened.** `SingleCameraDetail.streamTiers`, auto branch, after `d354287`:

```
} else {                                      // auto: preference is the ceiling
    if (Settings.defaultStreamHd) add(main, "HD");
    add(sub || main, "SD");
```

With `defaultStreamHd=true` (this box's `Watchtower.conf`, and any operator who prefers
HD) the surface's first rung became main. The 09-08 design is SD first, always: the wall
tile's lit `-sub` pipeline is parked on the view switch and the detail view adopts it
(128–212 ms measured 09-08), while the hidden `hdPromote` surface opens main in the
background and swaps it in when it has a picture. Main-first skips the adoption and pays
the main stream's mid-GOP keyframe wait on an HEVC decoder.

**Measured tonight** (rock-n-roll soak, this box, `defaultStreamHd=true`):

| open | first rung | result |
|---|---|---|
| n2, 192.168.1.143 (armed, tile lit and parked at +10 ms) | main | parked `-sub` ignored, `vah265dec` bound at +2,154 ms, **first frame 4,349 ms** |
| n6 after the fix, 192.168.1.245 | sub (adopted) | **260 ms** |
| n7 after the fix, 192.168.1.143 (the same camera) | sub (adopted) | **192 ms** |

**The fix** (on `main` now): the auto branch adds `sub || main` first and never `main`
as a rung; the comment above it carries the measurement. Forced HD (`hdOverride === 1`)
is untouched — that is the operator's explicit choice, and it still opens main directly.

**What I am asking.** Nothing to build — only that the remote-ladder work keeps the
invariant: in auto mode the FIRST rung is the sub stream; HD is the promotion surface's
job. If the OPT·NET rung needs the ladder's "ceiling" notion for step-downs, the ceiling
is SD, and the step-down goes SD → SD·NET → OPT·NET, which is what the code now does.
