# Memory-improvement soak (Ubuntu, 2026-08-21 00:35–08:28, wrapped at ~7.9 h on operator order)

Purpose: verify the three memory items shipped as v1.1.141 (macOS crash-handler
RSS, first-party MEMTEL component columns, teardown trim) and hunt further RAM
improvement candidates. 14 cold-start cycles, marker-mode driver at 2×, 15–30
seeks/clip. **Context that colors every number: the backend was DEGRADED all
night** — 62 cameras offline (the 10-house + 4.1 blocks awaiting physical
switch fixes) and the storage agent flapping — so the client fought retry
storms it never faces on a healthy night. That made this accidentally the
first memory-under-fault soak, which proved more useful than the plan.

## Crash protocol: zero non-SIGTERM fatals in 14 cycles.

## Did the applied items work?

1. **First-party component columns: YES.** 942 MEMTEL samples carried
   anon/file/shm/heapU/heapF all night; category arithmetic closes against RSS
   (spike sample: `rss=1066MB … anon=1034M file=32M shm=0M heapU=138M heapF=9M`).
   Cross-check vs the external smaps sampler: consistent where cadences align;
   medians differ (int. 278 vs ext. 204 MB) because the 30 s internal stream
   catches playback peaks the 5-min external one sleeps through — cadence
   artifact, stated, not hidden. The external sampler stays in harnesses as
   the independent witness.
2. **Teardown trim: WORKING, MODEST — and its logging had an instrument bug.**
   glibc retention (heapF) held at median 25 MB / p95 75 / max 113 across the
   night, and heapF sat at 9 MB at the very moment of the biggest RSS spike —
   glibc was NOT the spike. The [MEMTRIM] released= numbers from this night
   are garbage (unsigned wrap when trim leaves fordblks higher — 2^44 "MB");
   fixed to signed math the same morning, owned here. Verdict: keep the trim
   (cheap, keeps arenas lean), expect no headlines from it.
3. **macOS crash-handler RSS**: compiled, unverifiable on this box — verified
   the day the Mac next crashes or deliberately tests. Boundary stated.

## The night's real memory finding: decoder-arena churn is UNBOUNDED under retry storms

Peak RSS **1066 MB at 01:02:28** (yesterday's healthy-night peak: 630):
`up=216s opens=8` — eight session generations inside 216 seconds (stall/error
retries against the degraded backend) stacked **~900 MB of non-heap anonymous
memory** — FFmpeg/Qt decoder frame pools from overlapping teardowns, while
glibc heap stayed at 138 MB. Nothing leaked (the spike drained; cycle
baselines reset all night), but the transient is real and the mechanism is
clear: `_open()` for generation N+1 doesn't wait for generation N's player to
finish its asynchronous unload, and under retry storms generations stack.

**Improvement candidate #1 (numbered, concrete): serialize hero session
generations** — gate `_open()` on the previous MediaPlayer reaching
NoMedia/unloaded (or a single-inflight-teardown latch). Expected effect: spike
ceiling drops from ~N×130 MB toward ~2×130 MB under the same fault storm.
Client-side, small, testable by replaying tonight's conditions
(WT_HERO_TEST against a degraded backend).

## Other RAM uses examined, with verdicts

- **heapU crept to 231 MB max** (yesterday 139) under the retry storm —
  tracks open/error bookkeeping churn; returns to ~135 median; no action.
- **file-backed**: median 25, max 124 — page cache, evictable, no action.
- **shm = 0 all night** (offscreen-less X11 run differences vs yesterday's
  25 MB compositor buffers) — informational.
- **anon vs heapU gap** (the decoder-pool measure) is now directly readable
  off every MEMTEL line — the gap IS candidate #1's meter.

## Regression net (fault-night numbers, not comparable to healthy baselines)

351 opens, 3,463 seeks rendered, 224 seek timeouts (6.5 % — the degraded
backend, not the client; healthy-night baseline 0.84 %), 64 error lines (the
known Invalid-data class amplified by retries), 18 stall rescues — gave-up
count 0. Marker net consistent where scans completed: 96 unique verdicts,
end-overhang 71 % / median −12.5 s (control: 75–76 % / −11.4…−11.9 s — CV's
hold trial still not live). Exports: 16/16 sampled PASS with
delivered_range present; the 3 fails are the two known server classes.

## Recommendations

1. Implement session-generation serialization (candidate #1) and replay a
   fault-storm test to measure the ceiling drop.
2. Keep trim; re-judge on a healthy night with the fixed [MEMTRIM] logging.
3. The 6.5 % seek-timeout night is itself an argument for CV's two switch
   fixes — the client burns memory and retries against dead camera blocks.
