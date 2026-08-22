# Retention/vacuum soak (f33f156, 17dd65f) — CLIENT-HALF report (Mac, 00:16–08:56)

The half of the operator's soak order observable from the operator's Mac
through query-api :8000 only. **Authoritative numbers for claims 1–3 (expired
backlog rows, breaker gauge, /mnt free, volume CPU, PSI) are box-side and are
NOT in this file** — extraction queries in
`docs/letters/2026-08-22-retention-soak-pilot-half.md` §2; the full box order
is `docs/plans/2026-08-22-retention-soak-order.md`. Every figure below was
measured on this run or is written `not measured`. Sampler beat integrity:
104 five-minute samples, zero gaps > 400 s (max 309 s) — the Mac never slept.

## Verdicts, scoped to what a client can see

| claim | client-visible verdict | basis |
|---|---|---|
| 1 keep-up | **holding, within coverage visibility** | pre-rotation expired footage fell 554 s → 409 s while the cutoff advanced; frontier trailed the cutoff by only 3–7 min at every pre-rotation sweep; post-rotation the metric is 0 by construction (below) |
| 2 breaker | **not measured** (box-side gauge) | — |
| 3 reclaim/vacuum | **not measured** (box-side df/CPU) | — |
| 4 recording integrity | **CLEAN** | landing breadth never dropped: night median 53 cameras/5 min, ramp median 61, max 71 — breadth ROSE through the 07:00–08:56 ramp; arrivals proxy steady 167–218 k footage-s/h at stable camera count |
| 4 no deletion inside window | **CLEAN within coverage visibility** | frontier pinned at exactly `2026-08-17T00:00:02Z` across five sweeps 04:00–08:12 (133/133 cameras twice); PLUS the direct proof: coverage-hidden 08-16T20:00Z footage opened and played (3 segments, correct PDT) at 04:10 |

## The night's two measurement artifacts, so nobody re-trips on them

1. **UTC-midnight coverage rotation.** `/review/coverage` returns a
   day-quantized window; at UTC midnight day 08-16 left every response. My
   frontier tripwire fired (`inside_window=YES` from 04:00 on) — disproved
   by playback (above). All `YES` cells in fleet.csv from 04:00 onward are
   this artifact.
2. **cams_ok drift.** The 02:53 sweep's expired jump (409 → 19,385 s)
   coincided with cameras answering coverage rising 96 → 128; the jump is
   attributed to newly-reporting cameras' footage entering the sum, not to
   retention falling behind. From 05:07 all 133 answered and the series was
   stable.

## REAL FINDING for CV (server contract): coverage hides retained, playable footage

From UTC midnight until the oldest day actually ages out (~13:00Z), the
day-quantized `/review/coverage` response omits a day that still holds
**~13 hours of retained, playable footage** — measured: 08-16 absent from the
response at 04:00 local while a session at `08-16T20:00Z` returned 3 segments
with correct `PROGRAM-DATE-TIME`. The archive ribbon consequently tells a
guard "no footage this day" about footage that exists and plays — the
no-invented-absence twin of the honest-UI rule. Needs either sub-day
granularity on the oldest day or the response window keyed to the rolling
retention cutoff, not calendar days. (Letter to follow from whichever agent
picks it up; recorded here first.)

## Series (all measured)

**Fleet coverage sweeps** (hourly; cutoff = now−132 h):

| local | cams ok | expired s | frontier | note |
|---|---|---|---|---|
| 00:40 | 94/133 | 554 | 08-16T09:25:17Z | T0; frontier −3 min from cutoff |
| 01:47 | 96/133 | 409 | 08-16T10:37:20Z | draining while cutoff advanced |
| 02:53 | 128/133 | 19,385 | 08-16T11:47:03Z | cams_ok artifact (above) |
| 04:00 | 122/133 | 0 | 08-17T00:00:02Z | rotation artifact begins |
| 05:07–08:12 (5 sweeps) | 131–133/133 | 0 | 08-17T00:00:02Z **unmoved** | claim-4 anchor |

**Recording breadth** (distinct cameras whose `last_segment_at` advanced per
5 min): night (00:16–06:00) median **53** (52–67); ramp (07:00–08:56) median
**61**, max **71**. No sample below 52 all run; the LANDING-LOW flag (<30)
never fired. Arrivals proxy (footage-seconds/h at stable 133-camera count):
217k (→05:07), 187k (→06:09), 188k (→07:10), 168k (→08:12) — flat; breadth,
not footage-seconds, is where the fleet's morning motion shows, as expected
for a majority-continuous recording fleet.

**Cold session-open probes** (client full-stack: session create + playlist
fetch; ONE continuous camera, offsets rotated 7 min/probe ~24–25 h back —
NOT the box's build_manifest probe; do not cross-compare with its 6,533 ms
baseline):

| local | create ms | playlist ms |
|---|---|---|
| 00:16 | 1004 | 106 |
| 01:17 | 536 | 526 |
| 02:17 | 119 | 134 |
| 03:18 | 2505 | 1315 |
| 04:18 | 523 | 367 |
| 05:18 | 565 | 105 |
| 06:19 | 192 | 115 |
| 07:19 | 398 | 197 |
| 08:19 | 263 | 229 |

9/9 HTTP 200. **The fast-at-03:00 / slow-at-09:00 contention signature did
NOT appear in this series** — ramp probes (398/263 ms) sit inside the night
band, and the one outlier (2505 ms at 03:18) is at night. Boundary: this
measures the client session path against warm-ish 24 h-old data, not the
box's cold build_manifest over rotating camera+day; the box probe remains
the authoritative shape for the shared_buffers/Q1 decision.

**Storage-agent**: unreachable for the ENTIRE run — 104/104 samples
`degraded/false`, consecutive_failures 329 → 791, `last_ok_at=null`,
`cannot connect to storage-agent: [Errno 2] No such file or directory`.
If the deletion loop or breaker rides this agent, the box-side numbers must
say so before any claim-1/2 verdict is signed; from the client the drain
nevertheless LOOKED alive pre-rotation (expired fell while cutoff advanced),
which suggests the deletion path does not ride the agent — stated as
inference, not measurement.

## Not measured (box-side, with the filler)

Backlog rows / drain curve (§2 Q1), breaker (§2 Q2), disk free + volume CPU
(§2 Q3), tombstone audit + segments-landed-per-minute vs previous night from
the DB (§2 Q4), S3 stuck-key analysis, PSI/load. Raw client data:
`scratchpad/ret-soak/` on the MacBook (storage.csv, landing.csv, fleet.csv,
session.csv, hourly /streams+/metrics snapshots, run.log with flag
dispositions).

## ADDENDUM (09:26) — ramp tail to the operator's 09:30 deadline

Sampling was restarted 08:59–09:26 after the 08:56 close (3-minute gap,
recorded in run.log) to carry the decisive-window coverage as far as the
operator's hard end time allowed. Ramp-tail series (08:59–09:24): landing
breadth n=5 valid samples, median **61**, max **73** — the run's highest
breadth, still no sample below the night floor; fleet sweep at 09:19:
frontier **unmoved** at `2026-08-17T00:00:02Z` (125/133 answering, expired 0
by construction); session probe at 09:19: create 472 ms, playlist 413 ms —
still inside the night band. Ramp verdict unchanged by the tail: recording
breadth rose through 07:00–09:26 with zero degradation client-side.

**Closing statement on the four-claim condition.** The order's pass gate —
all four claims unrefuted at T+11h, claims 2 and 4 clean — is only
half-signable from this session, and that is a fact about access, not
effort: SSH to the box is denied for both known users, nothing beyond
query-api :8000 is exposed (probed and recorded at T0), and claims 2–3 plus
the authoritative claim-1 backlog exist only on the Ubuntu box. Claim 4 is
**clean in every client-visible dimension** (breadth, frontier, playback
proof); claim 1 is **holding within coverage visibility**; claims 2–3 are
**not measured** here and cannot be. The box-side order and extraction
queries are committed (`docs/plans/2026-08-22-retention-soak-order.md`,
letter §2) — the Ubuntu session signs or refutes the remaining half; its
Prometheus recorded tonight regardless. Per the operator's explicit
instruction the session ends at 09:30; the condition's satisfiable
remainder is exhausted.

## FINAL (10:0x) — the gate is signed: box report landed (2c8ef61), all four claims unrefuted

The authoritative box-side run (`docs/perf/2026-08-22-retention-soak.md`,
T0 22:10 → 09:50, n=692) closes the halves this file marked `not measured`:
claim 1 PASS on the envelope (with the governor-starvation defect named and
owned by CV), claim 2 **PASS CLEAN** (breaker 0 in all 692 samples), claim 3
PASS decisively (+1.76 TB), claim 4 **PASS CLEAN** (0 inside-window
deletions). **Pass condition met; the weekday-double ramp is explicitly NOT
certified (Saturday, 1.15×) — both reports carry that boundary.**

Cross-validations between the two vantage points, for the record:
- The box's T0 backlog was **104 rows** (the 39,141 reference was 6h stale —
  already drained) — which is exactly what this client half saw
  independently at 00:40: only **554 seconds** of fleet footage older than
  the cutoff. Two blind measurements, one story: steady-state hold, not a
  drain.
- The box's cold-open conclusion (latency tracks PRESSURE, not clock)
  supersedes the fast-at-03/slow-at-09 hypothesis — consistent with this
  client series, which found no time-of-day signature either.
- Recording integrity signed from both sides: box landed/min never below
  104 with no zero minute; client breadth never below 52 with the run-peak
  73 mid-ramp.
- The entire box-side deletion run happened while `/health/storage` showed
  the storage-agent unreachable (329 → 791 consecutive failures) — the
  deletion path demonstrably does not ride that agent; the dead socket is
  its own open item, still unexplained by either report.
