# 8-hour Events soak, iteration two — first soak on the Mac (2026-08-20, 02:51–10:51)

Operator order: re-run the 2026-08-19 marker soak on the operator's MacBook
(M1 Pro, macOS 26.3.1, AVFoundation media backend, tailnet **direct** to the
pilot), seek battery restored to first-iteration strength (random 15–30/clip),
eight numbered probes, **component-level RAM telemetry as its own deliverable**,
crashes investigated on the spot. Driver: the in-app WT_HERO_TEST/WT_MARKER_TEST
harness, app cycled ≤45 min, wrapped in `caffeinate -dis`.

Two builds ran: cycles 1–4 = v1.1.133 (`e675715`), cycles 5–41 = v1.1.134
(`2e88688`, mid-run probe sharpening: P6 gained raw `player.position`, P5
patience 15→60 s). **Marker methodology identical across both.** Branch
`mac/soak-iter2-harness`, PR to follow (shared code; this box cannot verify the
Linux build).

## Volume (each grep count was verified against a literal line; examples below)

| metric | this run (Mac) | iter. one (Linux, 08-19) |
|---|---|---|
| app cycles (cold starts) | **41**, zero crashes | 10, zero crashes |
| unique clips opened w/ rendered frame | **389** (640 rendered opens incl. cross-cycle re-opens) | 677 opens |
| open → first frame | med **1.07 s**, p90 2.18 s | — |
| open timeouts | **10 — every one a P5 no-footage pick; zero organic** | — |
| render-verified seeks | **14,444**, **0 timeouts** | 2,793, 30 timeouts (1.1 %) |
| seek → rendered frame | med **25 ms**, p90 43 ms, max 7.4 s | — (08-18 Linux: med 223 ms, 0.34 % timeouts) |
| verdict rows → unique clips | 351 → **275** (deduped from the start) | 311 → 189 |
| stall rescues / gave-ups | **0 / 0** | 3 / 0 |
| wall-clock gaps > 60 s | **0** (957 heartbeats) | n/a |

Example lines behind the counts:
`[HT] OPEN lat=1354 dur=62 ev=091c7b45-… t=1787183345860` ·
`[HT] SEEK req=30000 lat=25 …` ·
`[MKT] ev=1588e76b-… cam=hiwatch-04eecdd44fd6 startDeltaMs=3945 endDeltaMs=-16512 win=42s`

The one CRASH.log entry is the supervisor's own end-of-window SIGTERM tripping
the detector on the app's honest `[WT-FATAL] … killed by signal 15 … external
terminate` marker — a detector false positive, not a crash. DiagnosticReports
holds nothing from the soak window.

## Verdicts: START and END vs iteration one

**Lock rate 164/275 = 60 %** (was 48 %). This run crossed sunrise (02:51–10:51),
giving the contrast-diverse re-run iteration one asked for; 111 clips (40 %)
full-nolock — still scenes and low-contrast movers, stated as coverage.

**START** (131 locks): median **+1.9 s** (was −0.9 s); **36 %** within ±2 s
(was 51 %); **50 % early** — yellow before visible motion, worst +14.5 s (was
29 %); **15 % late** (was 19 %). The early tail grew markedly. Boundary stated
plainly: half this run is daylight — background roads/foliage trigger detector
zones with no foreground mover for the scanner to lock, which inflates "early"
exactly as CV's zone-trigger thread predicts. Not claimed as a regression;
filed as the daylight datum next to the night-only iteration one.

**END** (164 locks): median **−6.8 s** (was **−11.4 s**); overhang > 2 s on
**58 %** (was 76 %); honest within ±2 s **18 %** (was 7 %). And a tail iteration
one did not have: **24 % of clips end +2.0…+4.0 s LATE**, capped by our own
post-roll window edge (floors, not measurements), clustered on
`083bc1*`/`849459*` while the deep overhangs stay on `04eecd*`.

**⚠️ The same-night booth control overrules the reading these numbers invite.**
The Linux box ran this same iteration in an overlapping window (02:39–10:39,
`2026-08-20-events-soak2-linux-8h.md`) against the same fleet and measured the
end distribution **unchanged**: median −11.9 s, 75 % overhang (n=93), trial
camera −21.3 s (n=1) — "consistent with the trial NOT yet live". Two clients,
one fleet, one night, a 5 s median disagreement: the difference is
**measurement-side** (backend FFmpeg-vs-AVFoundation, clip selection, scene
mix), not a fleet change. Therefore, correcting the paragraph a first draft of
this report contained: this run's lower overhang and its trial-camera
−12.2 s (n=3, vs −25.0 in the 08-19 table) must **NOT** be read as the hold
trial having flipped — the booth's control says it had not. The +2…4 s late
tail is likewise a **Mac-scanner suspect** until a same-clip Linux/Mac A/B
rules the platform in or out — that A/B is the queued next step, and no letter
goes to CV on the hold thread from this run.

**153 offenders** (|Δ| > 2 s on either edge) named with camera and both deltas
in `2026-08-21-events-soak-mac-offenders.csv`.

## Component RAM telemetry (the run's second deliverable)

Three independent streams, 7.9 h: `vmmap --summary` every 120 s (230 samples),
`footprint` every 10 min (46), in-app `[MEMTEL]` every 30 s. Raw:
`scratchpad/soak-mac/mem/`.

**Which parts of Watchtower hold the memory** (dirty footprint, representative
end-of-cycle sample, `footprint-1787212264.txt`):

| component | dirty | behaviour across 8 h |
|---|---|---|
| C++/QML heap (MALLOC_SMALL + LARGE) | **165 + 62 MB** | the only variable part: ~60 MB at launch → 300–436 MB by cycle end; resets on restart, **no cross-cycle ratchet** |
| video decode surfaces (IOSurface) | **59.3 MB** | **byte-for-byte constant all night** — surface pool strictly bounded, no leak |
| GPU-owned (unmapped graphics + IOAccelerator) | 40 + 7 MB | flat |
| QML/JS engine (JS VM Gigacage) | 32 MB | 6 → ~30 MB, plateaus |
| everything else (__DATA, CoreMedia pool, stacks…) | < 3 MB each | flat |

Whole-process truth: physical footprint med **445 MB**, max **597 MB**;
`[MEMTEL]` RSS max **613 MB**; every cycle starts 355–461 MB and ends
411–613 MB. Verdict: within-cycle heap growth is bounded and non-compounding;
nothing video-shaped grows at all. **mach-RSS `[MEMTEL]` is now soak-verified
on macOS** (M2 item), e.g. `[MEMTEL] up=60s rss=418MB … livePipes=0`.

## The eight probes

1. **Measured-snap application** — **417 [P1] pairs**, drawn-position offset
   |dx| med 19.7 px, p90 136 px. Screenshot pairs on the three largest offsets
   visually confirm the underline's left edge moves when
   `[MSCAN] span start MEASURED` fires (`shots/p1-*.png`). Measurement without
   application: **0 observed**.
2. **End overhang distribution** — above, with the booth-control caveat: the
   fleet is unchanged per the same-night Linux run; this run's shift is a
   cross-client measurement discrepancy, now its own open item (same-clip A/B
   queued). Per-camera medians live in the offenders CSV + `analyze.py`.
3. **recording_id resilience** — `[P3] rows=100 dur0=0 noRec=70 dupPairs=0`
   (cycle 1) held all night (noRec 69–71); dur0 rose to 6–10 only in the
   morning cycles — in-progress episodes whose durations arrive on close, not
   a defect. **Zero duplicate started/ended rows, zero 0-duration finished
   rows: proximity pairing (v1.1.125) holds at soak scale.** CV's regression
   itself is still live (70 % of rows keyless).
4. **Poster honesty** — 398 hero posters counted: **363 eventFrame / 35
   liveFallback (8.8 %)**; the fallback fires only after the still errored or
   was honestly skipped (gate is by construction; e.g. `[P4] hero ev=72bb946c-…
   state=eventFrame`). No "LIVE over a recording" case observed — the 08-17 fix
   held.
5. **In-progress events** — 31 deliberate seconds-old picks (9 windows had
   none). **21 reached a first frame: fast cluster 0.85–2.0 s (7 picks), slow
   cluster 11.8–33.3 s (14 picks)** — the slow cluster is the lazily-cut
   session tail, worth CV's eyes if it annoys guards. 10 picks concluded
   **"No footage recorded around this moment." after 61–62 s of bounded
   retries** — honest, never instant. The "Recording in progress — waiting for
   the first footage…" state displayed correctly throughout.
6. **Paused-seek staleness (E12)** — 40 batteries via the real user path
   (seek while paused, no force-play). **36/40: the paused click rendered the
   target frame within 1.2 s — AVFoundation is NOT globally stale-on-paused-seek.**
   The 4 exceptions, each with an evidence shot: 1 click ignored outright
   (position moved −57 ms against an 8–20 s target), 1 quantized to +0.8 s,
   1 picture stale ≥1.2 s while the playhead moved (fresh-open re-open in
   flight — the operator's reported shape, transient), plus 2 v1.1.133 rows
   with unmoved playhead (pre-instrumentation, same signature). **Frequency:
   hard stale 1/40 (2.5 %), any suspicious outcome 5/40 (12.5 %), at 1.2 s
   probe patience.** Queued client fix: guarantee a rendered frame after any
   paused seek (re-issue a single-frame preroll if `_frameSeq` hasn't advanced
   ~1 s post-seek) — not blind-shipped at end-of-run; it touches the seek
   machinery a 14k-seek soak just validated.
7. **Player errors** — **zero error lines in 41 cycles**; zero FFmpeg
   "Invalid data" (the string cannot occur under AVFoundation); zero stalls.
   The Linux B2 class (~1 % poisoned opens) did not manifest: all 640 opens
   either rendered or were P5's no-footage picks. Boundary: the hero's
   `_error` text is not console-logged outside P5 sampling — an
   instrumentation gap queued for the branch, though render-verified
   opens/seeks mean an error state could not have hidden.
8. **Exports / delivered-range** — 37 jobs over announced episode windows at
   the **Standard tier** (`hevc_capable=false`, the request the app's Standard
   quality sends — `qml/Main.qml:1493` maps the drawer tier to this flag):
   **14 ready / 23 failed**, all 23 with one honest reason: *"no recorded
   footage in range for the selected quality — the camera's sub-stream may not
   have been recorded"* — on episodes that had just **played** in the same app
   (review sessions serve the main stream). **62 % of sampled motion episodes
   are not exportable at Standard**, which the export drawer's own copy
   contradicts: "Standard quality (H.264 720p sub) — kept the full retention,
   so **always available**" (`qml/ExportDrawer.qml:506,526`) — an honest-UI
   violation now with a failure rate; client fix queued (copy + pre-flight
   honesty), contract question in the letter. The booth's same-night 21/21
   PASS does not contradict this: different harness, different tier
   parameters — CV can see both request shapes server-side.
   The 14 ready jobs: **delivered_start/end == requested, shortfall_s=0.0,
   truncated=false on all 14**, 6 artifacts download-verified (3.6–4.9 MB,
   durations 24.95–25.9 s matching the windows) — confirming CV's
   delivered-range contract on a second client and platform, same night as
   the booth's first confirmation. B4 is also fixed in practice: failed jobs
   return a terminal `failed` with `error_msg` instead of vanishing.
   (Prober-side: `download_url` carries the nginx `/api` prefix; direct-port
   consumers must strip it exactly as `PlaybackClient.cpp:782` does — cost
   this harness one round, documented so nobody repeats it. 3 pre-fix 22-byte
   pulls were re-verified after the fix.)

## Corrections, owned in the open

- **The 2026-08-18 "darwin backend stamps no frame times" model did not hold
  tonight**: `[MSCAN] no PTS from backend` never fired and the scanner ran on
  real frame PTS the whole run (Qt 6.11.1 / macOS 26.3.1). The no-PTS fallback
  stays as a fallback; the platform note in `4020ec3` is superseded by this
  measurement.
- `tools/bump-version.sh` used GNU-sed syntax and **the version-bump hook had
  never worked on a BSD userland** — the Mac checkout could not commit at all.
  Fixed portably on the branch (first-ever commit from this machine).
- The soak supervisor counts our own end-of-window SIGTERM as a crash
  (WT-FATAL grep) — harness defect, noted so iteration three fixes the
  detector, not the app.

## Fix-or-letter ledger

| finding | disposition |
|---|---|
| bump-version.sh BSD-incompatible | **fixed** (`e675715`, branch PR) |
| P6 paused-seek no-op/stale (2.5–12.5 %) | client fix **queued** with mechanism + evidence shots |
| hero `_error` not in flight recorder | client fix queued (one log line) |
| Standard-tier export fails on 62 % of sampled motion episodes; drawer copy promises "always available" | **letter to CV** (availability contract) + client fix queued (ExportDrawer copy/pre-flight honesty) |
| cross-client endΔ discrepancy (Mac −6.8 s vs booth −11.9 s, same night/fleet) + Mac-only +2–4 s late tail | **ours, not CV's**: same-clip Linux/Mac MotionScan A/B queued; hold-trial letter withdrawn before sending |
| recording_id still null on ~70 % of rows | already open with CV (ledger §1); tonight adds "fallback holds at soak scale" |
| in-progress first-frame slow cluster 12–33 s | recorded; raise with CV only if guards report it |

Raw data: `scratchpad/soak-mac/` (cycle logs, mem/, shots/, p8-*.csv/jsonl,
heartbeat.log, analyze.py). Network: tailnet direct to the pilot, one app
instance, no writes beyond the 37 export jobs named above.
