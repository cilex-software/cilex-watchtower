# Triage-hero playback — performance BASELINE (2026-06-28, before fixes)

This is the **"before"** record for a before/after report, captured so we don't have to reconstruct the
baseline later (as happened with the earlier stress tests, whose raw CSVs got overwritten). Re-run the same
test after the fixes land and compare against the numbers + raw data here.

**Fixes this baseline is for:**
- `2026-06-28-hero-frozen-seek.prompt.md` — seeks ≥10 s freeze (apply the A1 far-seek re-open to the hero).
- `2026-06-28-hero-per-open-leak.prompt.md` — ~6 MB leaked per playback open.

## How it was measured
Harness `WT_HERO_TEST` (committed, inert unless set) — random event-clicks → hero auto-opens → ±1s/10s/30s/
1m/5m scrubber jumps (as the episode length allows); latency from the seek/open **command** to the first
**actually-rendered frame** via the video sink's frame signal; freeze = no frame in ~1.8 s (player stalls).
On freeze the harness re-opens a fresh event (the stuck clip never recovers). External `/proc` sampler
(150 ms) for CPU+RSS.

Run (on-screen, so the renderer is live), camera `.106`:
```
WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 WT_CV_AUTOLOGIN=1 WT_SECTION=events \
WT_HERO_TEST=1 WT_HERO_AUTOPLAY=1 ./build68/watchtower
```
**360 jumps / 195 event-opens / ~13.8 min.**

## BASELINE results

### Click → playback opens ("the big delay")
`n = 195 · mean 270 ms · median 235 ms · std 151 ms · min 109 · max 1265 ms`

### Seek → actually-rendered-frame latency, per jump size
| jump | rendered | froze | **froze %** | mean | median | std | min | max |
|---|---|---|---|---|---|---|---|---|
| ±1 s  | 62 | 10 | **14 %** | 29 ms | 26 ms | 11 | 12 | 63 |
| ±10 s | 24 | 48 | **67 %** | 20 ms | 20 ms | 5  | 12 | 29 |
| ±30 s | 28 | 44 | **61 %** | 19 ms | 18 ms | 6  | 0  | 30 |
| ±1 m  | 31 | 42 | **58 %** | 18 ms | 17 ms | 6  | 0  | 38 |
| ±5 m  | 15 | 56 | **79 %** | 20 ms | 18 ms | 3  | 15 | 26 |
| **ALL** | 160 | 200 | **56 %** | 23 ms | 21 ms | 9 | 0 | 63 |

When a seek renders it is fast (~17–29 ms median); the problem is that **56 % of all jumps, and 58–79 % of
jumps ≥10 s, FREEZE** (position moves, `mediaStatus`→LoadedMedia, no frame).

### Memory & CPU
- RSS **263 → 1330 MB · peak 1354 · +8.6 MB/min after the initial ramp, no plateau** (~6 MB leaked per
  open). RSS sampled at the 482 jump/open instants: 301–1354 MB (mean 1264).
- CPU 10–40 % steady, **spikes to 120 %** — every RSS spike (+42…+245 MB) and most CPU spikes are an
  **event-open**.

### Targets for the AFTER run
- Seek frozen %: **56 % (all) / 58–79 % (≥10 s) → ~0 %**; far-jump latency becomes a finite re-open time.
- Memory: **+8.6 MB/min → flat** (bounded RSS across hundreds of opens).
- Open latency: unchanged or better (≤~270 ms mean).

## Raw data in this folder (the "before")
- `2026-06-28-triage-hero-latency.before.ht.log` — every `[HT] OPEN`/`SEEK`/`SEEK TIMEOUT` event.
- `2026-06-28-triage-hero-latency.before.samples.csv` — RSS+CPU over time (150 ms).
- `2026-06-28-triage-hero-latency-graph.png` — the CPU/memory graph (full 360-jump run).
- `2026-06-28-triage-hero-latency-analyzer.py` — recompute everything + the graph.

## To produce the AFTER (when the fixes land)
1. Re-run the exact command above; save `/tmp/htfull_app.log` → `*.after.ht.log` (grep `[HT]`) and
   `/tmp/htfull_samples.csv` → `*.after.samples.csv`.
2. `python3 2026-06-28-triage-hero-latency-analyzer.py <after.ht.log> <after.samples.csv> <after-graph.png>`.
3. Diff against the BASELINE tables above for the before/after report.
