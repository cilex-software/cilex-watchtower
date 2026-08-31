# The first open of a process costs ~8–20×, and it is the PROCESS, not CV's cache

**Station:** `wt-sm-vnutri-01` (guard booth, Win 11) · **Date:** 2026-09-01
**Build:** 1.1.294–1.1.298 · **Backend:** `192.168.1.4:8000` (LAN)

## The finding

Across every playback harness run tonight, the first day-open of a process costs
16–27 s while later opens in the same process cost 0.6–7 s. That ~20× gap is
larger than every other effect measured this week combined — larger than
`head_split`, larger than the read-ahead hold, larger than the link itself.

## It is the process, not the server cache

The obvious explanation is CV's per-camera/per-day cache being cold on first
touch. **It is not.** Held server warmth constant and varied only process age:

Phase 1 — one process opening the *same day* three times, to warm CV thoroughly:

    open 1   25,333 ms
    open 2    7,064 ms
    open 3    1,025 ms

Phase 2 — five *fresh processes*, each opening that same, now provably warm day
(it had been opened 8+ times by this point):

    launch   open 1 (process-COLD, server-WARM)   open 2 (process-WARM, server-WARM)
    L1                26,868                                   1,905
    L2                17,765                                   5,214
    L3                  failed                                10,493
    L4                27,555                                     982
    L5                11,949                                   2,840
    median            22,316                                   2,840

**A cold process pays ~22 s on a day the server has served eight times already.**
Server-side caching cannot explain that; the state that matters lives in the client.

## The mechanism: the first open skips FAST OPEN

From `discab2`, all four launches, without exception:

    day_opens=6   fast_open=5      (and the ONE open without it is the first)

The open that skips FAST OPEN is the one that costs 16–27 s. Its `[PBTIME]` trace
shows why — it requests the **whole day** before narrowing:

    cold open (no fast_open):
      session_http ms=12477  bytes=2,253,507  frags=2882
                   st=[serve 12011.1, index 11764.8, acquire 6274.1]
      session_ready dt=12515ms
      bounded_bootstrap frags=2877 tgt=00:00:00     <- derives the target FROM the day
      session_http ms=1932   bytes=49,335    frags=62
      first_frame dt=16667ms

    warm open (fast_open win=30min tgt=00:00:13):
      session_http ms=197    bytes=49,350    frags=62
      session_ready dt=202ms
      first_frame dt=2213ms
      ...then the 2 MB day manifest, DEFERRED to after first frame

So on the first open the app pays a 2.25 MB / 2,882-fragment day manifest to learn
an instant that `bounded_bootstrap` then derives as `00:00:00` — and which
coverage already carries as `dayInfo[date].firstMs`.

## The open question — do guards actually hit this?

**Not yet established, and it must not be asserted either way.**

`PlaybackScreen.qml:717` claims coverage "is on hand BEFORE the day can be
clicked". If that holds, a guard cannot click a day before the calendar has its
coverage dots, the gate passes, and this is my harness clicking on a 30-second
timer faster than a human could — an artefact, not a defect.

If it does not hold, then the first open of every session pays a whole-day
manifest for an instant already in hand — which is precisely the behaviour the
standing goal names.

`[PBTIME] fast_open_skip why=` (added 2026-09-01) distinguishes them:
`no-dayinfo` / `no-firstMs` / `light-day` / `target-out-of-range`, plus `dayKeys=N`
for how many days coverage had populated at click time. **Do not act on this
finding until that line has been read.**

## Why this matters more than what it replaces

Every other lever measured this week moves the *warm* case, which is already
0.6–2.8 s and sometimes sub-second. This one moves the case a guard meets when
they walk up to the station and open playback for the first time — the case that
forms their impression of whether the system is fast.
