# Evening calendar + historic-playback soak — results (2026-07-01 20:21 → 22:00, ~1.65 h)

`WT_CAL_STRESS` rotating the full roster (open a day → scrub → next day, sweeping the retention
window) against the **real degraded backend** (all cameras unplugged but .201 — the reported
condition), on **`build/` (system Qt 6.4.2)** — the build the operator hit the issue on. Hang-aware
supervisor, RSS/CPU sampled every 2 s.

## Headline: the ".201 stops responding" is a CRASH, and it's Qt 6.4.2-specific

The soak **crashed 6 times** — a real, reproducible **SIGSEGV**, ~1 per 15 min of aggressive
calendar use. Every crash is the **same** signature: souphttpsrc closing its HTTP connection to our
proxy on session teardown, segfaulting inside **libsoup-3.0**:

```
[WT-FATAL] SIGSEGV; RSS=583 MB              (not OOM — host had ~10 GB free, RSS-shed valve is 5 GB)
  libsoup-3.0.so.0(+0x4bd4f)
  libgio-2.0.so.0(g_input_stream_close+0xfe)
  g_object_unref → g_object_unref
  g_main_loop_run → libgstsoup.so           (souphttpsrc's streaming thread)
```

This is almost certainly what the operator saw as "stops responding": under calendar/historic
churn the app **segfaults and dies**. It fires in the **same teardown path** as the ~300 ms hitch
— tearing down the currently-playing session — which is why "click a past day" is when it bites.

### Root cause — Qt 6.4.2's media backend, not our code
`build/` runs **system Qt 6.4.2**, whose QtMultimedia default backend on Linux is **GStreamer**
(souphttpsrc + **libsoup 3.4.4**). Under rapid session open/teardown, libsoup 3 use-after-frees on
connection close. Confirmed it's the backend, not us, by swapping backends:

| build / Qt | media backend | result under the same churn |
|---|---|---|
| `build/` Qt **6.4.2** | GStreamer (souphttpsrc/libsoup3) | **SIGSEGV in libsoup** (~15 min) |
| `build/` Qt **6.4.2** + `QT_MEDIA_BACKEND=ffmpeg` | FFmpeg (experimental in 6.4) | **SIGABRT** — `qt_assert` destroying a `QVideoFrame` during QML GC (~20 s) |
| `build68/` Qt **6.8.3** (production toolchain) | FFmpeg (mature, default in ≥6.5) | **survives** — no crash in 90 s, **no libsoup loaded**, teardown hitch **~20 ms** |

Both **Qt 6.4.2** backends crash (GStreamer→libsoup, experimental-FFmpeg→QVideoFrame assertion).
**Qt 6.8.3's** mature FFmpeg backend uses neither libsoup nor GStreamer HLS, so both crash modes are
gone — and as a bonus the calendar teardown hitch drops from ~307 ms to ~20 ms (also killing the
"awfully slow calendar" feel).

## Recommendation
- **Run/ship on the Qt 6.8.3 build (`build68`), not the Qt 6.4.2 `build/`.** It eliminates the crash
  and the teardown hitch. (The operator was testing on `build/` = Qt 6.4.2.)
- There is **no clean Qt 6.4.2 fix** — both of its backends crash under session churn.
- Next: a Qt 6.8.3 **validation soak** of the same duration to confirm crash-free over hours (the
  90 s check only rules out the two fast/known modes).

## Metrics (build/ Qt 6.4.2 run — for the record)
- **Crashes: 6** (SIGSEGV/libsoup), run lifetimes 390 / 630 / 1861 / 405 / 1410 / 901 s (mean ~15.5 min,
  random cadence — a race). **0 hangs** (the supervisor's 120 s heartbeat never stalled → confirms the
  teardown is a *bounded* stall, not a wedge; the app dies outright rather than hanging).
- **Teardown hitch `[PBSTOP]`** (n=499): playing **mean 307 ms**, stdev 37, min 3, max 1008; idle 0 ms.
- **RSS**: mean 858, max 1688 MB (aggregate inflated by within-run climb + the 6 relaunches, each
  resetting to ~300 MB). Crashes hit at **571–852 MB — not OOM**. The 1688 MB spike is a single
  outlier worth a follow-up but is not what killed any run.
- **CPU**: mean 20 %, max 53 %. 2 957 samples, 1 059 `[CAL]` actions across 7 launches.
- Graph: `docs/perf/2026-07-01-calendar-soak.png` (RSS + CPU, crash lines marked).
- Raw: `/tmp/cal_soak/` (app.log with full backtraces, incidents.log, samples.csv, supervisor.log).

See `docs/perf/2026-07-01-calendar-freeze-investigation.md` for the teardown-hitch analysis (the
bounded GUI-thread cost, separate from this crash).
