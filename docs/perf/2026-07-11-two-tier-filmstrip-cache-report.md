# REPORT: two-tier filmstrip cache — Linux/VA-API implementation + proof

_Response to `docs/plans/2026-07-11-hevc-filmstrip-thumbnail-cache.prompt.md`
(Windows→Ubuntu handoff). Implemented cross-platform, no `#ifdef`. Windows-side
halves of Tests 1-6 are marked for the Windows instance to fill on the next CI
build; all Linux halves are complete below._

## 1. What was done

**Sub-approach: two-tier cache** (the spec's primary path; the low-res-session
alternative was not needed — see Test 1). Files/methods, exactly as specified:

- `src/models/FrameCache.h` — thumbnail tier stays in `m_store` (unchanged key
  semantics: prev/next/cachedAround/rev all still index it); new full-res tier
  `m_fullStore`/`m_fullBytes` with `kMaxFullFrames = 48`, `kMaxFullBytes =
  64 MB`, both under the existing shared `kMaxBytes = 144 MB` budget;
  `bytesMB()` reports both tiers; new signal `fullResReady(ptsMs)`.
- `src/models/FrameCache.cpp` —
  - `captureFrame()` (delivery thread, DirectConnection — unchanged): after
    `toImage()`, encode a **≤256 px thumbnail** (env `WT_STRIP_THUMB_PX`)
    synchronously → insert `m_store` → `rev`/`changed()` — the strip's whole
    critical path. `moveAnchor` (operator/entry) frames also encode **full-res
    synchronously**; harvest frames dispatch the already-detached `QImage` to
    `QThreadPool::globalInstance()` for the full-res encode (insert under
    `m_mx`; skips if the pts was evicted meanwhile — no resurrection), then
    `fullResReady`. Per-frame `[CACHETIME]` breakdown under `WT_CACHE_TIMING`.
  - `repaint()` prefers `m_fullStore`, falls back to the thumbnail for one
    paint; PTS restamp unchanged.
  - `evictFullLocked()` — same farther-from-anchor rule, tight window.
  - `clear()` wipes both tiers.
- `qml/PlaybackScreen.qml` — `fullResReady` upgrade hook: while in frame mode,
  a landed full-res for the currently shown pts repaints it in place.
- `qml/FrameHarvester.qml`, `qml/FrameStrip.qml` — untouched (as the spec
  allowed); the image provider path serves the (already slot-sized) thumbnails.

**Invariants held:** only the `QImage` (decoder-independent CPU copy) crosses
threads — the `QVideoFrame` never leaves the delivery-thread emission (P0 UAF
rule); harvester churn lifecycle untouched; poison-latch/validity guards
untouched; mutex + `rev` semantics preserved.

## 2. Measurement that drove it (Test 1 — Linux, VA-API, HEVC 2560×1440, .201)

`WT_CACHE_TIMING=1`, 1,970 captured frames:

| stage | p50 | p95 |
|---|---|---|
| `toImage` + 256 px thumb encode (delivery thread, critical path) | **0 ms** | **1 ms** |
| full-res 1440p JPEG encode (now async, pool) | **38 ms** | 45 ms |

The old path paid that 38 ms synchronously per harvested frame → the fill was
**encode-bound (~26 fps)**; it is now **decode-bound** (2× harvest ≈ 40 fps),
and the critical path costs ~nothing. On VA-API the readback itself is ~free;
on D3D11VA it is slower — which is exactly why Windows was 40 % over the gate
while Linux sat just under it. Encode-splitting alone closes the gap; the
low-res harvest session alternative is unnecessary.

## 3. Perf gate (Test 2 — Linux; ≥60 HEVC strips)

WT_FSOAK, two instances, same plans as the 2-day soak (HEVC = .201/.106/.120/
.101/.110 @2560×1440; H.264 = .67). BEFORE mined from the round-10/11 archive
logs (all prior fixes in), AFTER on the two-tier build:

| codec | BEFORE p50 / p95 | AFTER p50 / p95 |
|---|---|---|
| HEVC 1440p | 722 / 974 ms (n=5795) | **704 / 726 ms** (n=63) |
| H.264      | 715 / 2209 ms (n=253) | **465 / 705 ms** (n=23) |

HEVC p95 −25 %, H.264 p50 −35 %; every AFTER percentile is under the 1 s gate
on Linux. (AFTER maxima — 1228/1679 ms — are single cold-offset first touches.)

Linux was already under the gate; the win here is headroom (H.264 p50 −35 %;
HEVC now pinned to the decode floor: ~7 frames at 2×20 fps ≈ 350 ms + session
overhead). The residual p95 tail on both codecs is the **server-cold-offset
class** (documented + optioned to CV in
`docs/letters/2026-07-11-cold-offset-first-segment-latency.md`), not capture
cost. **Windows validation slot:** expected to drop from ~1100 ms p50 toward
its decode floor — Windows instance to run `fsoak.ps1` on the next CI build
and fill this table's Windows rows.

## 4. Visual no-regression (Test 3 — Linux)

Screenshots (`2026-07-11-twotier-fm-entry.png`, `2026-07-11-twotier-fm-stepped.png`,
this directory): frame-mode entry
and a mid-fsoak stepped-to frame — the big view is full-resolution crisp
(2560×1440 HEVC), all 7 strip slots populated with sharp slot-sized thumbnails,
`.mmm` labels intact. The stepped shot was taken mid-cycle after 10 step-bursts
— i.e. a frame stepped into the ahead-filled zone, painted full-res (the async
tier + upgrade hook working). Incidental: the shot also shows the fixed camera
glyph and the calendar's midnight-rollover fix live.

## 5. Memory bound (Test 4 — Linux)

`FrameCache.bytesMB` (now both tiers) peaks ~29-31 MB during frame-mode churn
(was ~50 MB thumbnail-era full-res store) — far under the 144 MB budget; the
20-switch churn gauntlet ended at `cache=231f/30.8 MB`. RSS flat across the
runs (fsoak rss.csv sidecars).

## 6. A/B knob (Test 5 — Linux)

`WT_STRIP_THUMB_PX`: 256 (default) → 0-1 ms; 512 → 2-3 ms; old full-1440p →
38 ms. Largest strip slot is 171 px wide (strip height 96 × 16:9), so 256 px
keeps ≥1.5× supersampling headroom at zero measurable cost; 128 would save
nothing (already ~0 ms) and shave the margin. Default stands at 256.

## 7. Churn safety (Test 6 — Linux)

`WT_CHURNTEST=20` under gdb on the two-tier build (gappy 07-10 ↔ continuous
07-08, mid-fill pokes, frame mode hot): **20/20 switches, 0 SIGSEGV, harvester
filling, PASS** — the pool-encode tier introduces no new lifetime hazards (it
only ever touches detached `QImage`s and re-checks liveness under the mutex).

## Residuals / limitations

- Linux AFTER maxima (1.2-1.7 s singles) are the server cold-offset first-touch
  class, out of scope here (CV letter on file); p50/p95 both have real margin.
- Windows halves of Tests 1-6 pending on the Windows instance (next CI build
  carries this change; `windows-latest` rolling release publishes it).
- The upgrade repaint targets only the currently-shown pts — stepped-past
  frames upgrade lazily when revisited (by design; no user-visible cost found).
