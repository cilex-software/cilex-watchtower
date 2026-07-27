# Wall-composite cell spans: an optional layout spec for the E1 mosaic

**From:** Watchtower
**To:** Cilex Vision
**Date:** 2026-07-27
**Scope:** one feature — letting the server-composited review mosaic (E1) place
cameras in unequal cells, so the synchronized playback wall can mirror the Live
wall's new merged-cell tiles. Live-side is shipped and client-only; this letter is
the only backend dependency, and it is not urgent.

## 1. What shipped client-side today (context, no action needed)

The Live wall now supports operator-created **merged cells**: Shift+drag across a
rectangle of tiles → one camera fills the merged region (e.g. four 1×1 cells → one
2×2 tile for the entrance camera). Selection is Excel-grammar, merges persist per
(group, layout), survive crash-restores, and displaced cameras reflow. Pure client
geometry — one bigger `VideoOutput`, no backend involvement.

## 2. The gap

The **synchronized playback wall** is your composite: the client asks for N cameras
and receives ONE stream laid out as an equal grid. So a guard who merged cells on
the live wall loses that geometry the moment they enter wall playback — the mosaic
comes back uniform, and there is nothing the client can do about it (the pixels are
composited server-side).

## 3. The ask — an optional `layout` on composite creation

Wherever the composite session is created today (camera list + window), accept an
optional layout description; absent → today's equal grid, unchanged:

```json
{
  "cameras": ["hiwatch-…67", "hiwatch-…50", …],
  "layout": {
    "cols": 4, "rows": 4,
    "cells": [ {"camera_id": "hiwatch-…67", "c": 1, "r": 1, "cw": 2, "ch": 2},
               {"camera_id": "hiwatch-…50", "c": 0, "r": 0, "cw": 1, "ch": 1},
               … ]
  }
}
```

- Grid units, not pixels — you own the output resolution and scaling exactly as
  today; `cw`/`ch` are cell spans.
- Client guarantees: cells non-overlapping, in-bounds, one per listed camera —
  but please validate and 422 loudly rather than trust it.
- Unlisted grid positions are simply empty (dead-air slate, as now).
- If ffmpeg filter-graph cost is a concern: the layouts are static per session
  (a merge change = new composite session, same as a camera-set change today),
  so this is a different `xstack`/overlay arrangement, not a dynamic one.

## 4. What the client does with it

Entering wall playback from a live wall that has merges carries the same
geometry into the composite request, and the same Shift+drag gesture works
inside wall playback (a merge there = re-open the composite with the new
layout — session churn identical to today's re-composite on camera swap).

No numbers to agree on; the only question is whether the layout spec above fits
E1's compositor cleanly or you'd shape it differently — either way the client
adapts. Not blocking anything: the live-wall feature is complete without it.

— Watchtower
