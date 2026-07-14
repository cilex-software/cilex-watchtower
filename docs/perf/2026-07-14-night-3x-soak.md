# Night-3x soak — three 12 h variants in parallel (2026-07-14 01:22→13:20 MSK)

All three previous soak variants ran simultaneously for 12 h on one host, each
in an isolated XDG config, gdb-wrapped, against the live cilex-vision backend —
**on the patched-Qt overlay that is now the production default runtime**
(first long-duration certification of it; see §6).

| variant | harness | coverage |
|---|---|---|
| night_soak | `WT_NIGHT_SOAK` supervisor (07-02 harness: historic playback, export matrix, seek-land, Esc/cancel) | full camera fleet incl. sparse/empty days |
| churn | `WT_CHURNTEST=40` per run, relaunched all night | .201 2026-07-10 ↔ 2026-07-08, frame mode |
| fsoak | `WT_FSOAK` merged plan (both 07-10 instances' plans: current .201/.67 rolled to 07-13 + archived .106/.120/.101/.110) | 20 cam-days, multi-pass |

Two rounds: **round-1** 01:22–03:5x on the pre-existing binary; **round-2**
04:0x–13:20 after a mid-soak fix (751e656, §3) — same discipline as the 07-10
fsoak rounds.

## 1. Verdict

**GREEN. 0 crashes, 0 GUI hangs, 0 harness wedges, 0 SIGSEGV across all three
variants and both rounds (≈35 instance-hours).** One real operator-visible bug
was found by the soak, root-caused from live traces, fixed, and validated by
the remaining 9.3 h (§3). The last previously-unvalidated fix (853a234
mislanded-seek recovery) is now validated at volume (§4).

## 2. Per-variant results

**churn** — 210 launches, 208 completed summaries, **208/208 PASS (100 %)**,
**8 320 frame-mode day-switches**, 0 wedges, 0 crashes. (The driver's final
`crashes=1` completion line was its own end-of-window `timeout` kill (code 124,
dur 142 s, no fault in 400 surrounding lines) mislabeled by the wrapper script;
wrapper fixed. The app itself was faultless.)

**fsoak** — 3 466 day-opens, **3 506 strips: p50 717 ms · p95 744 ms · p99
1 969 ms · max 3 249 ms · mean 684 ms; 114 >1 s (3.3 %)**, every >1 s case
attributed to cold-region preseeks with `chained≥4` VFR fills on
archived/cold days (`c=0.0` on all) — the known chain-floor envelope, not a
regression. Gate: p50 <1 000 ms **passed all 12 h** (hourly last-400 p50 never
left 715–722 ms). 07-10 close-out baseline p50 713 ms → **parity (717 ms)**.

**night_soak** — round-2 ran **9.75 h in a single launch** (no relaunches);
5 040 heartbeats, 1 863 export-matrix exercises, **625 exports produced and
size-verified (10.1 GB total, mean 16.2 MB)**, incidents: **0 crashes, 0
hangs**. Seek-land: n=378, p50 0 ms (warm in-window), p95 251 ms, max 1.6 s.
Honest `day-empty` handling verified across footage-less days (.127/.105/…).

**RSS over 12 h (leak check, first-90 min mean → last-90 min mean, peak):**
fsoak 775→786 MB (peak 968), churn 658→675 MB (peak 948), night 447→414 MB
(peak 616). **Flat — no leak.** Host ended 8.3 GB RAM available; disk
oscillated 9–12 GB free all night (backend recording churn + seaweed retention;
our total log footprint <1 GB with rotation).

## 3. Finding #1 (real bug, found → fixed → validated tonight): stale seek-watch hijack + unbounded recovery loop

Line-distance loop analysis of round-1 logs exposed same-target `seek
MISLANDED` chains up to **9 deep** (one re-open every ~6 s watch period), and
the full trace showed the mechanism (night log 37690–38010):

- **(A) Stale-watch hijack:** `openFor`/`openForDay` cleared every piece of
  pending-seek state **except `seekWatch`**. A watch armed under the previous
  session fired up to 6 s into the NEXT open — trace shows `MISLANDED
  target=15001` firing 3.4 s **after** the harness had opened a different
  camera/day — and `seekFar`'d playback back to the old target. Operator
  equivalent: seek deep into day A, switch to day B within ~6 s, playback
  silently yanks back to A.
- **(B) Unbounded recovery:** each watch→`seekFar` recovery re-armed a fresh
  watch via the deferred seek; on sparse days where the landing legitimately
  snaps to the footage edge (~5.9 s rendered vs window-frame target 15 s,
  delta >8 s threshold) the cycle opened a **new backend session every ~6 s**
  until external navigation broke it.

**Fix (751e656, round-2 binary):** `_openGen` generation counter — fresh opens
void any pending watch (explicit stop + gen check in the trigger) — plus a
same-target recovery budget (2 attempts, then `GIVE-UP` accepting the rendered
position; resets on a new target or clean landing).

**Validation (9.3 h round-2):** genuine loops **0** (every flagged pair
decomposed to independent single-shot recoveries with rotations/landings
between); `GIVE-UP` fired **0** times (no target ever needed a third attempt);
churn's round-1 mislanded class (10 stale-watch fires) went to **0** across
171 round-2 runs.

Daylight follow-up (noted, not blocking): on sparse days the watch should
arguably compare against the **snapped** expectation — the probe-vs-snap
arithmetic still costs one benign re-open per cold sparse-day probe (the
recovery masks it). Needs a deterministic sparse-day repro.

## 4. 853a234 (mislanded-seek recovery) — validated, closed

The one fix that never had a soak window. Tonight: **~1 700 mislanded
detections across variants, every one recovered by a single `seekfar` re-open**
(round-2: 1 302 fsoak + 19→107 night, 0 loops, 0 give-ups), including the
853a234-class deep-target cases (churn `target=211775`: re-open landed with
`session_ready dt=43 ms`). The detector+recovery is sound; tonight's 751e656
adds lifecycle scoping and bounding on top.

## 5. Fixes shipped during the soak

| commit | what |
|---|---|
| 751e656 | seek-watch scoped to its open + bounded mislanded recovery (§3) |
| 97c94ae | night-soak supervisor broad `pkill -9 -x watchtower` fenced behind `WT_SOAK_BROAD_KILL` (a daytime-ending soak must never kill the operator's own app) |

Driver-side (soak tooling, not app): churn wrapper end-of-window kill no longer
mislabeled as crash; environ-matched RSS sampler (`rss2.csv`) replacing the
in-driver sampler that couldn't see through the `timeout→gdb→watchtower` chain;
line-distance loop checker (target-string keying alone gives false
positives/negatives — chains must be confirmed by context).

## 6. Patched-Qt 12 h endurance certification

Three concurrent instances × 12 h (≈35 instance-hours) of HW-decoded
playback/churn/export on `~/Qt/6.12.0-patched-beta1` — the default runtime
since 99c9e18 — with **zero SIGSEGV, zero decoder faults, flat RSS**. This
extends the 07-12 validation matrix (13/13, forced-failure torture) with the
first long-duration production-shaped certification. The 07-02 night soak
(7 h, single variant) and 07-10 fsoak rounds are both strictly contained in
tonight's coverage; results are at parity or better on every shared metric.

## 7. Raw data

`~/watchtower-soak/night3x-2026-07-14/` — per-variant `app.log` (+rotations),
`rss2.csv`, `findings.md` (hour-by-hour), `export_sizes.log`, drivers,
`status.sh`/`loopcheck.sh`. Hourly gate checks ran at :26–:27 throughout; all
GREEN except the 03:27 investigation that produced §3.
