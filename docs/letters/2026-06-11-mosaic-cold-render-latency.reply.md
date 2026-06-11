# Mosaic cold render: 34 s → ~5 s — all four asks shipped

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision (backend)
**Date:** 2026-06-12
**Re:** [`2026-06-11-mosaic-cold-render-latency.md`](./2026-06-11-mosaic-cold-render-latency.md)
**Status:** ✅ **SHIPPED + DEPLOYED + RE-MEASURED on your exact scenarios.** Backend commit `3043dbe`. Please re-measure with `WT_HLS_LOG=1` and confirm.

---

## TL;DR — your table, re-measured

16-cam 4×4 day session (2026-06-10), through the same query-api proxy you use, polling 503s exactly like your fragment-retry loop:

| case | you measured | now |
|---|---|---|
| session create | 6.7 s | **1.29 s** |
| first segment at playlist head (cold) | ~15.3 s | **3.68 s** |
| far seek into cold region | ~34.5 s | **5.11 s** |
| the segment right after it | ~17 s | **1.19 s** |
| already-rendered region | 50–130 ms | 136 ms (unchanged) |

Every cold segment now serves in well under its own 6 s of content, and the renderer sustains **~3.7× realtime uncontended** — play-stall-play after a cold seek is gone. With your ~13 s per-request chain budget, no request should ever bounce past the proxy again.

## The honest diagnosis first

Your headline read "the render speed itself is the problem" — it wasn't, quite. ffmpeg was only ~3.2 s of the ~16 s. The dominant cost was **us resolving the 16 cell sources with 16 sequential point lookups, each unbounded on the segments hypertable — ~1.9 s each ≈ ~31 s per cold segment**. Same disease we fixed in the hevc-500 thread (`131d1b6`), different organ. Your "reads as 'the renderer had to get there'" instinct was close: it wasn't walking the timeline, it was walking all of history 16 times per segment.

That said, we took your ask 2 seriously anyway — details per ask:

## Ask 1 — prewarm at the seek target ✅

There's now a per-session **render chase**: a cold `seg/N` request **jumps the render head to N** and renders forward from there. The old position is abandoned (at most one in-flight segment finishes). Your seg/300 case: the landed-on segment + its successors render from 300, never from wherever the head was.

## Ask 2 — faster-than-realtime ✅ (~3.7× sustained)

- Cell-source resolve: **one batched query** (two when a cell needs the midpoint fallback), bounded for chunk exclusion → ~31 s → milliseconds.
- The 16 source downloads now run in parallel.
- ffmpeg: two frame-threads per decoder (software H.264 decode was the serial cost; thread budget is fine post your pids fix — we measured 24 pids in the container during the burst), and fps-resample moved before scale so only kept frames get scaled. Uncontended render: **3.2 s → 1.3–1.8 s per 6 s segment**.
- We did **not** drop the encoder preset or the mosaic fps: at 3.7× realtime the encode isn't the bottleneck, so you keep the current grid quality. If you ever want 15 fps cells, it's a session parameter already (`fps`), not a server change.

## Ask 3 — render-ahead horizon ✅

The chase keeps rendering up to **`last_requested + 8` segments (≈ 48 s of lead)** — and *warm* hits also advance it, so steady playback continuously pulls the horizon forward and never reaches a cold edge. Verified on disk: after our far-seek test the chase had rendered past the last requested index unprompted. Env-tunable via `MOSAIC_RENDER_AHEAD` if 48 s proves short on your side.

## Ask 4 — render from wall_start on create ✅

Session-create prewarm now **seeds the chase** at the first ready fragment, so rendering starts the moment `POST /mosaic-sessions` returns — by the time your player fetches the head it's typically 1 poll from ready (3.68 s measured cold-cold; subsequent opens of the same region are cache hits).

## Semantics unchanged

`503 + Retry-After: 1` while compositing, `X-Cilex-Mosaic-State` headers, gap/range mapping, cache behavior — all exactly as before. No client changes needed; your existing retry pacing is the right shape for the new timings (you'll just see 2–5 polls instead of 15–35).

## One ask back

Re-run your measured table end-to-end in the client (especially open-the-wall → first frames, which we can't see from here) and send the numbers. If open-the-wall still reads slow despite segment times like the above, the remainder is session-create → first playlist fetch on your side and we should look at it together with data.

— Cilex Vision
