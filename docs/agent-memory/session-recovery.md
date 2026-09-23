---
name: session-recovery
description: START HERE after a context reset — full state of Cilex Watchtower and how to resume
metadata: 
  node_type: memory
  type: project
  originSessionId: 07da05e9-981a-465b-aad6-7f1cc1e8c07c
---

**Read this first to restore context.** Cilex Watchtower = a native Ubuntu
**Qt6/QML/C++ surveillance VMS operator client** (not a browser app), a client of
the **cilex-vision** platform. Cameras have no storage; footage/events come from
cilex-vision. Repo: `/home/cilex-vision/projects/cilex-watchtower`.

## Latest session (2026-06-21–29) — READ THIS FIRST (supersedes all blocks below)
`42231e0` **Guard endurance+STRESS soak DONE (2026-07-01 12:00) — CLEAN: 0 crashes/0 hangs/0 wedges, NO LEAK (RSS flat +4.2MB/h, max 702MB) over 12h under ~840 camera-swaps + ~1040 wall-swaps + 315 fullscreens + 416 video-plays / 104 cycles. The old swap leak did NOT reappear; the wall↔Live wedge fix held through 104 wall opens. Results: `docs/perf/2026-07-01-guard-stress-soak-results.md` + `.png`.** (harness in Main.qml) After the wedge fix, a simple-nav re-run validated it clean (**5h, 105 steps, 13 wall opens, 0 crashes/0 hangs**, RSS 343→550MB ≈ +41MB/h mild creep). Then expanded `WT_GUARD_SOAK` (Main.qml) to drive the leak-prone paths each ~11min cycle: Live = fullscreen random cams + **REPLACE/swap random cams into random tiles** (`liveMonitor.assignToCell`, 8/cycle — the historical swap-leak/OOM path) + layout churn 16/4/9; Events = all 4 tabs + **play random videos** (new `EventsArea.selectRandomEvent()` → hero); Wall = enter + `swapSlots` ×10/cycle. Verified full cycle: 0 [GUARD] ERR, no wedge/crash, livePipes rebuilds (one cosmetic GStreamer-CRITICAL seqnum assertion under rapid churn). **ON COMPLETION (noon): run `docs/perf/soak-tools/guard_analyze.py` + `guard_graph2.py`** on `/tmp/guard_test/` — now reports per-action counts/dwell + a STRESS-APPLIED tally (replaces/wall-swaps/fullscreens/layouts/plays) + RSS/CPU + graph; **scrutinise the RSS trend across ~500 replaces/~640 wall-swaps for a leak** (RSS-shed valve 5GB + hang-aware supervisor v2 are the backstops). Simple-soak data archived at `/tmp/guard_test_rerun_simple`. · 
`3618b9d` **Guard-soak found + FIXED a critical playback-wall↔Live GUI WEDGE.** A 10.5h guard-usage soak (`WT_GUARD_SOAK` in Main.qml: 17min Live + human-paced click-throughs of Events/Groups/Views/Health/playback-wall) showed **0 crashes/OOM/leak (RSS flat ~450MB)** BUT the GUI **wedged at 22min on the playback-wall→Live transition** — process alive, GUI frozen (so the supervisor's process-liveness check missed it → 9.6h frozen). Root cause: **`HlsProxy` ran on the GUI thread**, so `player.stop()` (GUI) deadlocked — it joins the demuxer, the demuxer waits for a mosaic segment, the proxy can't serve it (GUI stuck in stop()). **Fix: moved HlsProxy to its own QThread** (own NAM created in an `init()` slot via moveToThread+BlockingQueuedConnection; cross-thread auth via new `AuthController::token()` pushed over queued `setAuthToken`; port via std::atomic; ~PlaybackClient joins it). Verified: wall→Live cleared ×2, no freeze, mosaic plays (0 auth errors). **Supervisor v2 is now HANG-AWARE** (heartbeat stall ≥120s while alive → relaunch+record). Soak doc: `docs/perf/2026-06-30-guard-soak-and-wedge-fix.md`; tooling `docs/perf/soak-tools/`. **IN PROGRESS: full re-run on the fixed build until 2026-07-01 12:00** (data in `/tmp/guard_test/`; on completion run `docs/perf/soak-tools/guard_analyze.py` + `guard_graph2.py` for stats+graph; WATCH the RSS trend across the ~44 wall opens — soak#1 only opened the wall once before wedging, so this is the first real test of repeated wall enter/exit). Also earlier this session: snapshot-401 fix (route snapshots via the auth'd cvframe provider, `be723fd`) + P0#2 .106-lag armed-priority (`694b790`). · 
`694b790` **P0 #2 (.106 Live-wall 2-3s lag) — FIXED.** Cause: the wall gives its ≤`maxLiveDecodes`(9) live slots BY IP-SORT POSITION; .106 sat past the cap → 4s-polled snapshot, not live, despite being motion-armed. 3 fixes (**`maxLiveDecodes` UNCHANGED** — P0 #1 memory intact): (1) `LiveThumb.refreshMs` 4000→1000 (env `WT_THUMB_REFRESH_MS`) — capped tiles ≤1s stale, cheap via the cached snapshot endpoint; (2) `LiveMonitor.liveDecodeSet` ranks page cameras **armed-first** then position, top-N get live slots → armed cams (.106) real-time, idle drop to snapshot; stable (recompute on roster/sort/page, not every poll → no slot thrash); (3) `CameraTile` `◌ SNAPSHOT` badge on capped tiles. **Verified:** 3 armed (.106/.120/.201) ≤9 → all armed live ⇒ .106 LIVE; go2rtc :1984 wakes 0 (cached :8000), query-api absorbed 1s poll (~130/30s), go2rtc stable (RestartCount 0); live decodes still 9; screenshot confirms badges. Doc+png: `docs/perf/2026-06-30-live-106-lag-fix.md`. **Both P0s now resolved: P0 #1 contained (RSS-shed valve), P0 #2 fixed.** · 
`6b77f2d` **P0 #1 (Live-wall OOM crash) — CONTAINED via an RSS-shed safety valve; teardown proven robust; root leak open (likely upstream).** Built a `WT_WALL_CHURN` reproducer (+`WT_WALL_BADURL`/`WT_RTSP_TCP`) at a low cap (box is OOM-sensitive). ~600 teardown cycles — healthy churn (cap 2+6), black-hole connecting-fail, play-then-socat-proxy-drop — **ALL CLEAN** (RSS flat, livePipes≤cap, ZERO G_IS_OBJECT) ⇒ the `RtspVideoSource` teardown is NOT broadly broken; per-teardown-leak hypothesis disproven. The crash's `g_object_unref` G_IS_OBJECT + climb only occur with **go2rtc ACTIVELY OOM-looping** (abnormal mid-decode drops) — not safely reproducible (can't destabilize go2rtc), likely **upstream** in rtspsrc/decodebin aborted-stream handling. **Two-layer fix:** (1) TRIGGER removed — the go2rtc OOM-loop is gone after this session's go2rtc cached-snapshot fix (stable, RestartCount 0). (2) **RSS-shed valve (shipped+verified):** `MemTelemetry` checks RSS every 5s; above `WT_RSS_SHED_MB` (default 5000; 0=off) → `shedLive` → `LiveMonitor` collapses `maxLiveDecodes`→1 → wall sheds to (cached) snapshot tiles, capping RSS not OOM. Hysteresis 85%. Verified (200MB threshold: shed 4→1, RSS capped ~277MB; inert at 5GB default). Harness gated/inert for a future staged-instability repro. Doc: `docs/perf/2026-06-30-live-wall-oom-deepdive.md`. (P0 #2 .106-lag still open: decode-capped→4s snapshot poll; now cheap to speed up via the cached endpoint.) · 
`d5f2908` **go2rtc OOM alerts (ntfy, Jun28+29) investigated → two-sided; client mitigated + backend letter.** go2rtc (BACKEND) OOM-kills: 512MB cap for the **whole ~34-camera fleet** (68 streams, VA-API transcodes), RestartCount=19, OOMKilled=true — chronically OOM-prone (the known backend OOM-loop, see [[dev-box-oom-freezes]]). It wakes an RTSP/ffmpeg **producer per stream on demand**; ~9 concurrent cold wakes OOM the tiny cgroup. **Client's role:** `EvSnapshot` fetched go2rtc `/api/frame.jpeg` **eagerly per event-camera** (meant as a fallback for the stored still); the Triage feed spans many cameras, so cycling events woke many producers, and the **open-only leak harness (~26 ev/min, long soaks) amplified it** (Jun29 07:46 kill overlapped a run). **Can't prove the client was the SOLE trigger** (a browser/live-view consuming transcodes looks identical in go2rtc logs). **Fix:** lazy fallback — go2rtc frame fetched ONLY when `evImg` (stored still) 404s (`qml/EvSnapshot.qml`). **Backend letter:** `docs/letters/2026-06-29-go2rtc-oom-under-snapshot-load.md` (raise cap / bound+reap producers / serve frame.jpeg from a cached keyframe). **⚠ TEST-HYGIENE:** long open-only soaks load the OOM-sensitive backend (go2rtc producers via snapshots + playback-service) — the lazy fix helps, but keep future soaks shorter/gentler or gate snapshot fetching. (Corrected two wrong mid-investigation reads: NOT a src naming-mismatch — go2rtc HAS the hiwatch streams, 404 was a cold producer; and not provably client-caused.) · 
`92ec3f5` **⤷ LEAK SAGA RESOLVED — the residual is NOT shift-breaking; it PLATEAUS.** A 90-min continuous-playback soak (new `[MEMTEL]` telemetry) shows RSS climbs to a **~700-730MB plateau in ~15min then FLAT** (15-90min ≈ +0.0 MB/min; overall +0.32). **The famous '+66/+39 MB/min' was the one-time startup working-set fill — every prior test (≤4min) was too short to reach the plateau**, which also debunks the original 'linear/unbounded over a shift' premise. Discriminator: 0.07 MB/open (fast,2408 opens) vs 1.77 (slow,78) ⇒ NOT open-driven, and fast plateaus despite 2408 opens. earlyoom SIGTERMs at MemAvailable<~1.6GB (~5.8GB headroom now) ⇒ ~0.7GB plateau = ~8× margin, **no process-reset needed**. The mallopt+sourceSize fix lowered the plateau height + is good hygiene, but the OOM alarm was a short-test artifact. **Shipped `MemTelemetry`** (id=1 hero, id=2 wall; `[MEMTEL] up/rss/playSec/opens`) + `WT_HERO_SETTLE_MS` knob to confirm the plateau in the field. Doc: deep-dive **Revision 4**. · 
`c767aed` **✅ PER-OPEN RSS LEAK SOLVED + FIXED (was the +66 MB/min playback growth; earlier 'Qt-internal unfreed/unfixable' AND 'emergent/profiler-blocked' calls were BOTH WRONG).** Localized with a purpose-built **LD_PRELOAD malloc-site tracer** (`docs/perf/leak-tools/malloctrace.cpp` — heaptrack/valgrind unusable here; this is the profiler that works). Two client-side causes: **(1) glibc arena RETENTION (dominant)** — `mallinfo2` in_use FLAT ~270MB while RSS climbs + 0 live >1MB mmaps ⇒ NOT unfreed; large transient playback buffers churned per open ratchet glibc's dynamic mmap threshold → freed memory retained+fragmented in the arena, never returned. **Fix: `mallopt(M_MMAP_THRESHOLD/M_TRIM_THRESHOLD,128KB)`+15s `malloc_trim()` in `main.cpp`** (env `WT_MMAP_KB`) → **+66.3→+39.2 MB/min (~41%)**; 128KB is the sweet spot (32/64KB REGRESS — page-rounding). **(2) full-res snapshot decode** — `EvSnapshot` Images had no `sourceSize` + `CvImageProvider` ignored `requestedSize` → every still cached at full 2560×1440 (~14MB), 323MB #1 site. **Fix: `sourceSize` on both Images + provider downscales to `requestedSize`** → baseline **323→98MB**. Residual +39 = sub-128KB fragmentation (allocator-tuning floor); process-reset mitigation still applies for very long shifts but at a much lower rate. Diagnostic gates added: `WT_PROXY_STATS`,`WT_DUMP_SEG`,`WT_NO_PREFETCH`,`WT_MMAP_KB`. Full write-up: `docs/perf/2026-06-29-qt-decode-leak-deepdive.md` **Revision 3**. · `25b6f40` **LEAK BISECTION EXHAUSTED — emergent in the full client, not isolatable, profiler-blocked.** Every isolatable piece PLATEAUS (bounded ~150-330MB), only the full client sustains +66/min: standalone player on **QML VideoOutput** (client's exact render path) + **real captured HEVC segments** (file:// AND http://) → plateau; **QNAM alone** 3000 GETs → flat; **HlsProxy internals** (`WT_PROXY_STATS`: cache/inflight/sockets/replies) → all bounded; `WT_NO_PREFETCH` → -18%. NOT the player, NOT QNAM, NOT the proxy objects → emergent in the hero-play path. (Proxy-stats `0`s were a 2nd idle HlsProxy, not a cache clear.) **Malloc-site localization needs a heap profiler; BLOCKED (heaptrack unusable; valgrind impractical on SW-HEVC/VA-API) → next tool = LD_PRELOAD mmap-site logger.** NOT a Qt bug. **Mitigation stands: bounded per-event ~8MB/open, continuous-seek removed the scrub multiplier → not shift-breaking; process-level reset if needed (player-recreate doesn't free it).** Control repro `docs/perf/qt-leak-repro/` + gates kept. Doc: `2026-06-29-qt-decode-leak-deepdive.md` Rev2. · `a06f3cd` **⚠ LEAK DIAGNOSIS REVISED — it's CLIENT-side, NOT Qt (overturns the 8334457/5f63407 'Qt-internal unfixable' calls).** Built the standalone QMediaPlayer setSource-loop reproducer (`docs/perf/qt-leak-repro/`) and ran it EVERY way (bare sink / QVideoWidget render / mp4 / local+HTTP HLS / unique-URL / 6 distinct clips) — **ALL PLATEAU ~180-330MB; a bare QMediaPlayer does NOT sustain-leak.** So the +66 MB/min is the **client playback integration** (real HLS via our **HlsProxy**: libavformat→localhost HlsProxy→QNAM→query-api), not generic Qt. In-client bisect: **`WT_NO_PREFETCH` drops +66→+54** (read-ahead ≈18%); the rest is the proxy `forward`/QNAM + real-segment decode. **LIKELY CLIENT-FIXABLE; NEXT = localize HlsProxy::forward/cache/QNAM** (heaptrack unusable; bisect with gates). The repro is the CONTROL (rules out the bare player) — do NOT file a Qt bug on it. (Qt 6.12 re-bisect + smaps[heap+anon, GPU flat] + HW/SW-agnostic still stand; they just point at the client path now, not Qt.) Doc: `docs/perf/2026-06-29-qt-decode-leak-deepdive.md` (Revision section). · `8334457` **QT DECODE-LEAK DEEP-DIVE (cause found).** smaps: growth is CPU **heap +220MB + anon mmap +405MB**, GPU/DRM+dmabuf FLAT → NOT VA-API surfaces, it's the decode context + frame buffers. **SW decode +64 ≈ HW +66 → HW/SW-agnostic** (core pipeline). MALLOC_ARENA_MAX=2 +74 → not arena frag; mmap'd frames genuinely not freed. **CAUSE: Qt FFmpeg backend doesn't release the prior decoder's frame pool/buffers on `setSource` (~1 frame+context/open); Qt-internal, persists 6.8.3→6.12.0.** FIXES: Qt bug + standalone setSource-loop repro (real); reduce source-changes (continuous-seek did the scrub half); process-level auto-reset at an RSS threshold (player-recreate does NOT free it); GStreamer backend (from-source, large). Writeup `docs/perf/2026-06-29-qt-decode-leak-deepdive.md`. · `5f63407` **QT-UPGRADE RE-BISECT of the per-open leak → NOT fixed (per-event Qt leak is here to stay).** Installed **Qt 6.12.0** (aqtinstall, beside 6.8.3, at `/home/cilex-vision/Qt/6.12.0`) + `build612`; needed **`-DWT_ONLY_BYTECODE=ON`** (guarded CMakeLists escape hatch — 6.12.0's qmlcachegen SEGFAULTs AOT-compiling our QML). Open-only leak: **6.12.0 +68.1 MB/min ≈ 6.8.3 +66.3** → the FFmpeg-backend per-source-change decode leak is UNCHANGED across 6.8→6.12. GStreamer backend (only other lever) **isn't in Qt binary releases** (both ship `libffmpegmediaplugin.so` only) → needs Qt from source. **DECISION: stay on 6.8.3 LTS; accept + mitigate (bounded ~8MB/event-opened; continuous-seek already removed per-scrub re-opens) + file a Qt bug** (standalone setSource-loop repro). Data/result: `docs/perf/2026-06-29-qt-leak-rebisect.prompt.md` + `2026-06-29-qt612-leak.*`. (Qt 6.12.0 + build612 REMOVED after the test, ~2G reclaimed; re-install via aqtinstall + `-DWT_ONLY_BYTECODE=ON` to re-test. aqtinstall kept in ~/.local.) · HEAD **`aff29b7`** on `main`, **pushed, working tree clean.** This arc's commits (newest→oldest):
`684643b` **CONTINUOUS-TIMELINE THREAD CLOSED (CV reply8 → our reply9).** CV **flipped the server
`seek_mode` default legacy→continuous (`e1b1b84`)** after a clean hls.js no-regression check (hls.js already
seeks across the per-fragment discontinuity; only Qt's libavformat `hls` stalled). CV **declined** widening
base prewarm for the cold-base tail (16 GB OOM-sensitive host; h264-trans capped at concurrency 2) — left as
a **bounded later lever** (small window-behind-the-playhead warmer) IF operators complain about backward/far
cold seeks → then ping CV with the seek pattern. **NET: Ask 1 (continuous timeline + offset caching +
boundary fields) + Ask 2 (48h cap) SHIPPED + DEFAULT; per-scrub re-open leak gone; freeze fixed.** TWO
FUTURE-ONLY FLAGS parked: (1) **Playback wall `WT_SEEK_TEST`** inherits the fix (same PlaybackClient+hls.c) —
run when wall wiring lands; (2) **mosaic `/review/mosaic-sessions`** still per-segment-discontinuous → ask CV
for the same continuous treatment when we pick up multi-cam wall scrubbing. · `7685435`+`fd5ebab` **POST-CACHING RE-TEST (CV reply6 shipped offset-caching `673296e`; our reply7).**
Re-tested continuous in Qt: **warm/repeat scrubs now FAST (median ~0.3-0.7s, 1s ~60-165ms; was ~1.8s)** —
caching works. **Pure-direct diagnostic (no watchdog): continuous direct seeks LAND 99% (1% stuck), 0
re-opens** ⇒ the seek-watchdog isn't catching demuxer hangs (continuous PTS killed those), only SLOW seeks.
**Slow tail = COLD BASE renditions (S3 fetch, ~2-4s, variable) on backward/far seeks — NOT the offset step**
(CV's own finding), and re-opening hits the SAME cold base, so a tight 2.8/4s watchdog was counterproductive
(re-opened 26-29% cold-but-landing seeks). **Fix: watchdog → 6s LAST-RESORT** (tolerates cold-base, catches
only a genuine >6s hang) ⇒ **seek re-open rate → ~0 = per-scrub leak gone.** Cold tail needs BROADER/backward
base prewarm (CV's call; UX-niceness, not blocking; offset-prewarm won't help). Honesty note in reply7: seek
re-opens were never the dominant RSS driver — the per-EVENT Qt decode leak dominates (separate, Qt-upgrade).
GO to flip the server default (after CV's hls.js check). Logs `docs/perf/2026-06-28-continuous-postcache.*`.
**Playback wall NOW WIRED to continuous too (commit `e7e4345`, reply10): seekToWall direct + re-open only outside the loaded window OR across a discontinuity:true frag (`_crossesBoundary`, compact-space) + 6s watchdog; tl*/win* decouple preserved. WT_SEEK_TEST A/B (.106 06-26, 2.78h footage/24h): in-footage seeks 1s-3h 0% froze + DIRECT (15-173ms) vs legacy freezing 10s/30s + re-opening; ≥5h TIMEOUT = beyond-footage artifact. BOTH seek surfaces (hero+wall) now on continuous.** REMAINING: only the mosaic flag (future, multi-cam scrubbing). · `8dadde2`+`91ccc2b` **CONTINUOUS-HLS ADOPTED (CV reply4 shipped route B; our reply5 = GO).** Backend made
seeks landable via `seek_mode:"continuous"` (one continuous-PTS timeline, per-fragment discontinuity dropped)
+ shipped §4-ii per-fragment `discontinuity`/`boundary` fields. **Client wiring:** PlaybackClient requests
`seek_mode` (**default "continuous"**; `WT_SEEK_MODE=legacy` overrides) + echoes it in meta. EvHeroPlayer:
on a continuous session **seekToWall seeks DIRECTLY**, re-opens only when the jump crosses a
`discontinuity:true` fragment (**`_crossesBoundary`**: gap/codec/profile/pts_wrap) + a **2.8s freeze-watchdog**
for the slow/flaky tail; legacy keeps the every-far-seek re-open. **VALIDATED (WT_HERO_TEST, Qt FFmpeg
hls.c): direct seeks land 81% continuous vs 0% legacy; production logic 0% froze, seek re-open ~100%→18%.**
⚠ **CAVEAT: the UN-CACHED serve-time remux makes continuous seeks slow now (median ~1.8s) → the watchdog
still re-opens ~18% → the SCRUBBING-LEAK relief is GATED on CV caching the offset variant (their pending
step); re-test + tighten the watchdog after.** Manifest probe confirmed boundary marking is SEMANTIC +
mode-independent (10min clip=1 start; 4h motion=1 start+55 gap, identical both modes) + §4-i holds
(compact/wall byte-identical). **Ask 2 (48h cap) LIVE** (24/36/48h→200, 49/72h→400). New test gates
`wtSeekDirect` (direct-seek validation), `WT_SEEK_MODE`. **NEXT: wire the Playback wall (PlaybackScreen
seekFar→boundary-only, same pattern; run WT_SEEK_TEST) + re-test the leak after CV caches.** Validation logs
`docs/perf/2026-06-28-continuous-validation.*`. · `fbbab27`+`9f5ca08` **A3 PLAYBACK-SEEK LETTER THREAD — CV replied, we sent reply2.** CV (`…span.reply.md`)
**accepted both asks as backend-side**: Ask 1 (continuous-timeline) root cause = every rendition rebased to
**PTS=0** ⇒ a mandatory `#EXT-X-DISCONTINUITY` per fragment; fix = give a contiguous run continuous PTS +
emit discontinuity only at genuine boundaries (**route B** serve-time `-output_ts_offset` first ≈1wk, route
A cache-native later). Ask 2 = the 24h cap is an intentional `MAX_WINDOW_HOURS` 400-guard; **48h cheap now**,
multi-day gated on the per-request manifest JSONB re-parse. Our **reply2** (`…span.reply2.md`): (1) corrected
hlsdemux2→we're on **Qt FFmpeg `hls.c`** (av_log proof committed) so they can validate with `ffmpeg -ss`;
(2) validation pack = `2026-06-28-hlsseek-repro.sh` + our WT_SEEK_TEST/WT_HERO_TEST harness (offered to run
vs their build) + the committed before-baseline; (3) take 48h now (client enforces NO window cap → lifts
automatically); (4) **OPEN ASKS BACK TO CV — the client half waits on these:** (i) does route B keep the
per-fragment manifest `compact_start/end` byte-identical? (ii) **MARK the kept discontinuities per-fragment**
(gap/epoch/codec/profile/pts_wrap) so the client re-opens ONLY at boundaries; (iii) retention value for
multi-day scoping. **NEXT (gated on CV):** when continuous-HLS ships, relax EvHeroPlayer/PlaybackScreen
re-open to fire only at marked boundaries (→ scrubbing leak ≈ gone). · `a9d9dd0` **PER-OPEN LEAK INVESTIGATED → Qt-internal, unfixable client-side (2nd prompt, CLOSED as
won't-fix-client-side).** Bisected with an open-only harness (**`WT_HERO_OPENONLY`** loops event-opens no
seeks; **`WT_HERO_NOPLAY`** opens the session but skips the decode — both inert unless set) + /proc sampler.
Open-only RSS slope: **play(decode) +66 MB/min · no-play(session/proxy/QNAM) FLAT −0.3 · recreate-player
+59 (NO help)**. So the leak is the **Qt-FFmpeg decode pipeline on player.source**, NOT the session/proxy
(⇒ `DELETE /review/sessions` won't cut client RSS; HlsProxy cache is global+LRU-bounded 160MB); freed by
neither source-clear (A2) nor destroying the player (tested a Loader-wrap recreate — reverted, no benefit).
**Mitigation = the A3 backend continuous-HLS (kills the frozen-seek fix's per-seek re-opens, the bulk) +
a Qt upgrade (only fix for the residual per-event leak; the harness is kept to re-bisect).** Data+graph
`docs/perf/2026-06-28-hero-leak-bisect.*`; write-up in the leak prompt doc. · `9578b1a`+`300a539` **FROZEN-SEEK FIXED in the Triage hero (the first of the 2 prompts).** Ported A1 to
EvHeroPlayer: new wall-time **`seekToWall`** (≤3s nudge = direct player.position; further = **`_seekFar`**
re-opens a short session ~15s before the target → lands near the start, no cross-discontinuity stall) +
the **tl* episode-timeline decouple** (scrubber/transport run on the episode `[start,end]` from
episodeWindow via `_posToWall`, kept across re-opens; `_seekingToWall` pins the bar during the ~170ms
re-open). −10/+10 + scrubber now call seekToWall; testSeek too (so the harness measures the real path),
with a `!_loading` gate so the re-open's stop-flush isn't mis-timed. **BEFORE/AFTER (docs/perf/
`triage-hero-latency.baseline.md` + .after.*): seek froze 56%→2% (≥10s 58-79%→0%), all render ~166-225ms,
run 13.8min→2.4min.** ⚠ **memory now climbs PER-SEEK (every far seek re-opens) → the per-open-leak prompt
`docs/perf/2026-06-28-hero-per-open-leak.prompt.md` is the next priority (STILL OPEN).** · `6357b80`+`1aeb051` **TRIAGE-HERO LATENCY TEST + 2 fix-prompts.** Built **`WT_HERO_TEST`** harness
(EvHeroPlayer instruments click→first-frame [armed in onSessionReady] + seek→first-frame via the video-sink
frame signal; EvTriage sequences random selects + ±1s/10s/30s/1m/5m jumps, re-opens on freeze; new
`wtHeroTest` ctx prop + WT_HERO_AUTOPLAY). **FINDINGS (360 jumps/195 opens, .106): open median 235ms/max
1265ms; seeks ≥10s FREEZE 58-79% (≈56% all) — the FFmpeg-HLS discontinuity stall, A1 fix never ported to
the hero; rendered ones ~20ms; RSS leaks +8.6 MB/min (~6MB/open) to 1.35GB, every RSS/CPU spike = an open.**
BASELINE PRESERVED for before/after in `docs/perf/2026-06-28-triage-hero-latency.{baseline.md,before.ht.log,
before.samples.csv}` + analyzer (takes args) + graph. **Two fix prompts ready (NOT yet done):**
`docs/perf/2026-06-28-hero-frozen-seek.prompt.md` (port A1 seekFar+tl*/win* decouple to the hero; root fix =
backend continuous-HLS A3 letter) and `…hero-per-open-leak.prompt.md` (bisect like A2; likely DELETE
/review/sessions + player teardown). · `556760a`+`ed410bc` **P0 #2 FIXED — duplicate/overlapping clips for one motion + duration mismatch.** Each
motion episode = **THREE backend events sharing `metadata.recording_id`: motion_started (exact start, NULL
duration), motion_detected (start + duration; THE ONLY TYPE THE FEED CARRIES — the server excludes the bookends), motion_ended (the END +
duration).** Shown raw, the queue listed every episode TWICE (started row + ended row) and the wide P0
window overlapped neighbours → two rows looked like "the same motion." Fix: **`EventsStore.ingestReal` now
JOINS started↔ended by recording_id (`eventModel.all()` spans all loaded pages) → ONE row per episode,
ev.ts = the EXACT start, durationSec = the true span [start,end]; `episodeWindow` simplified to forward
[ts,ts+dur]; EvHeroPlayer opens EXACTLY [start-15s,end+15s] (no neighbour bleed, player dur == list badge).**
Verified .106: queue 67→34 rows, 12-min episode one row "12m43s·17:36:57", 188 frags, 0 errors. Backend
letter `docs/letters/2026-06-28-motion-episode-representation.md` (asks: episode-level events / documented
join; merge over-segmented near-continuous motion — measured gaps 0-11s). · `7a57d94` **feat — Triage hero
shows the recorded wall-clock time top-right (YYYY-MM-DD HH:MM:SS), ticks live; `_posToWall` inverse of
`_wallToPos`; moved the ▶PLAYBACK chip to top-left.** · `b0597ee`+`6a6f2ef` **P0 FIXED — "No footage recorded around this moment" for motion_ended events (+ the
same bug in Export).** ROOT CAUSE: **recording on these cameras is MOTION-TRIGGERED** — footage exists only
DURING a motion episode, nothing after it stops. A `motion_ended` event's `start_time` (= `ev.ts`) is the
END of the episode, with `duration_ms` = the episode length, so the footage is the span `[ts-dur, ts]`,
BEFORE ts. EvHeroPlayer opened a FORWARD window `[ts-15s, ts+dur+15s]` → past the end into empty space →
0 fragments → the error. **Verified live on .106 (`hiwatch-083bc14eff9a`): forward=0 vs backward=183 ready
fragments; 6/6 motion_ended events fixed (the 12m19s one 0→183).** Fix: EvHeroPlayer opens a WIDE window
`[ts-dur-15s, ts+dur+15s]` (bulletproof both-directions) + seeks to the episode start; Export sends the
episode span (was an empty forward mp4 — backend accepts it with 200, so it FAILED SILENTLY). Centralised in
**`EventsStore.episodeWindow(ev)` → {startMs,endMs}** (used by hero + export so they can't drift). Added
**`WT_HERO_AUTOPLAY`** test hook + WT_TRACE `[HERO]` log. Backend probe: `/tmp/diag_p0.py` (login admin/admin
→ `/events?camera_id=&start=&end=` → `POST /review/sessions` fragment count). Legacy `EventsScreen` export
(behind `WT_EVENTS_LEGACY`) + `openAt` still use the old forward path — low priority (the day session loads,
so no "No footage", just seeks to the episode end). · `32a0337` **fix: A1 POLISH — decoupled the scrubber timeline from the player window.** seekFar's short
~30min re-open used to drive win*/win → scrubber/markers/footage-track re-centred to 30min on a far jump.
Split it: **win*/frags = LOADED PLAYER session** (posToWall/seek/pipeline); new **tl*/tlFrags = TIMELINE the
scrubber shows** (footage track, markers, zoom-view bounds, Coverage, export). Fresh open adopts session as
timeline; `_seekReopen` flag → onSessionReady swaps only the player window, KEEPS tl*. WT_SEEK_TEST anchors
targets to tl*+playhead. Added **`wtTrace`** QML context prop + WT_TRACE-gated `[PB]` trace. Verified
(WT_PLAYBACK_IP @24h): every far seek logs "win=30min, timeline KEPT=1439min"; on-screen shot = full-24h
scrubber after 7 re-opens. Known follow-up: no auto-continuation at the 30min window EOS (pre-existing).
**REDO of all 3 stress tests on this build (graphs /tmp/test{1,2,3}_graph.png): T1 resize CLEAN (DONE, 0
crash); T2 seek ok=1524/TIMEOUT=3 — all 16 step sizes 1s..24h RENDER (was every ≥30s FROZE), plateau ~727MB
no leak; T3 events 15min ramp→980MB then FLAT +0.2 MB/min (was +642MB/15min), 0 crash, opens=0 (lazy-play =
recordings load on play-tap, not select).** All 3 fixes validated. · `c0d9238` **perf: clawed back the A2 baseline — lazy-load non-Triage event views.** A2's StackLayout kept
all 4 views resident (~580→~980MB). Now Triage stays resident; Verify/Timeline/Map lazy-load on first
visit then LATCH active (never destroyed → no recreate-leak). Measured: **Triage-idle 484MB** (even below
pre-A2 ~580, since lazy-play no longer auto-loads a recording); all-tabs plateau 981MB **slope +0 (flat,
leak still fixed)**. Further claw-back of the 981 (release a hidden view's Canvas/image) deferred. ·
**ACTION-LIST OUTCOMES from the 3 stress tests — ALL 3 NOW CLOSED (worked through with operator):**
`fb9efa8` **A1 FIXED — playback far-seek freeze.** `seekToWall()` now detects a far target (>20s from the
current compact pos) and calls new `seekFar()`, which re-opens a short ~30min session STARTING ~15s before
the target + seeks on load (mirrors EvHeroPlayer event-open) — target lands near the start of a fresh short
HLS, no cross-discontinuity seek, renders. Verified: before = ≥30s jumps all TIMEOUT; after = ok=32/0,
far jumps render 3-391ms. **Trade-off (prototype): a far jump re-centres the scrubber to ~30min; polish
follow-up = decouple the scrubber timeline from the player's loaded window.** Added `WT_SEEK_SPAN` knob;
seek harness now routes through `seekToWall`. · `f99504a` **A3 DONE — backend letter**
`docs/letters/2026-06-27-playback-seek-discontinuities-and-session-span.md` (asks: continuous-timeline HLS
so seeks don't need the workaround; + the ~24-36h session-span cap). · `b61474d` **A2 FIXED — events leak
(was +43..52 MB/min, +642MB/15min → now ~+0..7 MB/min, FLAT).** Found by INSTRUMENTED BISECT (heaptrack
crashes this stack), which revealed TWO compounding leaks (recreate-player, lazy-alone, StackLayout-alone
all still leaked ~+44 — only the COMBINATION is flat): **(1) the events stage `Loader` recreated its view
on every tab-switch — recreating ANY view interleaved with event-selects leaks (just-selected view torn
down mid-life); keeping ONLY Triage alive STILL leaked → all 4 must persist → fix = `StackLayout` keeps
Triage/Verify/Timeline/Map ALIVE. (2) selecting an event auto-opened+played its HLS recording, and Qt's
FFmpeg MediaPlayer leaks ~2MB decode context per source-change → fix = ON-DEMAND play (event-snapshot
poster + play overlay; play-tap/Space loads it) + pause-hidden hero.** Bisect facts: select-only flat,
tab-only flat, but select+tabs leaks. **TRADE-OFFS: baseline ~580→~980MB (all 4 views resident, BOUNDED)
+ recordings no longer auto-play. Follow-up: release Verify/Map resources when their tab is hidden to
claw back the baseline.** Earlier failed-experiment (recreate hero per event) was a red herring (the leak
isn't the player object). heaptrack STILL unusable here. (6-page PDF exec report: reportlab in
`/tmp/pdfvenv`, `/tmp/make_report.py`. Bisect harness: `/tmp/run_a2*.sh` + `/proc` sampler.) ·
`52af1b0` **test(harness): 3 env-gated UI-driver stress tests + an external /proc CPU/RSS sampler
(`/tmp/sampler.py`) + matplotlib graphers (`/tmp/graph_test{1,2,3}.py`, `/tmp/run_test*.sh`).** Drivers
(inert unless env set): `WT_RESIZE_TEST` (Main.qml, logs `[RT]`), `WT_SEEK_TEST`+`WT_SEEK_ITERS`
(PlaybackScreen.qml, opened via `WT_PLAYBACK_IP` @ 24h session, logs `[SK]`), `WT_EVENTS_TEST`
(EventsArea.qml via `WT_SECTION=events`, logs `[EV]`). **FINDINGS (2 real bugs to fix):**
**(1) ▸RESIZE = CLEAN** — 600 resizes incl. 1×1/3840×2160, no crash, no leak (RSS floor flat ~160MB),
only transient framebuffer spikes at 3-4K sizes that return. **(2) ▸PLAYBACK SEEK = BUG** — in-buffer
jumps render fast (1s≈36ms, 10s≈101ms, n=100) but **EVERY jump ≥30s FREEZES** (position moves, player
says Playing/Buffered, 0 frames for 45s). Real: scrubber-click + event-click both → `seekToWall`→
`player.position`. Cause = FFmpeg HLS demuxer stalling across the 24h session's ~2879 fragment
**discontinuities**. Day-scale jumps untestable: **backend caps a review session span at ~24-36h** (24h
ok / 36h+ returns empty; footage itself exists ≥4d). Playback mem plateaus ~780MB (HEVC 2560×1440, no
leak). **(3) ▸EVENTS = LEAK** — 15min browsing (cycling tabs + selecting events) climbs RSS **+642MB
(582→1223, sawtooth, NO plateau)**, driven by event-select→hero-recording-open; click→playback-open
latency median 67ms/mean 143ms/max 1157ms (n=295), no crash. (Backend playback contract: `POST
/review/sessions {camera_id,wall_start,wall_end,hevc_capable}` cookie-auth → `{session_id,manifest:{
wall_start,wall_end,fragments[]}}`; `frame.startTime` is unavailable on the HLS QVideoFrames.) ·
`d1f2a8c` **perf: decode snapshot tiles at display size — MEASURED ~224 MB (-33%) wall saving (the
biggest memory win yet).** Ran the videoscale + LiveThumb.sourceSize sweep the operator asked for, with
real stats (offscreen, N=5/config, Welch t-test, MALLOC_ARENA_MAX=2, cap-9). **Finding inverted my
guess: the SNAPSHOT tiles, not the live decode, are the sink.** LiveThumb's two Images (imgA/imgB
no-blank refresh) had NO sourceSize → each non-live tile decoded a full-res JPEG → QImage+texture, ×2.
Results vs 558.8±11.7 MB baseline: snapshots→tile-size **−223.8 MB [209,239] t=42 p<.001**; live
videoscale 480×270 only −47.8 MB [33,62]; live 160×90 ceiling −55.8 MB (⇒ **row-4 zero-copy ceiling is
≤56 MB — NOT worth building**); both −261 MB. **On-screen N=3 confirmed transfer: wall 677→421 MB
(−38%).** Screenshot-verified all 16 tiles render (no visual change). SHIPPED: LiveThumb sourceSize
defaults to tile size. Kept env knobs (inert unless set): **`WT_DECODE_SCALE=WxH`** (videoscale live
decode — optional, costs live res, NOT default) + **`WT_THUMB_SCALE=<px>`** (A/B test). Sweep harness:
`/tmp/sweep.sh` + `/tmp/analyze.py`. Wall = 16 tiles (9 live + 7 snapshot ≈ 32 MB/snap full-res). ·
`40d09a1` **fix: `WT_CV_AUTOLOGIN` without `WT_CV_URL` wiped the base URL → empty wall (0 cameras/0
pipelines on cold launch).** `loginWithPassword("")` overwrote m_baseUrl; now falls back to
`auth->baseUrl()`. **THIS is why cold-launch profiling runs showed `live_pipelines=0` — NOT a decode
bug.** With it fixed, `WT_CV_AUTOLOGIN=1` alone loads the wall. (Backend `/streams` needs the
`access_token` **cookie**, not Bearer; login = `POST /auth/login` JSON {admin,admin} → 200 + cookie.)
**heaptrack (the "tomorrow" task) is UNUSABLE on this VA-API/GStreamer/Qt stack — do not re-attempt:**
on-screen it freezes the Qt event loop (2 timer fires in 82 s → never builds pipelines); offscreen AND
standalone gst-launch both SIGSEGV (139) — heaptrack captured only ~2.8 MB of gst-init before crashing.
So heap MICRO-attribution isn't feasible; the smaps MACRO-breakdown (entry below: ~460 MB shell +
per-tile ~55 MB, ~800 MB anon = glibc arenas) stands as the answer. **Confirmed live wall HW-decodes:
`[WT-DEC] using vah264dec (hardware)` ×9** (settles the WT_HW_ONLY question — it IS hardware). Run with
WT_TRACE: `QT_QPA_PLATFORM=offscreen … WT_CV_AUTOLOGIN=1 WT_TRACE=1 build68/watchtower` decodes 9 @ ~550 MB. ·
`9b192de` **Windows-port scaffold — `packaging/windows/` + `if(WIN32)` CMake skeleton.** Decided (after
a `/deep-research` run): **same repo, not separate** (98 shared cross-platform files; Windows = the same
app + conditionals + packaging; runtime binaries fetched not committed). Created app.manifest (Win10/11,
long-path, PerMonitorV2 DPI, UTF-8, UAC asInvoker), watchtower.rc (manifest+version; .ico TODO),
fetch-gstreamer-windows.ps1, deploy.ps1 (windeployqt + GStreamer LGPL subset — copy step is TODO),
installer.nsi, README. CMake `if(WIN32)`: RC + WIN32_EXECUTABLE + /MANIFEST:NO + a `deploy-windows`
target. **Inert on Linux — verified Linux still builds clean + the target is absent off-Windows.**
`a038b41` **HW-decode instrumentation + enforcement (`WT_HW_ONLY`).** Decode is rank-based + silently
falls back to software: Linux `va` plugin `vah264dec`/`vah265dec` (rank 257, klass `…/Hardware`) edge
out software `avdec_*` (256); Windows = `d3d11h264dec` (DXVA) vs `avdec`. `WT_TRACE`→`[WT-DEC]` logs
codec+decoder+HW/SW (via `decodebin` autoplug-select/deep-element-added); `WT_HW_ONLY=1` refuses
software video decoders → guarantees no software H.26x decode (perf + codec-patent: OS/GPU decoder
carries the patent licence). Qt's QMediaPlayer backend here = **FFmpeg 7.1 LGPL** (same on Windows).
Mechanism validated standalone; full-app `[WT-DEC]` live-check pending (the wall built 0 pipelines — a
backend/streaming/login state, NOT this code: pipeline parses, hooks are inside startPipelineNow).
**Qt-version decision (deep-research): SHIP WINDOWS ON 6.8.3 LTS; 6.12 is Beta 1 (final ~22 Sep 2026,
next LTS) — revisit then. The GStreamerVideoSource 6.12 feature is Linux-only + we don't use Qt's
source API anyway.** Licensing: LGPL is satisfiable (dynamic-link + notices) or buy commercial; the
real cost is H.264/H.265 codec PATENTS (mitigated by OS/HW decode). Legal/NOTICE work parked per operator. ·
`0e1cdf0` **memory profiling + NV12 optimization (steady-state ~958→~825 MB).** Operator asked why the
9-tile wall uses ~958 MB ("just broadcasting video"). Profiled (NOT a leak — flat): smaps = 81% (~800 MB)
anonymous heap, only ~170 MB libs. **Key finding: cap-1 ≈ cap-9 RSS (~960 MB)** → cost is per-TILE
(snapshot ≈ live), ×16 tiles, + ~460 MB Qt/Mesa/GStreamer shell; the decode CAP doesn't cut steady mem.
73 threads → glibc arena bloat: `MALLOC_ARENA_MAX=2` in run-watchtower.sh trims ~30-50 MB (`f9123e4`).
Streams decode 1280×720. **Option (c) DONE (`0e1cdf0`): pipeline now pulls native NV12 (1.5 B/px) not
RGBA (4 B/px) — Qt's shader does NV12→RGB on the GPU; frame buffers 2.7× smaller, no videoconvert RGBA
pool, no CPU convert. Colour space/range carried from caps; new isEmptyGreenNV12 (Y≈0 AND chroma≈0).
Verified: renders correctly (colours right, empty-green drop works), RSS flat ~825 MB / 9,200 frames, no
leak.** Builds on both Qt 6.4.2 + 6.8.3. **NEXT (operator: "do a tomorrow"): heaptrack (`sudo apt install
heaptrack`, their terminal) for exact allocation-site attribution. Deferred bigger wins: true zero-copy
(VA surface → DMABuf/GL texture, no GPU→CPU download) + rendering tiles at DISPLAY res (~480×270 vs 720p
⇒ ~7× smaller per-tile buffers).** ·
`0d68a2b` **🟢 P0 RESOLVED — the live-video OOM crash is fixed by building on Qt 6.8.3 (verified
leak-free).** The Qt 6.4.2 VideoOutput leak (below) has no client-side workaround, so upgraded Qt:
installed **6.8.3 user-space via aqtinstall at `/home/cilex-vision/Qt/6.8.3/gcc_64`**, built watchtower
against it with **ZERO source changes** (`cmake -B build68 -DCMAKE_PREFIX_PATH=…/6.8.3/gcc_64`), run via
**`./run-watchtower.sh`** (launcher sets lib/plugin/QML paths → `build68/watchtower`). **VERIFIED on real
Wayland: cap-9 wall, 90 s, 10,608 frames, RSS FLAT ~950 MB** (was 8.5 GB → OOM in 30 s on 6.4.2). 6.8.3
ALSO fixes the GridLayout SIGSEGV. System Qt 6.4.2 (`build/`) = offscreen checks only now. Docs:
DEVELOPMENT.md Build/Gotchas, PROJECT_STATUS.md. The VideoFrameItem custom-item attempt was reverted
(all client render paths leak on 6.4.2). ·
`aa5aebe` **🔴 P0 — the recurring "Terminated" is earlyoom OOM-killing us for a Qt 6.4.2 VideoOutput
LEAK (not a code crash).** "Terminated"=SIGTERM; earlyoom's log: `SIGTERM … "watchtower" … VmRSS
9025 MiB`. Instrumented + traced: a steady **per-frame leak** — pipeline count flat at 9, RSS climbs
~3.4 MB per delivered frame (~260 MB/s at 9 decodes) → 8 GB in ~30 s → earlyoom. Bisected to
`m_sink->setVideoFrame()` (the VideoOutput path). **EXHAUSTIVELY proven it's Qt 6.4.2, not us:** leaks
identically on OpenGL+Vulkan+software RHIs, AND with the legacy QMediaPlayer source into the same
VideoOutput. Tried 3 client render paths — VideoOutput (3.4 MB/f), custom QSGSimpleTextureNode+
createTextureFromImage (6.8), QQuickPaintedItem/FBO (6.4) — **ALL leak** (reverted; no simple client
fix exists on 6.4.2). **KEPT (committed): a fatal-signal handler (prints signal+RSS at death →
self-classifies OOM-SIGTERM vs code-SIGSEGV) + `WT_TRACE=1` → `[WT-MEM] rss/live_pipelines/frames`
every 2 s + RtspVideoSource::livePipelineCount()/totalFramesDelivered().** Decision (operator: "both"):
**Qt upgrade is the ONLY fix (also kills the GridLayout bug)** → done + verified in `0d68a2b` (above).
`41dbef6` **finished the minimize SIGSEGV fix — converted the last 3 GridLayouts to `Grid`.** Follow-up
to 63aa381: `EvTriage.qml` (Events facts grid — the confirmed Events crash, 158px matched the log),
`PlaybackCalendar.qml` (7-col day grid, Playback+Wall), `OpsSidebar.qml` (Live 2×2 stats — survived
testing but same bug, converted for completeness). All → `Grid` positioner (no `QGridLayoutEngine`),
cells given explicit equal width. **NO `GridLayout {` left in qml/.** Verified real-iGPU: Live, Events,
AND Wall each survive 40 maximize/windowed/minimize cycles (all were segfaults); screenshots confirm
calendar/stats/facts render correctly. ·
`63aa381` **maximize/MINIMIZE SIGSEGV fixed — camera grid positioned manually, not GridLayout.**
Operator's "crashed on maximize/minimize" ("Terminated" = shell reporting a crashed window) is a
**Qt 6.4.2 Quick Layouts bug**: minimize→restore corrupts a `QQuickGridLayout` engine state, the next
rearrange derefs a dangling attached-Layout (`QQuickGridLayoutBase::rearrange`→`qmlAttachedPropertiesObject`).
Repro: cycle `win.visibility` Maximized/Windowed/**Minimized**; maximize-ONLY survives 40, +minimize
crashes in ~4. Ruled OUT: memory, hang, the responsive toolbar (crashes with it off), window size
(stays 1440×900), render loop (basic crashes too). FIX: the Live camera grid is now a plain `Item`
with cells placed by computed x/y/w/h (`gridArea` gCols/gRows/gSpace/cellW/cellH; handles auto-fit
1×1 + feature spans cw/ch + fillers) — no layout engine to corrupt. **Verified: Live survives 40
cycles (was segfault).** Toolbar collapse also deferred (0ms timer) to avoid re-entrant visible-toggle.
(EvTriage/PlaybackCalendar/OpsSidebar GridLayouts NOW converted in `41dbef6` — see above; no
GridLayout left. Long-term still: Qt upgrade past 6.4.2 to fix the root QQuickGridLayout bug.) ·
`79b58c8` **Q-CV6 FIXED (CV reply9, `b002010`) + one-click "Export as High"** — the "aged 1080p export"
was a BLACK clip: cam `…ff9a`'s SUB stopped recording 06-11, so a Standard (sub-only) export of a
main-only window got an all-`no_recording` manifest and the worker black-filled it at a hardcoded
1080p default. CV now fails honestly (`state=failed`, `error_msg` — the field our poller already
reads). Shipped option 1: `PlaybackClient.retryLastExportAsHigh()` + a ToastHost callback action
(`actionId`/`actionInvoked`) → the failure toast offers one-click **"Export as High instead"**.
Declined option 2 (backend Standard-from-main — our `ClipTranscoder` ladder already does small-720p).
Verified live (jobs `53421c72` failed / `a79594ea` High `2560×1440`). **⚠️ DEAD-SUB FINDING: CV flags
`…ff9a`/`…3a0d`/`…3a4b` recording main-but-not-sub — almost certainly == this session's green-tile +
`…3a0d` "Unsupported image format" snapshot symptoms (our live wall + picker stream the SUB). Reply10
asks Q-W4: camera-side (affects our live) vs recorder-side?** Letters: `…reply9.md` (CV), `…reply10.md` (us). ·
`ab57554` **responsive Live controls row** — when too narrow (unmaximized / low-res / side panel open)
the right-hand action buttons collapse MS-Office-style into a right-edge **`»` overflow menu**
(`overflowBtn` + popup with Go-back/Save/Arrange/Reset/Full-screen + Sort options). `_tbCollapsed`
compares `toolbarSpacer.x` (stable left-content width) + the right group's STABLE implicitWidths vs
`headerRow.width` — loop-free (hidden buttons keep their implicit size). Collapses the WHOLE right
group so only the ~38px `»` remains (stays reachable even with the panel eating width). Verified
collapsed + expanded on real iGPU. ·
`88950ca` **"back in time" icon** — the wall-playback button used `clip` (filmstrip); added a `history`
icon to Icon.qml (the CCW replay ring + CLOCK HANDS instead of a play triangle) and used it. ·
`49ca167` **Toggle Side Panel button** — shows/hides the Live right-hand panel (`OpsSidebar`, a
Main.qml sibling of LiveMonitor, Live-only). State `win.opsSidebarOpen` (default open) gates
`OpsSidebar.visible`. Button lives in **`TopBar`** right cluster (NOT the LiveMonitor toolbar — it
overflows its right controls at 1440 px), gated `showSidePanelToggle` (live wall only). Two-state
glyph per spec: window outline + vertical divider INSET from right (+ faint panel-region fill) = open,
divider hard against the edge = closed. `Accessible.name`/`checkable`/`checked` + Show/Hide tooltip.
Verified both glyph states + wall expands full-width when closed. ·
`22bde7d` **wall playback timer in lock-step with the picture on seek** — scrubber-click set
`player.position` instantly → `onPositionChanged` snapped `_smoothMs`/`playheadMs` to the target while
HLS buffered up to ~10 s → time chips + playhead lied about what's on screen. Fix: a `_settling` freeze
(`seekToWall` raises it BEFORE moving position) stops the 60 fps clock + guards
`onPositionChanged`/`onPlaybackStateChanged` so `_smoothMs` HOLDS; a `vout.videoSink.videoFrameChanged`
Connections (`enabled: _settling`) snaps it the instant the seeked frame renders; `settleGuard` (8 s)
fail-safe; loading bar shows during settle. Verified via `WT_WALLPERF` (held 1520 ms→snap, settles
107 ms–10.3 s). ·
`844d61f` **wall-wide loading bar on the "Go back in time" play wall** (`WallPlayback`, id `wallLoadBar`)
— play-wall analogue of `CameraTile.loadBar`: one indeterminate accent sweep (dim `#141a22` track),
anchored at the top of the transport (full width, directly below the camera grid + above the
seek/scrubber), `visible: (loading||pending) && errorText===""`. Verified via force-show screenshot. ·
`6ac4857` **Arrange tap opens the picker, never full-view** — `CameraTile.opened()` fires only from
`TapHandler{onTapped}`, whose PASSIVE grab let it fire alongside the arrange overlay's MouseArea →
tapping a cell (esp. the delegate recreated by the post-assign reconcile) popped the camera full-screen
instead of the picker. Fix: `CameraTile.tapToOpen` (default true) gates the TapHandler `enabled`;
LiveMonitor sets `tapToOpen: !arrangeMode`. Picker path (separate MouseArea) untouched. ·
`0288a96` **picker opens INSTANTLY** — profiled the "Tap to change"/right-click picker: structure was
always instant (cells pre-exist), but all ~32 go2rtc frame.jpeg thumbs RE-FETCHED on every open
(~2.7 s; `cache:true` useless — go2rtc serves fresh frames; raising the cap barely helped → go2rtc-
bound, not client). Fix: **pre-warm on entering Arrange** (tiles fetch when `arrangeMode` turns on, not
only on picker-open) + **keep-alive once loaded** (camId-keyed `_thumbLoaded`, survives delegate
recreation, not cleared on reset → every open after the 1st, Arrange or right-click, reloads 0) +
`_thumbMax` 3→6. Verified real-iGPU: pre-warm 31 thumbs in ~3 s, reopen = 0 reloads. ·
`dcc61d3` **cap concurrent VA-API decodes (default 9; `WT_MAX_DECODES` override)** — `LiveMonitor.
maxLiveDecodes`; only the first N tiles by grid position run a live pipeline (`liveDecodeAllowed`),
the rest show a periodic go2rtc snapshot via `LiveThumb` (all cameras stay visible). The residual
~5.8 GB scales with concurrent decode count, so this bounds it. **Verified real-iGPU: 4×-reassign
8.6→5.8→~3.3 GB (cap 9); screenshot shows a 4×4 all-populated (9 live + 7 snapshots).** Tune lower on
a weak box, raise (16) for an all-live wall. ·
`e2c870b` **stop decoding during Arrange + decode picker thumbs small (sourceSize 480)** —
re-assign scenario (Arrange→pick-and-assign ×4) balloon **8.6 GB → 5.8 GB**. Reverts the earlier
"keep alive in arrange"(Part2) + "pause during picker"(6390eb9) experiments (both kept/churned 16
VA-API decodes → balloon). Arrange just identifies cameras; build-stagger defuses the on-exit
rebuild. ·
`7bcabc9` **bound live-frame delivery to a 1-frame mailbox** (RtspVideoSource: onNewSample → single
`m_pendingFrame` + `m_frameMutex`, post ≤1 `deliver()`; newer frames replace the unconsumed one).
The low-latency path was posting EVERY decoded frame to the GUI thread via an **unbounded
QueuedConnection** (16×15fps×3.7MB ≈ 888 MB/s); when the GUI thread fell behind, the event queue
piled up and RSS ballooned. **Verified on the real iGPU (RSS heartbeat): steady-state 16-cam wall
now flat at ~457 MB (was unbounded).** ·
`6390eb9` **pause the live wall while the picker is open** (`videoActive: … && pickerCell < 0`) —
frees the 16 live decode contexts during the picker; rebuild staggered on close. (Marginal vs the
balloon below — keep for the single-open case.) ·
`2bc7c21` **picker-table crash fix** — hard-cap the "Tap to change" thumbnail fetches to **≤3
concurrent** (load limiter on LiveMonitor root: `_thumbWant`/`_thumbPump`/`_thumbRelease`, reset on
open). **SELF-TESTED offscreen (drove the picker open, instrumented): cap provably holds at ≤3** —
admit 3 → strict release→admit → drains all 32, inflight never >3. So the 32-fetch burst is GONE.
The picker built ALL ~32 go2rtc frame.jpeg thumbs (= iGPU frame-grabs) AT ONCE → OOM (4th crash;
operator correctly fingered "the table of cameras"). ·
`51f528d` **RELAYOUT-FREEZE FIX** — global pipeline-build rate limiter (PipelineBuildPump, ≤1 gst
build / 120 ms) + keep tiles alive in Arrange + gate picker thumbs on picker-open ·
`7bfcbfb` **drop the decoder "empty surface" green frame at the source** (RtspVideoSource onNewSample
samples the RGBA frame; uniform+green-dominant = the all-zero-NV12→RGB(0,135,0) signature → don't
deliver, don't mark playing → cover/reconnect take over). This is what finally kills the green that
survived the cover — the wedged sub-stream was *delivering* green frames, so frame-flow gating saw
"playing". · `f04861d` snapshot console-spam fix · `85525d3` loading bar + wall per-cell ms clock ·
`3769878` auto-reconnect (throttled) · `09130b8` green cover + frame-flow gating · `fc81bba` export
letters (Q-CV6) · `d7a8ef6` Standard label→720p · `a21da42` client compression.

⚠️ **RELAUNCH the app** — running `./build/watchtower` predates HEAD; just restart it for `694b790` (run `./run-watchtower.sh`, NOT build/watchtower — that is the leaky Qt 6.4.2 build).

🧠 **ROOT CAUSE — VA-API decode-memory watermark (now bounded by the decode cap `dcc61d3` → ~3.3 GB at cap 9; lower the cap for more headroom).**
Replicated both scenarios on the REAL iGPU with an RSS heartbeat + a `WT_TEST_PICKER` self-drive hook.
Findings: mailbox bounds *steady-state* (457 MB); the **picker / 4×-reassign churn balloons RSS to
~8.6 GB** (~530 MB **per live tile**), now cut to a **flat ~5.8 GB watermark** by `e2c870b`
(stop-decode-in-arrange + small thumbs). Ruled OUT as causes: thumbnail burst (capped ≤3, proven),
unbounded frame queue (mailboxed), reconnect cascade (disabling changed nothing), thumbnails
(sourceSize didn't move the 5.8 GB), glibc arenas (MALLOC_ARENA_MAX=2 only trims ~750 MB). So the
residual ~5.8 GB is **VA-API/i915 decode memory held after tearing down the 16 pipelines** — a flat
watermark below the Qt/frame layer; client code can't free it. **On a healthy box (~10 GB free) 5.8 GB
SURVIVES; on a swap-loaded box it OOMs.** → Keep the box rebooted / low-swap. **Real elimination needs
fewer concurrent VA-API decodes (smaller default wall, or a "freeze last frame, no live pipeline"
path) or a driver/gst fix** — a system-level look (`intel_gpu_top`, `LIBVA_*`/`GST_DEBUG`) at why each
decode holds ~360–530 MB. Optional cheap tweak: launch with `MALLOC_ARENA_MAX=2` (~750 MB). Re-add the
`WT_TEST_PICKER`
self-drive hook + an RSS heartbeat (added & reverted this session; re-add from git if needed).
🖥️ **THE BOX IS STARVED + NOT REBOOTED (2026-06-22 15:42): 7-day uptime, swap 6.1 GiB used, 1.6 GiB
free RAM, load avg 7.7.** Three crashes happened in this state. The code fixes remove the demand
bursts, but **strongly push a REBOOT** (or `~/safe-swap-clean.sh` / the `swap-clean.timer` from this
session — see `/home/cilex-vision/`) before/after testing. If crashes persist post-reboot, suspect a
steady memory leak (Docker backend OOM history), not Watchtower.

🔥 **CRASH (2026-06-22): app OOM-killed + 20 s system freeze during camera-change churn.** Repro:
Arrange → "Tap to change" → Esc → "Tap to change" again. Mechanism: `videoActive: visible &&
!arrangeMode` (LiveMonitor:916) ⇒ entering Arrange tears down all 16 video pipelines and exiting
**rebuilds 16 at once** (UNTHROTTLED gst PLAYING = 16 simultaneous VA-API decode contexts); the
"Tap to change" picker (GridView of go2rtc snapshot thumbs) piles on. On a box at **6.9 GiB swap**,
that wedged the shared iGPU (20 s freeze) and the OOM-killer SIGKILL'd it ("Killed"). **The
auto-reconnect did NOT cause it** (inactive arrange tiles don't reconnect; coordinator throttles).
**FREEZE FIX SHIPPED (`51f528d`, awaiting LIVE confirm)** — load-spreading, all three parts: (1)
**global pipeline-build rate limiter** `PipelineBuildPump` (RtspVideoSource.cpp, GUI-thread, leaked
singleton): `rebuild()` no longer builds inline — it enqueues + the pump calls `startPipelineNow()`
≤1 per **120 ms**, so a 16-tile burst (layout change / page turn / app start) comes up gradually
(loading bar covers it) instead of 16 simultaneous VA-API decode contexts. teardown()/dtor cancel a
queued build; reconnects ride the same pump. **RULE: any pipeline build MUST go through `rebuild()`
→ PipelineBuildPump — never build inline.** Verified offscreen (builds at 120/126/125 ms intervals,
queue draining 1 at a time). (2) **Keep grid pipelines alive in Arrange** (videoActive dropped
`&& !arrangeMode`) — no teardown-on-enter / rebuild-on-exit churn; overlay just dims. (3) **Picker
thumbs gated on `pickerCell >= 0`** — GridView delegates existed while hidden and fetched go2rtc
snapshots for every camera in the background (also the frame.jpeg spam source). Teardown still
capped by kMaxConcurrentTeardowns(8). **Can't repro the freeze offscreen → NEEDS LIVE TEST**
(Arrange/Tap cycling, layout changes, page turns); recommend a reboot first to clear 6.9 GiB swap.
Still worth `sudo dmesg | grep -iE 'oom|killed process|i915|gpu hang'` to confirm OOM vs GPU-hang.

🩺 **DIAGNOSTIC LESSON (2026-06-22):** the operator reported green STILL showing after the
green fix — but it was the **stale running binary**. Always confirm what's actually running:
`ps -o lstart,etimes -C watchtower` (process start) vs `stat -c %y build/watchtower` (build time).
The process had started 10:35; the fix was built 13:21 → 3 h of testing old code. When a "fix
didn't work," **check the running process age FIRST** before re-diagnosing the code.

**This session also added (`85525d3`, awaiting live confirm):** (1) an indeterminate **loading
bar** along the bottom of a connecting/reconnecting tile (honest sweep, no fake %; clears when
frames flow). (2) **Per-cell wall-clock (ms) on the playback wall** — `WallPlayback` is ONE
server-composited HLS stream (one decode/timeline → ms-synced BY CONSTRUCTION; no client sync to
do), so each cell now prints the identical `playheadMs` via `fmtWallMs()`, making the sync visible.

**GREEN-SURFACE FIX (`09130b8`) — shipped, awaiting live confirm.** A single camera (.120, a stalled
substream) showed a frozen green tile in the 4×4 AND a fully green single-cam view, while the backend
was fine (motion events flowing). Root cause: `VideoSurface.playing` meant "pipeline up", not "frames
decoding" — `RtspVideoSource` flips `playing=false` only on EOS/error/teardown, never on a *silent*
stall, so a green/frozen surface kept `playing=true` and showed through. Fix (`qml/VideoSurface.qml`):
`playing` now = real frame flow (`_hasRecentFrame`, set on `videoOut.videoSink.videoFrameChanged`,
cleared by a 2.5 s stall `Timer`) + an opaque `#0a0d11` cover over the `VideoOutput` whenever
`!playing`. Green never shows; a stall degrades to "Connecting…" and self-heals when frames resume.
Verified: build/smoke clean + a WT_TEST_QML harness renders 100 % `#0a0d11` (not green). **Auto-reconnect
SHIPPED (`3769878`):** stalled tiles now actively recover — `VideoSurface` rebuilds the pipeline with
per-tile exponential backoff (2/5/10/20/30 s; patient 8 s on a cold connect) via
`RtspVideoSource.reconnect()` (`Q_INVOKABLE`→`rebuild()`; qtmm re-sets source), and **every attempt is
serialized through the `ReconnectCoordinator` singleton** (≤1 initiation / 700 ms app-wide) so a
fleet-wide stall recovers one pipeline at a time, NOT a 16-pipeline burst — the freeze guard. Throttle
verified (6 requests released exactly 700 ms apart). **RULE: any other rebuild/reconnect path must also
route through `ReconnectCoordinator`.** Likely original cause for .120: opening the single view tears
down the grid tile's pipeline + opens a 2nd .120 sub pipeline; the open/close churn wedges go2rtc's .120
sub producer — now self-heals. A genuinely-wedged sub is a backend/go2rtc item. **Both the green-fix and
auto-reconnect await live confirm on .120 (relaunch needed).**

**EXPORT QUALITY + CLIENT COMPRESSION — shipped both sides; one CV item open.**
- Single-cam **Export drawer** now has: **Quality** (High = HEVC 1440p main original; Standard =
  H.264 sub) with grey-out+tooltip when the original has aged out; a **Compression** ladder
  (Original/1080p/720p/480p, sizes ≥ source greyed); and functional **overlay toggles**
  (default OFF = pristine, no re-encode).
- Backend (CV, migration **0045**): `CreateExportRequest` takes **`hevc_capable`** (true=High,
  false=Standard); fragments carry **`stream_type` ("main"|"sub")** = the authoritative
  "is the high-res original retained here" (orthogonal to `tier`, which is retention age).
  Verified live: High→**2560×1440 H.264**, Standard→**1920×1080** (the 720p sub upscaled to the
  1080p delivery profile; visual detail ≈720p). A High request over an aged span → **422** (string
  `detail`), surfaced as an export error; our grey-out prevents the normal case.
- **Client-side compression/overlays are OURS now — `ClipTranscoder` (`src/models/ClipTranscoder.{h,cpp}`):**
  ffmpeg via QProcess, **software libx264** (never contends with the live wall on the shared iGPU),
  scale + 2 `drawtext` overlays — camera caption via `textfile=` (no escaping), per-frame **footage
  wall-clock** via `text='%{pts\:localtime\:<clip_start_epoch>\:%Y-%m-%d %H\\\:%M\\\:%S}'` (verified).
  Wired through `PlaybackClient::createExport(..., hevcCapable, post)` where `post` =
  `{height,timestamp,name,label,startEpochMs,durationMs}`; downloads the clean export then transcodes
  to the final path (keeps the original on failure). **A2 (server overlay burn-in) is RETIRED.**
  ffmpeg 6.1.1 + DejaVuSans present on the box.
- **DONE (2026-06-21, `d7a8ef6`):** CV shipped native-720p Standard (`h264-main-720p`; reply5 —
  Q-CV5/Q-W1/Q-W2 all yes). Flipped the ExportDrawer label **"Standard · 1080p" → "720p"**
  (`sourceHeight` standard 1080→720; ladder now Original+480p; confirm-modal "(720p)"). **Verified
  live end-to-end** (drove the real backend, not just CV's word): a fresh-window Standard export →
  `resolution 1280x720` (~747 KB/8 s); playback manifest → `delivery_profile h264-main-720p` on every
  sub fragment. **Open (non-blocking, CV's court) — Q-W3 → Q-CV6:** re-exports of *pre-deploy / aged*
  windows still deliver **1080p** (byte-identical 8848 B across **3** fresh post-deploy jobs). CV
  (reply7) says the warm-path rendition cache is keyed by `(segment_id, delivery_profile)` → "no fix
  needed"; our Q-CV6 re-test (reply8) disproves that for the **export worker's aged/cold path** — it
  serves the old 1080p rendition even though the window's live session now reports `no_recording`.
  Recent-footage exports are correctly 720p (the common path), so non-blocking. Created 3 dev test
  exports (`wt-720p-verify`/`wt-720p-fresh`/`wt-cv6-retest`; the failing-1080p jobs `62588e85` +
  `bdb5237b` are for CV to inspect). reply8 also carries a **bitrate correction** (the sub is
  ≈1 Mbit/s / 1024 Kbps-configured, not "~0.1"). Thread: `…compression.reply8.md` (reply7 = CV's).

**ALSO shipped this arc:** green-wall fixes (the live grid binds a camId-keyed reconciled `gridModel`
so a poll/relayout never rebuilds tiles → no green flash — see DEVELOPMENT.md gotcha); brighter/larger
scrubber ruler digits + full date on the playhead watermark; **removed the dead camera-tile bookmark
button** (it was a no-op — cameras keep the ★ star/favourite; bookmarks are Events-only); a **layout
preset now exits the transient map-selection scope** to All cameras (+ a "✕ Clear selection" toolbar
chip shown only in that scope).

**PAUSED — freeze diagnosis (in progress, not finished):** user reports the host appears to freeze
(over RDP) immediately on Live **"Change layout"**. Likely the **shared Intel AlderLake iGPU (`i915`)**
— one chip does the app's VA-API decode + Mutter + GNOME-Remote-Desktop encode + go2rtc QSV — wedging
under VA-API decode-context churn on relayout (would freeze app+desktop+RDP together), and/or
**memory/swap/OOM** (15 GiB, ~1.2 free, 6.5 swap; documented Docker `ffmpeg`/`h264_qsv` cgroup OOM
history). **Recording is in Docker → killing the app is SAFE.** Diagnostic scripts left on the host:
**`~/freeze-watch.sh`** (1 s continuous monitor) + **`~/freeze-snapshot.sh`** (deep capture, run with
`sudo` — gdb needs root, ptrace_scope=1). **Not yet run** — awaiting the user to reproduce + paste
logs. Decision matrix + recovery order are in this session's transcript (least-disruptive: capture,
then `kill -TERM $(pidof watchtower)`; never reboot first; never `docker stop`).

**OFFERED, not started:** (a) broader view-scope simplification (a 2nd "favourite" exists on Saved
Views; possible Groups/Saved-Views/Favourites consolidation); (b) a live end-to-end export→download→
transcode verification pass.

**Platform note:** this was a ~7-day **resumed Remote** session; its Background-tasks panel accumulated
**9 phantom "Running" `run_in_background` entries** (processes long dead — a Claude Code bug; likely a
sandbox time-namespace/clock skew). Reported via `/feedback`; full write-up at
`/home/cilex-vision/claude-code-bug-report-background-tasks.md`. **A NEW session clears them.** Going
forward, **avoid `run_in_background` for verify/perf — use foreground bounded runs.** (The freeze
scripts + bug report live in `/home/cilex-vision/`, NOT the repo — local-only.)

## Latest session (2026-06-18) — earlier (supersedes the 06-02 block below)
Latest commit **`147ed50`** on `main` (pushed). The **Events redesign** (faithful QML port of
`designs/events-v2`: 01 Triage / 02 Verify / 03 Timeline / 04 Situation Map) is now the
**DEFAULT** Events screen, fully on real `/events` + `/maps`. Canonical task state lives in
**`docs/events-redesign-tasks.md`** (rows #1–#14, #17 ✅ done; only **#15 severity/AI data** +
**#16 camera placement** remain — both *operational/config on Cilex Vision's side*, not code).
Backend Events workstream is **closed**. This session's two features: **(#13) FOV coverage cones**
on Situation-Map pins (translucent wedge + outline via `rotation_deg`, tinted by pin state) and
**(#17) a camera-group switcher** in the Events mode bar (`groupFilter` scopes queue / wall /
timeline / map pins to All / a named group / Ungrouped; placed pins follow the group too).
New dev hook **`WT_EVENTS_VIEW=triage|review|timeline|map`** opens an Events sub-view directly
(for offscreen screenshots). Flags: `WT_DEMO` → mock showcase; `WT_EVENTS_LEGACY` → old table
screen. Verify offscreen via PIL crop of `WT_SCREENSHOT` PNGs (no ImageMagick on the box).
Letters exchanged this arc are under `docs/letters/2026-06-18-*`. Earlier blocks below are history.

## Latest session (2026-06-02)
Latest commit **`c18b5fa`** on `main` (pushed). The E1 wall is live; this session landed a
large client-feature batch and **closed BOTH backend threads** (recorder stall + E2 export) —
**no open backend asks** right now. For current truth read `docs/PROJECT_STATUS.md`,
`docs/BACKLOG.md`, the `docs/letters/` thread, and [[multicam-review-architecture]].

**✅ E1 16-cam synchronized wall DELIVERED + verified live.** (Earlier this arc it was blocked
at scale; CV fixed it in `51c7b4d` — `pids_limit` 256→1024, `-threads 1`/input, render semaphore,
seek-3s-early for 0-byte boundary segs — and I drove the real 4×4 wall on the iGPU: composites +
plays, populated cells synced, empties black-filled, cold seg ~1s.) Full thread:
`docs/letters/2026-05-31-disk-healthy-path-to-live.{md,reply…reply4}.md`. **Client facts:** wall
entry = the LiveMonitor **"Go back in time"** button (the only entry; reactive — no gate, "pending"
only on a 404); shipped an **18s render watchdog** (`WallPlayback.qml`, honest-fail a stuck composite)
+ a permanent **`WT_WALL_DAY=<YYYY-MM-DD|live>`** dev hook. Wall screenshots need the real **Wayland
display + VA-API** (`/dev/dri/renderD128`). Coverage A7+E4 ✅ — both calls send `?tz=<system IANA tz>`.

**Both backend threads CLOSED:**
- **Recorder per-stream stall — FIXED + WIRED.** CV `0ab548f` (thread closed via
  `…recorder-per-stream-stall.reply2.md`): per-stream **watchdog + auto-restart** (silent
  "ffmpeg-alive-no-frames" stall → restart in ~50s) + **`/streams.recording` is now mode-aware**
  (`recording`|`stalled`|`armed`|`disabled`|`offline`) + a new **`last_segment_at`**. *Correction:*
  `.106`/`.120` weren't dead — they were switched to **motion-triggered** recording (so `armed`, not
  stalled; `.106` reads ARMED live). **Wired client-side** (`10fffe1` + `1245699`): `CameraStatus::RecState`
  gained **Stalled/Armed/Disabled**; `recStateFrom()` parses the vocab on full fetch + 15s poll;
  `last_segment_at` → `CameraData` + a model role. **Counts: stalled→NOT REC, armed→recording, disabled→neutral.**
  UI: red **STALLED** badge + "RECORDING STALLED · since <last_segment_at>" tile strip + fault edge;
  neutral **ARMED** badge; **"Last recording"** row in single-cam + Health detail. Closes the old
  **"NOT REC 0 looked green"** gap. (Verify recording from the state/`last_segment_at`, or segment
  timestamps — NOT a bare `/streams` count.)
- **Combined-grid export E2 + I7 + A6 — SHIPPED + WIRED.** CV `d724a20` (thread closed via
  `…mosaic-export-e2.reply2.md`). E2 = `POST /review/mosaic-sessions/{id}/exports {wall_start,wall_end,mode}`
  → `{job_id}` on the shared `export_jobs` flow. **Wired client-side** (`fec0374`): `createExport`/
  `createMosaicExport` send optional **group_id+purpose**; `WallPlayback.exportSelection()` sends one
  group_id across N per-cam + 1 mosaic (I7 dual-archive); **`PlaybackClient.fetchExports()`** consumes
  **`GET /review/exports`** (A6); the **Clips & Snapshots library** (`ClipsScreen.qml`) now lists server
  exports (per-cam = `clip` icon; mosaic = `layers` icon "Grid · <group_id>") merged with local
  snapshots — purpose/state/resolution/group + Open via the proxied token download + a Refresh button.
  Verified live (4 exports incl. the `grid-verify-1` single+mosaic set).

**Other client features this session:**
- **Events screen** (`EventsScreen.qml`): fixed Camera-column alignment (`b7b3ab7`); **per-column sort +
  Excel-style autofilter on EVERY column** (`759d300`) — clickable headers (funnel + ▲▼), dropdown with
  Sort↑/↓ + search + Select-all/Clear + a distinct-value checklist; **Enter-to-apply** + **drag-resizable
  columns** (grips on Camera/Group/Time/Status; Event flexes) (`73f5ad2`). Added `EventData.tsMs` (epoch)
  for chronological Time sort. **NOTE: the `/events` feed is LIVE now** (motion events flowing; was empty).
- **Live Monitor**: **★ Favorites filter pill** (`a1080ae`) — camera-favorites filter was plumbed in the
  model but had no UI; now the first pill shows only starred cameras. Tile **hover-action fixes** (`6e41c3a`):
  unclipped dense grids (vertical Column → bottom-right Row), new **playback** icon (`Icon.qml` gained a
  **`pf`** filled-overlay channel), wired the dead Open-Playback + Favorite buttons, toggle active states.
  **bookmark stays visual-only (not persisted).**

**NEXT (all optional — nothing backend-gated):** (1) wire the single-camera **ExportDrawer Purpose** onto
`/review/exports` (A1 now accepts it; ~one line). (2) Latent: **fix the `availability !== "ready"` filter**
(PlaybackScreen) that drops hydrating/cold fragments. (3) Optional UI: persist **bookmark**; a
nav/command-palette entry for the wall (only entry today = "Go back in time").

**Durable backend/disk facts (this machine):** WD Purple disk was re-cabled + host
rebooted **21:09 MSK 2026-05-31** and is **solid** — `/health/storage` ok, `sda`
(WDC WD43PURZ, fs_uuid `07fa7c7d…`, managed_id `f437216b…`) `assigned`/`role=video`,
**zero `ata5`/`sda` resets even under full recording load**. The dev box **IS**
`192.168.1.79` (backend + recorder run locally; shutting it down takes them offline).
**Backend auth is COOKIE-based** (`-b "access_token=$T"` from `POST /auth/login`
admin/admin), NOT a Bearer header — `/storage/*` 401s on a bearer header. Footage
lives in **SeaweedFS** (`.dat`/`.idx` volumes under the mount); `/recording/segments`
+ `/admin/recordings` look empty without filters. **`/streams` lists 31 cameras**
(192.168.1.101–.131, was 4). **Recorder** was undersized for the 31-cam fleet (a 768 MB cap → restart-loop); CV
raised it to **2 GB / 512 pids** (`ad96216`) and later added a **per-stream watchdog**
(`0ab548f`). `/streams.recording` is **mode-aware** now (recording/stalled/armed/disabled)
+ carries **`last_segment_at`** — judge recording health from those (or actual segment
timestamps), NOT a bare `/streams` count. ("disk healthy" ≠ "recorder writing segments".)

**Two heads-ups:** (1) `sda1` is **double-mounted** — canonical `/mnt/cilex-vision/disks/07fa7c7d…`
*and* `/mnt/cilex-storage` — but CV confirmed this is an **intentional** reboot-persistent
bind from their storage-recovery runbook, not a stray automount; migration `0029` (pure
DDL) was unaffected. (2) **OS disk `/` ~91% (23 GB free as of 2026-06-02; was 97%/9 GB)** —
watch it; build churn fills it.

**Build reminder:** QML is byte-compiled into the binary — *no hot reload*; every QML edit
needs rebuild (`cmake --build build`) + relaunch. (A7 coverage is deployed; the 2026-05-31
IP-dedup fix is committed `0d04757`.) Offscreen smoke: `QT_QPA_PLATFORM=offscreen timeout 6
./build/watchtower` (exit 124 = ok). Screenshots: `WT_CV_AUTOLOGIN=1 [WT_SECTION=… | WT_FOCUS_IP=…
| WT_WALL_DAY=…] WT_SCREENSHOT=/tmp/x.png WT_SCREENSHOT_MS=… [WT_DEMO=1]`.

## Where we are (2026-05-30, earlier — for current status see PROJECT_STATUS.md + BACKLOG.md)
**P1–P6 are ALL COMPLETE** (Foundation+Live, Single-Camera, Playback, Export,
Events+Health, Saved Views/Clips/Prefs/palette). Latest commit **`4170cb5`** on
`main`, pushed to the **private** GitHub remote `origin`
(github.com/romayankin/cilex-watchtower).

**Since 2026-05-28 (post `623d660`):** Phase D landed (backend = camera source of
truth via `/streams`: go2rtc rtsp urls D1/D2/D5, recording-state D6, §D3 main HD
passthrough). A **live-streaming stability incident** drove RTSP-teardown fixes
(staggered/bounded teardown, worker-thread GStreamer teardown, green-frame-reset
fixes), low-latency RTSP path is now the **default** (`WT_LEGACY=1` opts out),
`WT_NO_POLL=1` disables `/streams` polling. A **go2rtc OOM incident (§D3)** —
clip-service's 20-camera rolling buffer opened 20 per-consumer VA-API transcodes —
was fixed backend-side by making the main stream **dual-source** (raw RTSP H.265
passthrough first, ffmpeg:vaapi only for browser HLS).

**HD snapshot capture — DONE, committed `df5576e`.**
`Artifacts::captureMainStreamSnapshot()` async-pulls a full-res JPEG from go2rtc
`http://<host>:1984/api/frame.jpeg?src=<stream>` (derived from the MAIN rtsp url,
not the substream the wall renders), saves `.jpg`, emits `snapshotCaptured`/
`snapshotCaptureFailed`; `CameraTile.qml` prefers it, falls back to
`captureFromTile()` on failure. Verified live: real 2560×1440 JPEG, pulls the raw
H.265 passthrough producer (NOT the 1280 ffmpeg transcode), transient one-shot —
no §D3 OOM risk. Open follow-up: port 1984 hard-coded (code TODO → backend ask to
expose the frame url on `/streams` + per-user auth). Working tree clean.

## Canonical current state — read these in-repo docs (authoritative)
- `docs/PROJECT_STATUS.md` — phase status + done-highlights.
- `docs/BACKLOG.md` — the prioritized open backlog (priority + 🟢ready/🔴blocked + owner + what unblocks each). **All P1 items are backend-gated; 🟢 items are client polish.**
- `docs/DEVELOPMENT.md` — stack, build/run/verify commands, all `WT_*` dev hooks, architecture (models + QML), API contract, Qt 6.4 gotchas.
- `docs/letters/watchtower-to-cilex-vision-api-requests.md` — the single living backlog of backend asks **and Cilex Vision's point-by-point responses** (BACKEND RESPONSE section). Items coded A#/B#/C#.
- `docs/agent-memory/` — an in-repo MIRROR of this memory dir (so memory survives a full machine loss). Refresh it (`cp ~/.claude/projects/<proj>/memory/*.md docs/agent-memory/`) when committing memory changes.

## Build / verify (full detail in DEVELOPMENT.md)
- Build: `cmake -G Ninja -B build -S . && cmake --build build` → `build/watchtower`.
- Smoke: `QT_QPA_PLATFORM=offscreen timeout 6 ./build/watchtower` (exit **124** = loaded fine; grep stderr for `.qml:`/warning).
- Visual: `WT_SECTION=<live|groups|events|health|views|clips|preferences> WT_SCREENSHOT=/tmp/x.png WT_SCREENSHOT_MS=1500 [WT_DEMO=1] timeout 12 ./build/watchtower` then Read the PNG. Use `WT_DEMO=1` to populate mock data; live (no WT_DEMO) to hit the real backend (allow ~3–5s for login+fetch on first network call).
- Always: build clean + offscreen no-warnings + a screenshot for UI changes; **revert any temp verification scaffold before committing** (grep `TEMP-VERIFY`).

## Backend (cilex-vision) — key facts
`WT_CV_URL` default `http://192.168.1.79:8000`, login `admin/admin`, OpenAPI at
`/openapi.json`; reachable from the dev box. Post-reply contract truths:
- Export `mode` ∈ **{wallclock, compact}** (enum; we send `wallclock` = freeze gaps). `"continuous"` is 400'd.
- EventType vocab: **entered_scene | exited_scene | stopped | loitering | motion_started | motion_ended** (offline/online are NOT events). EventState: new|active|stopped|exited|closed.
- `/events` feed is **EMPTY** — backend pipeline gap (their fix; detections=0 → no events). Keep the honest empty state.
- `/detections` 500 is **fixed**; `/health/storage` is **live + wired** (Health-screen storage strip).
- Full contract + responses: [[cilex-vision-playback-api]] + the letter above.

## How I operate here (working agreements)
- **Commit each completed unit to `main`** with a thorough context-restoration commit message (git log reads like a build journal), then `git push origin main`. The user wants work on `main` + pushed (private repo = crash backup).
- **Product rules**: never invent content (real data or honest empty states; mock only behind `WT_DEMO`); pixel-fidelity to `designs/design_handoff_watchtower/README.md`; footage only from cilex-vision. [[product-rules]]
- **Backend gaps**: build the full UI, transmit only fields the API accepts, mark the rest "pending," and record the ask in the letter. [[handling-design-backend-gaps]]
- Surface real decisions to the user (AskUserQuestion) rather than guessing scope.

## To resume
**(2026-05-31: see "Latest session" at the top for current next steps + the WD Purple
disk context. The list below is earlier background and may be partly stale.)**

Read `docs/PROJECT_STATUS.md` then `docs/BACKLOG.md`. Nothing is broken or
half-done. Next actionable (🟢, no blocker), quickest first: the `compact`
export-mode toggle, "−15s" seek, same-group playback switch, event-drawer
export/filters, then theme switching (a `Theme`-singleton refactor). Every P1
(Events pipeline B2, export/clips metadata A1/A3/A6, shared ack B1) waits on
cilex-vision's first batch — the one thing worth pinging them for is the
**synthesized multi-day mixed timeline** to verify the mixed-codec playback switch.

Related memories: [[build-roadmap]] · [[cilex-vision-playback-api]] · [[s06-playback-gaps]] · [[product-rules]] · [[handling-design-backend-gaps]] · [[stack-and-build-direction]] · [[toolchain-setup]] · [[video-pipeline-approach]] · [[data-persistence-and-naming]]
