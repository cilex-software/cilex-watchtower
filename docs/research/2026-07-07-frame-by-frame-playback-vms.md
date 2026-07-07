# Frame-by-frame / single-frame-step playback in a VMS — industry research

**Date:** 2026-07-07
**Status:** Research synthesis (drives a Frame-Step feature for Watchtower playback). Not yet a plan.
**Method:** Deep-research harness — 5 search angles, 25 sources fetched, 98 claims extracted, 25 adversarially verified (3-vote, need 2/3 to kill) → **21 confirmed, 2 refuted, 2 unverified**. The workflow's final auto-synthesis pass was cut off by a session rate-limit; this report is hand-synthesised from the 21 verified claims (each cited below), with lower-confidence items from the source pool explicitly flagged.
**Update 2026-07-08:** the 2 previously-unverified claims (their votes had errored on the rate-limit) were **re-checked directly** against multiple independent sources — both now **confirmed** (details in "Re-verified" below). The FFmpeg-TS-seek one is material and refines §2/§4.

## Why

We want a **Step Forward / Step Backward (frame-by-frame)** control on Watchtower's playback so a reviewer can advance recorded footage one frame at a time to catch a face, a plate, or the exact instant of an event. The hard part is **backward stepping** with inter-frame-compressed H.264/H.265, and doing it on our stack: **Qt 6 / QML `QMediaPlayer` + FFmpeg backend, playing HLS from cilex-vision**. This documents what leading VMS + NLE tools actually do, the decode technique for the backward case, what Qt can and can't do, and the HLS-specific pitfalls — verified vs. not.

Pairs with: our continuous-timeline HLS seeking (`seekToWall`/`seekFar`, commits around `684643b`), the rendered-frame counter `_frameSeq` and the frame-vs-playhead smoothness probe (`WT_SMOOTHTEST`), and the motion-episode model.

---

## Executive summary (for our stack)

1. **Frame stepping is universally a *paused-only* control built on precise seek — not a transport speed.** Every VMS surveyed gates "next/previous frame" on the paused state.
2. **`QMediaPlayer` does not natively step frames, and precise-seek accuracy is its known weak spot.** The credible path on our exact stack is the FFmpeg-backed **QtAVPlayer**, which exposes `stepForward()` / `stepBackward()` and PTS-exact seeking — it exists precisely because `QMediaPlayer` lacks these.
3. **Backward one-frame is "seek to the preceding keyframe, decode forward through the GOP to target−1."** This is the confirmed technique across mpv, FFmpeg, and two patents; it needs a **decoded-frame cache** (LRU) so repeated back-steps within a GOP don't re-decode from the I-frame each time.
4. **HLS makes exact-frame addressing harder**: seeks are time-based and rounding/fragment-boundary effects can land you on the wrong frame. Frame stepping must work in **presentation-timestamp (PTS) space**, not wall-clock rounding.
5. **Keyboard conventions are settled**: gate on pause; VMS use dedicated keys (Genetec **M/N**, Wisenet **Ctrl+←/→**); the NLE world uses **J-K-L** shuttle + **←/→** for frame step; hardware **jog = frame-step, shuttle = speed**.

---

## 1. How professional VMS and NLE tools expose it (UX + keyboard)

**All frame-stepping is paused-only, and both directions are first-class.**

- **Genetec Security Center** — `M` = *Next frame*, `N` = *Previous frame*, each documented as "when your playback video is paused." It also ships a synchronised **`Ctrl+Shift+H` = "Previous frame all"** that steps every displayed camera back one frame at once. [1]
- **Wisenet WAVE** — `Ctrl+→` = next frame, `Ctrl+←` = previous frame, both "on pause" (the same keys speed up / slow down during play). Confirms backward frame-step as a shipping control in an H.264/H.265 VMS. [2]
- **Milestone XProtect Smart Client (2025 R1)** — a dedicated timeline control that steps one frame in **both** directions ("move to the frame just before or after the one currently viewed"), plus a **shuttle/jog-style variable transport**: dragging the timeline control farther from center plays faster in either direction. [3]

**NLE / editorial convention (what operators coming from video tools expect):**

- **J-K-L shuttle** is universal: `J` = play backward 1×, `K` = pause/stop, `L` = play forward 1× — confirmed identically in **Final Cut Pro** [4], **DaVinci Resolve** [5], and **Adobe Premiere Pro** [6].
- **Single-frame step in the J-K-L model**: hold `K` and tap `J`/`L` to step back/forward one frame — confirmed for DaVinci Resolve. [5]
- **Hardware jog/shuttle** (e.g. Contour ShuttleXpress): the **inner jog wheel = one-frame-at-a-time stepping**; the **outer shuttle ring = variable playback speed**. This is the canonical mental model for "jog vs shuttle." [7]

> Takeaway for us: dedicated on-screen ◁▷-with-bar buttons **enabled only when paused**, keyboard `,`/`.` or `←`/`→` for step (see §5), and optionally the jog=step / shuttle=speed split if we add a scrub control later.

---

## 2. The hard part — backward single-frame step with H.264/H.265

**Why it's hard (confirmed):** inter-frame compression means a P/B frame can't be decoded alone — you must first decode the frames it depends on. "To access P1, I1 needs to be first decoded." [8] So there is no "decode the previous frame directly"; you must reconstruct it.

**The confirmed technique — seek-to-keyframe + decode-forward:**

- **mpv's decoder wrapper** does exactly this for reverse playback: *"Seeking to a keyframe before the target point → decoding forward to the target → storing decoded frames in a `reverse_queue`,"* then returning them in reverse order. [9]
- mpv's own manual describes backward playback as *"feeding bits of data in forward, putting the result in a queue, returning the queue data to the VO in reverse,"* and warns it *"can require buffering an extreme amount of decoded data, and completely breaks pipelining."* [10]

**Caching is the performance key (confirmed via two patents):**

- A **decoded-frame cache with LRU eviction** stores recently decoded frames and reuses them: *"When the cache is full, a Least Recently Used (LRU) replacement policy is used."* [11] This is the "backward-playback frame cache" — without it, every back-step re-decodes from the I-frame.
- **US Patent 7,035,333 (Panasonic)** teaches reverse playback by decoding and storing a GOP's key frames (I/P) in memory, then decoding the intervening B-frames on demand in reverse time order — a cache strategy, not per-output re-decode. [12]

**Bounding memory (confirmed):** mpv caps the reverse buffers explicitly (`--video-reversal-buffer` / `--audio-reversal-buffer`) — "the approximate maximum amount of bytes that can be buffered"; when exceeded it **drops frames** rather than growing unbounded. [10] Any cache we build must be bounded the same way (directly relevant given our long history of playback RSS bounding).

**⚠ MPEG-TS caveat (confirmed 2026-07-08, and material — our HLS uses `.ts` segments):** on MPEG-TS with H.264/AVC, FFmpeg's `av_seek_frame()` with `AVSEEK_FLAG_BACKWARD` is **unreliable — it does *not* dependably land on the preceding keyframe**; it can land on the exact timestamp (like `AVSEEK_FLAG_ANY`) or even the *next* keyframe. Root cause: TS has no global index, so seeking is a PCR-based binary search, worsened by audio/video PTS interaction. Corroborated by four independent FFmpeg mailing-list threads + the documented mechanism [21][22][23][24]. The standard workaround (also confirmed): **over-seek** — seek to a point safely *before* the target, reset the decoder, and decode forward to the target, verifying by decoded PTS.

> Takeaway for us: a back-step = seek to a point *before* the current GOP's I-frame (over-seek — do **not** trust `AVSEEK_FLAG_BACKWARD` to land before the target on TS), decode forward to (current − 1), display. Cache the decoded frames of the *current GOP* so consecutive back-steps within one GOP are cheap; bound the cache and evict LRU. Prefer `avformat_seek_file()` with a min/max-ts window over bare `av_seek_frame()` for more control. **Mitigation already in our favour:** our player seeks via libavformat's *HLS* demuxer (segment-level selection from the playlist), and our continuous-timeline work + `_frameSeq` frame-arrival detection mean we already coarse-seek-then-confirm rather than trusting one exact seek — so we sidestep the worst of the raw-TS imprecision.

---

## 3. Qt 6 `QMediaPlayer` — what it can't do, and the way around it

- **No native frame stepping in `QMediaPlayer`.** This wasn't verifiable as a single primary-doc quote, but is corroborated indirectly: the W3C media group confirms *browsers* have "no easy way to process media elements on a frame by frame basis" [13] — the same gap Qt has — and the existence of purpose-built libraries (below) is because the stock player lacks it. *(Confidence: the Qt-specific "no native step" is reported across the Qt-forum sources in the pool [14][15][16] but was not in the adversarially-verified top-25 — treat as strong-but-not-independently-verified.)*
- **Precise-seek accuracy is unreliable in the general case.** Confirmed on the parallel web platform: *"internal rounding of time values may mean that one seeks to the end of the previous frame instead of the beginning of a specific video frame."* [13] The Qt forum pool reports the concrete Qt symptoms — `setPosition()` snapping toward keyframes [16], and `QVideoFrame` not reporting correct `startTime`/`endTime` [15] — *(reported, not verified in this run)*.
- **The credible answer on our exact stack: QtAVPlayer** (FFmpeg-backed, same backend family as Qt's). It exposes:
  - `stepForward()` / `stepBackward()` — each *"always makes a step … and emits only one frame."* [17]
  - **PTS-exact seeking**: *"If there is a frame with needed pts, it will be returned as first frame"* [18] — i.e. it lands on the requested frame, not the nearest keyframe.

> Takeaway for us: don't expect `QMediaPlayer` to frame-step. Two realistic routes — **(a)** build stepping on top of pause + our own precise-seek-then-count-frames (we already have `_frameSeq` and a frame-arrival signal), or **(b)** adopt QtAVPlayer for the playback surface where frame-accuracy matters. The plan will weigh these against our HLS delivery and existing seek machinery.

---

## 4. Frame-accurate seeking in HLS / fragmented streams

- **Exact-frame addressing is inherently fragile** because seeks are time-based and rounding can miss the intended frame [13] — you must work in **PTS space** and verify the landed frame, not trust a computed time.
- **Real players expose a frame-addressed API over HLS/MSE.** Radiant Media Player's `seekToFrame(n)` accepts an absolute frame number **or** the literal `'next'`/`'previous'` to step exactly one frame, returning a Promise. [19] This is a concrete, shipping API shape for forward+backward stepping over segmented streams — a good model for our QML API surface.
- **Fragment boundaries are a known trap** (reported, source pool): the hls.js issue tracker documents seeking near a fragment boundary showing the wrong frame and needing look-up tolerance handling [20] — *(in the pool, not in the verified top-25; flagged because it maps directly onto our segmented delivery)*.

> Takeaway for us: our continuous-timeline HLS already gives contiguous PTS within a run (the `684643b` work), which is exactly the property frame-stepping needs. Stepping should compute target PTS = current ± (1 / fps) and confirm arrival via the rendered-frame signal, snapping within the loaded window rather than issuing a fresh time-seek per step.

---

## 5. Keyboard + jog/shuttle conventions (recommendation table)

Confirmed conventions, consolidated:

| Action | VMS (Genetec [1] / Wisenet [2]) | NLE (FCP/Resolve/Premiere [4][5][6]) | Recommended for Watchtower |
|---|---|---|---|
| Step forward 1 frame | `M` / `Ctrl+→` (paused) | `K`+tap `L`; also `→`/`.` | **`.`** and **`→`**, paused-only |
| Step backward 1 frame | `N` / `Ctrl+←` (paused) | `K`+tap `J`; also `←`/`,` | **`,`** and **`←`**, paused-only |
| Shuttle back / stop / fwd | — | `J` / `K` / `L` | `J`/`K`/`L` (optional, later) |
| Variable speed / scrub | XProtect drag-from-center [3] | shuttle ring [7] | jog=step, shuttle=speed (optional) |

- **Always gate stepping on pause** — the strongest cross-vendor invariant.
- Two-key convention pairs are common; offering both `,`/`.` (editor muscle-memory) and `←`/`→` (obvious) is low-cost.

> Note: a `←`/`→` binding must not collide with our existing scrubber −10/+10 s or far-seek keys — resolve by making arrows step-frame **only when paused**, and keep the ±10 s on the play state or on a modifier.

---

## Refuted / unverified (honesty)

- **Refuted (3-0):** "In mpv's backward mode the frame-step commands are transposed so a backward step is dramatically more expensive than forward." — mpv does not invert the commands; the *cost* asymmetry is real but the command semantics are not transposed. [10]
- **Refuted (1-2):** "Final Cut Pro's single-frame step is K+L / K+J." — not how FCP documents it; FCP uses arrow keys for frame step (K+J/K+L is the **Resolve** convention [5], which *is* confirmed).
**Re-verified 2026-07-08** (both were "unverified" only because their verification votes errored on the rate-limit — re-checked directly against independent sources):

- **✅ CONFIRMED (with nuance) — "FFmpeg `av_seek_frame()` + `AVSEEK_FLAG_BACKWARD` on MPEG-TS/H.264 does not dependably land on the preceding keyframe (≈ `AVSEEK_FLAG_ANY`)."** Corroborated by four independent FFmpeg mailing-list threads [21][22][23][24] and the documented PCR-binary-search mechanism (TS has no index). Nuance: the *exact* failure mode varies (lands on the exact timestamp, or sometimes the **next** keyframe) — the verified core is "**BACKWARD is unreliable on TS**," not a fixed "always == ANY." **Material to us** (our HLS is `.ts`-segmented) — folded into §2/§4 as the over-seek + decode-forward strategy; note our HLS-demuxer + frame-arrival confirmation already mitigate it.
- **✅ CONFIRMED — "Premiere frame-step is on the arrow keys; Shift+arrow jumps 5 frames; separate from J-K-L."** Adobe's official docs confirm Left/Right = frame-by-frame and **Shift+arrow = "step forward/back many" (default 5, configurable in Preferences → Playback)** [25], distinct from the J-K-L shuttle. (The original blog source [6] had internally-garbled left/right direction labels, but the substance holds and Adobe is authoritative.)

---

## Sources

Quality as rated by the harness (primary = official vendor/spec/patent; forum/blog = lower weight).

1. Genetec Security Center 5.12 keyboard shortcuts — *primary* — https://techdocs.genetec.com/r/en-US/Security-Center-User-Guide-5.12/Default-keyboard-shortcuts-in-Security-Desk
2. Wisenet WAVE keyboard shortcuts — *primary* — https://wavevms.com/data/help/keyboard_shortcuts.html
3. Milestone XProtect Smart Client 2025 R1 manual — *primary* — https://doc.milestonesys.com/sc/pdf/2025r1/en-US/MilestoneXProtectSmartClient_UserManual_en-US.pdf
4. Apple Final Cut Pro — Play media — *primary* — https://support.apple.com/guide/final-cut-pro/play-media-ver90ba4ef0/mac
5. DaVinci Resolve 18.6 manual (JKL playback) — *primary* — https://www.steakunderwater.com/VFXPedia/__man/Resolve18-6/DaVinciResolve18_Manual_files/part3552.htm
6. Premiere Pro J-K-L (No Film School) — *blog* — https://nofilmschool.com/2018/10/how-use-j-k-and-l-keys-premiere-pro-speed-your-workflow
7. Contour ShuttleXpress (jog vs shuttle) — *primary* — https://www.contourdesign.com/product/contour-shuttle-xpress
8. USPTO Patent 7,190,883 (frame dependencies / random access) — *primary* — https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7190883
9. mpv decoder wrapper (reverse_queue) — *secondary* — https://deepwiki.com/mpv-player/mpv/3.3-decoder-wrapper
10. mpv manual (backward decoding + reversal buffers) — *primary* — https://mpv.io/manual/master/
11. USPTO Patent 7,190,883 (LRU decoded-frame cache) — *primary* — (as 8)
12. USPTO Patent 7,035,333 (Panasonic, GOP key-frame store for reverse) — *primary* — https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7035333
13. W3C Media & Entertainment IG issue #4 (no frame-by-frame in browsers; seek rounding) — *primary* — https://github.com/w3c/media-and-entertainment/issues/4
14. Qt forum — seek video frame by frame with MediaPlayer — *forum* — https://forum.qt.io/topic/133704/how-to-seek-video-frame-by-frame-with-mediaplayer
15. Qt forum — QVideoFrame startTime/endTime incorrect — *forum* — https://forum.qt.io/topic/106091/qvideoframe-does-not-deliver-correct-starttime-and-endtime-qmediaplayer-issue
16. Qt forum — QMediaPlayer setPosition jumps to key frames — *forum* — https://forum.qt.io/topic/42392/qmediaplayer-setposition-jumps-to-key-frames
17. QtAVPlayer (stepForward/stepBackward) — *primary (repo)* — https://github.com/valbok/QtAVPlayer
18. QtAVPlayer (PTS-exact seek) — *primary (repo)* — (as 17)
19. Radiant Media Player — frame-accurate seeking (`seekToFrame`) — *primary* — https://www.radiantmediaplayer.com/docs/latest/frame-accurate-seeking.html
20. hls.js #2327 — seeking near fragment boundary / maxFragLookUpTolerance — *forum* — https://github.com/video-dev/hls.js/issues/2327

Additional pool sources (fetched, lower-yield): hls.js #6649, #7583.

**Re-verification sources (2026-07-08):**
21. libav-user — "Seeking backward to a key frame within transport stream" (the original report) — *forum* — https://ffmpeg.org/pipermail/libav-user/2013-September/005558.html
22. libav-user — "When Seeking … with AVSEEK_FLAG_BACKWARD, libav will seek to exact specified frame" — *forum* — https://www.mail-archive.com/libav-user@ffmpeg.org/msg12269.html
23. libav-user — "Why av_seek_frame with AVSEEK_FLAG_BACKWARD sometimes seeks to 'NEXT' keyframe?" — *forum* — https://www.mail-archive.com/libav-user@ffmpeg.org/msg11627.html
24. ffmpeg-devel — "av_seek_frame() issues with audio from MPEG-TS" (PCR-based-seek mechanism) — *forum* — https://ffmpeg-devel.ffmpeg.narkive.com/b1zJjFzM/av-seek-frame-issues-with-audio-from-mpeg-ts
25. Adobe — Premiere Pro default keyboard shortcuts (arrow = frame step, Shift+arrow = step-many) — *primary* — https://helpx.adobe.com/premiere/desktop/get-started/keyboard-shortcuts/default-keyboard-shortcuts.html

---

## Implications for Watchtower (bridge to the implementation plan)

The research validates a concrete direction that fits what we already have:

- **UI**: paused-only ◁▷ frame-step buttons on the playback transport + `,`/`.` and `←`/`→` keys (arrows step-frame only when paused, to avoid clashing with ±10 s seek).
- **Forward step**: trivial — advance to the next decoded frame (we already detect frame arrival via `_frameSeq` / the video-sink `frameChanged`).
- **Backward step**: seek to the current GOP's keyframe, decode forward to (current − 1), display; cache the current GOP's decoded frames (bounded, LRU) so repeated back-steps are cheap.
- **The Qt reality check**: `QMediaPlayer` won't frame-step or seek frame-accurately on its own — the plan must choose between (a) building step on pause + precise-seek + frame-count over our current player, and (b) QtAVPlayer for the frame-accurate surface. This is the central design decision the implementation plan will resolve, weighed against our HLS delivery, the continuous-timeline work, and the cross-platform (Linux VA-API / Windows D3D11) decode paths.
