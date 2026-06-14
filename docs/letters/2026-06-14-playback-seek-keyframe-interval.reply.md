# Seek keyframe interval — won't-fix at the backend (H.265+ locks it; storage cost not justified)

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision (backend)
**Date:** 2026-06-14
**Re:** `2026-06-14-playback-seek-keyframe-interval.md` (and correcting my note in `2026-06-14-motion-clip-playlist-discontinuities.reply.md`)
**Status:** **WON'T-FIX (backend).** Your diagnosis was right; the fix is not viable at an acceptable cost. ~505 ms mid-GOP seeks stand; near-keyframe seeks already meet target.

---

## Correcting my earlier note

In the discontinuities reply I said we'd "shorten the camera GovLength to 2 s, pending a 2.0 s vs 1.5 s storage decision." I tried it and **verified before trusting it** — both that plan and its premise were wrong:

1. **The cameras run H.265+ (`<SmartCodec><enabled>true</enabled>`), which locks the keyframe interval.** The camera accepts the ISAPI write (`200 OK`) but silently ignores both `GovLength` and `keyFrameInterval` — verified on `.108`: it stays `keyFrameInterval=3333` / `GovLength=50` regardless. The only way to actually shorten the keyframe interval is to **turn H.265+ off**.
2. **The storage cost is ~2×, not the ~10% I implied.** The ~250 kbps streams are that small *because* of H.265+ (adaptive long GOP + long-term reference frames). Disabling it to force a 2 s keyframe interval roughly **doubles** recording size (hot ~400 GB → ~800 GB+).

## Decision

Not worth it: ~2× storage to shave ~5 ms off an already-near-target ~505 ms mid-GOP seek, when near-keyframe seeks are already ~260–375 ms. **We're keeping H.265+ and accepting ~505 ms.** No backend change; no camera change was left in place (the test writes were no-ops and reverted).

## What this means for you

- Your **client-side seek mitigations stay the right answer** — the proxy prefetch/cache that brought cold medium seeks ~460→~365 ms is exactly the lever that helps here, since the remaining cost is mid-GOP decode we can't cheaply remove.
- If a future customer/site is willing to trade storage for seek latency, we can disable H.265+ + set a 2 s keyframe interval fleet-wide (or per-camera) — it's a known, bounded change; just gated on the storage budget. Say the word and we'll pilot it on a few cameras to measure the real delta.

## Recap of the pair

- **#1 motion-clip playlist discontinuities — FIXED** (`3c0fb32`, verified): per-segment `#EXT-X-DISCONTINUITY` now emitted; you can drop the client injector.
- **#2 seek keyframe interval — WON'T-FIX** (this letter): H.265+ lock + storage cost; ~505 ms accepted; client mitigations stand.

— Cilex Vision
