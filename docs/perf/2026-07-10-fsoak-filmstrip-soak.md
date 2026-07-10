# FSOAK: extended filmstrip soak — 2 instances, multi-camera/day churn, <1 s strip gate

**Operator ask (2026-07-10):** extended soak on multiple Watchtower instances (≤2 per
server); filmstrip must load **under 1 second**; jump day-to-day across current
footage (.201, .67) and archived footage (.106, .120, others); closely monitor
freezes and crashes; investigate every performance degradation, understand causes,
apply fixes.

**Setup:** `WT_FSOAK` harness (Main.qml, inert unless set) — each cycle: open a
(camera, day) pair → wait for rendered frames → ⅓ of cycles click a fragment →
enter frame mode → measure `strip_ms` (frame-mode entry → 7-slot filmstrip
chained-cached; gate 1000 ms) → 10 arrow-step bursts both directions → next pair
(coprime stride ⇒ consecutive cycles hop camera AND day); 25 % of jumps HOT (frame
mode kept across the day switch — the pre-4aa4ed7 crash gesture). Two isolated
instances (own `XDG_CONFIG_HOME`, gdb-wrapped, supervised, RSS sidecar, 500 ms
`[HB]` heartbeat): **A** = current cams (.201 5 days, .67 3 days incl. live-edge
today), **B** = archived warm tier (.106 sparse motion days, .120/.101/.110
continuous June). Watchdog scans every 30 s; windows end on crash / violation
burst / interval.

## Result across windows 1-4 (~2.5 h churn, ~190 cycles, ~185 strip measurements)

- **Crashes: 0. GUI freezes: 0** (no heartbeat gap > 2 s in any window).
- **Window 4 (all fixes in): A = 96 cycles, 97/97 strips < 1 s** (p50 715 / p95 960 /
  max 976 ms), **0 violations**; B = 73 cycles, 73/74 < 1 s (p50 710 / p95 959),
  the one miss = 2779 ms on the **first touch of a cold S3 warm-tier segment**
  (server-side cold-base, the known ~2-4 s archive tail — not client machinery).
- RSS: plateau behavior, no growth trend within windows (A ended ~756 MB, B ~1 GB
  under the heaviest warm-day frame-mode churn; frame cache alone caps at 144 MB).

## Findings → fixes (chronological)

1. **Live-edge behind-fill starvation (blank strip on today's footage).** At the
   live edge the harvester's 48-frame behind window (~2.5 s) crossed the final
   motion clip's leading kept discontinuity; the P0 "never seek across a gap" rule
   parked it — silently, every 300 ms. → Behind window now **clamps (halves) until
   it fits the contiguous run**; parks trace on reason change. 6 s timeout → ~1 s.
2. **Harvester cold-start taxed the gate** (window-1 p95 2245 ms). → **Pre-arm**:
   the harvester loads the session playlist (paused, no decode) at session-ready,
   so F skips manifest+probe; plus **`FrameCache.captureCurrent()`** — the shown
   frame becomes the strip's center tile instantly at frame-mode entry.
   p95 2245 → 739-982 ms, and window-4's 97/97 clean.
3. **pts 0 is a cursor, not a sentinel.** Heavy-day bounded bootstrap lands at
   00:00:00 → first frame pts 0.0; the harvester's `userPts <= 0` idle-guard and
   the strip's `shownPts <= 0` placeholder treated it as "nothing". → `< 0`.
4. **VFR chain knife-edge (real UX defect).** Tiles chain within 2.6×**median**
   frame duration; these cameras mix 40/80/100 ms intervals, so a 30 ms median
   (limit 78 ms) broke the chain at a real 80 ms gap — cached frames rendered as
   placeholder dots. → **130 ms floor** on the chain/adjacency limits (FrameStrip,
   FrameHarvester, FrameStepper). Still orders below true region jumps.
5. **Non-finite wall-seek guard (app hardening).** A NaN target (harness bug: read
   `frags[k][2]` on object rows) serialized as "Invalid Date", opened a nonsense
   session, got an empty manifest, and **tore down a healthy player** → frame mode
   dead 30 s. `seekToWall`/`seekFar` now reject non-finite targets loudly. (The
   soak's "deterministic empty manifests" were all this; the backend serves those
   windows fine — 61-frag raw probe.)
6. **Far-seek empty-manifest retry.** The 2026-07-03 transient (200 + 0 fragments)
   had a silent retry on fresh opens only; the seekfar path went straight to the
   error banner. → One silent same-target replay (~0.9 s) first. (Kept even though
   this soak's empties proved self-inflicted — the Jul 3 transient class is real.)
7. **Harness measurement honesty:** camera switches go through `openFor` (coverage
   refetch — direct `.camera` writes left the previous camera's day list active);
   rendered-frames gate uses a per-session delta of the cumulative `_frameSeq`;
   day-start cycles accept 4 chained slots (nothing exists before frame zero);
   days that age past retention mid-soak auto-prune from rotation (.120/06-06
   crossed the 35-day line at midnight during window 4).

## Bottom line

The <1 s filmstrip gate **holds on every current-footage cycle and 73/74 archive
cycles**; the single exceedance is the backend's documented cold-archive tail. No
crash, no freeze, no leak across ~190 open→frame-mode→step→jump cycles on 6
cameras × 14 day-pairs including live-edge today, sparse motion days, and
warm-tier archives. Soak continues with longer windows; harness + watchdog are
reusable (`WT_FSOAK`, `WT_FSOAK_PLAN`, `~/watchtower-soak/fsoak-2026-07-10/`).
