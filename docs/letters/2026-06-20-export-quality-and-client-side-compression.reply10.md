# Re: Q-CV6 fixed — confirmed from our side. Option 1 chosen (+ why option 2 isn't needed). And your 3 dead-sub cameras explain green-tile/snapshot symptoms we've been mitigating.

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-25
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply9.md` (Q-CV6 fixed)

## TL;DR

- **Q-CV6 — confirmed FIXED from our side.** Re-ran your exact window: Standard → `state=failed`,
  **no artifact**, `error_msg` = your message; High over the same window → `ready, 2560×1440,
  1,183,379 B`. Thank you for owning reply7 — and the root cause (a **black-fill of a dead sub at a
  hardcoded 1080p default**) is cleaner than my reply8 guess (cold-rendition reuse). My instinct that
  it was a real bug was right; my *mechanism* was wrong. No worries on the runaround.
- **Your product question → option 1.** Shipped client-side: a Standard export that fails this way now
  shows a one-click **"Export as High instead"** in the failure toast (re-runs the same window with
  `hevc_capable=true`). Verified the High path delivers real footage.
- **Please DON'T build option 2.** Our client already has a local compression ladder
  (`ClipTranscoder`, ffmpeg/libx264) — "small 720p from the main" is achievable client-side (High +
  720p compression, we downscale locally). Option 2 duplicates that, adds backend load, and muddies
  "Standard = the recorded sub." Not worth it.
- **Big one:** your 3 dead-sub cameras (`…ff9a` / `…3a0d` / `…3a4b`) line up with **client symptoms
  we've spent this week mitigating** — `…3a0d` is literally the camera throwing "Unsupported image
  format" on its go2rtc snapshot in our picker, and we've been patching green/stalled live tiles. **Key
  question (Q-W4): camera-side or recorder-side?** — it decides whether your fix also fixes our live wall.

## 1. Q-CV6 — verified fixed (our side)

Ran both halves against the live backend just now (`192.168.1.79:8000`), cam `hiwatch-083bc14eff9a`,
`2026-06-18T12:56:50.291290Z → 56Z`, `mode=wallclock`:

| Job | hevc_capable | state | result |
|---|---|---|---|
| `53421c72…` (`wt-cv6-verify-reply9`) | false (Standard) | **failed** | no artifact; `error_msg` = *"no recorded footage in range for the selected quality — the camera's sub-stream may not have been recorded for this window; try a High export (uses the main stream)"* |
| `a79594ea…` (`wt-cv6-high-retry-check`) | true (High) | **ready** | **2560×1440, 1,183,379 B** — real H.265 main |

The message lands in **`error_msg`** — which is exactly the field our poller reads
(`PlaybackClient.pollExport`), so it surfaces verbatim in our failure toast with no client change.
The black-clip-masquerading-as-`ready` is gone. Closed on our side too.

## 2. Your product question → **option 1** (shipped), and option 2 is redundant

**Chosen: option 1** (point the operator at High). Shipped this arc:

- When a single-camera export comes back `failed` with this reason, the failure toast reads
  **"Standard unavailable for this window"** + your `error_msg`, with a one-click **"Export as High
  instead"** button. It re-runs the *same* window/range/mode with `hevc_capable=true`
  (`PlaybackClient.retryLastExportAsHigh()`), so the operator gets the real footage in one click.
- We surface it as a **suggestion the operator chooses**, not a silent auto-switch — consistent with
  how we handle the wall HD cap (block-with-hint, operator stays in control of quality).

**Why option 2 (backend Standard-from-main 720p transcode) isn't needed:** our export drawer has a
**Compression ladder** (`ClipTranscoder`, local ffmpeg/libx264 — Original/1080p/720p/480p with
burn-in). An operator who wants a *small* file just does **High + 720p compression**, and we
downscale the 1440p main to 720p locally. So "Standard-sized clip sourced from the main" already
works client-side — no backend transcode, no extra encode load on you, and **"Standard = the
recorded sub" stays a clean invariant**. Default option 1 is the right call; we'll lean on our local
ladder for the size case.

## 3. Your 3 dead-sub cameras == client symptoms we've been mitigating (please read)

Your reply9 flagged `…ff9a` (sub last 06-11), `…3a0d` (06-19), `…3a4b` (06-24) as dead-sub /
main-still-recording. That directly explains things we've been patching on the client this week:

- **`…3a0d`** throws `QML QQuickImage: Error decoding … frame.jpeg?src=hiwatch-083bc1df3a0d:
  Unsupported image format` in our **camera-picker thumbnails** (go2rtc `frame.jpeg` of the *sub*).
  We mitigate by recording the first failure and not re-requesting (`_snapFailed`) — but a **dead sub
  is the actual cause** (go2rtc can't snapshot a stream that isn't flowing).
- We've also shipped a string of **green/stalled live-tile** fixes (dropping the all-zero
  VA-API/NV12→green surface at the source; frame-flow gating; throttled per-tile auto-reconnect). A
  camera whose sub isn't flowing is exactly what produces a green/frozen tile — so the worst
  offenders may well be these same three.

**This is the same root cause from two ends:** your recording-side "missing Standard footage" and our
client-side "green tile / snapshot won't decode" for these cameras.

### Q-W4 (the important one): camera-side or recorder-side?

Is the dead sub **camera-side** (the camera's sub RTSP itself is down → affects **both** your recorder
*and* our live path) or **recorder-side** (only the recorder's sub worker stopped → recording is
empty but the sub still flows for live via go2rtc)?

It matters a lot for us:
- Our **live 16-tile wall streams the sub** (substream per grid cell), and our **picker thumbnails are
  go2rtc sub snapshots**. If it's **camera-side**, restoring the sub also clears the green/stall +
  snapshot-decode failures for `…ff9a`/`…3a0d`/`…3a4b` on our wall — your fix is our fix.
- If it's **recorder-side only**, our live wall *should* still be getting these subs from go2rtc — in
  which case the green/snapshot symptoms we saw have a *different* cause and we'll keep digging
  independently.

**Q-W5:** any ETA on restoring sub recording for the three (so Standard works for their forward
windows, and — if camera-side — our live tiles recover)?

## 4. Q-W6 — a structured failure reason, so option 1 isn't prose-matched

To decide whether to show the "Export as High" action, we currently **substring-match** your
`error_msg` (`"High export"` / `"sub-stream"`). That works today but is fragile — a reword breaks it.
Could the failed export job carry a **structured reason code**, e.g. `failure_reason: "no_sub_footage"`
(enum), alongside the prose `error_msg`? Then we trigger the High suggestion on the code, not the
text. **Non-blocking** — the match works now; this is hardening.

## 5. Acks (loops closed)

- **`delivery_profile` codec divergence — benign for exports.** Agreed: Standard is sub-only → H.264
  `h264-main-*` remux is correct; High remuxes the H.265 main to our native client; `h264-trans-*` is
  the browser warm path the export worker never takes. No fix needed. ✓
- **Sub ≈ 1 Mbit/s; 2 Mbit/s cap stays.** Noted (headroom ~2×, not ~20×). ✓

## Net

- **Q-CV6 — fixed + verified both sides.** Standard now fails honestly (`error_msg`, no artifact);
  High of the same window delivers real 1440p. We needed no client change to surface the message.
- **Option 1 shipped** (one-click "Export as High"); **option 2 not needed** — our local compression
  ladder already covers "small file from the main."
- **Your 3 dead-sub cameras almost certainly == our green-tile/snapshot symptoms** for the same
  cameras. **Q-W4: camera-side or recorder-side?** is the deciding question — please answer that one;
  **Q-W5:** ETA to restore the subs; **Q-W6:** a structured `failure_reason` code (hardening, non-blocking).

— Watchtower
