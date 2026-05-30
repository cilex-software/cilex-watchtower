# Cilex Vision — server-composited synchronized multi-camera review (a mosaic stream)

**From:** Watchtower (operator client)
**Date:** 2026-05-31
**Priority:** HIGH (blocks the whole wall-playback feature; client-side approach is proven infeasible)
**Scope:** a new server-side capability — one synchronized, composited grid HLS stream — plus four supporting confirmations.
**Master-letter codes:** **E1–E5** (new "multi-camera review" domain).

---

## What we're building and why we need you

We want **synchronized wall playback**: an operator rewinds the *whole* camera wall to a moment and watches every visible camera play back **in lock-step** from that instant (one master timeline, one playhead, one transport) — the universal VMS model (Milestone, Avigilon, Genetec, Verkada).

We spiked the obvious client-side approach — open N `/review/sessions`, play each through `QMediaPlayer`+HLS, and slave them all to one master clock — and **measured where it breaks**. The sync *logic* is sound, but the streaming does not scale:

| Concurrent review streams | Result (measured, offscreen **and** real Intel iGPU) |
|---|---|
| 2 | plays, **stable ~350 ms** drift ✓ |
| 4 | all play, but **drift grows to ~4 s within ~13 s** — every tile stalls in lock-step; can't sustain realtime |
| 8 | "Invalid playlist" failures; ~0 sustain |
| 16 | 1 of 16 sustains |

We fixed the first wall ourselves — Qt's `QNetworkAccessManager` caps HTTP at ~6 connections per host, so one shared proxy starved many players; **per-session proxies with independent connection budgets removed the "Invalid playlist" failures**. But a second, harder wall remains: **per-stream decode + segment-feed throughput**. The client simply cannot decode/sync ~16 independent HLS streams in realtime; the sustainable ceiling on this hardware is **~2–3 streams** — far short of a 16-camera wall.

**So the compositing has to happen server-side.** This is exactly how the platforms that do large synchronized grids do it.

---

## E1 — The core ask: a composited, synchronized grid mosaic stream

One **review session that returns a single HLS stream of the whole grid**, composited and time-synced server-side. The client decodes **one** stream regardless of camera count.

```
POST /review/mosaic-sessions
{
  "camera_ids": ["hiwatch-…a", "hiwatch-…b", …],   // ordered → cell order
  "layout":     { "cols": 4, "rows": 4 },            // or just "count"; you choose packing
  "wall_start": "2026-05-29T00:00:00Z",
  "wall_end":   "2026-05-29T24:00:00Z",
  "cell":       { "width": 480, "height": 270 },     // per-cell render size (optional)
  "hevc_capable": true
}
→ 200
{
  "session_id": "…",
  "playlist_url": "/review/mosaic-sessions/{id}/playlist.m3u8",  // we proxy it like /review
  "grid":     { "cols": 4, "rows": 4, "cell_w": 480, "cell_h": 270 },
  "cells":    [ { "index": 0, "camera_id": "…a" }, … ],          // cell ↔ camera mapping
  "manifest": { "fragments": […], "wall_start": …, "wall_end": …,
                "clipped_to_finalized": …, "live_gap_s": … }      // SAME shape as /review/sessions
}
```

**Behavior we need:**
- **One shared timeline.** Every cell is the same wall-clock instant in every frame. Seeking/scrubbing the one stream moves all cells together — perfect sync, by construction.
- **Gaps rendered server-side.** A cell with no footage at instant *t* shows black / dimmed last-frame / a "no footage" marker — never a broken cell. (Matches what operators expect; we can't do per-cell gap handling if it's one muxed frame.)
- **Manifest reuse.** Return the **same manifest shape** as `/review/sessions` (fragments with `compact_*`/`wall_*`, `clipped_to_finalized`, `live_gap_s`) for the *composited* timeline, so our existing timeline/scrub/clamp code drives it unchanged.
- **Codec/quality.** A modest single-stream resolution is fine (the grid is downscaled cells); H.264 is universally decodable, HEVC if `hevc_capable`. The point is **one** decode on the client.

If a full live-composite is too heavy, an acceptable v1 is **composite-on-scrub**: render the mosaic for the requested window on demand (we're reviewing recorded footage, not live).

### Why this is the right shape
- Scales to 16 (or more) with **trivial client cost** — one decode.
- **Perfect** sync (server muxes one timeline) — better than any client re-sync heuristic.
- Reuses our session/manifest/HLS-proxy plumbing; the client change is "point the existing player at the mosaic playlist."

---

## E2 — Combined export of the synchronized grid

When an operator drags an In/Out range on the shared timeline, they'll want **both**: per-camera clips **and** a single combined grid archive of the synced moment (Verkada's dual-archive pattern). Does the export pipeline (`POST /review/exports`) support a **mosaic/grid export** (effectively exporting a window of the mosaic session), or do we ship per-camera clips now and stitch later? If the mosaic session exists, exporting a window of it is the natural mechanism.

## E3 — Scrub-preview poster frames (also our fallback)

For bandwidth-aware scrubbing we want sparse **poster/sprite frames (~1 per 10 s)** per camera for hover/drag preview. Two reasons it matters:
1. Standard scrub UX (Avigilon/Rhombus/AXIS all do thumbnail-on-scrub).
2. **Fallback architecture:** if E1 (mosaic) can't be done, our backup is a *thumbnail-hybrid* — synchronized poster frames for **all** tiles while scrubbing, full-rate video for only the focused 1–2. That also needs these frames.

Can you serve `GET /review/poster?camera_id=…&t=…` (or a sprite sheet per window)?

## E4 — Coverage union for the shared calendar

The wall calendar marks a day if **any** visible camera has footage. Either a batch coverage endpoint (`camera_ids[]` → union), or we union N `GET /review/coverage` calls client-side (depends on A7 shipping). Which do you prefer? (If A7 lands per-camera, client-side union is fine for now.)

## E5 — Confirm latent contract items (block correct playback regardless of E1)

- **Hydrating fragments are playable.** We currently drop `availability !== "ready"`; please confirm cold/hydrating fragments *are* in the playlist and *do* play, so we stop dropping them.
- **`resolution` field semantics** on fragments (currently unplumbed) — units/meaning.
- **Live-edge clamp** — confirm `clipped_to_finalized` + `live_gap_s` are the safe-to-play ceiling; the mosaic manifest should carry them too.
- **Mid-timeline codec switch** (H.264 720p ↔ HEVC 1440p across `#EXT-X-DISCONTINUITY`) over a multi-day window — does it play through? (For the mosaic this is your concern, not ours, which is another point in its favor.)

---

## Concurrency (if E1 slips and we must do client-side in the interim)

If a capped client-side mode is needed before the mosaic ships, tell us the **max concurrent review sessions + HLS pulls** one operator may open, and whether opening many sessions for the **same** camera is supported (we saw same-camera concurrent opens serialize). Our measured client ceiling is ~2–3 regardless, so we'd cap there and label it honestly — but the mosaic is the real answer.

---

## What Watchtower will do once E1 ships

The client side is mostly built/designed and waits on you:
- A `SharedPlaybackClock` + the existing session/manifest/HLS-proxy stack drive the **single** mosaic stream's transport (play/pause/speed/seek) — proven working.
- The wall enters "playback" mode in place (header calendar + bottom master timeline + transport), renders the one mosaic stream across the grid using your `cells[]` mapping, and "Return to live" restores per-tile RTSP.
- Day-jump, In/Out selection, and (E2) export all operate on the one synchronized timeline.

No fabricated data anywhere; until E1/E3 exist the wall-playback entry point stays disabled with an honest "coming soon — backend compositing pending," not a broken control.

---

## Acceptance, from our side

- `POST /review/mosaic-sessions` returns one HLS playlist of a composited, time-synced grid + a `cells[]` camera mapping + a `/review`-shaped manifest, operator-scoped.
- Every cell shows the same wall instant per frame; seeking the stream moves all cells together.
- Missing-footage cells render a server-side gap state, not a broken tile.

Happy to iterate on the request/response shape, the on-demand-vs-live composite trade-off, or the cell layout contract. The measured numbers above are why we're asking for this rather than brute-forcing it client-side.

— Cilex Watchtower
