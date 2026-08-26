# Cilex Watchtower — Project Status

> **[REDACTED 2026-08-22, operator order]** Credential strings removed at HEAD
> (`<REDACTED-CRED>` markers). Original bytes remain in git history pending
> history surgery + rotation (operator decisions).


<!-- 2026-08-26 pointer -->
> **2026-08-25/26 — the yellow-line / clip-length saga (events hero, operator's
> Mac): six fix rounds shipped overnight, verified by the operator's own runs;
> ONE item still open.** Canonical test: event `feafb3e4-8e90-43f8-ad1c-ee2debb13b72`
> (cam `hiwatch-083bc14efff9`, «1 Улица 3», night street, person exits at
> clip-0:30, camera stamped 15s; the operator's `cilex://open/ai6v…` and the
> Linux re-mint `cilex://open/aa4iu…` decode to the SAME event — site addressed
> via Tailscale vs LAN).
>
> **Shipped (v1.1.208, `d19ba00`; chain 58b7d6e→a187319→09b14c5→c106611→2f5f515→d19ba00):**
> declared/window-authoritative stop latch (never the session length, never
> AVFoundation's growing `player.duration`; scrub sessions are ±15s WIDER than
> the clip window); playhead display clamped to the window; MotionScan
> toImage-readback fallback for unmappable GPU frames (WT_MSCAN_FORCEIMG forces
> it on Linux); stale-note gate + PTS-divergence clamp + one-lie-latches-
> position-timing + >3s label-jump rebaseline (AVF stamps a jumping clock:
> measured pts=21882 at pos=4648, and pts=0 flushes at session boundaries);
> coverage (earliest/latest) advances only on seed/contiguous frames;
> coverage-hole REJECT of first-motion locks (`scanned=9725ms of claimed
> 22931ms` — the mid-clip band-lock killer); band end measures INDEPENDENTLY of
> the start, MONOTONIC (right only) and FINAL once a verdict lands >2.5s inside
> the window — after final, no re-measure and no more extensions (wind can't
> steer); motion-follows extension +15s×4 max, IN PLACE when the media already
> holds the bytes (server over-serve; no reopen on the Mac) else reopen;
> per-event LEARNED WINDOWS (replays open at the discovered true length —
> in-memory per run); seek end dead-zone 3s→1s (the 0:37 scrubber wall);
> `run-macos.sh` auto-tees every run to
> `~/Library/Logs/CilexWatchtower/run-last.log` (+run-prev.log); score buckets
> ALWAYS ON (one line/~2s: `max= floor= cells= drift=`).
>
> **Operator-verified on the Mac:** extend 25→40s in place ("media holds 60s"),
> band static once shown, counter never exceeds total, stop at window edge.
>
> **OPEN (the one residual):** the band's END freezes at ~23.5s while the person
> truly exits at ~0:30 — the Mac is served **640×360** (AVFoundation takes the
> master playlist's FIRST variant; Linux/FFmpeg picks 2560×1440 of the same
> session) and the walker's far phase drops under every detector gate at that
> scale. Two staged fixes: (1) CV letter
> `docs/letters/2026-08-26-review-playlist-variant-order.md` (single-rendition
> or highest-first review playlists — CV reply pending) — at 1440p the detector
> already follows the walker far past 23.5s; (2) a speed-bounded small-mover
> cluster gate: the compact/persistent/drifting-cluster detector is BUILT but
> ships TELEMETRY-ONLY (`cells=/drift=` in every bucket + a one-shot candidate
> line) because unbounded it rode distant road traffic to the 85s cap on 1440p
> (drift 14.6 sweeps vs a walker's ~1.2–3.5 cells/2s — the .110 lesson, tail
> edition; measured 08-26 01:59). Design the bound from the Mac's own telemetry
> in the next operator log. **Known issue, deliberate:** on 1440p road-facing
> scenes the paired-singles ride can over-extend toward the 85s cap (bounded;
> documented in `MotionScan.cpp`) — it is what carries every REAL extension on
> the new encode, and removing it cut the walker at 25s again (measured 02:05:
> sustained-only went final at 16.9s).
>
> **Also measured 08-25:** the served stream's score statistics dropped 4–5× on
> the same event between morning and evening (both samplers agree) — CV's
> decode-forward CRF-18 edge re-encode suspected; deploy-confirm letter
> `…hls-segments-serve-more-than-they-declare.reply3.md` pending. Detector
> thresholds were re-verified against the NEW encode.
>
> Test hooks: `WT_MSCAN_FORCEIMG=1` (readback path), `WT_MSCAN_NOPTS=1`
> (position clock), `WT_MSCAN_BLINDMS=N` (blind [2s,2s+N] after first sample),
> `WT_HERO_AUTOPLAY=1`. Diagnostic ask to the operator is always ONE paste:
> `grep -E "MSCAN|MKT|HERO" ~/Library/Logs/CilexWatchtower/run-last.log`.

<!-- 2026-08-17 pointer -->
> **2026-08-17 — the booth slow-wall is FIXED and the wall PASSES the
> operator's bar.** Measured: **15 minutes, zero stalls, 8/8 tiles lit, worst
> 19.1 fps/stream, no SLOW badge** (was: 10–15 of 32 thrashing at ~23
> stalls/min). See `docs/letters/2026-08-17-booth-designing-to-1500kbit.booth-reply.md`
> and PR #5. Two client changes did it, both "ask for the size we draw":
>
> 1. **`WT_SNAPSHOT_WIDTH_CAP`** — the client was requesting **FULL-SIZE**
>    stills and downscaling after decode (`CvImageProvider.cpp:190`, a June RSS
>    fix that does nothing for the network). Measured 3.72 fetches/s ×
>    **123.8 KB** ≈ 3.7 Mbit/s, service times to 3635 ms. With CV's shipped
>    `?w=` ceiling: link **4.74 → 1.82 Mbit/s**, loss **12–20 % → 3 %**, RTT
>    **25 → 9 ms**. One query parameter, 62 %.
> 2. **`WT_WALL_STREAM_SUFFIX=wall`** — CV's `{camera_id}-wall` (320×180 of
>    `-sub`) measures **50.5 kbit/s** vs `-sub`'s 368.5, so 8 live tiles cost
>    ~0.4 Mbit/s. ~~Keep `maxLiveDecodes ≤ 8`~~ **SUPERSEDED 2026-08-18** (CV's
>    go2rtc-OOM P0 letter): the "~56 MiB / 8-stream ceiling" figure was measured
>    with evictable page cache — real cost is **~34 MiB anon per consumed -wall
>    transcode**, and the ceiling is **min(memory, pids) ≈ 89**: memory
>    (3072−40)/34 ≈ 89 binds; pids (2048−61)/16.6 ≈ 120 does not — the healthy
>    state. **Warning (CV, 2026-08-18): if anyone trims the container's
>    pids_limit back toward 512 as "generous", the ceiling silently returns to
>    ~27 with ZERO kernel OOM evidence** — go2rtc can't fork its own healthcheck,
>    Docker marks it unhealthy, the watchdog restarts it, and the OOM counter
>    stays 0. The booth's blackout days (51 kernel OOM kills on 08-18 alone) were
>    go2rtc dying under the old 1 GiB cap — every tile drops at once, and each
>    mass reconnect re-crossed the line. The oft-quoted "~25 tiles in booth
>    practice" is suspect as a demand figure: it sat within one tile of the old
>    ~27 ceiling and rose to 40 within 30 min of the limits lifting (CV §4) —
>    booth attempted-vs-rendered counts are the real demand number. 135 tiles still does NOT fit pre-LAN (135×34 ≈ 4.6 GB);
>    the LAN plan retires -wall entirely (`-sub` passthrough, no ffmpeg). Also:
>    `rtsp_wall_url` is now ADVERTISED on /streams — client consumption queued,
>    suffix-append still works meanwhile.
>
> **The path's real budget is ~1.5–2 Mbit/s.** Loss is 0 % idle and 0 % up to 2
> streams, 2 % at 3, 5 % at 4, 30 % at 6 — self-inflicted congestion, not a sick
> path (RTT 8–9 ms idle).
>
> **The reconnect churn was OURS.** CV's arithmetic: our silence watchdog fires
> at **31 s**, go2rtc closes at **45 s and 60 s**, so the booth always tears down
> first. Their 46.7 attaches/hour at 5.8× turnover was our own watchdog
> recycling sessions, and the "median stream lifetime ~23 s" measured our timer,
> not stream death. **Open: move the threshold above 60 s** so the server's
> decision is observable at all.
>
> **Open faults:** `-wall` delivers **18.1–19.8 fps** where the fleet broadcasts
> 15 (31 consecutive samples — a fault to diagnose, filed with CV); only 8 of 35
> cameras are live video (CV's transcode memory, not our link); CV's 15-minute
> N=2 bare run is unrun because it now costs a *working* wall 15 minutes of
> downtime — operator's call.
>
> **Dead ends, so nobody re-runs them:** build-burst stagger, decode cost,
> decoder-blocks-reader (leaky queue), GUI/density saturation, PMTU blackhole,
> the Tailscale exit node (peer traffic is 1 hop, not via London), and CV's
> keepalive theory (they retracted it: silence needs 60 s, our sessions "died"
> at 23 s — our own watchdog). Withdrawn numbers: `width=1280` on `-sub` (it is
> `main_transcode`), `13.8 Mbit/s booth downlink` (measured through the exit
> node), `~5 Mbit/s usable` (that was throughput incl. retransmits), and
> `10.7 KB per still` (inferred, not measured — the real figure is 123.8 KB).

<details><summary>Superseded 2026-08-16 pointer (bandwidth-only reading)</summary>

> **2026-08-16 — the booth slow-wall is ROOT-CAUSED: the link, not the code.**
> Read `docs/letters/2026-08-16-wall-is-bandwidth-bound.md`. Measured from the
> booth (Tailscale peer byte counters): **4 live streams pull 4.50 Mbit/s and
> are stable; 32 live streams pull 4.18 Mbit/s and thrash.** Eight times the
> demand delivers LESS data — the path is saturated at ~4.3 Mbit/s. A 720p
> sub-stream costs ~1.1 Mbit/s, so 32 tiles demand ~35 Mbit/s; the booth's
> entire internet downlink measures 13.8 Mbit/s, so the wall never fit even in
> the best case. Per-tile rate is just 4.3 Mbit/s divided N ways: 13.3 fps at
> N=4, 3.4 fps at N=32. **The fix is CV's**: the 133 transcode producers pass
> `#video=h264#width=1280#hardware=vaapi`, shipping 1280 px over a WAN to be
> drawn in a ~235 px cell (~30× the pixels displayed); `width=320` should cut
> bitrate 6–8× and put 32 tiles at ~5–6 Mbit/s. Width only — frame rate
> untouched, the 15 fps rule stands.
>
> This SUPERSEDES the earlier leading mechanism ("go2rtc releases consumers
> without closing sockets"). CV's TCP capture was right in every particular —
> send queue pegged at 63,456 bytes with ZERO retransmits, read timeout,
> `close()` — and a full pipe is exactly what produces it: writing 1.1 Mbit/s
> into a socket draining at ~135 kbit/s (4.3 ÷ 32). What was missing underneath
> was why the socket drained so slowly. Survivor law ≈√N was a bandwidth
> artefact, not a lifecycle one.
>
> **Four hypotheses died with tests, recorded in that letter's §5**: burst-at-
> build (`WT_BUILD_STAGGER_MS` 1500 vs 120 ms — no change, ~26 stalls/min
> either way), GUI/density saturation (dies at 8 streams and 57 fps with an
> idle GUI), decoder-blocks-the-reader (leaky queue shipped, deaths held at
> ~23/min), and gst-launch `Parse error` deaths (harness ran alongside the app
> → 64 sessions to one NAT'd IP; not filed as a go2rtc bug).
>
> **Build channel is OPEN.** The booth now has its own toolchain (MSVC 14.44,
> Qt 6.12.0, GStreamer 1.26.11, CMake, Ninja); v1.1.68+ is built and deployed
> on the guard wall from `packaging/windows`-adjacent local scripts. The
> eight-item undeliverable queue is unblocked. Also found and fixed: go2rtc
> **refuses UDP** (`No supported stream was found`, bare gst-launch), so every
> consumer is forced onto TCP interleaved where congestion kills sessions
> instead of degrading them; and `RtspVideoSource::setErrored()` never logged,
> so bus errors never reached the flight recorder (`err=0` against a dying
> wall) — `[WT-ERR]` added in PR #4.


</details>


_Last updated: 2026-08-10. This file is the durable, crash-recoverable snapshot of
where the build is. Implementation details live in [DEVELOPMENT.md](DEVELOPMENT.md);
the design spec is `designs/design_handoff_watchtower/README.md`._

## Current status (2026-08-10) — P0 silent-playback-loss CLOSED client-side; "One Axis" Playback merged; the density sweep is complete

**Written by the Linux dev agent.** `main` = `79ae858`, pushed, working tree
clean, `wt-warden` active on the dev box. Everything below was verified from
this box before the push.

### 🔴→🟢 P0: playback died silently for a guard, and every health surface read green

A guard at the booth had **no recorded playback and no export** for an unknown
period. The visible symptom was five words — `Token expired` — inside one
camera's video pane.

- **Cause.** Watchtower refreshes its token in place at `exp − 600 s`.
  `AuthController::applyToken()` swapped the token and updated the shared
  network stack but **emitted no signal**, and two components keep their own
  stack and copied the cookie only on *login* or *base-URL change*:
  `PlaybackClient` and the local HLS proxy. A refresh is neither event, so from
  the first renewal onward every `POST /review/sessions` and every proxied
  segment carried a retired token. `/streams`, `/events`, snapshots and The
  Watch read the token per request and never noticed.
- **Fix** `f6b1890` — `AuthController` now emits `tokenChanged()` on every
  in-place swap; `PlaybackClient` re-copies the cookie into its own stack and
  into the proxy on it. **Verified by forcing the failure**: renewal interval
  set to 25 s (`WT_AUTH_RENEW_S=25`), playback opened after **two** refreshes —
  session opens, zero `Token expired`, zero 401s in the run.
- **Self-heal + visibility** `910f35e` — a 401 on session open now calls
  `noteUnauthorized()` (one refresh) and retries once before declaring
  anything; previously that path had **no 401 handling at all**. A playback
  fault now raises a station-level `PLAYBACK` strip on the Health screen beside
  `STORAGE`, and emits `[WT-DEGRADED] subsystem=playback …` / `state=CLEARED`.
- **The product failure was the silence, not the 401.** Letter
  [`2026-08-10-p0-silent-playback-loss.md`](letters/2026-08-10-p0-silent-playback-loss.md)
  states it as the motion-P1 shape in different clothes: *a gauge that only
  exists once things work cannot page when they don't.*

**CV has replied and shipped all four asks** (`090d9c4`, deployed, 113 tests) —
[`…p0-silent-playback-loss.reply.md`](letters/2026-08-10-p0-silent-playback-loss.reply.md):
the `subsystems` heartbeat field is accepted as proposed (names `[a-z0-9_-]`
≤32 chars, **max 8 per beat**; **any state string other than `"ok"` is treated
as fault**, so a future `"degraded"` fails safe; claims trusted only while
Warden is fresh); `StationSubsystemFault` pages at 5 min with **three absence
layers**; a subsystem fault lifts the station's severity into Cilex Pro
Mobile › Health today, with station code `subsystem_fault` reserved for v2; and
`cilex_client_unauthorized_total{surface}` + `ReviewAuthReplaySustained` now
catch this class server-side.

> **🔴 ACTION FOR WHOEVER PICKS THIS UP — the P0 is only half closed.**
> **No client sends `subsystems` yet**, so CV's `subsystems_reported` gauge is
> honestly reading **0 for both stations** and will keep firing until our beat
> carries the field. The acceptance test is CV's: ship the field, then inject a
> deliberate fault (force the 25 s renewal again) and expect the operator's
> phone to page **within ~5 minutes**. Send CV a line when the first beat
> carries it. Owner: whoever touches `warden/warden.py` next (the beat is built
> at `:489`).

### 🟢 "One Axis" Playback merged (`79ae858`, `--no-ff`, branch `design/playback-one-axis` preserved)

Claude Design's variant, built to the handoff: **one navigator** (35-day
archive ribbon + header + FOOTAGE/MOTION lanes on a single axis, replacing the
old calendar-vs-zoom-buttons split), the info rail dissolved, a four-group
transport, the ten-rate speed ladder with the **scan boundary above 10×
disclosed by colour**, export-as-marked-range gated behind frame mode, the
filmstrip regrown to nine cells, and a full keyboard map. Seven new components
(`PbRibbon`, `PbNavHeader`, `PbLanes`, `PbTransport`, `PbEventsPanel`,
`PbBanner`, `PbFmt`); **the session / seek / stepper machinery is preserved
verbatim** — the engine constraints in the brief (§3.6) were not renegotiated.

Two fixes rode along, found while verifying, and one is bigger than it sounds:
- `d19aaf7` — **the English catalogue was never loaded**, so `%n` plurals
  printed literally **app-wide**, not just on Playback.
- `cfe87f5` — `Esc` unwinds the export drawer before leaving the screen.

**Verified before pushing** (a push to `main` triggers CI, which republishes
the rolling installer the booth machine installs from): clean compile
(`[131/131] Linking`), smoke run with `WT_PLAYBACK_IP=192.168.1.160` giving
**0 QML errors**, and **0 unfinished** RU strings.

**Known-open on merge, recorded in the merge commit rather than left to
memory:**
- 🔴→🟢 **The filmstrip blanking (operator-reported 2026-08-10) is FIXED**
  (`0b68891`, merged `3a238a0`). **The export was innocent** — instrumented and
  measured clean end to end over two real 10 s jobs (strip 9/9 lit throughout,
  both files landed); `createExport` never touches the player. The trigger is a
  session **re-open**, and in the operator's own session the flight recorder
  (pid=1975323) shows `opens` 38 → 39 inside the same 30 s sample that opened
  the export drawer at 03:32:41.6 — adjacent to the export, not caused by it.
  Forcing a re-open under frame mode reproduced it exactly: **`lit=0/9` against
  `cache=288f`** — a *full* cache — with playback running, for 60 s+. Three
  defects: `onSessionReady` resumed playback under a paused-only mode (a moving
  cursor can never chain to cached frames); two `<= 0` sentinels treated **PTS 0
  as "no frame"**, which is precisely where a far-seek re-open lands (one killed
  the strip, the other killed the *centre* cell over a cache that held it); and
  a strip that could not resolve said nothing. Repro hook `WT_PB_EXPORT=1|2|3|4`
  is documented in [DEVELOPMENT.md](DEVELOPMENT.md) — 1, 3 and 4 need no
  backend write.
- 🟡 Video-area gain is **+8.8 % with the rail open** against the spec's ≥20 %
  goal (+45 % with it closed). The spec's own arithmetic omitted our 72 px nav
  rail and 36 px title bar; §7 and §2.6 contradict each other on this.
- 🟡 The **`archive: calendar` month-grid preference is NOT built** — absent
  from the build order and contradicted by the spec's §7.
- 🟡 **Five of seven honest states are unverified** — reaching them needs
  writes against the live backend, which real guards are watching.

### The density sweep is now complete

All four screens are shipped in Claude Design's density language (gapless
hairline cells, inset rings never borders, computed-fit math never converging
loops, overlays that never reflow): **Triage "Lanes"**, **Groups "Wall"**
(`qml/CameraGroups.qml`, with `qml/GroupsStatus.js` as the single source of
camera-status truth), **Playback "One Axis"**. **Verify "Strips" is the one
outstanding handoff** — brief sent
([`2026-08-07-verify-redesign.md`](design-briefs/2026-08-07-verify-redesign.md)),
Claude Design has not returned it.

> ⚠️ `qml/GroupsStatus.js:10-11` mirrors the `CameraStatus.h` enums **as ints
> across the QML boundary**. A wrong mirror silently reclassifies the entire
> fleet — it briefly rendered all 39 cameras as OFF. Change one, change both.

### The 16-camera wall: the compositor is innocent, the honesty is not (2026-08-10)

Operator report: opening the wall from Live › "Go back in time" showed **2 of 16
cameras with picture**, the rest black with a camera name and a ticking
timestamp. Asked for all 16 playing within 3 s.

**Both halves of that ask are answered, and neither is what it looked like.**

- 🟢 **Speed is already inside the bar.** Measured against the pilot backend
  (16 cams, 6 h window, **5 mosaic sessions, all disposed**): session create
  **191–643 ms**, first segment at the window head **0.69 s**, prewarm → segment
  served **1.2–2.4 s**. **The `~4–6 s` in `qml/WallPlayback.qml` was stale and is
  corrected** — do not quote it again.
- 🟢 **The compositor is not dropping cells.** Sampling the composited frame at
  the instant each camera has its own segment, **7 of 7 lit their own cell**
  (`.103 .104 .107 .108 .109 .133 .134`). Grid is 4×4, **1920×1080 @ 12 fps
  h264**, cells 480×270.
- 🔴 **"All 16 at once" is not reachable, and not a defect.** 14 of the 16 are
  motion-triggered, so at any instant they have no recorded video. Sampled at six
  instants across six hours, the lit count was **2/16 every time** — always
  `.135`/`.136`, the two that record continuously; typical is **3–4 of 16**. You
  cannot display footage that was never recorded. Anyone re-opening this should
  treat it as a recording-policy question, not a client bug.
- 🔴 **The real defect is honesty.** A black cell wearing a camera name and a
  millisecond timestamp reads as "loading", not "this camera recorded nothing
  here" — the no-green-by-default rule, broken. **The client cannot fix this
  alone**: `availability` is per-FRAGMENT (whole grid) and the mosaic manifest
  carries no per-cell truth. Needs a CV contract ask.
- 🔴 **Contract mismatch worth a letter.** The manifest calls all ~3,594 fragments
  `ready`, but a segment fetched at a random offset returns **HTTP 503 — 14 of 14
  attempts** — until `prewarm` is called. Today `ready` means "will be rendered",
  not "can be served".
- 🔴 **Intermittent crash on the wall.** VA-API `Failed to sync surface` →
  `Cannot map a video frame in ReadOnly mode!` → `corrupted double-linked list`
  → SIGABRT at 14 s. Confirmed on the unmodified tree, so it predates the
  2026-08-10 work. Faults reproduce every run; the abort does not.

Measure it yourself with `WT_TRACE=1 WT_WALL_DAY=live` (`[WALL]` lines: grid,
cell→camera map, availability histogram).

### Still open with CV / the fleet

- 🔴 **Recording P1 (2026-08-07, unresolved):** 12 of 23 armed cameras
  **detect motion but do not record** (21–37 h, staggered), 53 % of events have
  no clip, and storage-agent health flaps. Letter
  [`2026-08-07-motion-without-recording.md`](letters/2026-08-07-motion-without-recording.md).
  The client tells the truth about it now: tiles read `ARMED · NOT RECORDING`
  (`qml/GroupsStatus.js:20-25` — recent detection while the newest segment is
  over an hour older) and the badge carries `NOT READY` for a deaf armed
  camera.
- 🟡 **21 events dated Aug 8 are back in the open queue** after CV reverted the
  Windows agent's soak writes (22 dispositions + 5 acks + 1 bookmark — *not*
  the ≤84 feared; the exclusion set was empty, measured not assumed). **13 have
  no footage** (outage-era, the prebuffer P1); **8 have footage and now await a
  first real judgement.** The operator may want to re-apply any disposition
  that was genuinely theirs — attribution through the NAT is `admin@10.0.0.1`
  for everyone. CV's ranked advice: a dedicated `soak-bot` account, and
  endurance soaks read-only by default.
- 🟡 Asked CV for a **per-day segment count on `/review/coverage`**
  ([`2026-08-10-coverage-per-day-segment-count.md`](letters/2026-08-10-coverage-per-day-segment-count.md))
  — the archive ribbon's dots need it to be honest about *how much* footage a
  day holds, not just whether any exists.
- 🟡 Awaiting Codex on the ANPR certifications (`iDS-TCM203-A`,
  `F-TA-M21-GI1`) and the ignore-devices → reserved-IPs feature.

## Current status (2026-08-09) — station token INSTALLED, `wt-sm-vnutri-01` now reports to CV; 8 h UI soak clean; 6 defects found

**Written by the Windows station agent.** The booth station is no longer dark on
CV's `/admin/fleet`.

- **🔴→🟢 The station ingest token is installed and the heartbeat attaches to the
  pre-provisioned row.** Until 2026-08-09 the `STATION_TOKEN=` line in this box's
  `warden.conf` was **empty** — minted by CV on 08-07 and handed to the operator
  out-of-band, but never pasted in. Warden gates every beat and every upload on it
  (`warden/warden.py:566`), so the station had never beaten once: CV's fleet page
  showing "box is off or unreachable" was **truthful, not a display bug**.
  Now set; `warden status` reports `token=set`.
  - Key is `STATION_TOKEN` (`warden/warden.py:49`), sent as the
    `X-Cilex-Station-Token` header (`:489` heartbeat, `:546` bundle upload).
  - **The token itself lives ONLY on that machine** —
    `%USERPROFILE%\.config\watchtower-warden\warden.conf`, UTF-8 **no BOM**
    (Warden reads via `Path.read_text()` under a cp1251 locale; a BOM would
    corrupt the first line). ACL: inheritance broken, `localadmin` + SYSTEM only,
    zero Everyone/Users. **Never in this repo, a letter, or a screenshot.** If it
    is ever lost or leaked, ask CV to re-mint — never reuse or copy one.
  - Verified: `POST /client/stations/heartbeat` → **HTTP 200** returning
    `station_id 8af7ef38-925b-46d6-8a2b-5177970c39a7` (the pre-provisioned row —
    so no TOFU duplicate), with a bogus-token control returning **401**.
  - The crash bundle stuck since 08-07 (`001748a6…`, `exception-c0000409`)
    **uploaded retroactively** on the first authenticated pass: spool went
    `pending=1 sent=0` → `pending=0 sent=1`. Stale bundles are not dropped.
- **🟢 8 h random-click soak: no crash, no hang, no restart.** 2026-08-08
  10:00→18:03, 84 driver tours over live wall / groups / views / triage queue /
  playback, including real disposition writes. Same pid throughout, no new WER
  dumps, handles flat (2626→2601), no GDI/USER leak, CPU ~22 % of one core.
  **Caveat that matters: the wall was at full 16 pipes for only 2 % of samples**,
  so this validated UI/navigation/triage endurance, **not** sustained decode.
  Private bytes 601→1302 MB (peak) →1045 MB — rises and partly returns, so
  suspected retention, **not** a proven leak; unresolved, needs a wall-pinned run.
  Full record: [`docs/perf/2026-08-08-win-8h-soak.md`](perf/2026-08-08-win-8h-soak.md).
- **🔴 Client defects the soak surfaced** (shared code → `win/<topic>` branch + PR
  from this box, never straight to `main`): `qml/EventsArea.qml:359` TypeError
  ×171; `qml/LiveMonitor.qml:1736` TypeError ×60; `QIODevice::read
  (QNetworkReplyHttpImpl): device not open` ×190; `create group failed 409` where
  it is unproven whether the UI surfaced the error honestly.
- **🟡 Top-bar clock shows a stale time for up to 10 s after the window is
  re-exposed.** `qml/TopBar.qml:30` refreshes `root.now` only on a 10 s QML
  `Timer`, and QML timers are animation-driven so they do not advance while the
  window is unexposed. Observed reading `19:15` at a real 09:53. Fix is to also
  refresh on visibility change. It is a wake transient, **not** a frozen clock.
- **🟡 Two backend questions sent to CV** (letter
  `docs/letters/2026-08-09-snapshot-404s-and-empty-heartbeat.md`): event-snapshot
  `404`s at 17 218 in 8 h, and `POST /client/stations/heartbeat` accepting an
  **empty `{}` body with HTTP 200 and `"health":"healthy"`**.
- **⚠️ Restarting Warden restarts the guard app.** `warden.py:936` calls `spawn()`
  unconditionally with no already-running check, and the app it spawned survives
  its parent — so a config reload means stopping Warden **and** the orphaned
  `watchtower.exe`, or the new Warden puts a second wall on the same iGPU. This is
  the single-instance-lock gap `warden/install-windows.ps1:105-113` already flags.

### CV answered the fleet letter — one item is now ACTION FOR THE LINUX AGENT

Reply filed verbatim at
[`docs/letters/2026-08-09-fleet-page-station-row.reply.md`](letters/2026-08-09-fleet-page-station-row.reply.md)
(CV's own filename, which their letter 2 cites — the Linux agent had already
filed it; a duplicate I filed under the letter-1 name was removed).
CV shipped `6b3a381` (deployed) and closed their half. Their DB read
cross-checks against this box on three independent values (`app_uptime_s 46141`
= our 01:43:23 start + 46141 s; `last_upload_at` 6 s after `warden_started_at`;
spool `0/1/0`), so they are reading our row.

- **🔴 ACTION — `X-Watchtower-Station: <hostname>` header, `src/`, Linux agent's
  PR.** CV asked for §5.4 and **their consuming half is already deployed and
  waiting**; no real client sends it yet, so our PR's first request is its first
  live proof (they asked for a line when it lands). Spec: OS hostname (the same
  string check-in resolves by, e.g. `wt-sm-vnutri-01`), **on every API request**,
  one static header. Server side sanitises hard (lowercase, ≤63 chars,
  `[a-z0-9-._]`), joins case-insensitively to an **existing** row only, and
  attributes **only from an authenticated session**. It buys a traffic signal for
  `app_last_seen_at` that is independent of Warden's vouching — i.e. it is what
  makes the **frozen-wall signature** ("Warden says running but the app stopped
  calling") detectable at all for a NAT'd station. This is shared code, so it
  cannot come from the Windows box.
- **🔴→🟢 Our station row was absorbing every tailnet client's traffic.** CV
  confirmed our reading (a): our `last_seen_ip` was **10.0.0.1** — the docker
  bridge gateway — written by our own Warden's heartbeat, because everything
  arriving over Tailscale reaches the query-api container wearing that one
  address. Consequence neither side had seen: once our beat claimed 10.0.0.1,
  **a guard opening the mobile app over Tailscale was updating OUR
  `app_last_seen_at`** — a phone vouching for our wall. Fixed CV-side
  (`AMBIGUOUS_PEER_IPS` can never claim and never attribute). Conclusion adopted
  both sides: **client IP is not an identity key on this deployment.**
- **🟢 CV also fixed the two honesty complaints**: a provisioned row that has
  never beaten now renders as `never_enrolled` ("token never installed",
  info-severity) instead of "box is off or unreachable" — so "go check the booth"
  and "paste a token" are no longer the same row; and the green banner now
  requires zero unconfirmed clients, going amber otherwise.
### CV answered letter 2 as well — the 404s were our own P1, and both fixes are verified from this box

Reply filed verbatim at
[`docs/letters/2026-08-09-snapshot-404s-and-empty-heartbeat.reply.md`](letters/2026-08-09-snapshot-404s-and-empty-heartbeat.reply.md)
(CV `54d6933`, deployed 18:38Z).

- **The 17 218 snapshot 404s were the motion-without-recording P1, seen from a
  guard's chair.** `events/<id>/snapshot` does not serve a *stored* still — it
  **extracts** a JPEG on demand from recorded video, so a 404 means exactly one
  thing: **no footage covers that moment.** Our 8 h soak window sat inside the
  outage (13 cameras' prebuffer pipelines dead for days; 65 % of events younger
  than 5 days had no covering footage). So the answer to "is 36 misses/min the
  expected steady state" was **no, and it was never a client concern**.
- **🟢 Verified post-fix from this station, 2026-08-09 23:23–23:25 local**
  (after CV's 18:38Z deploy): the triage queue now renders **a real still with a
  duration badge on every visible row**, including camera **`.139`** — one of the
  three CV named as formerly dead. Compare `scratchpad/calib-events.png` (08-08,
  many blank tiles) with `scratchpad/postfix-triage.png`. 404s while actively
  browsing fell to **~17/min from ~36/min**; the residue is expected and
  permanent — events **born inside the outage window (≈ Aug 5–9)** have no
  footage that could ever be extracted, and our honest "no frame" tile is the
  correct rendering for them forever.
- **🟢 The empty-body heartbeat now 422s — verified independently.** Re-running
  our exact probe (empty `{}` + the real token) returns **HTTP 422** where it
  returned `200 "health":"healthy"` this morning. CV also reported a second
  defect our probe exposed and we had NOT claimed: the heartbeat UPDATE
  overwrote telemetry wholesale, so `{}` briefly **nulled the row's real
  telemetry** until the next real beat. Fleet audit found no other thin-beat
  caller — our probe was the first and last empty beat accepted.
- **🔴 ACTION — skip the snapshot request when `recording_id` is null (`qml/`).**
  CV blessed the cheaper negative as contract instead of adding a field: the
  event payload already carries `recording_id` + `duration_ms`. Encode exactly
  this: `recording_id: null` → **no episode, the snapshot WILL 404, do not
  request it**; `recording_id` set + `duration_ms` null → episode still being
  written, may 404 for ~60 s → the live-frame fallback we already gate correctly;
  both set → extraction should succeed, and a 404 there is retention (>35 d) or a
  server defect worth reporting. CV deliberately refused a `has_snapshot` alias
  ("a second name for one fact is how contracts rot"). Shared code → `win/`
  branch + PR. Nothing on CV's side waits on it.
- **⚠️ The wall-pinned soak must be ANNOUNCED to CV before it runs.** They want
  the window so they can watch their gauges against our decoder trace. They also
  note the go2rtc side is unchanged by the prebuffer fix — our 16 RTSP sessions
  were never the problem — and the box now has CPU headroom after their quota fix.

### 🟢 CLOSED: the soak's junk writes on the live queue — CV found and reverted them

Thread: [`2026-08-10-soak-disposition-audit.md`](letters/2026-08-10-soak-disposition-audit.md)
→ [`.reply.md`](letters/2026-08-10-soak-disposition-audit.reply.md)
→ [`.reply2.md`](letters/2026-08-10-soak-disposition-audit.reply2.md).

Our 8 h soak wrote junk into the queue real guards work, and **our own record of
which events was lost** (the crash-watch monitor's `tail -F` locked the driver's
action log at 10:02:24 — never tail a log a Windows writer is appending to).
CV reconstructed it from `audit_logs` and reverted everything in one
transaction, with 27 `SOAK_REVERT` rows and a preserved before-image.

- **Actual damage was far below our ≤84 bound:** 22 `EVENT_DISPOSITION` rows
  over 21 events, 5 `EVENT_ACKNOWLEDGE`, 1 `EVENT_BOOKMARK`. The 15:17:49
  group-create 409'd, so no write exists; the 16 `DELETE`s in the window were
  our own **mosaic-session teardowns** (by-design reaping, not damage).
- **No human judgement was overwritten** — the "a guard touched it later"
  exclusion set was empty, measured. 21 events returned to the open queue: 13
  are outage-era with no footage, **8 have footage and now await a first real
  human look**.
- **Record correction, ours:** the fourth triage button is **`Acknowledge`**
  (`qml/EvTriage.qml:937`, `kbd:"E"` → `EventsStore.ack()`), NOT a fourth
  disposition. The three dispositions are `authorized` / `false_alarm` /
  `dispatched` (`qml/EvTriage.qml:928-933`), matching CV's three observed
  values exactly. CV's "that button never fired" inference follows from our
  mislabel — it fired ~21 times and its writes are their 5 acknowledges.
- **Not a defect:** ~21 clicks → 5 rows because `qml/EvTriage.qml:936` gates the
  button on `status === "new"`; once disposed it is replaced by a `StateTag`.
  Checked deliberately, since a control that looks live and does nothing would
  be a house-rule violation. A window-resize hypothesis was also killed — all 84
  tour screenshots are 1843×900 (the 1440 width came later, with the 08-09
  restart).
- **Policy adopted:** endurance soaks are **read-only by default** from now on;
  write paths get deliberate, logged, single-purpose tests. A dedicated
  `soak-bot` account (CV's pick) is an operator action. The disposable-station
  idea is dropped — events belong to cameras and the site, so a soak station
  writes into the same queue anyway.

### 🔴 Station reality: Windows on `wt-sm-vnutri-01` is NOT ACTIVATED

Found 2026-08-09 while reading a screenshot — an «Активация Windows» watermark
now paints over the guard's triage screen, including across the disposition
buttons. Measured: `SoftwareLicensingProduct.LicenseStatus` resolves to
**NOTIFICATION — unactivated** (code 5; 1 would be licensed), with
`GracePeriodRemaining = 0`. This is an operator/licensing
action, not a code one, but it is a guard booth running a 24/7 wall with a
nag watermark over the UI. Needs a licence key applied to this machine.

## Current status (2026-08-07) — FIRST REAL GUARD STATION IS LIVE on Windows; iGPU measured; 4 install defects found

`wt-sm-vnutri-01` (guard booth, Светлый Мир «Внутри») is installed and running
from the `windows-latest` prerelease (build `4fcb90cd`, confirmed by the app's own
footer). Warden 1.2.0 supervises via the `wt-warden` Scheduled Task. **Written by
the Windows station agent — the Linux agent cannot see this box.**

- **🟢 iGPU decode PROVEN, and decode was the wrong worry.** Intel UHD 730, no
  discrete card. 16-tile wall (16 × H.264 720p sub): **VideoDecode 9.2 %**, but
  **3D/compositing 35.7 %**, CPU 2.9 % of 12 cores, RSS 804 MB. One main-profile
  **HEVC 2560×1440**: VideoDecode 2.5 %, 3D 21.3 %. 94 `[WT-DEC]` lines all
  `d3d11h264dec`/`d3d11h265dec` **(hardware)**, **zero `(SOFTWARE)`**, and zero
  refusals under `WT_HW_ONLY=1` — so no silent SW fallback. **The constraint is
  the scene graph, not the decoder**; `WT_MAX_DECODES` aims at the engine that
  isn't under pressure. Full record + caveats (15 fps cameras; wall measured in a
  1440×900 window): [`docs/perf/2026-08-07-win-igpu-decode-baseline.md`](perf/2026-08-07-win-igpu-decode-baseline.md).
  Note `qml/CameraTile.qml:132` hard-wires grid tiles to the sub stream, so **the
  wall is never HEVC** — promotions are detail/fullscreen/merged-HD only.
- **🔴→🟢 D1: WER local crash dumps were armed in the WRONG REGISTRY HIVE — on
  every Windows install to date.** `installer.nsi` is a 32-bit PE, so its
  `powershell` child is 32-bit and the `HKLM\SOFTWARE\…\LocalDumps\watchtower.exe`
  write was WOW64-redirected into `WOW6432Node`; WER is 64-bit and `watchtower.exe`
  is x64 (PE machine `0x8664`), so it never read it. Silent — the write succeeded,
  so the script printed success. Fixed: explicit `Registry64` view **plus read-back
  verification**.
- **🔴→🟢 D2: a plain non-elevated install left the station with NO supervisor.**
  The admin-only WER step ran before task registration under
  `$ErrorActionPreference='Stop'`, so it aborted the script and `wt-warden` never
  registered — while NSIS still reported success. Fixed: WER is best-effort, and
  the script now prints an honest armed/not-armed summary.
- **🟡 D3: stopping the `wt-warden` task does NOT stop Warden.** `warden.exe` is
  PyInstaller **onefile**: the task launches the bootloader, which spawns the real
  supervisor as a same-named child. `Stop-ScheduledTask` kills only the bootloader;
  the child is orphaned, keeps supervising, and **respawns the app** — so a restart
  yields two Wardens and two Watchtowers on one iGPU (measured, with PIDs).
  Mitigated in the Windows-only paths (install-time orphan sweep; `taskkill` on
  uninstall). **The real fix is a single-instance lock + a `stop` verb in
  `warden/warden.py` — shared code, so it needs a `win/…` branch + PR that this box
  cannot verify on Linux. Owed.**
- **🟡 D4: the station is off-LAN and both backend defaults point at the lab.**
  No tailnet peer advertises `192.168.1.0/24`; `192.168.1.79:8000/8554/1984` are
  unreachable from the booth. CV is reached at `100.107.51.72` over Tailscale.
  `AuthController.cpp:47` still defaults `WT_CV_URL` to the lab LAN, so a guard's
  sign-in screen offers an unreachable server. Handled in this station's
  `warden.conf`; **worth deciding centrally before station #2.** Cleared as a
  non-issue: CV derives serving URLs from the request host, so `rtsp_url`/`hls_url`/
  `snapshot_url` come back tailnet-addressed and reachable.
- **🔴→🟢 D5 (PR #2, the important one): the GUI-thread watchdog counts SYSTEM-SUSPEND
  time as a hang and aborts the app on every wake.** The station crashed on its own
  58 min after install: `[WT-HANG] GUI thread unresponsive for 2947s (watchdog 60s)`
  against a **measured 2943.8 s S3 suspend** (Power-Troubleshooter id 1: slept
  13:03:24.849Z, resumed 13:52:28.680Z). The GUI thread was never wedged — the whole
  process was frozen by the OS. `src/main.cpp:293` already claimed the protection
  ("CLOCK_MONOTONIC pauses across suspend on Linux") but the Windows branch used
  **`GetTickCount64()`, which is biased and counts sleep**. Fixed with
  `QueryUnbiasedInterruptTime`; Windows-only lines, Linux build cannot be affected.
  **Not compile-verified — the station has no MSVC/Qt toolchain; CI on the PR is the
  first build, so don't merge red.** Warden restarts the app so a guard sees a
  flicker, but **every wake would mint a bogus crash bundle** once the token is in,
  and poison CW-19's heartbeat with unreal restart churn.
  **Station mitigated meanwhile:** this box was on the stock balanced scheme and
  **suspended itself after ~50 min idle** — a guard wall that stops watching, which
  is a fault on its own. `standby-timeout` and `hibernate-timeout` are now `0` on AC
  and DC (display blanking left at 5 min — it wakes on input, never freezes).
- **🟡 D6: a deliberate `abort()` on Windows is filed as memory corruption.** Warden
  recorded `trigger: exception-c0000409` = `STATUS_STACK_BUFFER_OVERRUN`, because the
  MSVC CRT implements `abort()` via `__fastfail`. So our own watchdog abort is
  indistinguishable in the report from a real `/GS` stack smash, and points triage at
  the most alarming possible cause. Warden should classify a `[WT-HANG]` tail as a
  hang. `warden/warden.py` = shared → PR owed.
- **🟡 D7: the minidump was written but the bundle denies it and omits it.** Manifest
  says `minidump_written:false` while a valid **38,590,869-byte** `MDMP` sits in the
  crash dir at the crash timestamp — Warden sealed the manifest while WER was still
  writing 38 MB. **CV would receive "no dump" and no dump.** Needs a settle/rescan
  before sealing. Shared → PR owed.
- **🔴→🟢 D8: ANY pull request silently replaced the release stations install from.**
  The *"Publish rolling windows-latest release"* step in `.github/workflows/windows.yml`
  had **no `if:`**, and the workflow triggers on `pull_request` too — where `GITHUB_SHA`
  is the synthetic `refs/pull/N/merge` commit. Verified: after PR #2's build,
  `windows-latest` read *"Rolling CI build of `cee525d7`"* = *"Merge `63136f9a` into
  `8b6c38d3`"*, **reachable from no branch**, while still titled "Windows CI build
  (latest main)". So `gh release download windows-latest` served **unmerged PR code**,
  and `--cleanup-tag` destroyed the prior tag each pass. CLAUDE.md's clobber warning
  named CI vs `build-local -Publish`; **PR builds were a third clobberer nobody knew
  about.** Fixed: publish now requires `event_name == 'push' && ref ==
  'refs/heads/main'`. The versioned `v*` release job was already correctly gated.
  Note: merging PR #2 does not itself refresh a stale `windows-latest` — whatever
  pushes to main next does.
- **D1 justified itself within the hour:** `c0000409` is a fast-fail that bypasses
  `SetUnhandledExceptionFilter`, so the in-app handler wrote nothing — WER LocalDumps
  was the *only* mechanism that could capture this crash, and until this morning it
  was armed in a hive WER never reads.
- **Open on this box:** the CV station token is still with the operator and NOT in
  `warden.conf` — Warden reports `token=MISSING` and keeps heartbeats/uploads off,
  honestly. Until it lands, `/admin/crash-reports` is blind to this station.
- Defect detail: [`docs/perf/2026-08-07-win-station-bringup-defects.md`](perf/2026-08-07-win-station-bringup-defects.md).
  CV reply with the iGPU numbers: `docs/letters/2026-08-07-station-wt-sm-vnutri-01.reply2.md`.
- Remaining Windows port work is unchanged: eyes-on playback/export, DPI and
  sleep/resume, overnight soak, the W5 acceptance matrix.

## Current status (2026-07-27, night) — merged cells on the Live wall (operator feature request)

Shift+drag across wall tiles → merge into one big tile (e.g. 4×1×1 → one 2×2 for
the entrance camera). Excel/iVMS grammar chosen after an industry survey
(select-then-merge over Nx-style corner-drag; **modifier-gated so plain drag stays
reserved for future drag-swap** — operator's call). Anchor (drag-start) camera
fills the region and auto-promotes to HD within the transcode cap; displaced
cameras reflow honestly; swallow-rule for overlapping merges; Split via hover
action / M / Ctrl+click; floating pill with honest hints (never a silent no-op);
footer hint for discoverability. Spans persist per (group, layout) — Saved Views
and the CW-05 crash-restore carry them for free — and the grid dims are CAPTURED
from the auto-fit net at first merge, so a merge means what it meant on screen.
Renders on the existing fixed-net path (manual x/y/w/h — no delegate rebuilds, the
green-wall rule holds). Self-test `WT_MERGE_TEST=seed|verify` PASS ×2 processes
(11 assertions incl. anchor-camera continuity + slot math); screenshot-verified
(13 slots, `1–13 of 34`, paging correct); TABTEST/RESTTEST green; RU strings 0
unfinished. Phase 2 (playback wall = server composite) filed as
`docs/letters/2026-07-27-wall-composite-cell-spans.md` — not blocking.

## Current status (2026-07-27, late) — heartbeat CLOSED both sides; CW-13 decided; endurance GREEN

- **CW-15 endurance:** 24 h under Warden, GREEN all gates (report
  `docs/perf/2026-07-27-warden-endurance-cw15.md`); surfaced + same-day-fixed 3
  defects (idle-age cliff → hourly heartbeat re-save; loop-marker leak → folded
  markers filed as evidence; offline-thumb warning storm → 15 s backoff).
- **CW-19 dead-man heartbeat:** CV built the server side unprompted (contract
  frozen, migration 0062, 7 Prometheus rules); client half shipped same-day
  (Warden 1.1.0: intent-carrying `app_state`, final `warden_stopping` beat,
  shutdown-intent marker on `Window.onClosing`, `backend_unreachable_since`).
  Live handshake: first beat armed monitoring; deliberate stop **quiet**;
  kill -9 with the wall up **paged at exactly +10 min**; and the resolve window
  **exposed a real bug in CV's `expected` logic** (killed Warden froze
  `app_state=running` forever) — their fix `69cc2fe`, their words: "my own live
  testing missed this and yours caught it." §3 done-list items 1–2 closed.
- **CW-13 alarm channel:** closed by CV's decision — the channel IS the server
  (Prometheus→Alertmanager→ntfy); `ALARM_CMD` ships default-empty as a per-site
  escalation hook. Every on-box channel a guard could perceive was already
  forbidden by rule 1 ("the guard must never be the detector").
- **`minidump_written`** added to the station block (Windows analogue of
  `cores_available`), collector consumes `.dmp`s like markers; fake-.dmp verified.
- **Next per agreed sequence:** Windows leg CW-16…18 (identity formula +
  Scheduler resurrection pattern already specced in the reply letter) → CW-22
  installer → CW-20 secret. Owed to CV from the operator: batch-install size,
  target fleet size. Owed on this box: `sudo warden/setup-root.sh` for the first
  core-carrying bundle.

## Current status (2026-07-26) — Warden v1 LIVE on Linux: CW-01…CW-12 done, first real bundles in CV's store

The "oops it crashed, just restart it" era is over. Built and verified today
(plan: `docs/plans/warden-build-plan.md`; contract letters:
`docs/letters/2026-07-26-client-crash-report-ingest*.md`, frozen same day
across 4 rounds with CV — endpoints deployed their side, migration 0060):

- **In-app half (frozen at install):** CW-01 flight recorder (rotating log tee,
  SIGKILL-durable — already caught lines a killed pipe lost); CW-02
  modules/BuildID snapshots (offline symbolization — born from hand-symbolizing
  the 07-25 P0); CW-03 async-signal-safe crash marker w/ pre-minted report_id;
  CW-04 Windows minidump (compile-guarded, VM validation = CW-18); CW-05
  view-state persistence (restart lands the guard where they were; seed/verify
  self-test, kill −9 durable); CW-08 GUI-thread watchdog (60 s → abort → marked
  crash — a frozen wall must die loudly, never lie).
- **Warden (`warden/`):** parent-supervisor (restart 1→60 s backoff), collector
  (boot replay, token scrub, core cap), reply4 minting policy (3 singles →
  restart-loop; quiet-close bug found+fixed), two-PUT uploader with the full §4
  code table, USB export/reimport, systemd unit + install scripts.
- **Chaos-verified against the real pilot store (its first-ever uploads):**
  sigsegv, markerless sigkill (unknown-trigger flagged, by design),
  restart-loop open at death #4, SIGSTOP → hang-watchdog, manifest re-PUT →
  server `manifest_revisions=2`, stored-skip dedup ("bundle already held", 0
  bytes resent), clean stop → no report. Admin read side lists 5 reports, all
  `stored`.
- **Open:** CW-13 alarms blocked on the operator channel choice; CW-14/15
  remaining scope (reboot-mid-collection, ≥24 h endurance); Windows leg
  CW-16…18; heartbeat letter CW-19 after v1 bake; shipping secret CW-20 at
  installer-cut.

## Current status (2026-07-25, evening) — 🔴→🟢 P0: image-provider double-completion (reader-thread SIGSEGV)

- **Symptom:** SIGSEGV after 9.5 h uptime, RSS 267 MB (so not OOM), backtrace
  `QQuickPixmapReader::run` → `QQuickPixmapReader::asyncResponseFinished` →
  `QObject::deleteLater`. Not the scene graph — the **async image-provider**
  thread (`CvImageProvider`, every camera thumbnail and event still).
- **Root cause:** `CvImageResponse` could emit `finished()` more than once.
  `asyncResponseFinished()` runs `response->deleteLater()` **unconditionally**
  (qquickpixmapcache.cpp:766, verified in our own Qt tree), so emission #1 hands
  the object to Qt for deletion and emission #2 is delivered to a sender Qt has
  already deleted → dereference → crash. The narrow window that produced it: a
  non-atomic `m_cancelled` read in the governed-snapshot dequeuer racing
  `cancel()` on the reader thread, which let a queued `start()` complete a job
  that `cancel()` had already completed. Two further latent faults on the same
  three lines: `cancel()` emitted `finished()` **synchronously on the pixmap-reader
  thread from inside `processJobs()` while it holds that reader's mutex** — a
  recursive lock of a non-recursive `QMutex` (`quick_pixmap_cache_threaded_download`
  is on in this build) — and it called `m_reply->abort()` on a GUI-thread
  `QNetworkReply` from that same foreign thread.
- **Fix (`CvImageProvider`):** every exit path goes through a one-shot `finish()`
  latch; `cancel()` only sets an **atomic** flag and hops to the response's own
  thread; the destructor `disconnect()`s the reply before aborting (abort emits
  `finished()` synchronously, which otherwise re-entered our lambda from inside
  the destructor) and can no longer strand a governed-extractor slot.
- **Evidence:** an 11.5 min churn soak (`WT_GUARD_SOAK` + 700 ms thumbnail
  refresh, saturating and cancelling the 2-slot `/snapshot` queue) suppressed
  **318 duplicate completions** with zero crashes — i.e. the double-completion
  was happening constantly, and only the rare interleaving reached the freed
  pointer. After short-circuiting the benign post-completion cancel, the same
  soak logs **0** duplicates, so `[EVIMG] duplicate finish suppressed` is now a
  genuine regression alarm rather than routine noise.

## Current status (2026-07-25) — shell chrome: real window buttons + view tabs

Two operator-reported shell gaps, both closed:

- **Window buttons (minimize / maximize / close).** The app had none: under
  GNOME/Wayland the host chrome is Qt's own `bradient` decoration, which paints a
  title strip with no usable buttons. The window is now **frameless** and draws the
  handoff's own 36px title bar (`qml/TitleBar.qml`: 70px spacer · `WATCHTOWER`
  wordmark · current view in ink-2 · three 14px round buttons, close in `--bad`,
  glyphs at 0.5 opacity — exactly the design's `TitleBar`, which had been skipped as
  "replaced by host"). Move/resize go back to the compositor via
  `startSystemMove()`/`startSystemResize()`; the move grab starts past a 3px
  threshold so double-click-to-maximize still works, and `resizeFrame` lays 4px
  edge / 14px corner grips around the shell. Verified: buttons render (glyph crop),
  the login gate stops below the bar so a signed-out window is still closable.

- **"Open in new tab" was a lie.** The tile action existed but opened the same
  full-screen detail as "Open" and left nothing behind — indistinguishable, and a
  silent no-op by our own rule. There is now a **view-tab strip** (`qml/TabStrip.qml`)
  above the content: `tabs[0]` is the main tab (the nav-rail section, which may hold a
  camera opened *in place*), `tabs[1..]` are cameras opened in new tabs. Non-obstructive
  by construction — the strip does not exist until a camera tab does, and hides during
  playback and in fullscreen. Per-tab live status dot + IP-preserving middle elision
  (fleet names all end in the IP), close ×/middle-click, Ctrl+W · Ctrl+Tab ·
  Ctrl+Shift+Tab. **Only the active tab renders**, so N tabs are never N pipelines;
  `activateTab` re-resolves the camera against `CameraModel` so a tab opened minutes
  ago carries current status. Rail/palette/map hand-offs navigate the main tab and
  leave open tabs standing. 29-assertion self-test (`WT_TABS_TEST=1`) PASS; RU strings
  shipped; screenshot-verified on the wall and on a camera tab.

## Current status (2026-07-16) — PTZ/lens + audio-state surfaces shipped (honest-pending); netem harness; night-3x soak certified

- **Audio-recording state surface (SHIPPED BOTH SIDES, verified live 07-16):** CV
  shipped `audio:{supported,recording_enabled}` on /streams same day (device-derived
  via ISAPI `<Audio>` block, migration 0055, online-cams-only rollout) — real-mode
  verified: .50/.67 muted ears, .201 earless, offline fleet unknown/earless. Thread
  closed (`…audio-recording-fields.reply.reply.md`). Original scope: ear icon
  on wall tiles + camera detail when a camera records audio; struck-through ear when
  supported-but-disabled; NO ear when unsupported/unknown (honest absence — zero audio
  fields exist backend-side today, verified against OpenAPI + /streams). Parses
  `audio:{supported,recording_enabled}` forward-compatibly at both payload sites
  (fetch + 15 s status poll with per-row change signals); detail adds an "Audio" status
  row + tooltips; RU strings; `WT_AUDIO_DEMO` dev states. Reused the mock-era
  `hasAudio` field/role. Letter: `docs/letters/2026-07-16-audio-recording-fields.md`.
  Both states screenshot-verified (wall + .50 detail).

- **PTZ / motorized-lens control (client side COMPLETE, backend endpoint pending):**
  maximized live view gains a PTZ button on capable hardware only (gate from the
  backend-reported model: 31×DS-I456Z(B) motorized-lens fleet get it; fixed
  DS-I402(D)/.201 + DS-I259M(C)/.50 correctly do not). Panel: pan/tilt pad (full-PTZ
  class only), zoom/focus hold-to-move rows, autofocus, keyboard drive, and the
  **single "Restore defaults" button** (home preset / lens default + AF). `PtzClient`
  probes `GET /cameras/{id}/ptz` — today's 404 renders an honest pending banner;
  the panel activates on CV's deploy with no client release. Spec letter:
  `docs/letters/2026-07-16-ptz-lens-control-endpoint.md`. Dev pilots: `WT_DETAIL_IP`,
  `WT_PTZ_OPEN`, `WT_PTZ_DEMO` (mock caps for panel verification). All three panel
  states screenshot-verified; RU strings added. **UPDATE same day: CV SHIPPED all
  five endpoints to the exact contract (25 tests; per-camera serialize with 409,
  8 s server max-move backstop, pooled digest client + NEW auth-failure cooldown,
  423 verbatim, audit rows, RBAC, `PTZ_CONTROL_ENABLED` flag→501) and DEPLOYED —
  probe returns `lens` for Z-models; panel READY state live-verified in real mode
  on .106. Remaining: hardware walk-test when the Z fleet returns (CV flags
  autofocus/reset ISAPI shapes as best-effort until then; lens "wide" approximated
  via bounded zoom-out).**
  **CLOSED 2026-08-14 — the hardware walk-test is done. The operator verified the
  PTZ/lens functions on real Z-model cameras and reports them all working.** This
  closes the last open item on PTZ: the client panel, CV's five endpoints, and the
  optics now agree end to end on real hardware. The final client-side defect was a
  click producing move+stop 61 ms apart (flight-recorder measured) — imperceptible
  zoom travel next to a very visible autofocus hunt, which is why it read as
  "zoom refocuses instead of zooming"; `HoldBtn.minStepMs = 400` in
  `qml/PtzPanel.qml` guarantees a visible step from a tap. Do not re-litigate this
  as open — it was verified by the operator on the fleet, not inferred from code.
- **netem network-impairment harness** (`tools/netem-harness/`): port-scoped lo
  shaping (8000/8554/1984 both directions via docker-proxy path, verified), 13
  literature-grounded profiles, matrix runner reusing the soak gates, measured-RTT
  verify per row, operator-session guard, EXIT-trap teardown. Needs one-time
  `sudo tools/netem-harness/setup-root.sh` (tc-only sudoers rule) for impaired rows;
  baseline row runs unprivileged. Footage discovery built in (`discover-plan.py`)
  after hardcoded days rotted same-day.
- **Night-3x soak (07-14, `docs/perf/2026-07-14-night-3x-soak.md`):** all three soak
  variants 12 h in parallel on patched Qt — 0 crashes/hangs/wedges; found+fixed the
  stale seek-watch hijack + unbounded mislanded recovery (751e656); 853a234 validated
  at volume; first 12 h endurance certification of the patched-Qt default runtime.
- **🟢 CLOSED — backend incident 2026-07-16 (recordings wipe):** root cause was the
  recorder's emergency disk-pressure evictor measuring the WRONG DISK (root SSD at
  96%, not the 3.6 TB video disk) — it chased an unreachable free-space target for
  ~9 h, eating the archive oldest-first (catalog rows unconditionally; ~269 GB of
  raw bytes survived but unattributable). Operator decision: **loss is final**;
  history grows from 2026-07-16 03:59Z. CV fix `4666fc4` (right disk, 24 h min-age
  floor, no-progress abort) + FIVE independent deletion defenses (API floor, DB
  CHECK constraints, recorder clamp, single audited chokepoint, hourly deletion
  circuit breaker that latches + pages). Serve path re-verified healthy both sides.
  Standing watch: report if `no_recording` disagrees with coverage >1 poll cycle.
  Thread: `…-recordings-unplayable-data-loss.md` + `.reply.md` + `.reply2.md`.
  (coverage-tz letter remains its own OPEN thread — today's footage can't
  discriminate it while UTC and MSK agree on the date; tonight's will.)
- (superseded incident note kept for the record below)
- **🔴 Backend incident 2026-07-16 (~22:00 UTC 07-15): ALL playback blind.** Diagnosed
  past coverage into sessions: (1) pre-07-15 recordings deleted (coverage empty in UTC,
  sessions serve `availability:no_recording` for .201 07-10 etc.); (2) even the FRESH
  .67/.50 footage the UTC index lists (07-15 21:29–21:55Z) serves `no_recording` —
  index/data disagree both ways; (3) seaweed hot+warm volumes were VACUUMING tonight
  (deletion compaction, vol 1990 hot 19:31Z, 575/726 warm 22:09Z); (4) no container
  restarts, /health/storage 200 — NOT the storage-agent re-push signature, nothing
  restarted from our side. Two letters filed with verbatim repro:
  `2026-07-16-recordings-unplayable-data-loss.md` (URGENT) and
  `2026-07-16-coverage-tz-empty.md` (non-UTC tz always returns days:[] — operator
  calendar blind; found during, may share root). netem matrix baseline is BLOCKED on
  backend recovery (harness + footage discovery are ready and committed).

## Current status (2026-07-12) — Qt FFmpeg-backend crash OWNED end-to-end (patched binaries + proof)

- **Patched Qt is now the DEFAULT runtime** (operator decision, same day): plain `./run.sh` resolves
  `~/Qt/6.12.0-patched-beta1` when present (BuildID-verified at launch review), falls back to the SDK
  with a loud notice elsewhere; `WT_QT_PREFIX` still overrides. Rollback = `WT_QT_PREFIX=~/Qt/6.12.0/gcc_64 ./run.sh`.
- **Thumbnails wired (consumers #1+#2 live)** — CV `/review/thumbnails` v1 (green light, `cf0716a`): a
  24-tile keyframe **day-overview strip** (one sprite, once per day-open, session-cached, click-to-seek,
  suppressed on all-gap days) + a **scrubber hover preview** (1 keyframe tile ±30s, debounced/cached).
  Decoded once in C++, served via `image://thumbtile`; per-tile x/width honored (mixed aspect), honest
  gap glyphs. **Badge trap CV flagged FIXED** (`7732e50`): reachability now keys off `status` not
  `recording` — offline motion-enrolled cams (.106/.120) no longer wear healthy ARMED (verified: 31
  offline tiles read `REC ? · 2d`).
- **Thumbnail-endpoint spec answered** (`docs/letters/2026-07-12-thumbnail-endpoint-spec-reply.md`):
  frame-strip case solved client-side (two-tier cache) → CV's one-decode-N-frames variant parked;
  v1 adopted for minutes-apart consumers (scrubber hover previews + 24-tile day-overview, keyframe
  precision), sprites requested for count=24 only.

- **The poison-frame SIGSEGV is fixed at the Qt source, not just guarded.** Root cause proven:
  `QFFmpegVideoBuffer::map()` commits `m_swFrame` before `av_hwframe_transfer_data()`, so after one
  transfer failure every later map returns fake-success MapData (planeCount>0, null planes) and a
  single `toImage()` self-crashes (texture map + CPU-fallback map). Internal Qt patch series
  `third_party/qt-patches/6.12/` (0001 transactional commit + retry restore; 0002 map rejects invalid
  planes; 0003 RHI offscreen-frame balance; 0004 vaSyncSurface check; 0005 corrupt-flag surfacing).
- **Patched Qt 6.12 overlay built from source, root-free** (`tools/build-patched-qt/`: dev sysroot via
  apt-get download, v6.12.0-beta1 across qtbase/shadertools/declarative/wayland/multimedia, self-contained
  ffmpeg+stub bundle). **Decisive proof** (real Wayland/VA-API, one forced transfer failure): unpatched
  SDK → SIGSEGV; patched → CLEAN, transfer re-attempted next frame. Watchtower confirmed **RUNNING ON
  PATCHED ARTIFACTS** (runtime-evidence.sh, all BuildIDs match). ASan/UBSan clean on the guard path.
- App hardening retained (pre-map guard all-planes, state-driven decoder recreation, storm damper as
  load-only). Deploy: `WT_QT_PREFIX=~/Qt/6.12.0-patched-beta1 ./run.sh`; rollback: plain `./run.sh`.
  Full delivery report: [`docs/qt-upstream/2026-07-12-delivery-report.md`](qt-upstream/2026-07-12-delivery-report.md).

## Current status (2026-07-11) — extended filmstrip soak: 9 fix-rounds, <1 s gate holds

- **WT_FSOAK extended soak (operator-ordered)** — 2 isolated instances, ~2200+ cycles over 2 days
  across .201/.67 (current, live-edge) + .106/.120/.101/.110 (warm archives): **0 unrecovered
  crashes, 0 GUI freezes; filmstrip <1 s on every current-footage cycle** (p50 ~715 ms); the only
  >1 s classes are server-cold (first touch of a cold archive region; fragment-click deep into a
  fresh session — cut 5.7 s → ~2-3 s via an adaptive freeze-watchdog). One delivery-thread Qt
  converter crash (poison-frame storm) caught under gdb → **poison latch**; plus live-edge
  behind-fill clamp, harvester pre-arm + instant center tile, pts-0 legitimacy, VFR chain floor,
  NaN-seek guards, far-seek empty retry, honest stall clock + stall nudge, adaptive seekWatch.
  Full chronicle: [`docs/perf/2026-07-10-fsoak-filmstrip-soak.md`](perf/2026-07-10-fsoak-filmstrip-soak.md).
  Soak continues (harness: `WT_FSOAK`/`WT_FSOAK_PLAN`; runner `~/watchtower-soak/fsoak-2026-07-10/`).

## Current status (2026-07-10) — 🔴→🟢 P0 frame-mode segfault RESOLVED; live-events/status burst

- **P0 SIGSEGV under frame-mode session churn — root-caused and fixed same day.** Three stacked
  faults behind one report (blank filmstrip on today's gappy footage → freezes on fragment clicks →
  crash): (1) frame-level use-after-free — capture taps queued raw `QVideoFrame`s to the GUI thread
  and session swaps freed the decoder's VA-API context before delivery (`toImage()` → SIGSEGV,
  caught under gdb) → taps now convert at emission via `Qt::DirectConnection`; (2) harvester issued
  raw seeks across kept discontinuities + the 4a14650 `source=""` churn pattern → churn-safe
  lifecycle + `crossesDisc` bridge; (3) live-edge "at end" park starved behind-fill → blank strip on
  any today-footage → eval falls through to history fill. Harvest frames are no longer rendered at
  all (`FrameCache.harvestSink`). New `WT_CHURNTEST` harness: pre-fix crash in <1 min; post-fix
  20/20 day-switches + pokes clean, 146 corrupt packets absorbed, strip populated at the live edge.
  Full postmortem: [`docs/perf/2026-07-10-frame-mode-churn-segfault.md`](perf/2026-07-10-frame-mode-churn-segfault.md).
- **Live Events feed rebuilt to the CV thumbnails spec** — real mid-incident stills
  (`/events/{id}/snapshot?pos=mid`) through a 2-concurrent client gate (0×503 measured), shimmer/glyph
  placeholders (never black), IP-first camera line, one row per incident, 15 s refresh.
- **Events screen ↔ Live sidebar now in sync** — incident model everywhere
  (`exclude_types=motion_not_ready,motion_started,motion_ended`), 10 s `refreshIncremental()`
  top-merge (prepend new, patch triage in place — no model resets, no thumbnail refetch).
- **Authoritative status-badge timers** — CV shipped `status_since`/`recording_since`/`last_seen_at`
  same-day (letter + reply closed); badges prefer backend stamps (`LIVE · 9d` matches to the minute),
  observed-onset fallback kept for the ≤30 s `recording_since` null window. Badge-timer toggle in
  Preferences (default ON); clickable "Last motion" sidebar row.
- Windows CI: build job green on the full tree; artifact upload still sheds against GitHub's stale
  quota counter after the 6.5 GB purge (`retention-days: 3` now set) — next runs should clear.

## Current status (2026-07-08 evening) — outage resolved; review-UX burst (filmstrip frame mode, ARMED freshness, calendar refresh, VIEW ISSUE fix)

- **Frame-by-frame FILMSTRIP MODE** (`c8d7023`): `F` in playback swaps the toolbar row for a
  big-thumbnail strip (current frame centered/accented, per-frame `.mmm` labels; thumbs served from
  the decoded-frame cache via `image://fcache`, store now mutex-guarded); `←/→` tap = 1 frame, HELD =
  slow→fast shuttle ramp (400→66 ms); thumb click jumps; veiled ~0.7 s warmup pre-fills; F/Esc exits.
  `WT_FRAME_MODE` dev hook. Verified live on `.201`'s same-hour footage; Windows CI green.
- **ARMED badge shows motion-event freshness** (`190176f`): `ARMED · 4m/2h/3d/now`, dot pulses on a
  fresh event, amber after >24 h eventless — the "visible movement but no events" mismatch is now
  glanceable. Per-camera last-motion tracked in EventModel (motionRev counter binding — deliberately
  no row re-paging, which restarts tile RTSP). Visual proof pending a motion-armed camera.
- **Footage calendar refreshes while open** (`e7a8cd7`): 60 s quiet re-fetch (both calendars) — the
  "recording resumed but the calendar still says Jul 1" report; verified live with today's dot.
- **VIEW ISSUE tile link fixed** (`f725784`): the signal was emitted but handled nowhere; now lands on
  Health with the camera's detail panel open; hover underline + padded hit area; strip z-raised.
- **Recording outage FULLY CLOSED (07-10)** — after the clock fix (Provisioner) a 5th fault surfaced:
  `motion/arm` without `sensitivity` had left the camera at 0 (armed-but-inert; letter UPDATE 4);
  re-armed with 50 → motion chain live within seconds (event → pre-rolled recording). **Overnight
  alert-stream survival CONFIRMED 07-10** (first office entry 10:12:55Z → event + clip after ~16 idle
  hours; recorder readiness `vmd_confirmed: true`). Also shipped: **filmstrip v2** (hidden harvester
  decoder — steps are 0 ms cache repaints both ways) and the **live MOTION tile badge** (pulsing amber
  while events register; ~5 s poll latency, SSE push = CV ask). CV closed the functions thread
  (reply3): mosaic wall gated on `playback` — wired same day (`WallPlayback` calm overlay + auto-retry).
- Windows session-2 prompt for the laptop: `docs/plans/windows-port/2026-07-08-w2w3-session2.prompt.md`.

## Current status (2026-07-07/08) — RU i18n shipped; W2 core gates green on real GPU; frame-step planned

- **Russian language support shipped** (`b452783`) — EN/RU, OS-language default (`QLocale::system()`),
  live in-profile switch (Preferences → Time & language, `QQmlApplicationEngine::retranslate()`),
  `.qm` embedded via `qt_add_translations` (LinguistTools ships in BASE Qt — not an aqt module).
  ~65 chrome strings translated; remaining screens extend incrementally (`update_translations`).
  Verified: Linux screenshots both locales + Windows CI green.
- **Windows W2/W3 advanced on the laptop session** — W2 core gates GREEN on GTX 1070 (launch, d3d11
  HW decode, live pipelines, RSS bounded; `4fd72b4`); export re-encode switched to libopenh264
  (`53b6e28`); gstd3d11 decode closure bundled (`fb15f72`); W3 soak supervisor ported to PowerShell +
  smoke-green (`91a0a0f`, `56078c2`).
- **Windows session-2 (2026-07-08) on the fresh `f725784` artifact** — W2 core gates re-baselined
  GREEN; **HW decode double-confirmed at the GPU-counter level** (Video-Decode engine busy, not just
  the log). **Frame-stepping verified on d3d11** (HEVC 1440p, `[STEPT] wrongWay=0 fails=0 back
  p50=0ms` — PTS valid, hot back-cache, VA-API parity). **RU i18n verified on Windows** (EN OS-default;
  RU `.qm` loads/renders/persists on the MSVC build). **Found + fixed a real export regression**: the
  CI bundle moved to FFmpeg 7.1.3, whose filtergraph parser rejects the single-`\:` drive-letter escape
  `ClipTranscoder::escFilterPath` emitted → every compress/burn overlay export silently failed;
  fixed to the canonical `\\:` (`bacfe48`, measured before/after on-box, CI green; a drawer re-test on
  the rebuilt artifact is still owed). **W3 overnight soak GREEN** — two clean supervised runs (7 h +
  8 h, 0 crashes / 0 hangs, RSS bounded, procdump never fired; matches the Linux bar). **Filmstrip
  mode (`F`, `c8d7023`) functionally verified** on `.201`'s fresh 07-08 HEVC 1440p footage (frame mode
  enters, FrameStepper + FrameCache step the footage; clean strip screenshot blocked only by
  remote-session input/Tailscale-veil, not a defect). **Soak tooling fix** (`b70d1e0`): the export
  sidecar re-logged undeletable 0-byte exports every sweep (474 k lines for ~520 clips) — now logs each
  clip once, on actual removal. Results: `docs/perf/2026-07-08-win-w2w3-session2-results.md`,
  `-frame-step-windows.md`, `-win-export-drawtext-ffmpeg71.md`. Remaining: export drawer re-test
  post-rebuild, Win11 box + mixed-DPI/sleep-resume eyes-on, W5 matrix.
- **`/streams` `functions.playback` split wired same-day** (CV migration 0052): playback/timeline/export
  now gate on the new `playback` key (`playbackEnabled`, fail-safe true); live tiles stay on `live_view`.
  Reply letter `docs/letters/2026-06-16-request-function-state-in-streams.reply2.md`. Verified + Windows CI green.
- **Frame-by-frame stepping researched + planned** — deep-research (25 sources, 23 verified claims):
  [`docs/research/2026-07-07-frame-by-frame-playback-vms.md`](research/2026-07-07-frame-by-frame-playback-vms.md);
  implementation plan (P0 spike → P4, ~3–4 days, on the existing QMediaPlayer stack — key constraint:
  paused seeks render nothing → play-flush primitive; TS seek imprecision → verify-after-step):
  [`docs/plans/2026-07-08-frame-step-plan.md`](plans/2026-07-08-frame-step-plan.md). **P0 spike DONE
  same day (GO):** PTS 100% valid; **paused seeks RENDER on Qt 6.12** (EvHeroPlayer's "render nothing"
  note is stale) → backward step = paused seek + PTS verify, no play/pause cycle; no keyframe snapping;
  GOP 30–60f; cameras are TRUE VFR (25/50/100 ms deltas) so PTS-exact targets are the main path.
  Findings: [`docs/perf/2026-07-08-frame-step-spike.md`](perf/2026-07-08-frame-step-spike.md).
  **P1 DONE** (`3985458`): FrameStepper + |◀ ▶| transport buttons + keys (,/./arrows/Space) + RU
  i18n; forward 100/100 exact. **P2 DONE**: FrameCache decoded-frame cache (hot back-step
  ~3400→~0 ms, ≥95 % cache hits), window-edge/disc fallbacks, alternating soaks green on both
  codecs (0 wrong-way in 260 steps) — [`docs/perf/2026-07-08-frame-step-p2-soak.md`](perf/2026-07-08-frame-step-p2-soak.md).
  **P3 DONE** (¼×/½× speeds, Shift+arrows ±5f, .mmm paused readout, freeze-frame veil). **P4 DONE**
  (stepper on the events hero; playback soak regression green). Feature CODE-COMPLETE; manual passes
  open: veil eyes-on, 5-min paused session, hero step on real footage (blocked by the recording outage).
- **🟢 RESOLVED 07-08 ~14:03 UTC — the 7-day recording outage is OVER; both cameras recording**
  (`.67` H.264 1080p continuous, `.201` HEVC 1440p via fail-safe). Four stacked faults, all identified
  (letter UPDATE 2+3: [`docs/letters/2026-07-08-recording-outage-fleetwide-since-jul-1.md`](letters/2026-07-08-recording-outage-fleetwide-since-jul-1.md)):
  (1) `.67` registry password was wrong → operator factory-reset + re-activated with <REDACTED-CRED>
  (2) recorder's continuous engine only reconciles at STARTUP → `docker restart recorder-service`
  engaged `.67`; (3) `.201` motion control vetoed by `camera_clock_drift` (~3 s, camera-side; server
  NTP-true) — silent except a 3/sec log flood; (4) the fail-safe-continuous path excluded `.201`
  *because* it was armed → we disarmed it (workaround; CV API backup saved) → fail-safe records.
  **Pending: operator fixes `.201`'s clock (camera web UI) → re-arm motion (one API call).**
  CV asks filed: runtime continuous reconcile, clock-drift as health state, fail-safe for vetoed
  cameras, inventory hygiene (31 ghost cameras spawn No-route ffmpeg storms on every recorder boot).
- Open with CV: go2rtc ask-4 reply (needs product steer: `[MEMTEL]` exposure + demand-history UI);
  optional letter on CV's `/live` page black-tiles-with-valid-go2rtc-frames finding; `.67` camera
  still needs its operator power-cycle (login lockout).

## Current status (2026-07-06) — Linux client hardened; **Windows port in progress (W0/W1/W4 done, W2/W3 need a Windows GPU box)**

**Windows 10/11 port — same repo, Qt 6.12 msvc2022_64 (MANDATORY; 6.8.3 is Linux-only fallback).**
Canonical plan + phase prompts: [`docs/plans/2026-07-04-windows-port-plan.md`](plans/2026-07-04-windows-port-plan.md)
and `docs/plans/windows-port/W0..W5`. **To continue on a Windows laptop, start with
[`docs/plans/windows-port/START-HERE-WINDOWS.md`](plans/windows-port/START-HERE-WINDOWS.md).**
- **W0 done** — source made MSVC-compilable (`src/main.cpp`, `src/models/MemTelemetry.cpp` `Q_OS_*`-guarded;
  PSAPI RSS + SEH crash filter; `windows` CMake preset; `watchtower.ico`).
- **W1 done** — **`.github/workflows/windows.yml` builds `watchtower.exe` + NSIS installer on every push**
  (`windows-2022`, Qt 6.12 + GStreamer 1.26.11), artifacts `watchtower-portable` + `watchtower-setup`.
  Proved the MSVC compile/link. (4 CI fixes: aqt git-master for Qt 6.12 layout; GStreamer `/a` extract;
  Qt-owns-manifest; `gst*.dll` plugin names.)
- **W4 done** — per-user installer + LGPL notices/SOURCES + CI compliance check; **signing = unsigned
  (internal)**, `packaging/windows/SIGNING.md`.
- **W2 + W3 PENDING — need a physical Win10/11 GPU box on the LAN.** Prep done: runtime audit (decode is
  decodebin-rank-based → auto d3d11, no code change; fixed ClipTranscoder Linux fonts+escaping; FLAGGED:
  compress/burn uses `libx264`, absent from the LGPL ffmpeg → switch to `h264_mf`/`libopenh264` on-box),
  turnkey `packaging/windows/w2-bringup.ps1` + `docs/plans/windows-port/W2-RUNBOOK.md`. W5 = GPU matrix (last).

**Linux client hardening (2026-07-02–03) — shipped on Qt 6.12 (now primary, `build/`; 6.8.3 fallback `build68/`).**
- **HANG #1 root-caused + fixed** (`d81d887`): the rare "GUI wedge" was a **minutes-long QML GC on the GUI
  thread** (Qt ≥6.10), triggered by marshalling thousands of per-fragment QVariantMaps in `PlaybackClient::
  sessionReady`; fixed by shipping fragments as positional primitive rows. Validated 2.5 h, 0 wedges.
- **Far-seek coalescing** (same commit) — chaotic scrubber clicks no longer storm session re-opens
  (one in-flight open, last click wins); after-burst dead-video p90 5.8 s→0.9 s.
- **Transient-empty-manifest retry** — a fresh day-open that returns 0 fragments (backend blip) retries once
  before the "No footage" error. Backend letters: `docs/letters/2026-07-03-*`. Full write-up:
  `docs/perf/2026-07-03-night-soak-gui-wedge.prompt.md`. Earlier crash + TTFF fixes: `docs/perf/2026-07-02-*`.

## Current status (2026-06-25) — 🔴→🟢 P0 RESOLVED: the recurring "Terminated" crash was a Qt 6.4.2 VideoOutput memory leak; fixed by building on Qt 6.8.3 (verified leak-free)

**P0 — live-video memory leak / OOM crash (RESOLVED via Qt upgrade).** The operator's repeated
"Terminated" was earlyoom SIGTERM-ing watchtower at ~9 GB RSS — a per-frame leak in Qt 6.4.2's
QtMultimedia `VideoOutput` (~260 MB/s on a 9-tile wall → OOM in ~30 s). Bisected and proven to be Qt,
not our code (leaks on all RHIs + both video sources; no client render path avoids it on 6.4.2).
**Fix: build/run on Qt 6.8.3** (installed user-space at `~/Qt/6.8.3`, launched via `./run-watchtower.sh`)
— app source unchanged; **verified leak-free** (cap-9 wall, 90 s, RSS flat ~950 MB). 6.8.3 also fixes
the earlier Qt 6.4.2 GridLayout maximize/minimize SIGSEGV. See DEVELOPMENT.md → Build / Gotchas.

## Earlier (2026-06-25) — Q-CV6 FIXED (CV `b002010`, verified both sides); 3 dead-sub cameras flagged (likely == our green-tile/snapshot symptoms)

All P1–P6 complete; this section is the live edge. **Relaunch `./build/watchtower` to run HEAD.**

**Export quality + client-side compression — shipped + verified; one open backend bug (aged-window Standard export still delivers 1080p — Q-CV6, CV's court).**
- Export drawer: **Quality** (High = HEVC 1440p main original / Standard = H.264 sub) with
  grey-out+tooltip when the original has aged out; a **Compression** ladder (Original/1080p/720p/480p,
  ≥-source greyed); functional **overlay burn-in** (default off = pristine).
- CV (migration `0045`): `CreateExportRequest` takes `hevc_capable`; fragments carry `stream_type`
  (`main`/`sub`) = authoritative rendition (orthogonal to `tier`). Verified: High→2560×1440,
  Standard→1920×1080 (720p sub at the 1080p profile). High over an aged span → 422 (surfaced).
- **`ClipTranscoder`** (`src/models/ClipTranscoder.{h,cpp}`): local ffmpeg/libx264 — downscale ladder +
  burned-in camera caption and **per-frame footage wall-clock** (`drawtext %{pts:localtime:…}`). Wired
  via `PlaybackClient::createExport(…, hevcCapable, post{height,timestamp,name,label,startEpochMs,durationMs})`.
  **A2 (server overlay burn-in) retired** — overlays are client-side now.
- **DONE (2026-06-21):** CV shipped the native-720p Standard rendition (`h264-main-720p`; reply5,
  Q-CV5/Q-W1/Q-W2 all yes). Client label flipped — drawer reads **"Standard · 720p"** (`sourceHeight`
  1080→720), no-upscale ladder now offers Original + 480p. **Verified live from our side:** a
  fresh-window Standard export reports `resolution 1280x720` (~747 KB/8 s), and the playback manifest
  shows `delivery_profile h264-main-720p` for every sub fragment. **Q-CV6 — FIXED (CV `b002010`, reply9; verified
  both sides 2026-06-25).** Root cause was *not* a stale rendition or window age: that 1080p "clip" was a
  **black-fill** — cam `…ff9a`'s **sub-stream stopped recording 06-11**, so a Standard (sub-only) export of a
  06-18 window had an all-`no_recording` manifest, and the export worker black-filled the whole window at a
  hardcoded `h264-main-1080p` default → an 8.8 KB black clip mislabeled `ready`. CV now **fails honestly** when a
  window has zero footage in the selected quality. Verified from our side: Standard over `…ff9a` →
  `state=failed` (`error_msg` = "…try a High export"), no artifact; High over the same window → `ready
  2560×1440 1.18 MB`. The `error_msg` field is what our poller reads, so it surfaces verbatim.
  **Client (option 1) shipped:** the failure toast offers one-click **"Export as High instead"**
  (`PlaybackClient.retryLastExportAsHigh()` + a ToastHost callback action). Option 2 (backend
  Standard-from-main) declined — our local `ClipTranscoder` ladder already does small-720p-from-main.

  **NEW open thread — 3 dead-sub cameras (recording-side, CV investigating; likely == our green-tile/snapshot
  symptoms):** CV found `…ff9a` (sub last 06-11), `…3a0d` (06-19), `…3a4b` (06-24) recording **main but not
  sub**. `…3a0d` is the camera whose go2rtc `frame.jpeg` snapshot throws "Unsupported image format" in our
  picker, and dead subs are exactly what produce the green/stalled live tiles we've been patching. **Open
  question to CV (Q-W4): camera-side (affects our live wall + picker, which stream the sub) or recorder-side
  (recording only)?** Plus Q-W5 (ETA to restore subs) and Q-W6 (a structured `failure_reason` code so our
  option-1 trigger isn't prose-matched). Thread:
  `docs/letters/2026-06-20-export-quality-and-client-side-compression.reply{9,10}.md`.

**Other this arc:** green-wall fixes (reconciled camId-keyed `gridModel` → no tile rebuild on
poll/relayout; see DEVELOPMENT.md gotcha); brighter scrubber ruler + dated playhead watermark;
**removed the dead camera-tile bookmark** (cameras = ★ only; bookmarks are Events-only); a **layout
preset now exits the transient map-selection scope** (+ a "✕ Clear selection" chip).

**Relayout/OOM freeze — FIX SHIPPED `51f528d` (2026-06-22), awaiting live confirm.** The host froze
~20 s and the app was OOM-killed during camera-change churn (Arrange → Tap-to-change → Esc, repeated):
the shared Intel `i915` iGPU wedged on a burst of ~16 simultaneous VA-API decode-context creations,
on a box already swap-thrashing (6.9 GiB). Fix is load-spreading: a **global pipeline-build rate
limiter** (`PipelineBuildPump`, ≤1 build/120 ms; `rebuild()` no longer builds inline), **keeping grid
pipelines alive in Arrange** (no teardown/rebuild churn), and **gating the picker thumbnails** on the
picker being open. Teardown stays capped at 8 concurrent. Build-stagger verified offscreen; the freeze
itself only reproduces on the real iGPU, so **needs a live test** (Arrange/Tap cycling, layout
changes, page turns) — recommend a reboot first to clear swap. Diagnostic scripts remain on the host
(`~/freeze-watch.sh`, `~/freeze-snapshot.sh`); `sudo dmesg | grep -iE 'oom|i915|gpu hang'` would
confirm OOM vs GPU-hang. Backend asks open: only the non-blocking [Q-CV6 aged-export bug](letters/2026-06-20-export-quality-and-client-side-compression.reply8.md) (CV's court).

## What this is

A **native Ubuntu Qt6/QML/C++ surveillance VMS operator client** (not a browser app),
a client of the **cilex-vision** platform. The hard requirement is smooth GPU
decode/compositing of up to 16 live RTSP H.264/H.265 streams plus playback scrubbing.
Cameras have **no on-camera storage**; recorded footage and events come from cilex-vision.

## Phase status

| Phase | Scope | State | Key commit(s) |
|-------|-------|-------|---------------|
| P1 | Foundation + Live Monitor (16-stream wall, app shell, models) | ✅ done | (early history) |
| P2 | Single Camera Detail (S05) | ✅ done | `04abd30` |
| P3 | Playback + timeline (S06) | ✅ done | `e340c30` |
| P4 | Export + snapshots (export drawer + confirm modal) | ✅ done | `a3b567e` |
| P5 | Events + Health | ✅ done | `d1ad10f` (Health), `9d22db6` (Events) |
| P6 | Saved Views / Clips / Prefs / polish | ✅ done | all four pieces shipped |

## Done — highlights

- **Live Monitor**: 1/4/9/16 grids, paging, filters, status-first sort, tile hover actions, fullscreen. Real HW-decoded video via QtMultimedia (VA-API).
- **Single Camera Detail (S05)**, **Camera Groups (S03)**, **Preferences (snapshot folder, default stream quality)**.
- **Playback (S06)**: `PlaybackClient` + `HlsProxy` + `PlaybackScreen.qml`. Real recorded HLS from cilex-vision plays through a local auth proxy; manifest-driven timeline (footage/gap coverage), transport, zoom presets.
- **Export (P4)**: full `ExportDrawer.qml` (440px drawer + centered confirm modal) — preview, KV facts, `HH:MM:SS.mmm` range editors, options, required Purpose, gap-warning ribbon.
- **Health (P5)**: `HealthScreen.qml` — 6 stat cards over `CameraModel` counts + filtered camera table + 380px detail panel, plus a storage-subsystem status strip (`StorageHealth` → `GET /health/storage`).
- **Events (P5)**: `EventsScreen.qml` (filter pills + table + detail panel) + `EventModel` wired to the live `GET /events` feed; locally-persisted acknowledge.

## Open backlog

Prioritized — with blocked-status, owners, and what unblocks each — in
**[BACKLOG.md](BACKLOG.md)**. Backend contracts (our asks + Cilex Vision's
point-by-point responses) are in the API-requests letter. In short: every **P1**
item is backend-gated (Events pipeline B2, real export/clips metadata A1/A3/A6,
shared ack B1); the **🟢 actionable-now** items are client-side polish (theme
switching, same-group playback switch, `compact` mode toggle, event-drawer
export/filters).

## P6 progress

- ✅ **Saved Views** — `SavedViewsScreen.qml` (3-col card grid + filter pills) + `SaveViewModal.qml`. `SavedViewModel` now persists views in QSettings (restorable layout/filter/group), with `saveCurrent`/`remove`/`touch`/`toggleFavorite`; mock gated behind `WT_DEMO` (was unconditional). Card counts computed live via `CameraModel.countFiltered`. "Save current view" wired from Live Monitor + the screen; Open applies a view to the Live Monitor.
- ✅ **Preferences completion** (§9) — Workspace (Default landing: Live / saved view / group, applied on boot), Time & language (24h/12h, wired to the now-live top-bar clock + playback), Alerts (sound + desktop-notification toggles, persisted; alert-firing pipeline deferred). Settings gained `defaultLanding`/`time24h`/`alertSound`/`desktopNotifications` + a `clock()` formatter. Light/Dark theme switching deferred (`Theme` is a static singleton). Also fixed the static "17:42" top-bar clock → live + real tz.
- ✅ **Command palette (Ctrl+K)** (§10) — `CommandPalette.qml`: center-top 680px overlay searching cameras / groups / saved views / events over the existing models; grouped results with thumbs + live/rec badges, keyboard nav (↑↓/↵/Esc), footer count. Opens via Ctrl+K and the top-bar search. Activating navigates (camera→detail, group→filtered live, view→apply, event→events). Clips omitted (no enumerable source yet).
- ✅ **Clips & Snapshots library** (§296–304) — `ClipsScreen.qml` + `SnapshotModel` over the local Artifacts dir; artifact table + detail panel (real image preview) + Open / Reveal-in-folder; reached via the command palette (nav rail has no Clips item, per design). Server-exported clips pending the backend list endpoint (letter §A6).

**P1–P6 are all complete.** Remaining work is backend-gated (the API-requests letter) + optional polish/deferred items below.

## Events screen redesign (events-v2) — done (design port, behind `WT_DEMO`)

A faithful Qt6/QML 1:1 port of the `designs/events-v2` HTML/React prototype — the
re-imagined Events area as **four views over one shared store**, built to the four
spec files (`triage-queue-spec.md`, `verify-screen-spec.md`, `timeline-screen-spec.md`,
`map-screen-spec.md`). Commits `7df90aa` → `d09e397`.

- **Shared store** `EventsStore.qml` (singleton): the events-v2 mock domain (20
  events, cameras/types/dispositions) + the only mutators every view uses —
  `ack` / `bookmark` / `dispose` — so OPEN/CRITICAL/CLEARED counts and the same
  event update across all views live. Procedural `EvSnapshot` (CCTV still: AI box,
  tod scene, tamper/offline, OSD) is the only "video"; all icons/glyphs via Qt Quick
  Shapes (no SVG plugin). Primitives: EvIcon/Sev/TypePill/StateTag/EvButton.
- **EventsArea** shell: 01–04 mode switcher + rationale + live status strip; stage
  hosts the views via a Loader.
- **01 Triage** (`EvTriage` + `EvPlayer`): 384px priority list + detail pane that
  plays the clip inline (transport + seekable scrubber w/ event window), facts grid,
  per-type SOP checklist, disposition note, action bar.
- **02 Verify** (`EvVerify`/`EvWall`/`EvSessions`): Wall (S/M/L card grid, hover
  preview, Threat/Dismiss) ⇄ Smart Sessions (zone-grouped, bulk bar), contextual
  toolbar.
- **03 Timeline** (`EvTimeline`): per-camera swimlanes, duration bars, markers,
  click-popover, dashed "now" line, 90m/3.5h/8h windows.
- **04 Map** (`EvMap`): schematic site plan + pulsing camera pins + count badges +
  legend; live-feed rail ⇄ per-camera detail (Verify/Dispatch/Clear).
- **Integration / data source:** `EventsStore` has two sources — `loadMock()` (the
  showcase) and `ingestReal(rows, camLookup)` (live `/events`). **The redesign is now the
  DEFAULT Events screen** (cutover done `d4490d6`). Flags (`src/main.cpp`): **`WT_DEMO`** →
  redesign on the mock showcase; **`WT_EVENTS_LEGACY`** → the old table-style `EventsScreen`
  (instant fallback). Inline hero playback, real frames, real Map, Assign/Export all live.
  Stable task tracker: `docs/events-redesign-tasks.md`.
- **Real-data foundation (done 06-18, `614148d`):** real `/events` mapped honestly via
  `EventsStore.ingestReal`; `EventModel` exposes `durationMs` + `recordingId`.
- **Backend contract shipped + wired (done 06-18, `233229b`):** Cilex Vision shipped all
  five asks (their `…-events-redesign-shipped.md`, backend `44f7bd8`/migration 0042).
  `EventModel.parseRow` now reads `severity`, `triage_state` (NOT `state`), `disposition`,
  `disposition_note`, `bookmarked`, `zone_restricted`, `detection{class,confidence,bbox}`,
  `camera_name`, `zone`; `acknowledge/disposition/bookmark` POST to `/events/{id}/…` and
  swap in the returned row (WT_DEMO keeps a local fallback). `ingestReal` maps real
  severity→priority, triage_state→status, etc.; `actionsPending` is now **false** (actions
  live). Today all events are `severity:low` / `detection:null` (motion-only) — critical/high
  + AI box light up with no rework when smart events/AI land.
- **Follow-up asks shipped + consumed (done 06-18, `2ced7d8`):** Cilex Vision shipped §1–§3
  (their `…-followups-shipped.md`, backend `76dd398`/migrations 0042+0043). (1) **in_progress**
  mapping fixed — `verified`/`dispatched`→`in_progress`; no client change (`_triageToStatus`
  already maps it). (2) **Assign** — `EventModel.assignEvent` + `fetchOperators`
  (`GET /operators`); the Triage "Assign" button is now a real operator picker; events read
  in_progress when assigned. (3) **`PATCH /cameras/{id} {restricted}`** shipped admin-only —
  we accepted admin-only (it's camera policy; redesign only reads `zone_restricted`).
  - **§4 Camera Map** (their `maps`/`map_objects`, migration 0040) is the real per-camera
    site-plan source — we'll **consume it** (dropping the grid-fallback / our own store).
    Asked for the `GET /maps/entities/cameras/{camera_id}/placement` reverse-lookup; will
    grid-fallback the ~28 unplaced cameras; default to the active plan. See reply
    `…-followups-shipped.reply.md`.
- **Imagery part 1 — real event frames (done 06-18, `52114e1`):** `CvImageProvider`
  (authenticated async image provider, `image://cvframe/…`); `EvSnapshot` shows the real
  event-moment frame (`GET /events/{id}/snapshot`) under the OSD in real mode, honest
  "NO FRAME AT EVENT TIME" on 404; mock keeps the procedural still.
- **Situation Map on the real Camera Map (done 06-18, `9bf148d`):** `SiteMapModel` fetches
  CV's active plan + placements (`/maps?status=active`→`/maps/{id}`→`/maps/{id}/objects`);
  `EvMap` real mode draws the real floor plan (pre-signed `background_url`) + camera pins at
  `(x_norm·W, y_norm·H)` with an "N of M placed" note (2/31 today). Mock keeps the schematic.
  CV closed the Events **backend** workstream (their `…-unassign-and-placement.md`; unassign
  now reverts to `acknowledged` — no client change needed).
- **Next (not built):**
  - **Imagery part 2** — real HLS playback in the Triage hero (reuse `/review/sessions`;
    isolated `PlaybackClient`; the *stable* QtMultimedia path). Needs interactive verification
    (offscreen can't screenshot live video).
  - Wire the **Export clip** toolrow button; then **production cutover**.

## Recovery pointers

- Build/run/verify, dev hooks, architecture, API contract, gotchas → [DEVELOPMENT.md](DEVELOPMENT.md).
- Each commit message is written as a context-restoration anchor (`git log` reads like a build journal).
- Design spec of record: `designs/design_handoff_watchtower/README.md` + `design/watchtower.html`.
