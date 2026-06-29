# go2rtc OOM-kills under camera-producer load — 2026-06-29

**To:** Cilex Vision backend
**From:** Watchtower client
**Severity:** critical (paged via ntfy-critical), recurring

## What happened

`ContainerOOMKilled` alerts fired for the **go2rtc** cgroup twice:

| when (UTC) | when (MSK) | processes OOM-killed in go2rtc cgroup |
|---|---|---|
| 2026-06-28 20:29 | 23:29 | 8 |
| 2026-06-29 07:46 | 10:46 | 3 → 1 |

`docker inspect go2rtc`: **`Memory=536870912` (512 MiB), `RestartCount=19`, `OOMKilled=true`** — chronic, not a
one-off. `GET /api/streams` shows go2rtc serves the **whole fleet: 68 streams (~34 cameras × main+sub)**, several
of them VA-API transcodes (`ffmpeg:cam-1#video=h264#width=1280#hardware=vaapi`, …).

> **Status (2026-06-29 ~16:42 MSK):** the cap has since been raised **512 → 1024 MiB** (`infra/docker-compose.yml`
> `go2rtc.mem_limit`) and the container recreated (`RestartCount` reset to 0) — thank you. The asks below still
> stand: 1 GiB may remain tight for the full 34-camera fleet under heavy wall use, and
> `docs/operations/memory-budget.md` still lists go2rtc at `512m` (now stale).

## Cause (two-sided — we own one side, the cap is the other)

go2rtc starts a producer (RTSP connect / ffmpeg transcode) **per stream on demand**. Around both kills its log
shows a burst of `mjpeg/mjpeg.go:126 … write: broken pipe` to the host — frame/stream requests that woke cold
producers and were then abandoned. Wake enough producers at once and a **512 MiB cgroup sized for ~zero
concurrent producers** OOMs; ~9 concurrent cold requests was enough.

**1. Our side (mitigated this commit).** Watchtower's event-snapshot widget fetched the go2rtc live frame
(`/api/frame.jpeg?src=<camera>`) **eagerly for every event shown**, as a fallback for the stored event-still.
The Triage feed spans many cameras, so showing/scrolling/cycling events woke a producer **per distinct camera**
— and our leak-test harness (opening ~26 events/min for long stretches) amplified that into sustained
producer-churn, plausibly contributing to the memory pressure (the 2026-06-29 07:46 kill overlaps a client
run). **Fix:** the live frame is now fetched **only when the stored still actually 404s** (lazy fallback),
which confines go2rtc traffic to genuinely still-less events. We can't prove our client was the *sole* trigger
(a browser/live-view consuming the transcoded streams would look the same in the logs), but we've cut our
footprint regardless.

**2. Your side (the ask).** A 512 MiB cap for a 34-camera go2rtc, where any consumer can wake a producer, is the
root fragility — a single client requesting stills should not be able to OOM it. Please consider:

- **Raise the go2rtc memory cap** to match the producer count it may hold, and/or **bound concurrent
  producers** with prompt teardown of producers whose only consumer broke the pipe.
- **Serve `/api/frame.jpeg` from a cached recent keyframe** instead of waking a full RTSP/transcode producer
  per request. Snapshots/thumbnails don't need a live pipeline; a cached still would make them cheap **and**
  remove the transient `404`s we see when a producer is cold (which is also why our fallback sometimes can't
  render). This is the highest-leverage fix for both the OOM and snapshot reliability.

## How to reproduce

Request `/api/frame.jpeg?src=<camera>` for ~10 distinct cold cameras within a few seconds and watch go2rtc RSS
climb toward its cgroup cap → OOM. Our old eager-fallback did this incidentally across the event feed; the
lazy fix stops it from our side, but the cap + per-request producer-wake remain independently reproducible.

## Follow-up ask: make go2rtc sizing observable + self-tuning (an admin WebUI + a recommendation model)

Sizing go2rtc today means editing `infra/docker-compose.yml` (`mem_limit`/`pids_limit`), `--force-recreate`-ing
the container, and hand-updating `docs/operations/memory-budget.md` (already stale at `512m`). That's
error-prone and invisible to operators — and it's guesswork. You said on 06-16 you'd "rather size the cap to
real wall behaviour than guess"; make that a product surface. Two parts:

### 1. An admin WebUI panel for go2rtc (and the other tunable containers)
- **Current limits + controls.** Show `mem_limit`, `pids_limit`, and the HD/main-transcode concurrency cap,
  with editable controls whose **Apply performs the recreate** — so the panel is the source of truth (no shell,
  no compose edits, no stale doc).
- **Live state.** Current RSS vs the cap; live transcode/producer count vs `pids_limit`.
- **History — median, p95/p99, and high peaks.** RSS and transcode-count over time as a **median line + p95/p99
  band + peak (high-water) markers**, with **OOM-kill events overlaid**. You already emit
  `cilex_container_oom_kills_total` and scrape per-container memory (node-exporter/Prometheus), so the series
  exist — this is that data surfaced *in the console*, not just Grafana. The median shows steady state; the
  **p99/peaks are what actually decide the cap** (the median is near-idle and hides the transcode bursts that
  OOM).
- **Budget guardrail.** The panel knows the host total and the sum of the other always-on `mem_limit`s and
  warns/blocks any value that breaches the rule-of-thumb — every GiB given to go2rtc is a GiB less headroom
  before earlyoom kills a co-tenant (the Watchtower client shares this 16 GB box).

### 2. A model that recommends the best values (don't make the admin guess)
Compute recommendations from that same history:
- **`mem_limit`** ← `ceil(peak_p99 × margin)` (e.g. margin 1.3) — sized just above the observed 99th-percentile
  peak, **not** the median (median ≈ idle; the peaks are what OOM).
- **HD-transcode concurrency cap** ← fit the per-stream cost: `RSS ≈ base + k · concurrent_HD` (a linear
  regression over the history yields `base` and `k` = MiB per HD transcode). Then
  `max_safe_HD = floor((mem_limit − base) / k)`. This turns the three knobs (cap, `mem_limit`, per-stream cost)
  into one equation — pick any two, the model gives the third.
- **`pids_limit`** ← observed max ffmpeg-fork count × margin.
- **Host-constrained, not in isolation.** The recommendation is a constrained optimisation:
  `maximise allowed concurrency  s.t.  Σ(always-on mem_limits) + peak client RSS + earlyoom reserve ≤ host RAM`.
  When the only safe way to raise go2rtc is to lower another container's budget, the panel should say so.

Watchtower can feed the demand side of the model: our `[MEMTEL]` heartbeat already reports the wall's concurrent
live-decode count (`livePipes`) and client RSS, so "HD streams the wall actually asks for vs what go2rtc can
hold" is computable end-to-end rather than guessed.
