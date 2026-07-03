# Prompt — Root-cause the rare GUI-thread wedge (HANG #1) from the 2026-07-02 night soak

## Status
**✅ RESOLVED 2026-07-03 — root-caused WITH a live stack, fixed, validated. Plus a second,
user-reported freeze class (scrubber click-spam) found and fixed the same day.** Original
prompt kept below for the record; resolution first.

---

## RESOLUTION (2026-07-03)

### The wedge = a MINUTES-LONG QML garbage collection on the GUI thread (Qt 6.12), not a deadlock
Reproduced in **58 min** with an amplified cocktail (`WT_SOAK_FIX_CAM/DAY` pinned to the heavy
2026-06-29 day, `WT_GRAB_STORM=20`, `WT_HLS_SLOW_MS=8000` + new `WT_HLS_SLOW_EVERY=6`), the app
running **as gdb's child** (fifo-driven — Yama `ptrace_scope=1` denies a sibling `gdb -p`, which
is also why the supervisor now needs `WT_PTRACE_ANY`). Two spaced all-thread backtraces show the
GUI thread inside ONE `QV4::MemoryManager::runGC` call — `GCStateMachine::transition` →
`MarkStack::drain` — entered from `allocString` **while marshalling the session-ready `fragments`
payload** (`QList<QVariant>` of per-fragment `QVariantMap`s) through
`VariantAssociationPrototype::fromQVariantMap` inside `PlaybackClient::sessionReady` →
`onSessionReady`. Kernel state: main thread **R (running)**, all other threads parked — a pure
GUI-thread compute stall. **It self-recovered after ≈2.5 min total.** The overnight HANG #1 was
this exact stall: the supervisor killed it at 150 s mid-GC, masking the recovery ("not reproduced
twice" — it recovered before ever being seen live).

Why it arrived with the Qt 6.12 migration: the incremental `GCStateMachine` + the
`VariantAssociation` reference wrappers for QVariantMap are new in the ≥6.10 line — 6.8.3's soaks
(8.8 h + 12 h) never hung. Why "near a heavy-day export": every soak cycle's export/drawer step and
every session open marshalled thousands of maps (up to 4873/open), so heavy-day churn built the GC
graph fastest right around export activity. RSS stayed normal (~687 MB) — matching the original
HANG #1 (~450–665 MB, NOT OOM).

**Eliminated en route** (all with data, all on 6.12/`build/`):
- Teardown-join on starved reads: 47 `WT_CAL_STRESS` day-switches under TOTAL segment starvation
  (`WT_HLS_SLOW_MS=300000`) — every `[PBSTOP] switch took=0ms`. The FFmpeg backend interrupts
  starved IO fine (the bounded ~1 s stall of 2026-07-01 was GStreamer/6.4.2-only, now moot).
- Export download/transcode → GUI handoff: fully async, and not even on the soak path (soak sends
  an empty post map → no ffmpeg).
- The drawer `grabToImage` as the blocker: grabs were the garbage *amplifier*, not the block —
  under `WT_GRAB_STORM=20` with the payload fix in, zero GUI gaps.

### Fix 1 — starve the GC at the boundary (the wedge fix)
`PlaybackClient::requestSession` now emits fragments as **positional primitive rows**
`[cs, ce, wsMs, weMs, disc, boundary, codec, tier, resolution, stream_type]`, **pre-filtered to
`availability=="ready"`** (every consumer dropped non-ready anyway), with ISO→epoch-ms parsing
moved to C++; the dead `meta["events"]` map-array (zero consumers, hundreds of maps/open) is no
longer forwarded. Consumers updated: `PlaybackScreen.onSessionReady`, `EvHeroPlayer.onSessionReady`
(QML-side `{cs,ce,ws,we,…}` structures unchanged → no UI refactor). The mosaic path
(`mosaicSessionReady` → `WallPlayback`) still ships maps — **follow-up: same recipe when wall
review lands** (it consumes non-ready rows for its gap bar, so the filter must differ).
Measured: QML-side `marshal=` p50 9 ms / p90 16 ms / max **1149 ms** → **~1 ms** flat.

### Fix 2 — far-seek coalescing (the user-reported click-spam freezes, same day)
While validating, the operator produced ~5 freezes/min by **chaotically clicking the scrubber**.
Classified with the new `WT_SEEK_SPAM` driver (12 deterministic clicks @140 ms × 40 bursts) +
`WT_SMOOTHTEST`'s 1 s GUI heartbeat: **zero GUI gaps in every run — these were video-level, not
the wedge class.** Cause: every far click did teardown + a fresh session POST (and clicks landing
mid-open were **silently dropped**); under a degraded backend the storm self-amplified to
**2.3 opens/click** (480 clicks → 1107 opens). Fix: at most ONE far-seek open in flight
(`_farInFlight`); later clicks only replace the pending target (last click wins), applied
in-window via the deferred seek or via exactly one follow-up open (`PlaybackScreen.qml`).
A/B (healthy backend, identical click sequence): after-burst recovery **p90 5.8 s → 0.9 s, max
11.1 s → 2.1 s, 15 s-timeouts 3 → 0** (304/480 clicks coalesced). Degraded A/B is floor-limited
by the injected 8 s hold itself (p90 8.8 → 8.6 s) — the cascade compounding is what the fix
removes. Note: the synthetic 8 s hold exceeds the 6 s seek-watchdog, so the watchdog re-opens
resonate in that harness config — an artifact (real cold-base is 2–4 s), not a regression.

### Validation — PASSED (2026-07-03 evening)
- **Final gate: 2.5 h full amplified cocktail on the final binary, STALL=15 — ONE continuous
  process, alive 8994 s of a 9000 s window, 0 wedges / 0 crashes / 0 GUI stalls ≥15 s / 0
  `[SEEKBAR]` violations, across 1037 session opens, 151 successful + 101 correctly-rejected
  exports.** Pre-fix, the identical cocktail wedged at 58 min ⇒ ≥2.6× exposure clean (and
  ~2× the opens). Includes live operator abuse mid-run (manual navigation, exports,
  calendar-fighting the pinned soak).
- Earlier same day: 55+ min payload-fix cocktail clean incl. a minute of operator chaos;
  4 spam runs (1920 chaotic clicks) — zero GUI-heartbeat gaps >2 s in every run.
- Artifacts checked, not regressions: `[NSEEK] BAD` under the cocktail is the §6 stale-playhead
  measurement artifact (pre-fix same cocktail: 0 OK/115 BAD — same shape); RSS spiked >1500 MB
  in 75/3332 samples (grab-storm ×20 + holds compounding, harness-only) and recovered to the
  ~525 MB plateau (last read 541 MB, no ratchet).
- Broad overnight re-soak recommended (the patched supervisor now gdb-dumps any live wedge:
  `WT_PTRACE_ANY` + capture block in `night_soak_supervisor.sh`, logs default OFF `/tmp`).

### Also found during validation (operator interventions, same day)
- **Transient EMPTY session manifest**: a 22 Jun day-open returned 200 + 0 fragments under
  load; identical request minutes later → 4760 ready. Client now retries a fresh-open empty
  manifest ONCE (~1.5 s) before the terminal "No footage recorded" (PlaybackScreen
  `emptyRetry`); backend letter `docs/letters/2026-07-03-transient-empty-session-manifest.md`.
- **"Standard unavailable → Export as High" is backend-truthful**: .106 records MAIN-only
  (probe: 4760/4760 frags `('main','warm')`, identical with `hevc_capable=false`) — no sub
  stream exists, so STD export honestly fails and main plays 1440p at 11 days. Model
  questions → `docs/letters/2026-07-03-camera-substream-recording-gaps.md`.
- **Preferences-window brief freeze on open** (operator observation) — unmeasured; likely
  first-instantiation jank now that the GC class is gone. P3 follow-up: measure with the
  WTSMOOTH heartbeat around opening Preferences.

### Follow-ups
- **Qt upstream bug**: minutes-long `runGC` on a VariantAssociation-heavy heap (Qt 6.12.0) —
  needs a standalone marshalling-loop repro; the two full stacks are in
  `~/watchtower-soak/wedge-p1b/gdb.log` (BT PASS1/PASS2). Not yet filed.
- Mosaic fragment payload (above). — **Repro/diag tooling kept** (all env-gated, inert):
  `WT_SOAK_FIX_CAM/DAY`, `WT_GRAB_STORM`, `WT_HLS_SLOW_EVERY`, `WT_SEEK_SPAM`, `WT_PTRACE_ANY`,
  and `scratchpad wedge_catch.sh`-style fifo-gdb catching (supervisor has the equivalent now).

---

## Original prompt (2026-07-03, pre-resolution) — kept for the record

**OPEN — P2.** This is recommendation #4 of `docs/perf/2026-07-02-night-soak-report.md` ("Root-cause
HANG #1 before wide rollout"). It is the last un-closed item from the Qt-6.12 rollout soak (the crash
`4a14650` and the TTFF item `ff707ab` are both done). Not a blocker for day-to-day work; flagged
"before WIDE rollout" because a 1-in-3h GUI freeze is unacceptable on an operator's live wall.

## The observation (what we know)
During the overnight Qt-6.12 soak (2026-07-02 23:58 → 07-03 07:00, `build/` = Qt 6.12, real Wayland,
harness `WT_NIGHT_SOAK` + `docs/perf/soak-tools/night_soak_supervisor.sh`), **run #1 (a ~3.27 h launch)
wedged its GUI thread exactly once.** Then the supervisor's hang detector killed + relaunched it, and
run #2 (~3.7 h) never reproduced it. So: **~1 wedge in ~7 h total, only ever seen once.**

**It is a genuine GUI-event-loop wedge, not OOM and not merely the soak driver stalling.** Two
*independent* GUI-thread heartbeats stopped simultaneously for >150 s:
- `[NTIME]` — emitted by the soak `Timer` (`qml/Main.qml:459`, on the GUI/QML thread).
- `[WT-MEM]` — emitted by a plain `QTimer memTimer` started in `main()` at 2 s cadence
  (`src/main.cpp:378-385`), also on the GUI thread.

Both are driven by the GUI thread's event loop. For **both** to go silent for >150 s, the GUI thread
must have stopped processing timer events entirely ⇒ a hard block / deadlock / non-returning call on
the GUI thread. RSS at the time was normal (~450–665 MB) ⇒ **not** an OOM/earlyoom kill.

**Context around the wedge:** it occurred around a **HIGH-quality export of the heaviest day in the
set — camera `.106`, day `2026-06-30`, 3542 fragments** (the same monster day that drove the 27 s TTFF
outlier). That export itself **completed OK (~8 s)**, so the export *job* did not hang; the wedge was
around/adjacent to it (drawer open, session churn, or the grab). Frequency **1 in ~3 h**; not
reproduced in run #2.

## What we DON'T have (the gap this prompt exists to close)
1. **The raw soak logs are gone.** They lived in `/tmp/night_soak_full/` (`app.log`, `incidents.log`,
   `samples.csv`) and the **2026-07-03 reboot cleared `/tmp`.** Confirmed absent; nothing was copied
   into the repo. The report's summary above is the only surviving record.
2. **No stalled-thread stack was ever captured — not even before the reboot.** The supervisor records a
   *log tail* on a hang and then `kill -9`s the process (`night_soak_supervisor.sh:66-76`); it never
   attaches a debugger. So we have "what actions preceded it" but **never "where the GUI thread was
   blocked."** Without a backtrace of the wedged thread, root-causing is guesswork.

**⇒ The single most valuable deliverable of this task is to catch the wedge again WITH a stack.**
Everything else follows from that.

## Code-grounded suspect analysis (done — read before you start)
I read the export + drawer + heartbeat paths. Findings:

### Suspect A — the export-drawer **preview grab** (strongest GUI-wedge mechanism) ⭐
`PlaybackScreen.openExportDrawer()` calls **`vout.grabToImage(...)`** (`qml/PlaybackScreen.qml:1584`; also
`snapshot()` at :1573) — a scene-graph **GPU→CPU readback of the live VideoOutput**. On the heavy day the
VideoOutput is presenting a **1440p HEVC frame decoded via VA-API**. `grabToImage` forces a render +
readback that is **synced against the scene-graph render thread**, and `QQuickWindow`'s GUI↔render sync is
a rendezvous — **if the render/RHI thread is wedged under VA-API contention, the GUI thread can block at
the sync point**, which would silence both heartbeats. The soak opens the drawer **every cycle** right
after an export (step 5, `qml/Main.qml:558-568`). This fits "near a heavy-day export" better than anything
else. **Prime suspect.**

### Suspect B — export completion → GUI handoff: **largely RULED OUT on the soak path**
- `ClipTranscoder` (the ffmpeg post-process) is **fully async** — `QProcess` + `finished/progress/failed`
  signals, no `waitForFinished` on the GUI thread (`src/models/ClipTranscoder.cpp:95-125`).
- The download **streams chunks** to disk via `readyRead → file->write(reply->readAll())` on the GUI
  thread (`src/models/PlaybackClient.cpp:656-659`). A large synchronous write *could* stall briefly under
  disk pressure (the soak's sidecar `rm`s clips every 20 s) but nowhere near 150 s.
- **Crucially, the soak passes an EMPTY post map `({})`** (`qml/Main.qml:489`), and `createExport` stores
  post **only if non-empty** (`src/models/PlaybackClient.cpp:541`). **So the soak's HIGH/STD exports never
  run ffmpeg at all.** The post-process is therefore **NOT on the soak's wedge path** — it would only
  matter for a *real operator* doing a compression/overlay-burn export. Keep B as a suspect **only** for
  operator-driven compression exports, not for reproducing this soak wedge.

### Suspect C — cross-thread **proxy rendezvous** (the known wedge class)
The earlier wall↔Live GUI wedge (`3618d3d`) was exactly a GUI-thread block waiting on the `HlsProxy`
thread. That was fixed by moving the proxy to its own `QThread` with **`Qt::QueuedConnection`** for
steady-state (`src/models/PlaybackClient.cpp:74-86`); only `init` uses `Qt::BlockingQueuedConnection`
(`:73`, startup-only) and the dtor has a bounded `m_proxyThread->wait(3000)` (`:99`). So no *obvious*
steady-state GUI→proxy block — **but** the wedge coincided with export/session activity, and the
`4a14650` session teardown/re-open path is adjacent. If the stack points at the proxy or a
`BlockingQueuedConnection`, this is it.

### Suspect D — Qt FFmpeg media backend + VA-API under teardown/re-open churn
`4a14650` removed a UAF but the media backend still posts cross-thread frame/state events. A heavy-day
session (3542 frags) plus a concurrent `grabToImage` could deadlock the render/decode/VA-API threads;
because the wedge is GUI-event-loop-wide, **anything that makes the GUI thread rendezvous with a wedged
render/decode/VA-API thread qualifies.** Overlaps A.

**Working hypothesis:** A + D — a `grabToImage` readback on a heavy-day 1440p VA-API surface rendezvous-
blocks the GUI thread against a stalled render/decode thread. The stack will confirm or kill this.

## Task
### Step 1 — Instrument the supervisor to capture a stack BEFORE it kills (do this FIRST)
In `docs/perf/soak-tools/night_soak_supervisor.sh`, inside the incident-recording block (after the hang
is detected, **while `$APP` is still alive** — i.e. between the current lines 68 and 75, before the
`kill -9`), dump the wedged process state:

```sh
# --- capture the wedged process (GUI-thread stack is the whole point) ---
if [ "$reason" = hang ]; then
  echo "-- gdb thread apply all bt:" >> "$INC"
  gdb -p "$APP" -batch \
      -ex 'set pagination off' \
      -ex 'thread apply all bt' >> "$INC" 2>&1 || echo "   (gdb unavailable)" >> "$INC"
  echo "-- kernel wchan per thread (blocked-in):" >> "$INC"
  for t in /proc/$APP/task/*; do
    printf '   tid=%s state=%s wchan=%s\n' "${t##*/}" \
      "$(awk '{print $3}' "$t/stat" 2>/dev/null)" "$(cat "$t/wchan" 2>/dev/null)" >> "$INC"
  done
fi
```

- `gdb -p` works here even at `ptrace_scope=1` because **the supervisor is the parent** of `$APP`
  (tracing a descendant is always allowed). If gdb isn't installed, `sudo apt install gdb` — run that in
  **your own terminal** (sudo needs a real TTY; see the long-shell-commands working rule).
- The kernel `wchan`/state loop is a zero-dependency fallback: it shows what each thread is blocked in
  kernel-side (`futex_wait` = lock/rendezvous; `poll`/`ep_poll` = idle event loop; a VA-API/DRM ioctl =
  GPU wait) even if gdb is missing or symbols are thin.
- **Also preserve logs OUTSIDE `/tmp` this time** so a reboot can't eat them again — set
  `WT_SOAK_DIR=$HOME/watchtower-soak/$(date +%F-%H%M)` (or under `docs/perf/`), don't rely on the
  default `/tmp/night_soak`.
- **Debug symbols:** confirm the repro build resolves our frames — if `bt` shows `watchtower` frames as
  `??`, rebuild the repro tree `-DCMAKE_BUILD_TYPE=RelWithDebInfo`. Even without app symbols, the Qt /
  libav / VA-API / `libc` `pthread_cond_wait` frames from system libs already tell you WHICH subsystem is
  stuck — but app symbols make it decisive.

### Step 2 — Build a TARGETED repro to raise the 1-in-3h hit rate
The full `WT_NIGHT_SOAK` rotates all 32 cameras and 14 days, so the heavy-day + drawer-grab coincidence
that triggered the wedge is rare. **Pin the harness to the trigger conditions:**
- Force the camera to **`.106`** and the day to a **heavy (thousands-of-fragments) day**, and drive
  **open → seek → open export drawer (grab) → export** tightly in a loop. The cheapest way in: add an
  env-gated focus mode to the `nightSoak` timer in `qml/Main.qml` — e.g. `WT_SOAK_FIX_CAM=<ip>` +
  `WT_SOAK_FIX_DAY=<YYYY-MM-DD>` that override `_cam()` / `dayOff`, and bias toward step 5 (drawer open)
  every cycle. Keep it inert unless set (match the existing `wtNightSoak`/`wtSoakNoExport` gating style).
- Note the heavy day is a *moving target*: `.106`'s 3542-frag day was `2026-06-30`, which is "3 days ago"
  as of 07-03 and ages out of the 14-day window over time. Pick whatever `.106` day currently has the
  most fragments (open it once, read `playbackScreen.tlFrags.length`).
- Consider a **`grabToImage`-only micro-repro** to isolate Suspect A: a tiny harness that just plays the
  heavy-day session and fires `vout.grabToImage()` in a tight loop (every ~500 ms) while seeking. If that
  alone wedges, you've localized it to the grab without needing the whole export machinery.

### Step 3 — Run until it catches a wedge WITH a stack, then read it
Run the targeted repro under the patched supervisor on **real Wayland** (offscreen won't work — it needs
the live VA-API renderer, and 6.12 offscreen SIGBUSes under playback churn anyway). Let it run until the
incident file has a `HANG/GUI-WEDGE` block **with a `thread apply all bt`.** Read what the GUI thread
(usually thread 1) is blocked on:
- Blocked in `QQuickWindow` / RHI / `grab` / render-thread sync, or in a VA-API/DRM ioctl → **Suspect
  A/D confirmed** → the fix is to stop grabbing the live VideoOutput on the GUI-critical path (see below).
- Blocked in a `futex`/`QMutex`/`BlockingQueuedConnection` involving the proxy or media backend →
  **Suspect C** → find the cross-thread rendezvous and break it (mirror the `3618d3d` fix: move the work
  off the GUI thread / make the connection non-blocking).
- CPU pegged at the wedge (check `samples.csv` CPU% at the wedge timestamp) → a spin/busy-loop, not a
  block → different class again.

### Step 4 — Fix per the confirmed cause
Likely fixes if it's the grab (A/D):
- **Don't block the GUI thread on the preview.** Options, cheapest first: (a) drop the live-frame preview
  entirely and use the last decoded snapshot / a placeholder in the export drawer (the preview is
  cosmetic — the drawer is a form); (b) make the grab best-effort with a guard so a heavy day skips it;
  (c) grab a **downscaled** target so the readback is cheap; (d) throttle so only one grab is ever
  in-flight. The drawer must open instantly regardless of grab outcome.
- If the stack implicates the media backend under teardown+grab concurrency, coordinate with the
  `4a14650` teardown ordering (never grab across a source-swap).

## Files
- `docs/perf/soak-tools/night_soak_supervisor.sh` — add the gdb/wchan capture (Step 1); switch
  `WT_SOAK_DIR` off `/tmp`.
- `qml/Main.qml` — the `nightSoak` timer (`:436-576`), the export/drawer steps (`:542-569`); add the
  targeted focus mode (Step 2).
- `qml/PlaybackScreen.qml` — `openExportDrawer()` / `vout.grabToImage` (`:1581-1585`), `snapshot()`
  (`:1572-1577`); the export drawer (`ExportDrawer`, `:1597-1619`).
- `src/models/PlaybackClient.cpp` — export lifecycle: `createExport` (`:507-545`), `downloadExport`
  (`:638-689`), `runPostProcess` (`:691-717`); proxy thread setup (`:63-99`).
- `src/models/ClipTranscoder.cpp` — confirm it stays off the GUI thread (it does today).
- `src/main.cpp` — the `[WT-MEM]` heartbeat (`:377-386`) — the wedge sensor; don't change, just know it.
- `docs/perf/2026-07-02-night-soak-report.md` — the source report (§3 HANG #1).

## Verify
- **Repro caught:** the incident file contains a `HANG/GUI-WEDGE` block **with a resolved
  `thread apply all bt`** showing the GUI thread's blocked frame. (This alone is a milestone — it's what
  we never had.)
- **Fix validated:** re-run the targeted repro (heavy-day `.106` + drawer-grab + export, the exact
  trigger) for **longer than the original exposure that produced the wedge** (≥7–10 h, ideally more since
  base rate is ~1/3 h) → **0 GUI wedges**, heartbeats never gap >150 s, `[SEEKBAR]` clean, no new crashes.
- Then a broad `WT_NIGHT_SOAK` pass to confirm no regression on the general flow.

## Gotchas / current toolchain (READ — some sibling prompts predate the migration)
- **Toolchain migrated 2026-07-02.** Primary = **Qt 6.12** → `build/`; fallback = **Qt 6.8.3 LTS** →
  `build68/`. **System Qt 6.4.2 is BANNED** (CMake floor 6.8) — **ignore any older prompt that says
  "build on 6.4.2".** Launch via **`./run.sh`** (never `./build/watchtower` directly). The wedge was on
  **6.12** — reproduce there.
- **On-screen only.** The wedge needs the live VA-API renderer. `QT_QPA_PLATFORM=offscreen` won't
  exercise it, and 6.12 offscreen SIGBUSes under playback churn regardless (use `build68` only for
  offscreen smoke, which is not applicable here).
- **This was NOT reproduced on the second run** — expect to run the *targeted* repro a while. If the
  targeted harness can't raise the rate, fall back to the broad soak but keep the gdb capture armed.
- **heaptrack is unusable** on this VA-API/Qt stack (documented repeatedly) — don't reach for it; the
  gdb-on-wedge + `/proc` sampler are the tools.
- **Preserve raw logs outside `/tmp`** (a reboot already ate the first set). 
- Auto-commit + push when verified (Conventional Commits + the Co-Authored-By / Claude-Session
  trailers), per the working agreement.
