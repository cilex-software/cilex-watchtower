# Marker soak, iteration 2 (Ubuntu, 2026-08-20 02:39–10:39) — with memory-by-component telemetry

Second run of the yellow-line audit, operator-amended: component-level memory
telemetry as its own stream, crashes to be fixed on the spot, seek battery back
to 15–30 per clip. 20 cold-start cycles, `wt-soak3` systemd unit, FFmpeg/PTS
path (no_pts_mode=0 all night — the Mac's fallback never engaged here).

## Crash protocol result: NOTHING TO INVESTIGATE

Zero non-SIGTERM fatals in 20 cycles (`grep WT-FATAL supervisor.log | grep -v
'signal 15'` → empty; the only signal-15 lines are the supervisor's own cycle
caps). Stall watchdog fired 8×, recovered 8×, gave up 0×
(`06:19:46 [HERO] STALL reopen #1 wall=1787193718267 seq=2409`).

## Marker verdicts (deduped by event from the start: 184 unique of 247 rows)

| metric | tonight | 08-19 baseline |
|---|---|---|
| unique clips to verdict | 184 | 189 |
| lock rate (≥1 measured edge) | 51 % | 53 % |
| START: n / ok(±2s) / median | 81 / 53 % / **−0.4 s** | 78 / 51 % / −0.9 s |
| END: n / ok / median | 93 / 4 % / **−11.9 s** | 100 / 7 % / −11.4 s |
| END overhang >2 s | **75 %** (70/93) | 76 % |

The end-overhang distribution is statistically unchanged — **CV's fallback
arithmetic still governs fleet-wide**, as expected pre-trial. The hold-trial
camera `hiwatch-04eecdd44fd6` produced only ONE measurable end tonight
(−21.3 s): consistent with the trial NOT yet live, but one sample is not a
verdict — the scoped-camera run after CV flips remains the real measurement.
93 unique offenders named in `2026-08-20-events-soak2-offenders.csv`.
Sample verdict line: `06:16:56 [MKT] ev=ef4ccf3f… cam=hiwatch-849459c4f007
startDeltaMs=nolock endDeltaMs=nolock win=25s`.

## Memory by component (96/96 samples, 5-min cadence, /proc/smaps categories)

| component | first | median | p95 | max | last |
|---|---|---|---|---|---|
| **RSS total** | 35 | 434 | 571 | **630** | 605 |
| heap | 1 | 100 | 126 | 139 | 125 |
| anon LARGE (≥8 MB regions — decode arenas/frame buffers) | 0 | 88 | 199 | 255 | 169 |
| anon small (Qt/QML/JS working set) | 1 | 154 | 245 | 261 | 148 |
| file-backed (code+resources page cache) | 34 | 30 | 136 | 137 | 137 |
| shmem (compositor/GPU buffers) | 0 | 25 | 38 | 41 | 25 |

**Verdict: churn, not leak.** The RSS trajectory oscillates (sampled every
30 min: 35→610→304→487→434→569→422→494→332→197→443→406→571→459→445→351) —
peaks track playback intensity and every cold start returns to baseline; no
category grows monotonically across cycles. The three largest anon regions run
~37/25/17 MB during playback (software-decode frame arenas). File-backed
grows once to ~137 MB (page-cache warm-up) and pins — expected, evictable.
Heap is remarkably flat (median 100, max 139) across 535 clip opens.
Per-cycle top-mappings snapshots archived (`pmap-*.txt`).

## Probes

1. **Measured-snap application: 370 applications logged** (`02:39:26 [MSCAN]
   span start MEASURED wall=… detectorDeltaMs=-264`), 129 periodic screenshots
   archived for audit. Application is counted from the apply-path log line
   (it prints only when the marker actually moves); the screenshot pairing
   was not diffed frame-by-frame — stated boundary.
2. **End overhang**: unchanged (table above) — the client-side end-snap is
   therefore still earning its keep on 75 % of measurable clips.
3. **Episode integrity**: no duplicated rows, no 0-duration finished rows
   observed across cycles (detected-only feed + raw_motion_event_id era).
4. **Poster honesty / 5. in-progress**: not separately instrumented this run
   (driver picks finished clips; the newest-follow window at cycle starts was
   not sampled) — carried to the next iteration. Stated plainly.
6. **Paused-seek staleness**: Linux baseline not instrumented (FFmpeg path;
   the suspect is AVFoundation) — remains a Mac-run probe.
7. **Player errors: exactly ONE variant** — `[HERO] player ERROR 2 'Invalid
   data found when processing input' status=2` × 29 lines ≈ ~5 poisoned opens
   (~0.9 % of 535, matching the known B2 leading-cut class already in CV's
   court with event ids).
8. **Exports / delivered-range: 21 sampled, 21 PASS, delivered_range=PRESENT
   on every job** (`EXPORT: hiwatch-04eecdd44fdb PASS delivered_range=present`)
   — first client-side confirmation of CV's 709bd47 field. Client shortfall
   warning remains queued to consume it in UI.

## Seek battery (restored 15–30 per clip)

6,893 rendered seeks, 58 timeouts = **0.84 %** — between the 1× baseline
(0.34 %) and the 08-19 2×-playback rate (1.1 %), consistent with mixed
1×-seek/2×-playback duty. Literal: `06:25:58 [HT] SEEK TIMEOUT req=60000` —
the 30/60 s cold-storage class, unchanged.

## Dispositions

- No new client bugs found; no crashes; nothing fixed mid-run because nothing
  broke. The night's value is the component-memory baseline + the unchanged
  end-overhang (pre-trial control dataset) + delivered-range confirmation.
- Open items unchanged: CV hold trial (awaiting flip), NTP decision
  (operator), armed-is-not-stalled fix (next client item), probes 4–6 owed to
  the next run on their proper platforms.
