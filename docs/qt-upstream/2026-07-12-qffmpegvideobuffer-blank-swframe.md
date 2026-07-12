# Qt upstream report (QTBUG-ready): retained blank m_swFrame after failed av_hwframe_transfer_data → fake-success map → SIGSEGV in qImageFromVideoFrame

_Prepared 2026-07-12 from a field crash in Cilex Watchtower (VMS operator client).
Status: root cause proven at source + binary level with a deterministic reproducer;
one-hunk candidate patch attached; affects at least 6.12.0-beta1 line through
current `dev` (verified by source read on both)._

## Root cause and violated invariant

`QFFmpegVideoBuffer::map()` (src/plugins/multimedia/ffmpeg/qffmpegvideobuffer.cpp)
commits the member **before** the GPU→CPU transfer:

```cpp
if (!m_swFrame) {
    m_swFrame = makeAVFrame();                       // committed pre-transfer
    int ret = av_hwframe_transfer_data(m_swFrame.get(), m_hwFrame.get(), 0);
    if (ret < 0) {
        qWarning() << "Error transferring the data to system memory:" << ret;
        return {};                                   // m_swFrame stays non-null, BLANK
    }
    convertSWFrame();
}
...
mapData.planeCount = desc->nplanes;                  // > 0, from the format
mapData.data[i] = m_swFrame->data[i];                // ALL NULL on the blank frame
mapData.bytesPerLine[i] = m_swFrame->linesize[i];    // 0
```

FFmpeg documents `av_hwframe_transfer_data()` as leaving the destination
untouched/blank on failure. So after ONE failed transfer, **every subsequent
`map()` of that buffer skips the transfer and returns a *successful* MapData
(planeCount = nplanes) whose plane pointers are all null** — the invariant
"successful map ⇒ valid plane pointers" is violated. Downstream:

- `QVideoFrame::map()`'s only buffer-failure signal is `planeCount == 0` → the
  fake success propagates (qvideoframe.cpp).
- `QVideoFrame::toImage()` retries conversion whenever its cached image is null
  (qvideoframe.cpp) — and **one single `toImage()` call maps the buffer twice by
  itself**: `qImageFromVideoFrame` first tries the RHI texture path
  (`QVideoTextureHelper::createTextures` → `map()` #1 → transfer fails →
  graceful "Cannot map a video frame in ReadOnly mode!"), then falls back to
  the CPU converter (`map()` #2 → fake success → the pixel copy walks the null
  planes) → **SIGSEGV**. No second consumer is required.
- The RHI texture path itself survives fake-success maps only by accident:
  `mapData.dataSize` computes to 0, so texture upload reads nothing.

## Field evidence (two production crashes, ~6 h apart, same instruction)

Environment: Qt 6.12.0 online-SDK gcc_64 (libQt6Multimedia BuildID
`7a95ec5a8c7ba0a36d479ae400d5c0a9797198e8`, ffmpeg plugin BuildID
`73c735588e6834015e2307aca293de57b4efc6a7`; SBOM qtmultimedia revision
`e225aedb5ec76ca6a0fe7079c0b84dbcbb490553`); bundled FFmpeg 7.1
(libavcodec 61.19.101); VA-API: libva 2.20 / intel-media (iHD) 24.1.0,
AlderLake-S GT1; Mesa 25.2.8; kernel 6.17, Ubuntu 24.04.4, Wayland.
Stream: HEVC Main 2560×1440 over HLS; trigger: corrupt packets at truncated-TS
joints under session churn ("Packet corrupt" → "Failed to sync surface" →
transfer failure).

Both crashes (thread differs, instruction identical — intra-library frame
offsets match exactly; full `thread apply all bt` captures archived):

```
#2 qImageFromVideoFrame(QVideoFrame const&, VideoTransformation const&, bool)
#3 QVideoFrame::toImage() const
#4 FrameCache::captureFrame(...)            ← app capture tap
   ...preceded in the log by:
   [hls] Packet corrupt ...
   [AVHWFramesContext] Failed to sync surface 0x..: 1 (operation failed).
   Error transferring the data to system memory: -5
   Cannot map a video frame in ReadOnly mode!
```

## Deterministic reproducer (no corrupt stream needed)

`tools/xfer-interpose.c` — an LD_PRELOAD seam that force-fails the Nth
`av_hwframe_transfer_data` call (`XFER_FAIL_AFTER`/`XFER_FAIL_COUNT`; note Qt
loads its bundled FFmpeg into the plugin's local scope, so the seam resolves
the real symbol via `dlopen("libavutil.so.59", RTLD_NOLOAD)`).

With any VA-API (or other hw) playback app that calls `toImage()` on delivered
frames: fail ONE transfer → that same `toImage()` call crashes. Our capture:

```
[XFER] call#1 ... FORCED_FAIL(-5)
Error transferring the data to system memory: -5
Cannot map a video frame in ReadOnly mode!
Thread 1 received signal SIGSEGV
#2 qImageFromVideoFrame(...)   ← frame offsets identical to the field crashes
#3 QVideoFrame::toImage()
```

The interposer log doubles as the sequence proof: **no transfer attempt occurs
between the graceful failure and the crash** — the second map provably skipped
the transfer on the retained blank frame.

## Candidate patch (attached: `qffmpegvideobuffer-commit-on-success.patch`)

Commit `m_swFrame` only after a successful transfer (one hunk). This also
restores retryability: a later map of the same buffer legitimately re-attempts
the transfer (transient VA-API sync failures recover). Defensive hardening
worth considering additionally: `QVideoFrame::map()` could reject a MapData
whose planeCount > 0 while `data[0] == nullptr`.

## Experiments run (application side, Qt binary SDK)

| experiment | result |
|---|---|
| Force-fail 1 transfer (unpatched Qt, direct toImage) | SIGSEGV, instruction-identical to field crashes |
| App pre-map guard (map + `bits(0)==nullptr` check before toImage), single fail | 1/1 caught, no crash |
| Guard, 60- and 80-fail bursts | 60/60, 80/80 caught, no crash |
| Guard, every-transfer-fails torture (~2,000 frames, two runs) | 1761/1761 + 2240/2240 caught, no crash; render path co-existed safely |
| Full churn gauntlet (20 day-switches) + 60-fail storm | PASS, cache recovered post-storm, 0 SIGSEGV |
| `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=,` (software decode) | zero transfer calls → class structurally absent |
| `QT_DISABLE_HW_TEXTURES_CONVERSION=1` | same defect/protection; different first-mapper |

Not run: locally rebuilt patched Qt (the binary SDK's qt-configure-module
fails on `Qt6::GuiPrivate` target resolution for out-of-tree module builds —
patch is validated by mechanism + reproducer; Qt CI can validate directly).
Sanitizers: not run against a Qt debug build for the same reason; the null-plane
deref is fully characterized by the deterministic reproducer.

Relation to QTBUG-124586: possibly adjacent (VA-API map failures), not assumed
identical — this report stands on its own reproducer.

## Application-side mitigation shipped meanwhile (Watchtower)

Pre-map guard in the capture path: probe `map(ReadOnly)`; treat map-failure OR
map-success-with-`bits(0)==nullptr` (the fake-success signature) as a skipped
frame + brief capture damper. Extra cost on healthy frames ≈ 0 (the transfer
happens once; toImage's own map reuses the committed frame). Note for other
users: an earlier 3-second "latch after a null toImage" mitigation was
INEFFECTIVE against this defect — toImage never returns null here, it crashes;
only the pre-map probe intercepts the poisoned state.


## Reconciliation with the 2026-07-10 queued-frame UAF postmortem

Both postmortems stand; they describe two DIFFERENT layers that the corrupt-
packet storms exercise in sequence:

- The 07-10 finding (queued raw QVideoFrames converted after their decoder's
  AVHWFramesContext died) is a real lifetime hazard — stale lifetime IS one way
  `av_hwframe_transfer_data()` comes to fail. The DirectConnection fix removed
  that failure *source* for our taps.
- THIS finding is what turns any such transfer failure — stale lifetime,
  corrupt input, VA sync failure — from a recoverable error into a
  deterministic crash: Qt retains the blank m_swFrame and the next map lies.

I.e. 07-10 removed one trigger; 07-12 removes the amplifier that made every
remaining trigger fatal. The adjacent patches (0003 RHI frame balance, 0004
vaSyncSurface check, 0005 corrupt-flag surfacing) close the remaining paths
that let damaged surfaces travel silently.
