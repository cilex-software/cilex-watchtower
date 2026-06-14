# Seek-latency decomposition — what the >500 ms numbers are made of (2026-06-14)

Re-ran the flagged operations with **stage instrumentation** (issued → Buffering
[flush] → Buffered [segment fetch] → first video frame [decode] → resumed), plus
`WT_HLS_LOG` for the segment fetch and a direct manifest-size probe. On `.108`
(hot HEVC 1440p, 06-13) and the 16-cam wall (06-13). Instrumentation was
TEMP-VERIFY, reverted after.

## Single-camera backward seeks (reported 525–862 ms)

| seek | flush (→Buffering) | fetch (→Buffered) | decode (→first frame) | **first frame** | resumed (reported) |
|---|---|---|---|---|---|
| −1 s | 375 ms | ~1 ms | 80 ms | **455 ms** | 527 ms |
| −5 s | 367 | ~1 | 84 | **452** | 526 |
| −1 m | 337 | ~0 | 150 | **487** | 620 |
| −10 m | 345 | ~1 | 149 | **495** | 621 |
| −50 m | 345 | ~1 | 146 | **492** | 620 |
| −1 h | 388 | ~1 | 144 | **533** | 623 |
| −10 h | 369 | ~1 | 114 | **484** | 623 |

**What contributes:**
- **~340–390 ms = GStreamer pipeline FLUSH** (the demuxer tearing down and
  re-establishing decode at the target). This is the dominant term and is
  inherent to QtMultimedia's FLUSH-mode seeks — independent of seek distance
  (−1 s costs the same flush as −10 h).
- **~1 ms = segment fetch.** Negligible — the suspect (network/server) is NOT
  the cost; the target segment is hot/buffered and served instantly.
- **~80–150 ms = decode** to first frame (HEVC 1440p keyframe).
- **~100–140 ms of the reported number is a MEASUREMENT ARTIFACT** — the bench's
  "resumed" waits for 3 consecutive rising position samples (~150 ms) after the
  frame is already on screen. Real user-perceived = **first frame ≈ 450–530 ms**.
- The earlier **862 ms (−1 h)** was run-to-run variance; this run clustered
  526–623 ms resumed / 452–533 ms first-frame.

No cheap client fix: the cost is the demuxer flush + decode, not anything we
issue. Forward seeks are faster only because they don't flush (data is ahead).

## Wall +1 s (reported 1.23 s)

flush 59 ms → fetch 1 ms → decode 11 ms → **first frame 71 ms** → resumed 240 ms.
The 1.23 s was a **first-seek-after-open warm-up artifact** (the prior run's
center seek hadn't established; the first measured seek ate the penalty). In-place
wall scrubs are ~70 ms to first frame. Not a real cost.

## Wall day-switch (reported 4.3–4.6 s)

| stage | day-1 | day-5 |
|---|---|---|
| **session setup** (mosaic POST manifest build + client parse, → source set) | 1582 ms | 1970 ms |
| **server cold-render of seg0** (→ Buffering) | 2628 ms | ~2514 ms |
| decode (→ first frame) | 10 ms | ~0 ms |
| **first frame** | 4220 ms | 4484 ms |
| resumed (reported) | 4353 ms | 4651 ms |

Both dominant halves are **server-side**; client decode is ~10 ms. The "session
setup" half is the **24-hour manifest**, confirmed by a direct probe:

| mosaic window | POST time | fragments | body |
|---|---|---|---|
| **24 h** | **1181 ms** | **14 376** | **3.1 MB** |
| 1 h | 54 ms | 600 | 127 KB |

Opening a day loads a 14 376-fragment / 3.1 MB manifest (server build ~1.2 s +
client JSON parse making up the rest of the ~1.6–2.0 s).

## Optional levers (neither urgent — day-switch is within norm)

1. **Client — narrower initial wall window.** Open ~1–2 h around the target
   instead of the full 24 h: manifest ~14 376 → ~1 200 fragments, session setup
   ~1.7 s → ~0.1 s, day-switch ~4.5 s → ~2.9 s. Trade-off: the scrubber would
   cover less of the day unless we lazy-expand to keep full-day scrub. Design call.
2. **Backend — compact the mosaic manifest** (gap-merged ranges or pagination) so
   a 24 h window isn't 3.1 MB / 14 376 per-6 s entries. Would cut both the build
   and the parse. Letter if pursued.
3. The server cold-render seg0 (~2.6 s) is the other half — backend (their
   synchronous-first-fragment / deeper-prewarm levers from the cold-render thread).

## Net
Nothing >500 ms is a client *defect*. Single-cam backward seeks are GStreamer
flush + decode (~450–530 ms real, the rest a bench artifact); wall scrubs are
~70 ms; wall day-switches are server manifest + cold-render with a clear
client-side option (narrower window) if we want to chase the ~1.7 s manifest half.
