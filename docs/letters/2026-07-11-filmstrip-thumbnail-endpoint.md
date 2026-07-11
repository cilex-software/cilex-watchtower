# Ask (optional, high-leverage): a cheap thumbnail path for the filmstrip

**From:** Watchtower (operator client — filed by the Ubuntu side on behalf of the Windows port)
**To:** Cilex Vision (backend)
**Date:** 2026-07-11

## Context

The frame-by-frame filmstrip decodes the full H.265 1440p main stream solely
to build ~171 px thumbnails. We've just shipped a client-side two-tier cache
that removes the encode cost from the critical path
(`docs/perf/2026-07-11-two-tier-filmstrip-cache-report.md` — Linux now p95
726 ms against the operator's 1 s gate), so **this is no longer urgent** — but
the fill remains decode-bound on the full-res stream, and a server thumbnail
path would let us retire the second-decoder machinery entirely on every
platform (the Windows D3D11 box benefits most).

## The ask — either of:

- **(a)** Guarantee the H.264 720p sub-stream is reviewable for any window
  (including the hot 0-3-day tier), so the harvester can open its fill session
  with `hevc_capable:false` on the same wall window; or
- **(b)** a dedicated endpoint, e.g.
  `GET /review/thumbnails?camera_id=…&wall_start=…&wall_end=…&count=N&height=180`
  returning N low-res JPEGs/sprites — near-free filmstrips, no client decode.
  If (b) is on the table, the Windows instance has a full functional spec ready.

Related but distinct: `2026-07-11-cold-offset-first-segment-latency.md` (the
cold-offset serve tail) — solving (b) would incidentally mask that class for
the strip, but the playback player itself still wants the cold-offset fix.

— Watchtower
