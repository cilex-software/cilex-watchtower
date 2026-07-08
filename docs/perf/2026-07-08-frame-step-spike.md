# P0 frame-step spike — findings (GATE: GO, with a simpler primitive than planned)

**Date:** 2026-07-08 · **Plan:** `docs/plans/2026-07-08-frame-step-plan.md` §P0 · **Verdict: GO** on the existing QMediaPlayer stack — the QtAVPlayer fallback is NOT needed. Two findings *improve* on the plan's assumptions; one stale belief was corrected.

**Method.** (a) GOP/fps ground truth via the playback API directly (sessions → `playlist.m3u8` → `.ts` segments → `ffprobe` per-frame `key_frame`/`pts_time`); (b) in-app measurements on the REAL playback path via a new `FrameClock` C++ probe on the video sink + a `WT_STEPSPIKE` phase machine in `PlaybackScreen` (phases: A cruise → B paused-seek → C landing-accuracy → D forward-flush ×100/60/60). Runs: `.106` HEVC 1440p ×2, `.201` H.264 720p ×1 — all on Qt 6.12/Wayland/VA-API.

## The five unknowns → answers

### 1. `QVideoFrame.startTime()` validity over our HLS-TS → **VALID, 100%**
481/481 rendered frames across all runs carried a real PTS (`invalidPts=0` everywhere); `FrameClock`'s median frame duration (50.0 ms) matches ffprobe ground truth exactly. **The research's "startTime can be −1" concern does not apply to our backend/stream.** → `FrameClock` ships as the stepping PTS source; its PTS ring gives **exact previous-frame targets** for back-steps through recently-played footage.

### 2. Paused-seek rendering on Qt 6.12 → **PAUSED SEEKS RENDER (exactly 1 frame)**
All 9 reps (3 per run): a `player.position` change while paused painted **exactly one frame** (`framesDelta=1`) — the landed frame. The `EvHeroPlayer` "paused seeks render nothing" comment is **stale on 6.12** (true when written, on the older backend). Consequence: **backward step needs NO play/pause cycle at all** — a paused seek + PTS verify is the whole primitive. (Keep the play-flush variant as the 6.8-fallback path guard; `build68` remains our fallback toolchain.)

### 3. Seek landing accuracy → **frame-grid quantized, NO keyframe snapping; VFR wobble confirmed**
Position-domain requests land PTS-quantized to the frame grid:
- `−25 ms` (sub-frame): stays on the same frame (4/5, 5/5) — sub-frame requests round, so back-step targets must clear a full local frame interval;
- `−50 ms`: previous frame (or −100 where the local VFR gap was 100 ms; once same-frame);
- `−75 ms`: −50/−100/−150 mix — the frame grid under VFR;
- **no rep ever snapped to a GOP head** — the backend does precise decode-to-target internally, at **~15–30 ms** true latency for in-buffer backward seeks (measured 300–332 ms minus the 300 ms instrument settle). The plan's 100–300 ms GOP-decode estimate was pessimistic: with 30–60-frame GOPs on HW decode, backward landing is effectively instant.
- **Window-edge clamp (incidental finding):** at the loaded window's start, position writes clamp silently (`posDeltaMs=0`) — the stepper's edge fallback (route via `seekToWall`) is mandatory, and `pos≈0` must be detected *before* seeking. (The spike's `d=250` rows measured this clamp, not seek accuracy — the T-form open lands ~6.6 s into the window and phase B consumed that runway; accepted, since d=50/75 already answer the accuracy question.)

### 4. GOP structure (ffprobe, real recordings) → **30–60-frame GOPs; true VFR streams**

| Stream | Codec / res | GOP | Frame-interval histogram (ms) |
|---|---|---|---|
| `.201` main (hot) | HEVC 2560×1440 | **60 f ≈ 3.0 s** | 50×307 · 100×145 (+49/99 jitter) |
| `.201` sub (warm) | H.264 1280×720 | **30 f ≈ 1.5 s** | 50×306 · 100×146 |
| `.106` main (warm) | HEVC 2560×1440 | **60 f ≈ 2.0–4.0 s** | 25×78 · 50×446 · 100×194 |

The cameras emit **true VFR** (motion-adaptive: 40/20/10 fps regimes, container declares 15). A fixed frameDur estimate would same-frame ~⅓ of back-steps → **PTS-exact targets (ring) + verify-after-step are the main path, not a safety net.** Also: the tier model has drifted from the 05-26 contract — `.106`'s 8-day-old footage serves as **HEVC 1440p `warm`** (not H.264-720p-sub); fragment `codec`/`resolution` fields remain the only truth. ✔ matches how we already drive the decoder.

### 5. Forward play→pause-on-first-frame → **99.5% exact single-frame; ~50–100 ms true latency**
220 flush cycles: `advHist` = **217×1 frame, 1×2, 1×3** (≈0.9% overshoot; P2's verify corrects those), `ptsAdvHist` = +50 ms (~64%) / +100 ms (~33%) — i.e. the *actual next recorded frame* under VFR, which is correct stepping. Latency P50 350 / P95 400 ms **including the 300 ms instrument settle** → true ≈ **50–100 ms**.

## Revised primitive (supersedes plan §D2 — simpler)

- **Forward:** `play()` → pause on first `videoFrameChanged` (proven 99.5% exact, no seek).
- **Backward:** while paused: target PTS = `FrameClock.prevPtsMs(current)` (exact, from the ring) — else `current − 1.5×medianDur`; seek `player.position += (targetPts − lastPts)`; the landed frame **paints on its own** (finding 2); verify landed PTS < pre-step PTS, retry deeper (bounded) on same-frame.
- **Edges:** `pos ≤ ~1 frame` or crossing a `disc` boundary → `seekToWall` slow path (finding 3's clamp).

## Operational side-finding (needs the user's attention)
**No camera has recorded since 2026-07-01 15:16 UTC** (`live_gap_s ≈ 6.3 days` on session create; `functions.recording.enabled=true` still). `.67` is the known login-lockout; `.201` also stopped Jul 1 — so the fleet currently records **nothing** despite recording being "on". Also visible: `/streams` now lists 33 cameras and carries the new `functions` keys (`core`, `monitoring`, `nlp_search`, `dev_tools`) — our fail-safe parser ignores them correctly.

**Next:** P1 (step engine + forward step + UI + keys + i18n) per the plan, with §D2 replaced by the revised primitive above.
