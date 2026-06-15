# Timeline event markers on the playback scrubber — industry research

**Date:** 2026-06-15
**Status:** Research synthesis (drives a future timeline event-markers feature). Not yet a plan.
**Method:** Deep-research harness — 5 search angles, 22 sources fetched, 83 claims extracted, 25 adversarially verified (3-vote, need 2/3 to kill) → 22 confirmed, 3 refuted, 8 synthesized findings.

## Why

We want event markers on the playback scrubber so a reviewer can see when motion started and ended (and, later, other camera events: line-crossing, intrusion, person/vehicle, tamper). The hard part is **density**: a busy camera at a 24h zoom emits so many events that naïve markers become a useless solid wall. We also need **show/hide** controls. This documents what leading products actually do, what's verified vs. unverified, and a recommended design.

Pairs with: the zoomable timeline scrubber (commits `0746a71`, `6de058b`) and the motion-event lifecycle (motion_started/ended are one episode joined by `recording_id`; see `docs/...` and the motion-event-lifecycle note).

---

## Executive summary

The industry converges on a clear split:

- **Motion is drawn as a colored *span* (start→end) over the recording bar — never a point tick.**
- **Discrete events are *icon/point* markers in distinct colors, kept visually separate from the bars.**
- **Nobody uses per-event-type swimlanes** in the surveyed VMS clients.

For density, real VMS products lean on **on-demand querying and category-level toggles** rather than automatic heatmaps. The only concrete clustering math (per-zoom level-of-detail, ~40px minimum spacing) comes from **dataviz libraries**, not VMS vendors. The cleanest data+visual model for our `motion_started→motion_ended` episodes is **Grafana's point-vs-region annotation distinction**.

---

## 1) Marker representation (verified)

| Product | How events render on the timeline |
|---|---|
| **Milestone XProtect** | **Two stacked tracks** — upper = selected camera's recordings, lower = all cameras in the view (focus-plus-context). Recording **type by fixed color**: light-red = recording, **red = recording *with motion*** (a span), green = audio. **Bookmarks = blue icon** (hover previews video); integrated incidents = **markers in non-blue colors**, can appear as pop-ups. A **"Color codes legend"** button lists active colors. Design stable across 8+ years of manuals. |
| **Avigilon ACC** | Single scrubber bar: **red = motion, blue = recorded, white = no video**. Continuously zoomable **¼ second → years** (slider + scroll wheel). |
| **Hanwha Wisenet WAVE** | Single bar: **black = none, green = recorded, blue = bookmark, red = motion** (red appears only after a Smart Search — see §2). |
| **Grafana** (cross-domain model) | **Point annotation** = vertical line + icon (single moment). **Region annotation** = shaded start→end band, stored with both `time` and `timeEnd`. Hover shows description + tags. |

**Verified pattern (3-0):** continuous colored **bars** for recording/motion *state* vs discrete colored **icons** for point *events*. No surveyed VMS uses dedicated per-event-type lanes.

## 2) Density management across zoom (the core problem)

- **On-demand surfacing beats always-on.** Wisenet WAVE shows **no motion on the timeline by default**. The reviewer draws a region on the image (a semi-transparent Smart-Search grid); only then does the timeline populate with red start→end fragments for that region. No region = whole frame. Scanning a yearly archive takes seconds. *Default timeline = quiet; motion is surfaced only when/where asked.*
- **The zoom range forces level-of-detail.** ACC spans ¼-second to years; at the wide end, individual events are physically unrenderable and must aggregate.
- **Concrete thresholds come from dataviz libraries, not VMS docs.** Mapbox **Supercluster**: default **cluster radius = 40px** (relative to a 512px tile extent); clustering computed **per zoom level** (minZoom 0 → maxZoom 16); points within the radius merge into one cluster carrying a **count**; `getClusters(bbox, zoom)` returns clusters-vs-individual-points for the current zoom.
  - **1-D translation:** enforce a minimum pixel gap between markers; below it, merge adjacent/overlapping events into a counted cluster; recompute per zoom so summaries expand into individuals on zoom-in.

> ⚠️ **Gap:** No surveyed VMS documents an automatic "collapse to heatmap" threshold or bucket size. Any auto-density rule we build is an **informed design heuristic**, not a documented industry standard.

## 3) Show/hide & filtering (verified)

- **XProtect** = per-**category** toggles under *Settings → Timeline*: Incoming/Outgoing audio, Additional data, Additional markers, Bookmarks, **Motion indication**, All-cameras track — plus the color legend. Rationale (verbatim): *"For a clearer overview… you can adjust what is shown on the timeline tracks."*
- **Limitation to beat:** XProtect bundles **all** analytics (line-crossing, intrusion, person, vehicle) under one *Additional data/markers* toggle — **no per-event-type control**. We have distinct types and can do better.
- **Default-quiet is a legitimate strategy** (WAVE shows nothing until asked) to avoid the wall.

---

## What the research could NOT establish (caveats)

- **No verified findings** for Genetec Security Center, Bosch BVMS, Axis Camera Station, Verkada, Eagle Eye, UniFi Protect, Synology, Frigate, Blue Iris, YouTube chapters/most-replayed, video editors (Premiere/FCP/DaVinci), or vis.js/Gantt libraries. They were searched but did not survive into the verified set — treat as **unknown**, not absent.
- **Refuted (0-3 in verification) — DO NOT rely on:**
  - Avigilon "Rarity slider" and a "2-second minimum-duration default" for timeline event suppression.
  - A "~100,000-point performance threshold" for switching markers→aggregation.
  - A WAVE "Show Bookmarks" toggle with a green-bar indicator.
- **Version sensitivity:** XProtect's audio-direction color mapping flipped between the 2018-R3 and 2023R3+/latest manuals; the "Color codes legend" button is confirmed only in 2025R2/latest. Keep our own legend stable.
- **Subtle nuance:** XProtect/WAVE/ACC encode motion as *recording-with-motion shading* tied to recorded coverage. **Our** `motion_started→motion_ended` are **free-standing episodes** (joined by `recording_id`) — closer to **Grafana region annotations** than to coverage shading.

---

## Recommended design for our scrubber

We're well-positioned: our motion is already a clean **start→end episode**, which *is* the region-annotation model.

**Representation**
- **Motion episodes → colored spans** on a thin events lane beneath the recording bar (XProtect-red convention / Grafana region).
- **Point events** (line-crossing, intrusion, person/vehicle, tamper) → small **type-colored ticks/icons** with hover tooltip (type + time).
- A small **color legend** that doubles as the show/hide control.

**Density across zoom**
1. **Per-zoom LOD clustering** with a **minimum pixel spacing** (start ~6–8px for ticks; tune): events closer than that merge into a **cluster marker with a count** ("⊕ 12"); zoom in to resolve. Recompute on each zoom change.
2. **Motion at wide zoom → density band.** A busy camera's episodes are seconds apart; at 24h they fuse anyway, so render the **union as an intensity band** (darker = more motion per bucket) and resolve individual start/end episodes only once they exceed the min spacing on zoom-in. *(Our designed heuristic — flagged as not VMS-documented.)*
3. **Default-quiet option** for noisy cameras (WAVE lesson).

**Show/hide**
- **Per-event-type toggles** (better than XProtect's single bundle) + a **master "Events" on/off**, exposed via the legend; remember per-user.
- Defaults: motion band ON; point events ON but auto-clustered.

**Pitfalls to avoid**
- Rendering every event as an always-on tick at all zooms (the wall).
- One toggle for all analytics types.
- Tying motion display to recording coverage when our episodes are standalone.
- Baking in the refuted "magic numbers."

---

## Sources (verified set)

Primary / authoritative:
- Milestone XProtect Smart Client manual — https://doc.milestonesys.com/latest/en-US/standard_features/sf_sc/sf_funda/scfunda_ui_timelinemain.htm (+ 2023R3, 2025R2 PDFs)
- Avigilon ACC 6.14 Player guide — https://d8eqw8u9b6kgn.cloudfront.net/file_library/pdf/acc6/avigilon-acc6.14-player-en.pdf
- Hanwha Wisenet WAVE manual — https://www.hanwha.se/Presentationer/Wisenet_WAVE_User_Manual.pdf ; WAVE Motion Smart Search — https://support.hanwhavisionamerica.com/hc/en-us/articles/115013260867-WAVE-Motion-Smart-Search
- Grafana annotations — https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/annotate-visualizations/ ; HTTP API — https://grafana.com/docs/grafana/latest/developers/http_api/annotations/
- Mapbox Supercluster — https://github.com/mapbox/supercluster

Searched but not surfaced into the verified set (treat as not-yet-established): Genetec, Bosch, Axis, Verkada, Eagle Eye, UniFi Protect, Synology, Frigate, Blue Iris, YouTube, video editors, vis.js.

## Open questions (for the design phase)

1. When exactly should the timeline auto-collapse markers into a density band/heatmap vs keep discrete markers? (No VMS documents a threshold — we must design the heuristic, e.g. from a Supercluster-style min-spacing.)
2. Do we want granular per-event-type toggles (we should — beats XProtect)?
3. Multi-lane swimlanes vs a single events lane at scale?
4. 1-D-specific min-pixel-spacing and time-bucket sizes (the 40px/512px figure is from 2-D map clustering — extrapolated).
