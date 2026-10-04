# Memory Index

➤ **START HERE after a context reset → [session recovery](session-recovery.md)** — full Cilex Watchtower state (P1–P6 done, latest commit, build/verify, backend facts, working agreements) + how to resume.

**Current comparison, 2026-10-04:** [Kimi and Qwen Labs benchmark](kimi-qwen-labs-benchmark.md) — exact shared starter prompt, plain-language task explanation, 100-point scoring, winner rules, checkout locations, maximum-capability preference, and preparation still required before START. No scored run has started.

**Durable, crash-recoverable records live IN THE REPO (this memory dir is local and won't survive a machine loss):**
`docs/PROJECT_STATUS.md` (current status + roadmap) and `docs/DEVELOPMENT.md` (stack, build, dev hooks, architecture, API, gotchas), plus `docs/letters/` (backend functional-spec letters). Pushed to GitHub.

## Status & roadmap
- [build roadmap](build-roadmap.md) — **current** phase status: P1–P5 done (commits), P6 next, deferred items. Canonical status.
- [events-v2 redesign](events-v2-redesign.md) — **done 06-18**: faithful QML port of designs/events-v2 (Triage/Verify/Timeline/Map over one mock store), shipped behind `WT_DEMO`; next = back with real EventModel.
- [stack and build direction](stack-and-build-direction.md) — original locked stack + scope + phase plan rationale (native Qt6/QML/C++ VMS, 16-stream wall is the hard part).

## How to work (feedback / rules)
- [product rules](product-rules.md) — invariants: no invented content, design fidelity, footage only from cilex-vision (consolidates the three below).
- [design fidelity required](design-fidelity-required.md) — match the handoff README "in greatest detail"; re-read the section + HTML before building.
- [feedback: no placeholder content](feedback-no-placeholder-content.md) — real data or honest empty states; mock behind WT_DEMO; no fake identities/counts/names.
- [handling design/backend gaps](handling-design-backend-gaps.md) — full UI + spec letter + honest "pending"; never silent no-op controls.
- [feedback: long shell commands](feedback-long-shell-commands.md) — give long shell commands as a script file; user's terminal splits wrapped pastes; sudo needs the user's own terminal.
- [feedback: letters are single-problem](feedback-letters-single-problem.md) — new backend asks go in their own dated file under `docs/letters/`, not bolted onto the master letter.
- [feedback: auto commit & push](feedback-auto-commit-push.md) — always commit AND push completed+verified changes straight to main immediately, no asking; Conventional-Commits style + Co-Authored-By trailer.

## Implementation details
- [toolchain setup](toolchain-setup.md) — installed toolchain, build/run/offscreen-smoke/WT_SCREENSHOT commands, Qt 6.4 resource-prefix gotcha.
- [video pipeline approach](video-pipeline-approach.md) — QtMultimedia (not qml6glsink); VA-API confirmed; camera-IP-lockout caveat; WT_TEST_IP/WT_CAMERAS/WT_SECTION; videoActive streaming rule.
- [data persistence and naming](data-persistence-and-naming.md) — cameras in SQLite (CameraStore); mock only via WT_DEMO; names/groups user-owned, never invented.
- [motion event lifecycle](motion-event-lifecycle.md) — motion_started/detected/ended = ONE episode joined by recording_id; clip_url lives only on motion_detected. **CORRECTED 2026-09-23: the SERVER excludes started+ended (`exclude_types`) — the feed is motion_detected-ONLY. The old "client suppresses motion_detected" note was the exact inverse; `isSuppressedType()` is gone.** Motion pill is client-side; paging via m_fetched.
- [timeline event-markers research](timeline-event-markers-research.md) — deep-research (2026-06-15) on VMS scrubber event markers: motion=span (Grafana region model), points=ticks, per-zoom LOD clustering, density band at wide zoom, per-type show/hide. Drives future timeline-markers feature.
- [dev-box OOM freezes](dev-box-oom-freezes.md) — **PC freezes = cilex-vision backend containers OOM-looping (seaweed-volume, ffmpeg), NOT a Watchtower bug. RESOLVED 06-15: weed needs `GOMEMLIMIT=1.5G`+2G cap (Go GC blind to cgroup); fix `c496920` live + holding. GOTCHA: restarting storage-agent alone leaves recording DOWN → recover with `docker restart query-api` (re-pushes the disk set).**

## cilex-vision API (Watchtower is a client; cameras have no storage)
- [playback via cilex-vision](playback-via-cilex-vision.md) — detailed S06 contract: auth, sessions/manifest/HLS, export, the proxy approach, segment-500 fix history, go2rtc.
- [cilex-vision playback API](cilex-vision-playback-api.md) — current contract incl. **export accepts only 4 fields** (confirmed via OpenAPI) + test windows/camera_ids; pairs with the export letter.
- [S06 playback gaps](s06-playback-gaps.md) — tracked follow-ups (codec switch blocked on synth timeline; export drawer now done) + latent hydrating/resolution issues.
- [multicam review architecture](multicam-review-architecture.md) — **synchronized wall playback**: client-side N-way HLS sync proven infeasible (~2–3 stream ceiling, measured); chose server-composited mosaic (backend E1). Don't re-attempt client-side. Client P1–P5 blocked on E1.

_Note: product-rules overlaps design-fidelity-required + feedback-no-placeholder-content; cilex-vision-playback-api overlaps the richer playback-via-cilex-vision. Kept for cross-reference; prefer the "current"/canonical one per topic. The repo docs above supersede all for status + impl detail._
