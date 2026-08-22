# Retention/vacuum soak (f33f156, 17dd65f): all four claims unrefuted — claims 2 and 4 CLEAN — with one named availability defect (the governor starves retention up to 35% of every hour) and one Saturday-shaped boundary

**Run:** 2026-08-21 22:10:31 → 2026-08-22 ~09:50 local (T0+11.7h), Linux pilot box.
**Code under test:** verified LIVE by content+behaviour (in-container grep counts, master args `-garbageThreshold=0.15 -maxParallelVacuumPerServer=2`, batched-path log signature since 16:15) after my timestamp heuristic false-negatived — CV deployed from the working tree before committing. Image-age vs commit-time is not deploy evidence.
**Samplers:** 60s series (backlog/breaker/load/PSI/disk/landed/vol-CPU; n=692), disks+restarts CSV (added 22:35), filer pressure/failure CSV (added 22:52), 30-min rotating cold-open probes (n=23), recorder log harvest. All in `/home/cilex-vision/soak-2026-08-22/`. Timestamps epoch; no writes to CV anywhere (read-only SQL/logs/stats; probes are session-opens, the read path).
**Context stated up front:** T0 sat ~45 min after the 21:19–21:26:45 recording incident; s3 and seaweed-filer are chronic self-restarters and are treated as properties of the system under test; the 39,141 backlog reference was 6h stale at T0 — the batched deletes had already drained it (T0 backlog 104). This run therefore tests STEADY-STATE HOLD, not a drain.

## Verdicts

| claim | verdict | the number that decides it |
|---|---|---|
| 1. Retention keeps up | **PASS on the envelope — with a real availability defect** | No 2h rising window anywhere; every tooth rolled and drained back to the 100–500 band (final sample 327). But the governor sawtooth left retention granted-0 for 27% of the night and 35% of the 07:00–09:07 ramp window. |
| 2. Breaker doesn't eat itself | **PASS, CLEAN** | `cilex_deletion_breaker_tripped` = 0 in all 692 samples, through 9 starvation teeth and 55+ s3 restarts. The throttle path logs itself as "breaker NOT tripped" — the f33f156 reason-split behaving. |
| 3. Reclaim survives the unwind | **PASS, decisively** | Pool 2.9912 → **4.7514 TB** (+1.76 TB net over the run; min 2.9390, never trended down after the first hour). sdb1 +0.34 TB, sda1 +1.41 TB, no divergence toward the 5 GiB floor. Volume CPU: brief 61% peak, otherwise <25% — nothing like the 132–591% burn at 0.01/8. |
| 4. Safety and recording | **PASS, CLEAN** | Strict inside-window check on last-copy deletions: **0 rows**. Tombstones ≥ logged deletions (safe direction, 0.8% gap = my harvest loss). MIN(start_time) sits 1–2 min OLDER than the cutoff — no overshoot, no >24h lag. Recording never dipped against last night. |

**Pass condition met: all four unrefuted at T+11h, 2 and 4 clean.** One certification explicitly NOT granted: see "Saturday" below.

## The finding that outranks the pass: governor starvation (CV owns it, root cause measured)

Retention and hot-expiry share ONE tumbling 1-hour budget window (opens at first admit, no baseline reservation). Measured split inside the first starved window (19:15–19:50Z, CV's recorder log): **hot_expiry 37,152 = 85.1%, retention 6,485 = 14.9%**. Hot expiry deletes redundant hot copies (warm twin verified); retention deletes the LAST copy — two risk classes under one envelope, and the cheap one crowds out the destructive-but-necessary one ~5:1, then both starve until the window rolls.

Shape over the run: **9 starvation episodes** (≥5 min sustained rise ≥100/min), 174 min starved of ~695 min ≈ **25% of the run retention-unavailable**; teeth peaked 1,778–**7,623** (worst at 07:0x, mid-ramp). Every tooth drained within minutes of its window roll. Literal mechanism line:

```
WARNING rebalancer: Retention deletion throttled: asked 2000, granted 0 (window 49628/49628).
Backlog will be picked up next window — the breaker is NOT tripped, ...
```

Fix direction (CV's, not deployed tonight, correctly): per-reason envelopes or a reserved retention floor — a token bucket alone would feed hot expiry 85% of the refill too. Also theirs: the per-refusal WARNING logs 13 identical lines per millisecond while starved.

## Saturday, stated so the pass cannot imply more than it measured

The decisive 07:00–10:00 ramp premise (arrivals roughly double) did not occur: **2026-08-22 is a Saturday**; arrivals ramped 1.15× (246/min vs 214 trough). At 1.15× the envelope held (worst tooth 7,560→7,623 drained; backlog 487 at gate close). **The weekday-double case is NOT certified.** Follow-up: one weekday 07:00–10:00 sampler-only re-check, no code change, no attention beyond arming it.

## S3 delete failures: transient, zero stuck keys

4,984 distinct keys failed a delete at least once tonight; **max failures for any single key = 1** — no key failed twice, the permanent-orphan class is empty this run. The 07-15 orphan question stays answered by the tombstone reconciliation above. Filer-level batch failures ran 14.5% cumulative (1,330/9,169; hourly 23%→1%, ceasing after 02h) — consistent with CV's ~10% steady / 20–35% burst figures. CV's 1.3–1.5×-work-per-pass hypothesis was WITHDRAWN by them same-morning on this series — the retry overhead was a burst that ceased after 02h, not a structural tax; the hourly numbers above are the correction, not support. Their permanent-orphan worry and their restarts-explain-the-teeth suggestion were likewise withdrawn against this run's census and correlation (their words, 2026-08-22 morning).

## The chronic pair, counted honestly

s3: 338→**397** (59 restarts, ~1 per 12 min all run). filer: 55→**94** (39, ~1 per 17 min; memory cycles to ~90% then a clean exit — the pressure signal precedes each restart in filer.csv). Recording survived every one of them: landed/min never below 104, no zero minute. Correlations: teeth are driven by the governor window (granted=0), not by the restarts — restart increments do not line up with tooth edges (e.g., teeth at 23:10/00:13 vs s3 increments spread ~every 12 min regardless). CV's open defect (clean exit code 0, no OOM) keeps its mystery; the leading-indicator series they asked for is in `disks.csv`/`filer.csv`.

## Cold session-open: contention over cold pages, not time-of-day

23 probes, rotating camera+day (never today's, HAVING >50 frags): baseline 0.07–0.6 s all night — but spikes to **3.77 s (00:42), 2.09 s (01:11), 3.53 s (04:42), 2.08 s (08:41)** land where psi_io/load spike (24.8/35, 27.1/35, 12.6/30, 18.9/36), while quiet minutes at ANY hour stay sub-second. The plan's "fast at 03:00, slow at 09:00" contrast is superseded: on a box where compaction+retention work all night, latency tracks PRESSURE, not clock. Same conclusion for the fix ordering (`shared_buffers` + Q1 first); baseline recorded, no fix shipped, no improvement claimed.

## Recording integrity vs last night (confound stated)

Tonight 208–265 landed/min vs last night 110–159 at the same clock — tonight is ~2× because last night's fleet had 62 cameras offline (switch block returned 08-21 morning). The comparison cannot hide a drop in this direction; no drop exists. Min landed 104/min (04:5x, tooth + compaction concurrency).

## What this run cannot establish (unchanged from the plan, plus one)

- The governor's ceiling under a built backlog (needs the attended injection test).
- The WEEKDAY morning ramp (Saturday run — see above).
- Whether cold session-open improves (no fix shipped; baseline only).
- Whether the ~10–15% failing deletes would stick under multi-day observation (tonight: all transient).
- Daytime peak beyond 09:50.

## Corrections owned during the run

1. My deploy check false-negatived on image-age vs commit-time (CV corrected; verified live by content+behaviour before T0).
2. My "unchanged since 19:09:02Z" read mixed UTC with local — 27 minutes, not an evening; filer was the FASTER restarter in that window, not slower.
3. My first tooth-1 timing (from partial data) was off by 4 min and 800 rows vs the series; corrected from the CSV.
4. My first 4b pass double-counted via harvest-overlap; my first dedupe failed on my own timestamp prefix; the true reconciliation is 152,578 logged vs 153,815 tombstoned (safe direction).
5. The 65%-starved proxy from T+4h was too loose and was not reported; the ≥5-min-sustained definition (25%) is what stands.

Raw data: `/home/cilex-vision/soak-2026-08-22/` (series.csv n=692, disks.csv, filer.csv, probes.csv n=23, recorder-lines.log deduped, baseline.txt, report-notes.md with the full gate-by-gate log).

---

## Correction 2 (same day, ~17:3x): claim 3 was SPACE-ONLY — readability after compaction was never verified, and the read path is now failing

Mobile's P0 to CV (2026-08-22 afternoon): review segments returning 500,
2,835 volume-integrity failures/30 min, a read at offset 35.4 GB in a 1.07 GB
file, volume servers restart-looping. Independently verified from this side:
segment 3 of 3 returned HTTP 500 through the app's own session->playlist->
segment path, on footage WRITTEN 2026-08-21 morning — before the soak — and
unreadable after it.

What this corrects in this report:

1. **Claim 3's scope.** "Reclaim survives the vacuum unwind" was refutable
   only by free space trending down. It PASSED on that clause and the pass
   stands AS SCOPED — but the scope was wrong to leave unstated: nobody
   verified that footage remained READABLE after compaction rewrote the
   volumes. The offset-past-EOF signature is the textbook stale-needle-index-
   after-compaction failure. If CV's root-cause lands there, the vacuum
   unwind traded CPU for correctness and this report's "PASS, decisively"
   deserves the asterisk it now has.
2. **"Compaction is lumpy" understated it.** Full extraction from disks.csv:
   near-CONTINUOUS compaction 23:49->09:58 (sdb1 23:49-00:28 and 04:43-05:47;
   sda1 essentially nonstop 00:29-09:58) at 2-10 GB/min. Ten hours of volume
   rewriting, not waves.
3. **The follow-up every future storage soak inherits:** a readability probe
   belongs in the sampler — N random OLD segments GET-verified per hour,
   not just session-opens. Space, catalogue, and bytes are three different
   claims; this run measured two of them.

Timeline + verification details handed to CV on their P0 thread (msg
f52fd961, 17:2x local). The catalogue-half of this report (safety audit,
tombstones, backlog) is unaffected — mobile's caveat that "archive depth is
computed from the catalogue, not from readable bytes" applies to the depth
CLAIM, and this report's §"Safety audit" already measured only the catalogue
and said so.
