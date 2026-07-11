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

## Rounds 5-9 (2026-07-11, second soak day)

8. **Delivery-thread converter crash (gdb-caught) → poison latch.** ~2 h in, a
   corrupt-packet storm (truncated-TS joints from interrupted segment fetches —
   stored segments verified clean via ffprobe) made VA-API surface sync fail;
   Qt printed one graceful "Cannot map a video frame in ReadOnly mode!" then
   SIGSEGV'd inside `qImageFromVideoFrame` on the NEXT frame of the storm, whose
   map falsely succeeds (Qt 6.12 defect; crash was on the delivery thread with a
   live frame — the DirectConnection design held). Supervisor relaunched
   seamlessly. Fix: first graceful map failure latches ALL capture off for 3 s —
   storms pass, the harvester self-heals.
9. **Stale-anchor fills after re-opens** (+1.7 s past the cursor, center-only
   strip) → empty-chain fills now base on the MAIN player's position
   (`mainPosMs`, host-fed), which IS the cursor when paused. (First attempt read
   the harvester's own `player.position` — 0 on fresh sessions; the harness
   caught the regression within five cycles.)
10. **Uniform ~5.7 s strips on deep fragment clicks** decomposed with timestamped
    traces: an in-window direct seek into a region of a JUST-OPENED session hits
    the serve-time remux cold → main player renders nothing for the full 6 s
    freeze-watchdog; the watchdog's re-open then lands in <1 s (fresh session
    remuxes AT the target). Fix: **adaptive watchdog** — 2.5 s when the target
    is >60 s past the highest position rendered this session (cold region), 6 s
    otherwise. Measured: the click-deep+F gesture dropped 5.7 s → ~2.0-3.0 s.
11. **Stall detector never fired** — `_fillAhead` reset the stall clock on every
    300 ms eval pass. New-work-only resets; the stall nudge (skip forward past a
    demuxer wedge instead of park-and-reseek into it) now has a fair clock.
12. Environmental, correctly survived: Cilex Vision deployed query-api mid-soak
    (~16:00, connection-refused for ~1 min) — instance B rode through with
    honest errors, no crash, no wedge; .120's June 6 aged past 35-day retention
    at midnight → honest refusal (harness auto-prunes such days).

Cumulative through window 10: **B (untouched control): 1656 cycles, 1654/1656
strips <1 s (worst 2.9 s = cold-archive first touch), 0 crashes.** A (fix
carrier, restarted per round): p50 715 ms steady in every window; remaining >1 s
cases are the two bounded server-cold classes (first touch of a cold archive
region; fragment-click deep into a fresh session then immediate F — now ~2-3 s
worst, was 5.7-6 s).

13. **Pre-emptive re-open for never-rendered deep targets** (round 10): a seek
    >5 min past anything rendered this session skips the doomed direct seek —
    the re-open starts the remux AT the target. Fragment-click worst case
    4.2-5.5 s → ~1.7-3 s; window 12 validation: **A 211/213 strips <1 s (p50
    715 / p95 965), the periodic slow-triplets gone**, first burst-free A
    window since 5. Server-side floor documented + optioned in
    `docs/letters/2026-07-11-cold-offset-first-segment-latency.md`.

## Bottom line

Final state after 12 windows / 2 days / **~4,300 combined cycles**: the <1 s
filmstrip gate holds at **p50 ~715 ms / p95 <1 s on both instances**; the only
exceedances are isolated first-touches of server-cold offsets (bounded ~2-3 s,
floor documented to CV with options). **One crash total** (Qt 6.12 converter on
poison frames — latched off), auto-recovered by the supervisor; **zero GUI
freezes; zero leaks** (RSS plateau/declining). B's untouched control run: 1,925
cycles, 1,923 <1 s, including surviving a live backend deploy. Harness +
watchdog are reusable (`WT_FSOAK`, `WT_FSOAK_PLAN`,
`~/watchtower-soak/fsoak-2026-07-10/`).
