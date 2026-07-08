# Frame-by-frame stepping on Windows / d3d11 — verification (2026-07-08)

**Result: GREEN.** The P0 assumptions that gated the frame-step design (`docs/plans/2026-07-08-frame-step-plan.md`)
were measured on VA-API (Linux) only. This note re-verifies them on the **d3d11 / Qt-FFmpeg-D3D11VA**
playback path on Windows. They hold **identically** — no per-backend divergence, nothing to patch around.

## Environment
- **Box:** Windows 10 Pro 19045, **NVIDIA GTX 1070** + Intel UHD 630 (dual-GPU). Qt **6.12.0** msvc2022_64.
- **Build:** CI artifact `watchtower-portable` from run `28944878755` (`f725784`, current `main` HEAD) —
  the fresh i18n + frame-step + VIEW-ISSUE build. Unpacked at `C:\git\portable\2026-07-08\`.
- **Backend:** cilex-vision over **Tailscale** (`http://100.107.51.72:8000`, admin/admin autologin). The
  `192.168.1.79` LAN address is **not reachable** from this box (Wi-Fi AP client-isolation: TCP 8000 and
  ICMP both fail); Tailscale peer `cilex-vision-server` is `active; direct`, and live/playback both proxy
  through `:8000`, so the Tailscale route is sufficient. (Same finding as the 2026-07-06 W2 bring-up.)
- **Footage:** `.106` (`hiwatch-083bc14eff9a`), day `2026-06-29`, boot instant `15:30:00` **local**
  (= 14:30 UTC; the box is GMT/BST). Landed inside the 06-29 window (footage 09:49–14:47 UTC / 10:49–15:47
  local). The decoded stream is **`hevc (Main) 2560×1440, ~20 fps`** — i.e. real **HEVC 1440p** playback,
  the decoder-heavy case the plan wanted. (Coverage reports 06-29 as tier `warm`; `warm` is a **storage**
  tier, not a codec — the HEVC main stream is still what plays. Corrects the 2026-07-07 soak note's
  "warm ⇒ H.264 720p" assumption for this day/instant.)

## How it was driven
`packaging`-style env harness (`C:\git\portable\run-steptest.ps1`), all trace to a redirected stderr
(`QT_FORCE_STDERR_LOGGING=1`), the app boots straight into Playback and self-runs the acceptance soak:
```
WT_CV_URL=http://100.107.51.72:8000  WT_CV_AUTOLOGIN=1  WT_TRACE=1
WT_PLAYBACK_IP=192.168.1.106  WT_PLAYBACK_DAY=2026-06-29T15:30:00  WT_STEPTEST=100
```
`WT_STEPTEST=<N>` = the P2 acceptance harness: alternating blocks of 10 forward / 12 backward steps
(net −2 frames/cycle drifts the playhead below the cache floor so every path — cache hit, direct
flush, overseek+walk refill — gets exercised), asserting direction per step and quitting with a
`[STEPT] SUMMARY`. Session open: `session_ready dt=512ms frags=1813`, bounded window `frags=252`
around `tgt=15:29:45`.

## Result — [STEPT] SUMMARY (d3d11, HEVC 1440p)
```
[STEPT] SUMMARY steps=100 wrongWay=0 fails=0 paths={"flush":28,"cache":70,"walk":2}
        fwd(n=50 p50=132 p95=223) back(n=50 p50=0 p95=0) cache=25f/8.0MB
[STEPT] DONE   (app quit clean, 0 [WT-FATAL], no watchdog/seekFar re-opens)
```

| Acceptance gate (prompt §B) | Required | Measured | Verdict |
|---|---|---|---|
| `wrongWay` (steps that moved the wrong way) | 0 | **0** | ✅ |
| `fails` | ≤ 1 (window-edge only) | **0** | ✅ |
| back-step p50 | ≈ 0 ms | **0 ms** (p95 also 0) | ✅ |
| forward-step latency | — | p50 132 / p95 223 ms | ✅ (one play-flush frame) |
| paths | cache carries hot back-steps | flush 28 / **cache 70** / walk 2 | ✅ |

## The five P0 unknowns, re-answered on d3d11
1. **`QVideoFrame` PTS validity** — VALID. Every `[WT-STEP]` line reports a readable `dPts` (`±50.0`,
   `±100.0` ms); `wrongWay=0` is a PTS-verified assertion, so PTS drives stepping on d3d11 exactly as on
   VA-API. (No fallback to mid-interval-only estimation was needed.)
2. **Paused-seek rendering / play-flush primitive** — works. Forward steps land via `flush` (play →
   pause-on-first-frame) at `paintMs≈49–99 ms`; the primitive never relies on a bare paused seek, so the
   6.8-vs-6.12 paused-seek difference is moot here too.
3. **Seek landing accuracy** — frame-exact. `dPts` lands on discrete frame boundaries (50 ms grid at
   ~20 fps); no keyframe snapping observed. When a direct back-seek under-shoots into the recently-stepped
   hot zone, the documented `overseek+walk` fallback fires and lands exact: e.g.
   `back overseek behind=300 newPos=150 retries=1` → `landed dPts=-50.0 via overseek+walk(7) fullMs=1634`.
4. **GOP / back-step latency** — the decoded-frame cache makes it a non-issue: **70/100 back-steps were
   cache hits at p50=0 ms**. Only 2 `walk` refills (~1.6 s each) across the run — the same hot-zone
   pathology P1 measured on Linux, absorbed by the P2 cache identically here.
5. **Forward-step overshoot** — none material. `fwd` deltas are a clean `+50`/`+100` (single-frame, with
   the occasional VFR double), no 2-frame runaway; `wrongWay=0` on the forward half too.

## Second run — `.201`, fresh same-day (07-08) footage
Requested corroboration on a different camera + *live-recorded* footage (not an aged archive):
`.201` (`hiwatch-0c75d29549ad`, DS-I402(D)), day **2026-07-08**, boot instant `18:00:00` local
(mid-window; `.201` recorded ~7.5 h today, 15:02–22:32 local, near-continuous, after the recording
outage lifted). Session `session_ready dt=481ms frags=901`; the recorded main stream also decodes as
`hevc (Main) 2560×1440 ~20fps` (the "hot" tier — so this is fresh same-day HEVC 1440p; the live-wall
`[WT-DEC] d3d11h264dec` line is the separate SD substream).

```
[STEPT] SUMMARY steps=100 wrongWay=0 fails=0 paths={"flush":28,"cache":70,"walk":2}
        fwd(n=50 p50=132 p95=233) back(n=50 p50=0 p95=0) cache=24f/11.2MB
```

Byte-for-byte the same verdict as the `.106` run — wrongWay=0, fails=0, back p50=0 ms (70/100 cache
hits), fwd p50=132 ms, one clean overseek+walk fallback (`dPts=-50.0 fullMs=1535`). Frame stepping
holds on a second camera and on **freshly recorded** footage, not just historical archives.

## Conclusion
Frame stepping is **at parity on Windows/d3d11 with the Linux/VA-API baseline** — PTS-verified direction,
hot-cache back-steps at ~0 ms, exact forward flush, clean overseek+walk fallback, 0 fails, 0 fatals, no
watchdog interference. No d3d11-specific behavior divergence was found; **no code change is warranted.**
This closes the frame-step Windows-parity risk row in the plan (§5 "Windows parity") on the PlaybackScreen
surface.

## Caveats / not-yet-covered
- **HEVC hardware-decode via D3D11VA not independently confirmed by a GPU counter.** The *stepping
  behavior* is proven on HEVC 1440p footage, but whether the QMediaPlayer/FFmpeg playback path used the
  D3D11VA hwaccel (vs a software HEVC decode) is an eyes-on gate — Task Manager → GPU → Video Decode during
  1× playback (W2-RUNBOOK Step 3, tracked under the W2 eyes-on gates).
- **Live HEVC decode (`d3d11h265dec`) not exercisable right now.** All HEVC HiWatch cameras are physically
  unplugged (client-site install, see the recording-outage letter); the only live cameras are `.201`
  (H.264, `d3d11h264dec` — proven in W2) and `.67` (H.264, RECORDING STALLED). Live HEVC decode returns
  when an HEVC camera is back online.
- **Events hero player (P4) step on real footage still blocked** by the recording outage (newest events
  return 0-ready-fragment manifests) — unchanged from the plan's P4 note; the engine is the same
  soak-proven path.
