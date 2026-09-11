# Adaptive live quality (auto tier step-down) + remote live

**Status: TRANSPORT RUNG + HD→SD LADDER SHIPPED 2026-09-08 (mac).**
(prior:) **TRANSPORT UNBLOCKED 2026-09-07 evening** (CV reply
`2026-09-07-remote-live-exists-behind-the-api-port-and-the-numbers-you-asked-for.reply.md`):
remote live already exists — authenticated HLS/fMP4 through the API port,
the path Cilex Pro Mobile already uses. The `-opt` tier is measured feasible
and **waits on one word from the operator**. Phase 1 shipped from the Mac.
Owner for phases 2-3: Linux agent (video path, reference platform) unless the
operator directs otherwise.

## Problem, measured 2026-09-07

Off-site, no VPN: API :8000 reachable, go2rtc :8554 closed → wall shows
snapshot fallbacks with amber connecting bars; single-camera view is black
"Connecting…" forever (no backdrop, no escalation). Operator ask: YouTube-like
auto quality — if a stream struggles for X s, drop HD→SD, then →"optimised",
with the tier visibly badged like today's HD/SD chip.

Two separable problems:
1. **Transport** — remote live does not exist at all (CV letter, above).
2. **Adaptation** — on links that CAN carry live but not 16×HD/SD, step down.

## Phase 1 — honesty in the stuck state (SHIPPED, mac, this commit)

- `LoadingState` gains an optional `sublabel`.
- Single-camera view: after 12 s of active-but-not-playing, "Connecting…"
  gains "Still trying — the live stream may be unreachable or too slow from
  this network". No behavior change, purely what the operator sees.
- NOT done (needs a live backend to verify): snapshot backdrop in the single
  view, mirroring `CameraTile`'s `LiveThumb` connecting backdrop. Linux agent:
  `SingleCameraDetail` has `camera.snapshotUrl` available; same contract as
  the tile. Verify against the pilot before shipping.

## Phase 2 — the ladder (needs CV's opt tier for the third rung; HD→SD works today)

Per-`VideoSurface` consumer (tile + single view), a small tier controller:
- Tiers: `[main (HD), sub (SD), opt]` — URLs from `/streams`; never
  client-side resampling (15 fps law: rate is set on the cameras; tiers are
  server-side producers only).
- **Step-down triggers** (all from signals that already exist in
  `VideoSurface.qml`):
  - cold connect: 2 full connect cycles (~16 s) with `!_everPlayed` → next
    tier down;
  - degraded: existing `fps < 10` for 3 windows (~6 s), then 3 more → down;
  - repeated stall: ≥2 stall-reconnects inside 60 s → down.
- **Step-up**: manual always; automatic only in the single view after ≥5 min
  stable, probing one tier up ONCE (wall never auto-steps up mid-session —
  stability beats flicker).
- **Never blank on a switch**: a tier change is a url swap on the same camera
  — tile keeps its snapshot backdrop, single view keeps Phase-1 states;
  identity never changes, so nothing is cleared (CLAUDE.md stability rule).
- **Override**: extend the existing tri-state `hdOverride` to
  auto/HD/SD/opt; auto is default and follows the ladder.
- **Badge**: extend the HD/SD chip — shows the EFFECTIVE tier, prefixed when
  auto-chosen (`AUTO·SD`, `AUTO·OPT`); wall tiles get a small mono tier chip
  only when below their configured tier (no clutter at default).
- **Telemetry**: MEMTEL counters `tierDown`/`tierUp` so soaks and the booth
  log show ladder activity.

## Phase 3 — remote transport client work (shape depends on CV's answer)

- Live HLS: smallest client delta (reuse loopback proxy + player), seconds of
  latency, fine for remote spot-checks.
- rtsps://: GStreamer `rtspsrc` supports TLS; needs the CA story (already
  measured on mac: bundle CA via default QSslConfiguration — GStreamer needs
  its own knob, `tls-validation-flags`/database).
- WebRTC: best latency + congestion control, largest client lift.

## Evidence

- Port probes + colleague symptom analysis: the 2026-09-07 letter (above).
- Existing machinery cited: `qml/VideoSurface.qml` (`degraded`, fps windows,
  reconnect coordinator, cold-connect 8 s), `qml/CameraTile.qml` (snapshot
  backdrop + amber connecting bar), `qml/SingleCameraDetail.qml`
  (`hdOverride` tri-state, SD/HD chip).

## Update 2026-09-07 evening — the three answers, and corrections owned

Sources: CV's reply (above), the Linux agent's
`2026-09-07-uplink-measured-80-mbit-and-a-port-forward-nobody-announced.md`,
the booth's `2026-09-07-your-third-tier-exists-it-is-called-wall.reply.md`.

**Corrections (macOS agent, owning them):**
- My "16 sub tiles ≈ 16–32 Mbit/s" assumed 1–2 Mbit/s per sub tile. Measured:
  184 kbit/s (CV, one camera, today) / 223 kbit/s (fleet mean, August) →
  a 16-tile remote sub wall is ~3.0–3.6 Mbit/s. Uplink is 42 Mbit/s (CV,
  measured) or ~80 (Linux agent, measured; the agents' numbers differ — either
  way ≥10× headroom). The opt tier is for the VIEWER's downlink, not the site's
  uplink.
- "Ask CV to build a third tier" was half-blind: `{id}-wall` already existed
  (192×108, 8 fps, 50 kbit/s QVBR) — the booth ran it for weeks and removed it
  on 2026-08-29 (34 concurrent transcodes throttled the fleet to 8 fps:
  concurrency, not codec). `-opt` (640w @ 15 fps, ~393 kbit/s, CV-measured) is
  still the right NEW tier for remote viewers; `-wall` is thumbnail-grade and
  currently takes 11–21 s to first byte (CV's to fix).

**Transport for phase 3 (now concrete):**
- `GET /streams/live/stream.mp4?src=<id>-sub` (fMP4, one long GET, first bytes
  ~3.1 s) or `stream.m3u8` (HLS) — authenticated by the same `access_token`
  COOKIE the HlsProxy already carries (Authorization header NOT accepted).
  Reachable on :8443 (Let's Encrypt on the DDNS name — public cert, no CA
  bundling needed on that path) and :8000 (plaintext; the Linux agent has asked
  for :8000/:3000 to be closed at the router once mobile confirms).
- `/streams` already returns `hls_sub_url`, `hls_wall_url`, `webrtc_wall_url`,
  `rtsp_wall_url`, `rtsp_sub_url`; CameraModel parses only the rtsp pair today.

**New ladder constraints (from measurement):**
- Per-tier/per-transport CONNECT BUDGETS must exceed measured time-to-first-
  byte: fMP4 `-sub` ~3.1 s, `-opt` ~4.8 s, `-wall` 11–21 s — our current
  8 s cold-connect rebuild would strangle `-wall` by construction, and the
  step-down controller must never rebuild faster than the tier can deliver.
- A tier must hold 15 fps at its own resolution under the committed
  concurrency (booth §5; CV commits 32 concurrent `-opt` fleet-wide, failure
  past the cap is go2rtc OOM = every stream drops). 8 fps under load is a
  fault to diagnose, not a tier.
- Client plumbing seed already exists: `WT_WALL_STREAM_SUFFIX`
  (CameraModel.cpp:461-476) rewrites the wall's sub-URL suffix client-side —
  the tier switch needs a producer and a policy, not new plumbing (booth §2).


## Update 2026-09-08 — Transport rung + HD→SD ladder SHIPPED (mac)

Implemented and pushed from the Mac (shared code, straight to main per CLAUDE.md).

**What shipped**
- **Transport rung (C++).** `LiveProxy` — an app-lifetime loopback proxy (its own
  thread, mirrors `AuthController` baseUrl/token like PlaybackClient's) exposing
  `LiveHttp.liveUrlFor(rtspUrl)`. `HlsProxy` gained a strict `/live/stream.mp4?src=<name>`
  route → authenticated upstream `/streams/live/stream.mp4?src=<name>` (`forwardLive`:
  progressive passthrough, no cache/single-flight/retry, honest 502, aborts upstream
  when the player hangs up). `src/models/LiveProxy.{h,cpp}`, `HlsProxy.{h,cpp}`,
  `main.cpp`, `CMakeLists.txt`.
- **Source ladder (QML).** `VideoSurface` gained `tiers: [{url,badge}]` (best first).
  When non-empty it owns `url`, and steps DOWN on measured failure: a cold connect
  that will not complete (2×~8 s), or sustained `degraded` (8 s). Backend is chosen by
  URL scheme so the http fMP4 rung uses QtMultimedia, not the rtsp-only pipeline.
  Legacy single-`url` callers (VideoTest) unchanged.
- **Consumers.** `SingleCameraDetail` builds HD→SD→SD·NET (preference is the ceiling;
  a forced tier collapses to that tier + its NET fallback) and the SD/HD chip now shows
  the EFFECTIVE tier, amber + `AUTO` when the ladder chose it. `CameraTile` builds
  [quality-rtsp, quality-NET] and shows a small amber tier chip only when stepped down.
- **Recycler reconciled.** The tile's stuck-pipeline recycler (`errRecycle`) now
  ADVANCES the ladder when a lighter rung exists instead of destroying+rebuilding the
  surface (which reset the ladder and looped on an unreachable transport). Only at the
  lowest rung does it fall back to the original destroy-and-rebuild.

**Verified (offscreen, mac, against a one-camera CV mock: dead RTSP port + a real
fragmented-MP4 on the fMP4 route)**
- Isolated proxy: `/live/stream.mp4?src=` → 200, first byte ~1 ms, PROGRESSIVE; path
  traversal / wrong-file / percent-encoded dots all rejected; upstream failure → 502.
- Ladder: RTSP cold-fail → `[TIER] step down → SD·NET (cold-connect)`; error-driven →
  `[WT-TILE] stepping tier down (errored)` → `[TIER] step down → SD·NET (recycle)`.
- The client then issues the AUTHENTICATED `GET /streams/live/stream.mp4?src=cam1-sub`
  — the transport is consumed end to end.
- The `SD·NET` amber tier chip renders on the wall tile (screenshot).

**NOT yet verified — needs a real display or the live backend**
- Actual fMP4 PIXELS rendering. Offscreen QtMultimedia probes ~128 KB then waits with
  no VideoOutput sink pulling (the documented offscreen no-render caveat in
  DEVELOPMENT.md), so the last mile — frames on screen from the fMP4 rung — must be
  confirmed on a real display or against the pilot from a network where RTSP is blocked.
- Auto step-UP (single view, after long stability): deliberately NOT built yet
  (stability beats flicker); manual step-up via the SD/HD chip works.
- `-opt` rung: waits on CV (operator's "build -opt"). Slots below SD when it ships.

## Update 2026-09-11 — the HTTP rung was dead on macOS; it is HLS now, and LAN tiles stay on RTSP

**Symptoms (operator, 2026-09-10/11):** remote wall — tiles on `SD·NET` all
"STREAM UNAVAILABLE", 119 × "Failed to load media"; on the site LAN — some tiles
pushed to `SD·NET` by one-off errors while neighbours played on RTSP, then dead.
The operator's downlink measured **108 Mbit/s** — bandwidth was never the cause.

**Root cause, measured:** Homebrew Qt on macOS ships ONLY the AVFoundation
("darwin") media backend (`qt.multimedia.plugin: Available backends ("darwin")`).
AVFoundation cannot play a never-ending progressive fMP4: on the real Cocoa run
loop `QMediaPlayer` fails at 2.3 s with exactly "Failed to load media" (status
InvalidMedia). The same stream decodes fine with `ffmpeg` (first frame 3.8 s).
Two harness lessons paid for on the way: (1) `QCoreApplication`/`offscreen` never
pumps the Cocoa run loop, so the darwin backend silently does nothing — earlier
"128 KB then stall" mock readings were partly that; (2) fake `$HOME` does not
isolate QSettings on macOS (`cfprefsd` serves the cached domain), so test
instances silently used the operator's real session.

**Fix (shipped):**
- The HTTP rung is **HLS** (`/streams/live/stream.m3u8?src=`): proxy route
  `/live/stream.m3u8`, `/live/hls/playlist.m3u8?…`, `/live/hls/segment.ts?…`
  (playlists pass through unmodified; go2rtc's relative refs resolve back under
  `/live/`), HEAD answered headers-only. `stream.mp4` stays routed for
  FFmpeg-backend platforms. Verified on AVFoundation via the proxy: first frame
  2.2 s, ~15 fps, 1280×720; 8 concurrent all play.
- Live requests round-robin over a **4-manager keep-alive pool** (HLS = many short
  requests; the 6-per-host cap only starves long-lived GETs, which no longer exist).
- **RTSP-reachable gate**: `ReconnectCoordinator.noteRtspFrame()` records the last
  rtsp frame seen by any surface; `VideoSurface.canStepDownTier` refuses an
  rtsp→http step while that is < 60 s old. Quality steps within a transport are
  unaffected. The tile recycler consults the same gate. A laptop roaming off the
  VPN mid-session still falls back after the 60 s decay.
- HTTP rung cold-connect budget raised to 15 s (HLS master→media→segments; the
  `-opt` transcode measured 6.8–7.3 s to first frame).

**Next: the `-opt` rung.** Over HLS via the proxy on AVFoundation (measured
2026-09-11): `-opt` first frame 9.6 s, 640×360, ~256 kbit/s at night; `-wall` first
frame 13.9 s, 192×108, ~8 fps — it WORKS over HLS (the "0 bytes for 15 s" was
fMP4-specific, corrected). Both fit the 15 s HTTP budget, `-wall` barely. Letter
`2026-09-11-transcoded-rungs-over-hls-start-in-10-14-s-and-the-request-rate.md`
asks CV for start-up figures, `-opt` confirmation + cap, and 1–2 s HLS segments
(0.5 s segments ≈ 5.4 req/s per tile; a 25-tile wall ≈ 135 req/s).

## Update 2026-09-11 (evening) — OPT·NET rung shipped, remote wall budget, CV's numbers

CV's reply (`2026-09-11-transcoded-rungs-over-hls-start-in-10-14-s-and-the-request-rate.reply.md`):
producer spin-up confirmed (cold 4.7–6.3 s at go2rtc, warm 0.00 s; encoder flags
do nothing); `-opt` official on 133 cameras, cap 32 enforced with
`503 opt_tier_budget_exhausted` + Retry-After; `hls_opt_url`/`rtsp_opt_url` in
`/streams` since d94f28d; 0.5 s HLS segments are a go2rtc constant; **their live
proxy saturates at ~130 req/s → hold 10 tiles on the HTTP rung.**

**Shipped (mac, straight to main):**
- `/streams` fields read, never derived: `hls_sub_url`, `hls_opt_url`, `rtsp_opt_url`
  (`CameraModel`, roles + map; `[STREAMS] cameras=133 hls_sub_url=133 hls_opt_url=133`
  logged when coverage changes, with a sample path).
  `LiveHttp.liveUrlForUpstream(field)` maps CV's URL to the proxy route; the old
  derivation remains only as a fallback.
- **`OPT·NET` rung** below `SD·NET` in auto mode (wall tiles + single view); forced
  HD/SD stay pinned to their tier + its NET fallback. Badge shows `OPT·NET` /
  `AUTO OPT·NET`.
- **Remote wall budget**: `ReconnectCoordinator.remoteMode` (set on the first
  rtsp→http step, cleared by any rtsp frame) caps the wall's live decodes at
  `httpLiveBudget = 10`; the rest become snapshot tiles. ≈54 req/s vs CV's 130 cliff.
- **Failed lower rung returns**: a rung that never plays after a rung that did
  (e.g. `-opt` answering 503 past the cap) hands the surface back to the last playing
  rung and is not retried for 60 s. Recovery, not a step-up probe.
- HTTP rung budget stays 15 s per cold attempt (CV: cold ≈10 s at our player; warm ≈ 2–3 s
  at the picture — first bytes are instant but the frame waits for the next keyframe, Linux
  agent's CC note 2026-09-11).

**Not done / open:** Retry-After is not parsed (flat 60 s); `rtsp_opt_url` is parsed
but on no rung (LAN never steps to opt by design); CV's 32-concurrent 15 fps load
test is still unrun on their side; the producer linger (3b) — we said yes.
