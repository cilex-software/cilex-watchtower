# Windows FSOAK: filmstrip <1 s holds (HW-decoded), but the HLS proxy WEDGES under heavy-day re-open churn

**Platform:** Windows 10 (desktop--alienware, 12 cores), the `windows.yml` port —
NOT the Linux VA-API box the earlier fsoak validated. Decode path here is Qt's
FFmpeg backend + **D3D11VA**, and the low-latency live path is GStreamer
`d3d11h264dec`. Build = `453aa45` (fsoak rounds 2-4), fetched as a portable zip
from the new `windows-latest` CI **release** (see the CI note below).

**Backend:** cilex-vision reached over **Tailscale** (`100.107.51.72:8000`) — the
`192.168.1.x` LAN is dead from this box (Wi-Fi isolated; traffic routes via
Tailscale). Playback HLS streams fine over Tailscale (segments 80-150 ms).

**Harness:** `WT_FSOAK` + `WT_FSOAK_PLAN`, two instances (`≤2/server`):
**A** = current (`.201` 4 days incl. today's live edge, `.67` 3 days,
continuous-recording → multi-thousand-frag manifests), **B** = archived warm tier
(`.106`/`.120`, sparse motion days). Runner/analyzer: `C:\git\portable\fsoak\`.

## Result summary

| Metric | Windows result |
|---|---|
| Crashes (`[WT-FATAL]`/SIGSEGV) | **0** across ~90 cycles / 4 runs |
| Hard GUI freezes (`[HB]` gap >2 s) | **0** (worst gap ~1.07 s) |
| Filmstrip `strip_ms` < 1 s — H.264 1080p (`.67`) | **PASS** (~850 ms typical) |
| Filmstrip `strip_ms` < 1 s — HEVC 1440p (`.201/.106/.120`) | **MARGINAL** — p50 ~1100 ms, ~40 % just over the 1 s gate |
| **Day-open availability under churn** | 🔴 **WEDGES** — see below |

The Linux fsoak got 97/97 current strips < 1 s and 0 wedges. Both Windows issues
below are **platform-specific** and were invisible to the Linux run.

## Finding 1 (marginal): HEVC 1440p filmstrip ~1100 ms — HW-decoded, readback-bound

Qt's FFmpeg backend **is** hardware-decoding HEVC — confirmed in
`qt.multimedia.ffmpeg.hwaccel` logs: `Found potential codec "hevc" … Checking HW
context: d3d11va … HW device is OK … Selected format 171` (= `AV_PIX_FMT_D3D11`),
stream `hevc (Main) 2560x1440`. So the ~1100 ms is **not** software decode.

The split is by codec/resolution, not by instance-contention: H.264 1080p (`.67`)
strips fill in ~850 ms (PASS); HEVC 1440p strips take ~1100 ms — just over the
gate. The harvester decodes at 2× and reads each frame back GPU→CPU
(`FrameCache.toImage`) + JPEG-encodes it; a 2560×1440 HEVC D3D11 surface is
~3-4× the readback/encode cost of a 1280×720/1920×1080 H.264 frame, which is
enough to push the 7-slot fill past 1 s on this box. Marginal — it straddles the
line; the strip always chains, it's just slightly slow.

**Options:** read harvest frames back at a reduced resolution for the strip
thumbnails (the main frame-by-frame view can keep full-res), or accept ~1.1 s on
1440p HEVC as within tolerance. Not a decode-mode bug.

## Finding 2 (severe): the main player's HLS proxy WEDGES under heavy-day re-open churn

After a variable number of rapid heavy-day opens, **every** subsequent day-open
fails: `ttff > 25 s`, `cache=0f`, permanently. The identical open (`.201`/`07-10`,
284 frags) took **2.0 s at n=0 but > 25 s after the wedge**. Onset is variable and
**contention-accelerated**: cycle **13** under 2 instances, cycle **~38** solo,
cycle **8** solo (a 2nd run) — the signature of an event-loop stall under load,
not a deterministic code path.

### It is the HLS proxy thread, proven

- FFmpeg reports `qt.multimedia.ffmpeg.mediadataholder: Could not open media.
  FFmpeg error description: Immediate exit requested` / `Error number -138` on
  every post-wedge open. "Immediate exit requested" is FFmpeg's **avio interrupt
  (I/O timeout)** — the demuxer is waiting on the loopback proxy and giving up.
- The manifest HTTP (`POST /review/sessions`, playlist GET) still returns **200** —
  the backend and the app's own `PlaybackClient` NAM are fine.
- It is **not** resource exhaustion: the wedged instance had *fewer* TCP
  connections (24) and comparable handles (1352) than the still-healthy other
  instance (36 conns / 1563 handles), and RSS oscillated (no leak).
- **Decisive probe** (curl the loopback ports of the wedged process): it has two
  `HlsProxy` listeners —
  - `127.0.0.1:59585` (the port FFmpeg opened against — the **main player's** proxy):
    `GET /` → **HTTP 000 after 6 s**, `GET /review/sessions/…/playlist.m3u8` →
    **HTTP 000 after 12 s**. Totally hung — including a bare `/` that needs zero
    upstream work (just an instant 404). Its **event loop is not processing socket
    events**.
  - `127.0.0.1:59588` (the **harvester's** proxy): `GET /` → 404 in 1 ms,
    playlist → **200 in 60 ms**. Healthy.
  - Backend direct → 200. Fine.

So the harvester is **not** the culprit — the **main playback proxy** stalls under
the main player's own re-open churn.

### Why heavy days churn re-opens

`PlaybackScreen.onSessionReady` deliberately does **not** attach a huge day
playlist (prerolling thousands of segments blew TTFF). For any day > 1200 frags it
bootstraps a bounded ~30-min window via `seekFar()`, and `EndOfMedia` rolls the
window forward with another `seekFar()`. Continuous-recording cameras (`.67`,
`.201`) hit this constantly; the soak's day-hop (new day every ~13 s) + far
preseek per cycle drives the re-open rate hard. Each `seekFar` is
`player.stop()` + new `setSource` against the single-threaded proxy.

`HlsProxy` runs on its own `QThread` with an async `QNetworkAccessManager` — there
is **no synchronous block visible in the code**, yet the event loop stops. Pinning
the exact stall needs a **native thread-stack capture** (WinDbg / procdump) on the
wedged process — black-box probing can't see which Qt/winsock operation the proxy
thread is parked in. Prime suspects: QNAM per-host connection backlog under the
prefetch+main+retry load, or a socket/reply state interaction specific to Windows
under rapid `player.stop()`-driven aborts.

### No recovery path

`MediaPlayer.onMediaStatusChanged` handles `EndOfMedia` (window roll-over) but
**not `InvalidMedia`**. `onSessionFailed` just sets `errorText` and clears the
source — it never recreates the poisoned proxy/player, so the wedge is permanent
until app restart.

## Root-cause capture (cdb, 2026-07-11)

Installed WinDbg via winget (cdb copied to `C:\wt\dbg`), reproduced the wedge under
2-instance contention, and auto-attached `cdb` to dump all 44 thread stacks (MS
public symbols). Findings:

- **The proxy event loop is ALIVE, not deadlocked.** With `WT_PROXY_STATS=1`, the
  proxy-thread timer keeps firing (~10×/15 s across the two proxies) *during* a
  stall; and **no thread is blocked on a lock with a Qt6Network/Qt6Core/watchtower
  caller** — the 19 `NtWaitForSingleObject` threads are FFmpeg demuxers + the
  NVIDIA D3D pool (`nvwgf2umx.dll`), and there are 9 live `MsgWaitForMultipleObjectsEx`
  event loops (GUI + the two proxies + workers).
- **The FFmpeg demuxer is blocked in `avformat_open_input`** (`av_probe_input_format3`
  → `WaitForSingleObject`) — i.e., stuck reading from the proxy's loopback socket,
  which is the direct wedge mechanism.
- **Pending upstream replies at the stall** (`PROXYSTATS … inflight=1 sockets=2
  replies=3`) with no gross backlog — the proxy has issued upstream GETs that have
  not completed.
- Two regimes: **frequent transient** stalls (an open exceeds 25 s then recovers)
  and a **rare permanent** hang (the bare-`/` probe timed out in one earlier run;
  did not recur across 13 min of 2-instance hunting).

**Conclusion:** the loopback socket that FFmpeg's `avformat_open_input` blocks on is
only ever written from the upstream reply's `finished` handler, and that upstream
GET has **no timeout** — so a single hung reply pins the socket (and the demuxer's
open) until Qt's avio interrupt gives up ("Immediate exit requested"), with the
stuck reply/socket/inflight entry never reclaimed. The proxy loop staying alive +
pending replies + demuxer-blocked-in-open all fit this.

## Fix applied (2026-07-11)

**Bound the proxy's upstream fetches** (`HlsProxy::forward()` + `startPrefetch()`):
`QNetworkRequest::setTransferTimeout(s_upstreamTimeoutMs)` (idle-based — resets on
each byte, so slow-but-progressing fetches are untouched; default 10 s, env
`WT_HLS_UPSTREAM_TIMEOUT_MS`). A hung reply now aborts → `forward()` writes a **502**
to the loopback socket → the FFmpeg demuxer's own segment-retry re-asks instead of
blocking forever, and the reply/socket/inflight entry is reclaimed. Safe/additive:
it changes only the hung-reply path; healthy fetches behave identically. Verifying
via re-soak (no playback regression + stalls reduced).

## Further hardening (if residual stalls remain after the timeout)

1. **Self-heal watchdog (mechanism-agnostic, additive — only fires when already
   wedged).** In `PlaybackScreen`, arm a timer on each session open; if no first
   frame arrives and `mediaStatus` shows failure/stall, restart the `HlsProxy`
   (tear down + re-`init()` on a fresh port) and re-open the current window. Covers
   the rare permanent hang regardless of mechanism. Must respect the churn-safe
   lifecycle in `docs/perf/2026-07-10-frame-mode-churn-segfault.md`.
2. **Reduce socket churn.** `Connection: close` per segment creates a high socket
   turnover that stresses Qt's Windows socket notifier; keep-alive would cut it —
   *but* FFmpeg's HLS reader may not reuse connections (`http_persistent`), so
   confirm effectiveness before investing.
3. **Reduce the trigger.** Rate-limit / coalesce `seekFar` re-opens; rapid operator
   seeking + day-hopping is legitimate and should not be able to wedge playback.
2. **Self-heal watchdog (mechanism-agnostic, additive — safe because it only fires
   when already wedged).** In `PlaybackScreen`, arm a timer on each session open;
   if no first frame arrives and `mediaStatus` shows failure/stall, treat it as a
   wedge → **restart the `HlsProxy`** (tear down + re-`init()` on a fresh port via
   a new `PlaybackClient` method) and re-open the current window. Restores the
   operator experience regardless of the exact stall mechanism. Must respect the
   churn-safe lifecycle rules in `docs/perf/2026-07-10-frame-mode-churn-segfault.md`.
3. **Reduce the trigger.** Rate-limit / coalesce `seekFar` re-opens; rapid operator
   seeking + day-hopping is legitimate and should not be able to wedge playback.

## CI note (unrelated, but blocked this work)

Every Windows build on 2026-07-10 compiled/deployed/installer-built cleanly and
then **failed at `Upload portable`: "Artifact storage quota has been hit. Usage is
recalculated every 6-12 hours."** The account-wide artifact quota lags deletes by
hours, so the latest `watchtower.exe` was unretrievable. Fix (branch
`ci/windows-release-publish`): publish the portable zip + installer to a rolling
`windows-latest` **Release** (separate storage, not subject to the artifact quota)
+ `contents: write` + `continue-on-error` on the artifact uploads. Verified — the
release published and this soak ran off it. Recommend merging.
