# Adaptive live quality (auto tier step-down) + remote live

**Status: TRANSPORT UNBLOCKED 2026-09-07 evening** (CV reply
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
