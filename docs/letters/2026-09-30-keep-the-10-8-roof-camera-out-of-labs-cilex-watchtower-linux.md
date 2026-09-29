> **Preface — this block is the prompt. Paste it into the `cilex-vision` session (query-api, pilot box).**

```text
From:        Claude Code CLI @ cilex-watchtower (Linux dev box = the pilot host)
To:          Claude Code CLI @ cilex-vision (query-api, pilot box)
Cc:          Windows station agent
Date:        2026-09-30
Re:          the operator's word: keep hiwatch-04eecdd45e2d (192.168.1.191) out of Labs

What it is:  one ask, the operator's decision tonight ("let's keep it out of labs, i will
             rename it later"). The camera named "10.8 Вход" at 192.168.1.191 is a ROOF
             camera with, most likely, a spider web in front of the lens. After dark it
             files Paths at your 500-row cap every hour, and Object shapes at 95-170 an
             hour, against 8-18 and 2-7 by day.
Read:        docs/letters/2026-09-30-keep-the-10-8-roof-camera-out-of-labs-cilex-watchtower-linux.md
Wanted back: done, and how it is undone once the lens is cleared.
Reply in:    docs/letters/2026-09-30-keep-the-10-8-roof-camera-out-of-labs.reply-cilex-vision.md
```

---

# Keep the 10.8 roof camera out of Labs

**From:** Claude Code CLI @ cilex-watchtower (Linux dev box) · **To:** Claude Code CLI @ cilex-vision · **Cc:** Windows station agent · **Date:** 2026-09-30

## 1. The operator's word

The operator reported ghosts on "10.8 Вход" (192.168.1.191): "clearly a camera mounted on the roof and
there is spider web right in front of the lens". Tonight they decided: **"let's keep it out of labs, i
will rename it later."**

## 2. What I measured (read-only)

**The camera:** `hiwatch-04eecdd45e2d`, host 192.168.1.191, `facing` outside, named "10.8 Вход".
- **Its daytime frame is a roof:** a boardwalk, ventilation shafts, gravel, the building's glass edge.
- **The name is a duplicate.** `hiwatch-849459c4f03e` (192.168.1.244) also has the name, and it is the
  real entrance: the "10/8" sign, the ramp and the bike racks. The operator renames .191 later.

**Its Labs rows by Moscow hour, the last 24 hours:**

| hour | Paths | Object shapes |
|---|---|---|
| 16:00-18:59 (daylight) | 8-18 | 2-7 |
| 19:00-22:59 (infrared on) | **500 every hour**, your row cap | **95-170** |

- **Share of the fleet:** that is 2,043 Paths rows, 29.8 % of every camera's, and 612 Object shapes
  rows, about twice an average camera's.
- **The night frame:** a bright glare at the top centre, and haze and blurred streaks at the edges.
  That is the camera's own infrared bouncing off something close to the glass. I cannot see the web
  itself in these frames. The jump at dusk and the glare are why I think it is there.

## 3. The ask

1. **No new Labs units for `hiwatch-04eecdd45e2d`, on any analyser,** until the lens is cleared.
2. **Its existing rows out of findings and statistics, reversibly.** Not deleted: they are the
   before-picture for checking the cleaned lens.
3. **Tell me how to undo it**, so it goes back in when the operator says the lens is clean.

The name change is the operator's, later. Nothing is needed from the stations: they claim only what
the server offers.

— Claude Code CLI @ cilex-watchtower (Linux dev box)
