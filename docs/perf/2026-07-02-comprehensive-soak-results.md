# Comprehensive soak — results (2026-07-01 23:12 → 07-02 08:00, 8.79 h)

Full `WT_GUARD_SOAK` (Live wall/fullscreen/replace/layouts + Events 4 tabs + video + playback-wall
swaps) **plus** the new single-camera playback block (rotate every camera → open a day → historic
scrub → rapid calendar day-sweep), on **`build68` + Qt 6.8.3 (mature FFmpeg backend)**, against the
**real degraded backend** (all cameras unplugged but .201). This validates the crash fix under the
full workload and characterises historic-playback behaviour in the degraded state.

## Verdict: the Qt 6.8.3 fix holds — 0 crashes, 0 hangs, no leak
| | Qt 6.4.2 (`build/`, GStreamer) | Qt 6.8.3 (`build68`, FFmpeg) |
|---|---|---|
| run | evening cal soak, 1.65 h | comprehensive, **8.79 h** |
| **crashes** | **6** (SIGSEGV/libsoup) | **0** |
| hangs | 0 | 0 |
| launches | 7 (6 relaunches) | **1** |
| teardown hitch (playing) | 307 ms | **9 ms** (max 23) |

- **1 launch, 0 crashes, 0 hangs** over 8.79 h — 15,770 samples, 1,318 actions (43 cycles), 0 `[GUARD] ERR`.
- **RSS: mean 575 MB, max 777 MB, trend +2.2 MB/h ≈ flat → NO LEAK** (genuine check: one continuous run,
  no relaunch resets). CPU mean 5.7 %, max 50 %.
- Actions: Live 473, Events 341, Playback (calendar+scrub) 252, Playback-wall 126, Groups/Views/Health 126.
- RSS peaks (~777 MB) on `playback-wall`; CPU peaks (~50 %) on the rapid `playback-cal-sweep`. Both recover.
- **The libsoup SIGSEGV that crashed Qt 6.4.2 6× is gone** — the FFmpeg backend loads no libsoup/souphttpsrc.

## Historic playback IS slow — quantified (your "playbacks don't work / very slow")
Across the whole soak, video was in the **playing state only ~82 s of 8.79 h** (0.26 %); 94 % of ticks
were `NoMedia`. Some is sparse footage (most camera/day combos are empty → honest "No footage"), but a
direct measurement pins the real cost:

- **Backend load path is fast**: session-open 0.33 s, playlist 0.10 s, **each segment ~0.09 s**.
- **But time-to-first-frame ≈ 14 s** opening a day for a camera with lots of footage (.106, ~12 h /
  **1446 ready segments** on 2026-07-01): the player sits at `NoMedia` for ~14 s, then plays smoothly.
  The delay is the **FFmpeg backend prerolling the full 24 h continuous playlist** (1518 segments /
  207 KB), not segment latency.

So historic playback *works* on the fixed build but is **slow to START** (~14 s spinner) for
heavy-footage days, because `openForDay` always loads the entire 24 h. (This is also why the soak's
low play-rate: the harness's 12 s open-dwell was shorter than the ~14 s load, so paced opens moved on
before the first frame — a harness-tuning artefact that happens to expose the real TTFF.)

### Recommended follow-up (separate from the crash fix)
- **Shrink the initial playback window / seek-on-open**: open a bounded window around the target
  instant (or the day's first footage) instead of the full 24 h, so preroll isn't gated by a
  1500-segment playlist; lazily widen the scrubber timeline. Biggest lever for perceived speed.
- Or a lighter/windowed backend manifest for day-opens.
- Meanwhile a determinate "Loading…" affordance would make the ~14 s read as progress, not "broken".

## Recommendation (unchanged, reinforced)
**Ship/run on Qt 6.8.3 (`build68`)** — eliminates the crash and the teardown hitch. The remaining
historic-playback start latency is a preroll optimisation, tracked above.

## Artifacts
- Graph: `docs/perf/2026-07-02-comprehensive-soak.png` (RSS + CPU + trend, 8.8 h single run).
- Raw: `/tmp/full_soak68/` (app.log, incidents.log — empty, samples.csv, supervisor.log).
- Prior: `docs/perf/2026-07-01-calendar-soak-results.md` (the Qt 6.4.2 crash), `…-freeze-investigation.md`.
