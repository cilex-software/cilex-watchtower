# Playback soak, Linux dev box — the booth's 47.8 % silent-freeze does NOT reproduce on localhost: 99.0 % played, session-open p50 318 ms (booth: 9,913 ms)

**Machine:** `cilex-vision-MS-7E06` (Ubuntu 24.04.4, same box as the CV pilot backend — client→server path is loopback).
**When:** 2026-08-21 09:14–11:00 local (operator window 09:00–11:00; start 09:14 because the driver had to be cherry-picked and built first).
**Build:** v1.1.144 `build=10d77008` — banner sha verified against the cherry-pick `10d7700` (booth's `WT_PB_SOAK` driver from `win/pb-soak`, landed on main).
Literal: `2026-08-21 09:14:32.287 === watchtower start v1.1.144 pid=2473498 build=10d77008 qt=6.12.0 os=Ubuntu 24.04.4 LTS ===`
**Env:** `WT_TRACE=1 WT_CV_AUTOLOGIN=1 WT_PB_SOAK=1 WT_PLAYBACK_IP=192.168.1.148` (seed camera "3.1 Улица 2", online + continuous recording at pick time).
**Shape:** 4-min idle control, then 3 app cycles (09:18, 10:00, 10:43; caps 2700/2700/1018 s) to a hard 11:00 stop. All cycle exits rc=124 = the runner's own deadline `timeout` (SIGTERM); the `[WT-FATAL] … killed by signal 15 … RSS=407 MB` lines in cycle 3 are the app's honest self-report of that external kill, not a crash.
**Wait budgets (driver, unchanged from booth):** 40 s seek wait, 30 s coverage wait, 6–14 s dwells, 3–8 jumps/camera.
**Writes:** none — driver only reads (no exports, no acks, no dispositions; the sole POSTs are `/auth/login` and `/review/session` opens, which playback itself requires).
**Fleet context at start:** 124 online / 9 offline (the 55-camera switch block returned overnight; booth ran against the degraded fleet).

## 1. Verdict split — the headline

390 soak jumps (`grep -c "\[PBSOAK\] VERDICT" pbsoak.log` = 390; each line is one jump, no duplicates).

| outcome | n | share |
|---|---|---|
| **played** (playhead advanced >500 ms over the dwell) | **386** | **99.0 %** |
| did not play, frags=0 (honest empty window) | 1 | 0.26 % |
| **did not play, frags>0 — DEFECT class** | **3** | **0.77 %** |
| seek-wait timeouts (40 s budget) | 0 | 0 % |
| errors reported | 0 | every failure silent, same as booth |

Booth, same driver, 6 h: 50.9 % played, **47.8 % of all jumps = footage present, nothing moved**. Here: **0.77 %**.

All four failures, verbatim:

```
09:23:52.157 VERDICT cam=hiwatch-083bc1f79620 day=2026-08-19 span=1440m target=11:57:26 ttffMs=639  frags=0  played=no advancedMs=0 err=none
09:32:16.803 VERDICT cam=hiwatch-04eecd5eaef8 day=2026-08-18 span=1440m target=09:12:35 ttffMs=5023 frags=78 played=no advancedMs=0 err=none
09:32:43.013 VERDICT cam=hiwatch-04eecdd45079 day=2026-08-21 span=1440m target=04:33:07 ttffMs=7976 frags=2  played=no advancedMs=0 err=none
09:53:08.040 VERDICT cam=hiwatch-083bc14effc1 day=2026-08-18 span=60m   target=21:29:32 ttffMs=9605 frags=61 played=no advancedMs=0 err=none
```

Caveat on the 3 DEFECTs: the driver's `ttffMs` falls back to wall-clock when no
new first-frame stamp arrived, so "a frame rendered" is NOT established for
them — they are "fragments present, playhead never advanced in a 6–14 s dwell."
The failure **shape** the booth saw exists here; the **rate** does not.

Coverage: 49 distinct cameras, 6 distinct days (2026-08-16 … 2026-08-21), 81 camera picks, all five scales exercised.

## 2. Session-open timings vs the booth

[PBTIME] distributions, this run (all `session_http` returned code=200; n=845, incl. control):

| stage | n | p50 | p90 | max | booth (6 h) |
|---|---|---|---|---|---|
| session_http (POST /review/session round-trip) | 845 | **318 ms** | 2,166 | 19,848 | — |
| session_ready | 842 | **420 ms** | 3,029 | 21,608 | p50 **9,913** / p90 22,445 / max 44,498 |
| first_frame | 521 | 1,151 ms | 3,788 | 12,992 | p50 16,275 / p90 29,444 / max 48,046 |

Literal: `2026-08-21 09:18:49.668 [PBTIME] session_http ms=1751 code=200 bytes=98606 attempt=0`

Same endpoint, same day, ~24× faster at the median on the loopback path.
No drift across the run: per-hour session_http p50 was 384 ms (09:xx, n=346)
and 303 ms (10:xx, n=499) — no queue built up over 1.7 h of churn.
Dispatch concurrency stayed low: `inflight_own` was 0 for 622 of 845 dispatches,
2–3 during boot barrages, briefly 5 twice.

**Not measured:** the booth ran 01:00–07:00, this run 09:14–11:00 — server load
in the two windows differs and is not controlled here. The clean discriminator
is still the booth letter's §1 ask (server-side request-received→response-sent
timing for their window).

## 3. Latency vs manifest size — refining "it is not the manifest"

By fragment count (this run never saw >205 frags; booth saw up to ~3,941 —
their day windows were denser; buckets above 500 are **not reached**, not zero-cost):

| frags | jumps | ttffMs p50 | p90 | max |
|---|---|---|---|---|
| 0 | 1 | 639 | — | 639 |
| 1–50 | 245 | 881 | 2,056 | 7,976 |
| 51–500 | 144 | 1,990 | 5,301 | 10,201 |
| 501–2,000 | 0 | not reached | | |
| >2,000 | 0 | not reached | | |

By session response body size (`bytes=` on the same session_http lines):

| body | n | p50 | p90 | max |
|---|---|---|---|---|
| <10 KB | 318 | 206 ms | 1,001 | 4,028 |
| 10–100 KB | 387 | 318 ms | 2,129 | 9,331 |
| 100 KB–1 MB | 85 | 479 ms | 2,679 | 9,030 |
| **>1 MB** | **55** | **1,906 ms** | **9,504** | **19,848** |

So on loopback, size DOES order latency — but the whole effect is ~1.7 s at the
median. It cannot produce a 10 s median by itself. Two facts worth CV's eyes:

1. **Session bodies reach 2.3 MB** (55 opens >1 MB; slowest:
   `10:43:58.556 [PBTIME] session_http ms=19848 code=200 bytes=2158778 attempt=0`).
   Building/streaming those took 8–20 s server-side *even with zero wire cost* —
   the loopback moves 2 MB in milliseconds, so that time is production, not transfer.
2. **3 small-body (<100 KB) opens still took >5 s** (worst 9,331 ms for 13,690
   bytes) — a rare genuine server stall independent of size.

Hypothesis for the booth (labeled as such, not measured from here): on their
8.48 Mbit/s path a >1 MB body costs 1–2 s of wire alone and convoys the shared
connection pool, so small session opens queue behind megabyte responses; loopback
never exposes that. Their §1 server-side timing + response bytes would separate
build time from wire time per request and settle it.

## 4. Per-scale table

| span | jumps | played | ttffMs p50 | p90 | max |
|---|---|---|---|---|---|
| 15M | 69 | 100.0 % | 1,056 | 5,529 | 10,201 |
| 1H | 77 | 98.7 % | 1,089 | 3,127 | 9,605 |
| 6H | 57 | 100.0 % | 1,161 | 2,794 | 7,755 |
| 12H | 96 | 100.0 % | 1,096 | 3,441 | 8,602 |
| 24H | 91 | 96.7 % | 1,308 | 3,882 | 7,976 |

Booth's worst scale was 15M at 43.8 % played; here 15M is 100 %. No scale is
distressed on the fat path; 3 of the 4 failures happened at 24H.

## 5. Idle control (4 min, before the cycles)

12/12 played, ttffMs 326–3,556 ms, session_http p50 346 ms (n=32).
Booth control: 10/10 played, first frame 835 ms–7 s. Both machines are healthy
when the path is quiet; the difference is that mine stayed healthy under churn.

## 6. Link

The client→server path is loopback (no NIC). A read-only `/healthz` probe every
10 min: p50 35 ms, p90 899 ms, max 1,011 ms (n=11) — even trivial endpoints
show ~1 s tail spikes while the pilot backend does its normal work, which bounds
how "instant" any request can be on this box. Wire throughput is effectively
unbounded relative to 2 MB bodies. Booth measured 8.48 Mbit/s mean on their path.

## 7. RSS trend

30 s sampler, per app process (start / end / max, MB):

| cycle | pid | start | end | max |
|---|---|---|---|---|
| control | 2473498 | 0 (spawn) | 414 | 436 |
| 1 (09:18–10:00) | 2493768 | 11 | 306 | 595 |
| 2 (10:00–10:43) | 2707340 | 422* | 312 | 559 |
| 3 (10:43–11:00) | 2913297 | 590* | 368 | 590 |

*first sample landed during the boot barrage, not at spawn. Peaks are
mid-cycle (many decoders in flight), ends are LOWER than peaks — no monotonic
growth, no leak signature over 1.7 h. Consistent with the 08-21 memory-soak
finding that transients, not creep, are the RSS story.

## 8. Coverage honesty (report, don't conclude)

- NO-COVERAGE: 9 of 81 camera picks (11.1 %) produced no day with footage
  within the 30 s budget (booth: 44 %). Literal:
  `09:19:25.676 [PBSOAK] NO-COVERAGE cam=hiwatch-083bc1df39e9 -> next camera`
- Days with footage per pick: max **6**, mode 6 — same ceiling the booth saw,
  now from a second machine on a healthy-fleet morning. The 35-day retention
  contract vs 6 visible days remains a CV-side question (the coverage ribbon
  shows what `/review/days` returns; whether older days exist in storage is
  not observable from this client).

## 9. Bugs found this run, dispositions

1. **Driver cosmetic:** the first `CAMERA #1` pick races the `WT_PLAYBACK_IP`
   boot auto-open; the first jumps run on the seed camera while the pick line
   names another. Verdict lines carry the true open camera (`root.camId`), so
   no data corruption — worth a one-line fix in the driver (guard `_psState="cam"`
   until the boot open settles). Disposition: noted for the booth agent (driver
   owner); not blocking, data honest.
2. No client-side defects beyond the known DEFECT class (frags>0, nothing
   moves, err=none — 3 occurrences). The client-honesty item from the booth
   report stands: those three sat silent where "still loading" belonged.

## 10. Answer to the question this run existed for

**The booth's wait is not the session endpoint's intrinsic speed.** On a fat
path, the same endpoint, the same day, answered at p50 318 ms and 99.0 % of
jumps played. Their 9.9 s median and 47.8 % silent-freeze live somewhere
between their box and the server — link, proxy hops, or the interaction of
their thin pipe with multi-megabyte session bodies (§3) — or in a server-load
regime specific to their window (not controlled here). CV's server-side
timing per their letter's §1, plus logging response bytes, splits every
remaining possibility.

**Boundaries:** hours differ from the booth window (09:14–11:00 vs 01:00–07:00);
no server-side timings exist yet; >500-frag manifests never occurred here;
response-encoding (gzip or not) not measured; first_frame lines cover 521 of
845 opens (day/span switches and rapid re-jumps don't all produce one).

Data: `scratchpad/soak5/` (pbsoak.log 742 lines, pbtime.log 8,737, rss.csv 207,
link.csv 11, control.log, cycle-{1..3}.log, supervisor.log).

---

## Correction, same day (15:40): cycle 3 ran with the live wall decoding 16 streams — and it changes the conclusion only by strengthening it

While verifying the §9 reply for the booth, I checked what the app was actually
showing during each cycle. `WT_PLAYBACK_IP`'s boot hook (`qml/Main.qml`,
`playbackBootHook`) scanned only the first 50 roster rows for the camera IP;
when roster ordering left `192.168.1.148` beyond row 50 at cycle-3 boot, the
hook looped forever and the app stayed on the live wall while the soak driver
worked the playback machinery underneath. Measured per cycle
(`live_pipelines=` in [WT-MEM] lines):

| cycle | wall state | verdicts | played | session_http p50 |
|---|---|---|---|---|
| control | off (115 samples at 0) | 12 | 12 | 346 ms |
| 1 | off (0 of 1,252 samples at 16) | 156 | 152 | 390 ms |
| 2 | off | 171 | 171 | 299 ms |
| **3** | **16 pipelines, 502 of 503 samples** | **63** | **63** | **302 ms** |

Literal: `2026-08-21 10:43:11.415 [WT-MEM] rss=341MB live_pipelines=16 frames=272`

What this corrects:

1. My morning status line said the app "boots straight into Playback" — that
   was inferred from the code comment, and it held for control + cycles 1–2
   only. Cycle 3 (63 of 390 verdicts, 16 %) ran under 16-stream live-wall
   decode contention.
2. It does not weaken the verdict — it strengthens it: under the very
   contention class the booth flagged in their §7, this box still played
   63 of 63 jumps at p50 302 ms. (Not a like-for-like of the booth's 49
   streams on a UHD 730; stated as measured, 16 streams on this box's VA-API.)
3. Cycle 3 also owns the run's worst single open (19,848 ms for a 2.16 MB
   body at 10:43:58) — consistent with boot-barrage + wall spin-up pressure,
   still answered and played.
4. The hook bug is fixed: the boot hook now scans the full roster
   (`qml/Main.qml` playbackBootHook; commit pending in the same push as this
   correction). The RSS peaks table in §7 reads unchanged — cycle-3's 590 MB
   peak was wall-driven, which is now the labeled cause rather than an
   unexplained decoder surge.
