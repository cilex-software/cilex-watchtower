# Adaptive live quality (auto tier step-down) + remote live

**Status: DESIGN — blocked on CV** (letter
`2026-09-07-remote-live-is-dark-8554-is-closed-and-the-tier-ask.md`: remote
transport decision + the third "opt" tier). Phase 1 shipped from the Mac.
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
