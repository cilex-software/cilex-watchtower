# ARCHITECT TASK — Bring the HEVC 1440p filmstrip under 1 s (two-tier harvest cache)

_Handoff spec. Pairs with `docs/perf/2026-07-10-windows-fsoak-proxy-wedge.md` (Finding 1)
and `docs/perf/2026-07-10-frame-mode-churn-segfault.md` (the capture-thread invariants)._

## Mission

Make the frame-by-frame **filmstrip** (`strip_ms`) load in **< 1 s on HEVC 1440p**
cameras on **all platforms** (Linux Qt 6.12 + 6.8.3, VA-API; Windows Qt 6.12,
D3D11VA/FFmpeg), **without** degrading the big stepped frame-by-frame view (it must
stay full-resolution). Measure first, implement a two-tier cache, prove it on both
decode backends.

## Why it matters / what's wrong today

The operator requirement is "filmstrip loads under 1 second." Measured on the
current build (the WT_FSOAK soak, 2026-07-10/11):

- **H.264 1080p** (`.67`): `strip_ms` ~850 ms — **PASS**.
- **HEVC 1440p** (`.201`, `.106`, `.120`): `strip_ms` ~**1100 ms**, p95 ~1.3 s —
  **~40 % over the gate**.

It is **not** a decode-mode bug — Qt's FFmpeg backend is confirmed
**hardware-decoding** HEVC (D3D11VA on Windows via `qt.multimedia.ffmpeg.hwaccel`
logs → `Selected format 171` = `AV_PIX_FMT_D3D11`; VA-API on Linux). The overage is
the **per-frame GPU→CPU readback + full-resolution JPEG encode** the harvester pays
while filling the strip's slots, and 2560×1440 HEVC frames cost ~3–4× a
1280×720/1920×1080 H.264 frame. `strip_ms` is the time for the harvester to
chain-cache ≥ 5 of the 7 slots around the cursor, so it is dominated by that
per-frame capture cost at the 2× harvest rate.

## Root cause, code-grounded

`src/models/FrameCache.cpp::captureFrame(const QVideoFrame&, bool moveAnchor)` runs
on the media backend's **delivery thread** (`Qt::DirectConnection`, correct per the
P0 UAF fix) and does, **per captured frame**:

1. `const QImage img = frame.toImage();` — full-res GPU readback (~2560×1440).
2. `img.save(&buf, "JPG", 88);` — **full-res JPEG encode** (the likely dominant cost).
3. insert `pts → jpg` into `m_store` (`QMap<qint64, QByteArray>`), bump `m_rev`,
   emit `changed()` (the strip's slot model rebuilds on `rev`).

The **same** `m_store` is read two ways:

- `FrameCacheImageProvider::requestImage()` → `imageForPts()` → decodes the full
  JPEG and `scaled()`s it to the requested slot size — the **strip thumbnails**.
- `repaint(pts, tol)` → decodes the full JPEG → `QVideoFrame` → `m_sink->setVideoFrame()`
  — the **big stepped view**, which needs **full resolution**.

So the strip only needs tiny images, but the cache pays a full-res encode for every
frame because `repaint()` shares the store. That coupling is the bug.

## Approach — two-tier cache (thumbnails fast + full-res async)

Split the store so the **strip-fill critical path pays only a cheap thumbnail
encode**, while full resolution remains available for the stepped view:

1. **Thumbnail tier (drives `strip_ms`, delivery thread, synchronous & cheap).** In
   `captureFrame`, after `toImage()`, scale to a strip-slot-sized thumbnail and encode
   *that* (or store it un-encoded — measure). Insert into a thumbnail store; bump
   `rev`/emit `changed()` here so the strip updates as soon as the thumbnail exists.
   This is what `strip_ms` waits on, and a ~180–256 px thumbnail encode is ~1–2 orders
   of magnitude cheaper than 1440p.
2. **Full-res tier (drives `repaint()`, off the critical path).** Hand the
   **already-read-back full-res `QImage`** to a worker (`QThreadPool`) to JPEG-encode
   into a separate full-res store, bounded to a small window around the anchor.
   `repaint()` prefers full-res; if it isn't ready yet for a just-stepped-to frame,
   fall back to the thumbnail for one paint and upgrade when the full-res lands. **The
   frame-mode *entry* frame stays synchronous full-res** (`captureCurrent()`,
   `moveAnchor=true`) so the big view is instantly crisp; only harvest frames
   (`moveAnchor=false`) defer full-res.
3. **Measure first** to size the thumbnail and confirm the win (see Tests). If
   measurement shows `toImage` (readback), not encode, dominates, the encode-splitting
   alone won't close the gap — fall back to the **alternative** below and document why.

**Alternative (if measurement says readback dominates, or two-tier is judged too
heavy):** decode the harvest stream at lower resolution. The harvester shares the main
session's playlist (`hevc_capable:true` → H.265 1440p); give the *harvester* its own
low-res session (`hevc_capable:false` → H.264 720p sub, same PTS domain via
`wall_start/wall_end`), so decode **and** readback **and** encode all shrink. Larger
change (a second `PlaybackClient`/session + PTS alignment) — only take it if the
two-tier win is insufficient, and keep the stepped view on the full-res main-session
frames.

## Files · classes · methods · how to change

- **`src/models/FrameCache.h`**
  - Add the full-res tier: `QMap<qint64, QByteArray> m_fullStore; qint64 m_fullBytes;`
    plus caps (full-res window much smaller than `kMaxFrames`, e.g. ~48). Keep
    `m_store` as the thumbnail tier (can raise `kMaxFrames` since thumbnails are tiny).
  - Add a thumbnail size knob: `static constexpr int kThumbPx` + env `WT_STRIP_THUMB_PX`
    override; and a measurement gate `WT_CACHE_TIMING`.
  - Add a `QThreadPool*` (or use `QThreadPool::globalInstance()`) for the async full-res
    encode; optionally a signal `fullResReady(qint64 pts)` so a pending `repaint` can
    upgrade.
- **`src/models/FrameCache.cpp`**
  - `captureFrame()`: keep `frame.toImage()` on the delivery thread (**do not** move the
    `QVideoFrame` off-thread — P0 UAF). Then: `img.scaled(kThumbPx…, SmoothTransformation)`
    → encode thumbnail → insert `m_store` → bump `rev`/`changed()` (fast path done). If
    `moveAnchor` (operator/entry frame) → also encode full-res **synchronously** into
    `m_fullStore`. Else → dispatch the **`QImage`** (a detached CPU copy — safe
    off-thread, unlike the frame) to the pool to encode full-res → insert `m_fullStore`
    under `m_mx`.
  - `repaint()`: read `m_fullStore` first; fall back to `m_store` (thumbnail) if absent;
    keep the PTS restamp.
  - `imageForPts()` / `FrameCacheImageProvider::requestImage()`: serve from `m_store`
    (already thumbnail-sized — drop the now-redundant full decode+scale).
  - `evictIfNeededLocked()`: evict both tiers vs the anchor — thumbnails generous,
    full-res tight window; keep the "drop the end farther from `m_anchorPts`" rule.
  - Preserve all mutex discipline (`m_mx`) and the `m_rev`/`changed()` semantics the
    strip relies on.
- **`qml/FrameHarvester.qml`** — no functional change required (still feeds
  `FrameCache.harvestSink`); optionally raise `aheadTarget`/`aheadLow` now that captures
  are cheap. Keep the churn-safe lifecycle intact.
- **`qml/FrameStrip.qml`** — no change to the `image://fcache/<pts>?r=<rev>` usage;
  verify the slot pixel size matches `kThumbPx` (no upscaling blur).
- **`qml/PlaybackScreen.qml`** — verify frame-mode entry (`enterFrameMode` →
  `FrameCache.captureCurrent()`) yields a full-res center, and that stepping
  (`stepper` → `repaint`) shows full-res; wire the `fullResReady` upgrade if you add it.

## Cross-platform requirements

Identical code on all platforms — **no `#ifdef`**. The readback+encode cost exists on
both backends (Linux VA-API faster, Windows D3D11VA slower), so the fix helps Linux
(headroom) and is what pushes Windows under the gate. `toImage()`, `QImage::scaled`,
JPEG encode, and `QThreadPool` are all platform-neutral.

## Invariants you must not regress

- **P0 UAF rule:** capture converts the raw `QVideoFrame` via `toImage()` **on the
  delivery thread inside the emission**. All new work (thumbnail scale/encode, async
  full-res encode) must operate on the resulting **`QImage`** (a decoder-independent CPU
  copy), **never** on the `QVideoFrame`, and never queue the frame across threads. See
  `docs/perf/2026-07-10-frame-mode-churn-segfault.md`.
- Harvester churn-safety (keep-source, single `setSource` swap, no cross-discontinuity
  seeks) unchanged.
- Memory stays bounded (`kMaxBytes`); the added full-res window must not blow the
  144 MB budget — report steady-state RSS + `FrameCache.bytesMB`.
- The big stepped view stays **visually full-resolution**; the strip stays crisp at slot
  size (no blur/upscale).

## Tests to prove the fix

1. **Cost breakdown (justifies the design).** With `WT_CACHE_TIMING`, log per-frame
   `toImage_ms` vs `thumb_encode_ms` vs `full_encode_ms` on HEVC 1440p, on **both**
   Windows (D3D11) and Linux (VA-API). Report the split and which sub-approach it drove.
2. **Perf gate (the requirement).** `WT_FSOAK` + `plan-current`/archived on HEVC cams
   (`.201`, `.106`, `.120`), ≥ 60 strip measurements each, **both platforms**: report
   `strip_ms` min/p50/p95/max + PASS-rate **before vs after**; **target p95 < 1000 ms**
   on HEVC 1440p, with H.264 unchanged. (Harness/metrics: `[FSOAK] strip_ms=… PASS|SLOW`;
   runner `C:\git\portable\fsoak\fsoak.ps1` on Windows / `~/watchtower-soak/` on Linux;
   backend over Tailscale `http://100.107.51.72:8000` from the Windows box.)
3. **Visual no-regression.** `WT_SCREENSHOT` of frame mode on both platforms: the big
   stepped frame is full-res/crisp; step ±10 and confirm each shown frame is full-res
   (not a thumbnail), including frames stepped into the ahead-filled zone (proves the
   async full-res catches up). Attach before/after images.
4. **Memory bound.** Confirm `FrameCache.bytesMB` ≤ budget and RSS flat across a long
   frame-mode soak (`[WT-MEM]`/`MemTelemetry`) — the two-tier store must not leak or
   overrun.
5. **A/B knob.** Sweep `WT_STRIP_THUMB_PX` to show the perf/quality curve and justify the
   default.
6. **Churn-safety intact.** Re-run the frame-mode churn/soak (`WT_CHURNTEST` / the
   `WT_FSOAK` 25 %-hot day-jumps) on both platforms: **zero `[WT-FATAL]`/SIGSEGV**,
   harvester still fills, no new stalls.

## Definition of done + REQUIRED report

Ship on `main` (or a PR) with Windows CI green **and** clean Linux builds (6.12 + 6.8.3),
then produce a **detailed report**:

1. **What was done** — exact files/methods changed (`FrameCache.{h,cpp}` two-tier,
   provider, `repaint`, eviction; any QML) and which sub-approach (two-tier vs low-res
   harvest session) you chose.
2. **How** — the measurement outcome (Test 1) that drove the choice; how the
   delivery-thread/`QImage`-only safety and memory bounds were preserved; how it stayed
   platform-neutral.
3. **Proof — on BOTH platforms, with numbers not adjectives:** the before/after
   `strip_ms` distributions (Test 2, p95 < 1000 ms on HEVC), the frame-mode screenshots
   proving full-res stepping (Test 3), the memory/RSS evidence (Test 4), the A/B curve
   (Test 5), and the churn-safety result (Test 6).
4. **Residual/limitations** — e.g. if HEVC p95 lands at, say, 950 ms with little margin,
   or if the low-res-harvester alternative was needed and why.
