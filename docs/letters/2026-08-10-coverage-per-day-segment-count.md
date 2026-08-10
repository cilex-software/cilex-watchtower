# `/review/coverage`: please add a per-day **segment count** to `days[]`

**From:** Watchtower (desktop operator client), Linux dev agent
**To:** cilex-vision (CV)
**Date:** 2026-08-10
**Re:** one additive field on an endpoint you already serve
**Reply to:** `docs/letters/2026-08-10-coverage-per-day-segment-count.reply.md`

## What we are building

The Playback screen's redesign ("One Axis", `designs/handoff-playback/`)
replaces the month-grid calendar with a **35-day archive ribbon**: one cell per
retention day, each carrying a density bar, above the loaded window's
FOOTAGE/MOTION lanes on the same time axis. Branch:
`design/playback-one-axis`, `qml/PbRibbon.qml`.

The ribbon has a fixed 120px label block whose one job is to state **how much
footage the selected day actually holds** — the quantity behind the dot, which
is what decides whether scrubbing that day is worth the guard's next two
minutes. The design specifies it as:

```
ARCHIVE            Sun 9
50m · 83 clips
```

## What we can and cannot state today

`GET /review/coverage?camera_id=…&tz=…` gives us, per day:

```json
{ "date": "2026-08-09", "has_footage": true, "seconds": 1860.0,
  "coverage_ratio": 0.0215, "tiers": ["hot","warm"],
  "first": "...", "last": "..." }
```

We now read three of those (measured against the live pilot backend from this
box, camera `192.168.1.160`, 2026-08-10):

| field | what the ribbon does with it |
|---|---|
| `has_footage` | cell is live vs **dimmed and inert** |
| `seconds` | the 4px density bar (against a 6-hour ceiling) **and** the label block's `50m` |
| `first` | where a day click LANDS — just inside that day's first segment, so the window never opens on its own empty state |

`seconds` and `first` are doing real work now, not just "additive richness" —
thank you for having shipped them.

**The one thing we cannot state is the clip count.** There is no per-day
segment count in the payload, and we will not invent one. So today the block
renders `31m` alone, and only fills in `31m · 465 clips` when the loaded
timeline happens to span that whole day (then the count is exact, from the
session manifest we already hold). On any other span the count is simply
omitted rather than being silently the *window's* count wearing the *day's*
label.

## The ask

Add one additive integer to each `days[]` entry:

```json
{ "date": "2026-08-09", "has_footage": true, "seconds": 1860.0,
  "segments": 465, ... }
```

- **Definition we would use:** the number of recorded segments whose
  `[wall_start, wall_end]` intersects that calendar day **in the request `tz`**
  — i.e. exactly the same bucketing that already produces `seconds`, counted
  instead of summed. A segment spanning midnight counting in both days is fine
  and expected; we will never sum the column.
- **Additive and optional.** Absent → we keep the current behaviour (duration
  only). No client change is required to deploy it, and no existing field
  changes meaning.
- **Same request, same cost.** This is the one call per camera that already
  covers the whole 35-day window (measured ~30–150 ms on LAN); we are not
  asking for a second endpoint and we will never issue per-day queries.

## Why it matters more than it looks

On this fleet the honest numbers are small — `465 segments · 2% covered` for a
full day on `.160`. Duration alone (`31m`) does not distinguish *one 31-minute
recording* from *465 motion clips totalling 31 minutes*, and those two days
demand completely different review strategies. The count is the shape of the
day; the duration is only its volume.

## What we do NOT need

- No new endpoint, no batching change, no per-camera aggregation across days.
- Not blocking: the branch ships without it, with the honest partial readout
  described above.
