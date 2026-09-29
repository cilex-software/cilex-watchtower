# Cilex Watchtower — Project Status

> **[REDACTED 2026-08-22, operator order]** Credential strings removed at HEAD
> (`<REDACTED-CRED>` markers). Original bytes remain in git history pending
> history surgery + rotation (operator decisions).


<!-- 2026-09-29 PLAYBACK: HEAD SPLIT BREAKS HEVC SESSIONS -->
> **2026-09-29 23:19 — FIXED IN THE APP (09b39f1): clips that died ~15 s in and went black**
>
> **What the operator saw:** a Colour clip (10 Улица 4, 20:56 MSK) played about 13 s, then jumped to
> the end and went black.
>
> **The cause, measured read-only on that window with the same request the Linux app sends:**
> - The server cuts the two head-split pieces with libx264 (playback-service `cache.py`, since
>   2026-07-18, built for mobile).
> - An HEVC session's other fragments are the HEVC main, stream-copied. So the codec changed at the
>   joint, with no marker.
> - Our player's libav HLS demuxer decoded 224 frames (14.75 s) and then refused all 1,768 HEVC
>   packets. It still refused them with a discontinuity tag added.
> - Without head_split, all 5 fragments were HEVC: 2,280 frames, 0 errors.
>
> **Why it slipped through:** the app has asked for head_split on every session since 2026-08-31.
> The server defers to the client (`broadcast_settings` main = `auto`). My measurement then timed
> segment 0 and never played across the joint.
>
> **The fix and what's left:**
> - The app now asks only on H.264 sessions (the Mac). Linux and Windows pay the whole first
>   segment again at open.
> - **The server side is fixed too, not deployed yet.** cilex-vision confirmed it as their bug:
>   `build_manifest`'s head_eligible never checked the codec. Their fix splits only a fragment
>   delivered as H.264. It is built and tested, and deploys with their next query-api restart
>   tonight, on the operator's word.
> - Once live, it covers every running client whatever it asks, the booth's build included. The
>   admin setting stays `auto`.
> - **Still open:** an HEVC session that falls back to the sub where main has a hole mixes codecs
>   the same way. Not measured on a real hole; a discontinuity marker did not help our player at
>   tonight's joint.
> - **Agreed with cilex-vision, not built:** ONE CODEC PER SESSION, chosen by the server.
>   - A window touching a main hole is served whole from sub.
>   - The session will say `delivered: "main" | "sub"`, with `because: "main_hole" | "no_main" | ...`
>     when it is sub.
>   - **The app's part when it lands:** `ExportDrawer.qml` (`retentionKnowable`, :208) must treat
>     sub-because-of-a-hole as "can't tell". It offers High and lets the export endpoint
>     adjudicate, as on the Mac. Otherwise it would call the whole selection aged out.
>   - Their letter comes after the pilot, with a real main-hole camera-hour to decode read-only.

<!-- 2026-09-29 LABS: V1 object_profile READ-ONLY TRIAL -->
> **2026-09-29 — Vehicle search V1 (colour of each passage + thumbnail): read-only trial done; V1 as specified does NOT pass**
>
> cilex-vision's specs V1-V4 (`docs/letters/2026-09-29-vehicle-search-without-ai-task-specs-cilex-vision.md`,
> no AI). The report: `docs/letters/2026-09-29-vehicle-search-without-ai-task-specs.reply-cilex-watchtower-linux.md`.
> - **Code** (54b5541, not wired into the worker):
>   - `tools/labs/object_profile.py` (`op-1`);
>   - an opt-in observer in `shape_observations.py`. blob_geometry's rows are identical with and
>     without it, measured on a real hour;
>   - `selftest_object_profile.py`, 31 checks, in pre-commit. 14 of 14 planted bugs were caught.
> - **Measured** (104 of 120 camera-hours of 2026-09-28, 5 cameras, sub, checked blind by eye):
>   - **Colour's light-cast measure is over its cut on 78 % of daytime passages.** These scenes are
>     colourful by day, and Colour's own module agrees on the same footage.
>   - **With that gate limited to dusk and night:** red 10 of 10, white 10 of 12, black 10 of 18,
>     blue 4 of 16.
>   - **White vehicles read "blue":** sky reflected in glossy paint, seen from above.
>   - **The second colour** is right 9 of 103 times.
>   - **Main vs sub:** the same accuracy, so sub is enough.
> - **The operator's calls (22:10 MSK), all as proposed; done in `op-2` (72688ab):**
>   - the cast gate only at dusk and night (an unknown sky keeps Colour's gate);
>   - B, a saturation floor for "blue", in object_profile only (Colour byte-identical);
>   - `colour_2` off;
>   - sub only.
>   - Self-test 40/40; 21 of 21 planted bugs caught.
> - **The second-colour search has started** (reply 3). Numbers are on development rows, so they are
>   optimistic:
>   - A white car's windscreen mirrors the sky as a solid blue region. It is the commonest FALSE
>     "white and blue".
>   - Reading the second colour only from the side-panel band (M3) cuts false seconds from 93 of 132
>     one-coloured things to 2. But it finds only 3 of 21 real ones: second colours barely reach the
>     counted pixels.
> - **The second trial is a PILOT of the real analyser** (the operator, 22:45 MSK; CV's reply 4):
>   - one station (office suggested), the five cameras only, rows admin-only, deleted by
>     `analyzer_version` if it fails;
>   - **worker-0.3.7 (8db9ce1) has the `object_profile` lane.** Thumbnails are PUT under the lease
>     before the results that name them. It claims only once the server's OpenAPI has the
>     thumbnail PUT;
>   - the app names it Vehicles / Транспорт.
>   - **Server half DEPLOYED 23:17 MSK** (query-api 1.0.100, cbfdd33; reply 6). `object_profile`
>     is registered switched off, scope `listed`, five cameras. The live OpenAPI's thumbnail PUT
>     matches the lane's check (verified).
>   - **Next:** the operator picks the station, the Windows agent installs 0.3.7, and CV switches
>     it on for that station's hose. This host stays on 0.3.6, server-stopped.
>   - Reply 5's questions are answered: "unknown" is not a finding; gated rows keep their
>     thumbnails in the pilot.
> - **Rule, from cilex-vision (amended spec):** trials NEVER run on the pilot host. It records every
>   camera.
>   - This trial ran up to 9 decodes at once there, which took it to load 33.8 with 1.25 GB
>     available (CV's figures).
>   - From 20:42 it ran one process at a time, at nice 19 and ionice idle.
>   - At ~21:56 the Claude Code harness stopped it on low memory. It was not restarted.
> - **Contact sheet** (local only, people and vehicles, never commit):
>   `/home/cilex-vision/labs-trials/v1-2026-09-28/index.html`.

<!-- 2026-09-29 LABS: THE PATH ON THE PICTURE + "NO FRAME" -->
> **2026-09-29 — Findings: the path on the picture; and why clips said "No frame at event time" for minutes**
>
> **The path on the picture** (operator request: "I want to see the path and direction … so I can
> check you've done a right conclusion"):
> - Under the player, a toggle: "Path on the picture" (Paths) or "Box and path" (Object shapes).
> - It draws what the row claims:
>   - **Paths:** the decoded `path` (24 equal-time points; `wtlabs::decodePath`), an arrowhead, a ring
>     where it was first seen, and a dot where it is at the frame on screen. The dot shows only when
>     the points are equal-time (`path_step_s`).
>   - **Object shapes:** the largest box and the passage's arrow.
>   - **The camera's other rows** of that analyser during the clip, dimmer (`LabsTimeline.rowsOf`).
>     One line per tracked region; a group walking together is one region to the analyser.
> - Paths rows now show their heading as an arrow (↖ etc.): the NET direction **in the picture**,
>   "N" toward the top of the frame (labs_track_linking.py says so itself), not the compass.
> - **Verified:**
>   - On the operator's two examples, the decoded path drawn on the real frames (read-only) with
>     the same interpolation: 10 Улица 2 17:57:47 runs right to left along the walkway, the dot on
>     the walker at +5.3 s and +10.5 s. It trails her by up to ~80 px (<1 s); I have not measured why.
>   - 1 Улица 5 17:55:16 ("NW"): the pair's walk recedes up and to the LEFT in the picture, about
>     140 px left for 180 px up, so NW is the correct 8-way reading of the picture.
>   - In the app, on the vnc platform against the live endpoint: the overlay drew the selected row
>     plus "3 more on this camera"; drawn pixels at x 576-1274, inside the picture's rectangle
>     568-1336.
>   - A fix found on the way: without a frame the video item's rectangle falls back to the whole
>     stage (measured), so the overlay shows only while it has one.
>   - Tests: labs-findings has two real paths decoded to within 1/128 of their stored entry and
>     exit; labs-timeline pins the overlap rule.
>
> **"No frame at event time" for minutes, then it plays:**
> - **CORRECTED 20:12 MSK, the same evening. I had this wrong.** I read query-api's `[SESSIONTIME]`
>   figures as seconds and wrote that sessions took a median 39.6 s (p90 97.3 s, max 663 s), mostly
>   `t_index`. They are **milliseconds**: `routers/review.py:622/662/731` multiply by 1000 (read after
>   cilex-vision said so). Sessions opened in a median **39.6 ms**, so `t_index` explains nothing the
>   operator saw. Owned in
>   `docs/letters/2026-09-29-review-sessions-take-40-s-to-open.reply2-cilex-watchtower-linux.md`.
> - **The real cause, per cilex-vision's reply** (`…take-40-s-to-open.reply-cilex-vision.md`, not
>   verified by me): a server bug.
>   - Short clips got an HEVC main fragment stacked on subs that already covered them.
>   - With `hevc_capable=false`, which the Mac forces (`PlaybackClient.cpp:431-440`), each one was a
>     full 1440p transcode.
>   - These ran on the one transcode slot that every session's first piece also needs; five ran in
>     the operator's minutes.
>   - Fixed and deployed in cilex-vision 1.0.99 (ae8775d), 20:08 MSK. Since then, playback's log
>     holds no plays, so nothing is measured yet.
> - The poster covers the player until the first frame, and a Labs finding has no event still, so it
>   read "no frame" all that time.
> - The app made it worse, and now doesn't:
>   - **Selection rests 450 ms** before the player takes it. Stepping through rows had opened a
>     session per row: 12 in 9 s, each served in full.
>   - **A play tap JOINS the session already being prepared** instead of asking again. Before, a
>     tap during the prefetch queued a duplicate; the 25 s deadline fired, and each "tap to retry"
>     queued another.
>   - **A Labs row's poster says what the player is doing:** "PREPARING THE RECORDING ON THE
>     SERVER · N S", "RECORDING READY · PRESS PLAY" or "WAITING FOR THE FIRST FRAME". It no longer
>     asks the server for an event still that cannot exist.

<!-- 2026-09-29 LABS: A4-A6 1.2.0 PASSAGES + worker-0.3.6 -->
> **2026-09-29 — Object shapes (blob_geometry) files one row per PASSAGE, within a row budget; worker-0.3.6**
>
> **Why, both measured today:**
> - **The operator's crow:** they opened a "Wide" finding on 5 Улица 7 (15:57:58) and read "car, truck, bus".
>   It was a crow: 19 rows in 19 s, relabelled every second, each 0.05-0.08 % of the picture. Checked
>   read-only in `labs_observations` and on the frames, with the stored boxes drawn on them.
>   - "car, truck, bus" is `labs_shape_classes.suggests`, cilex-vision's advisory lookup per shape
>     (migration 0086), which the server joins onto every row. My Labs card printed it as a field
>     (fa79062); f1a897e removed it from the card.
> - **The 500-row cap:** busy hours pass it and are lost whole. hiwatch-083bc17adca6 12:00Z failed
>   twice (525, 530). cilex-vision's letter
>   `docs/letters/2026-09-29-blob-geometry-busy-hours-and-the-500-row-cap-cilex-vision.md` asks for
>   a row budget the analyser cannot pass.
>
> **A4-A6 1.2.0 (`tools/labs/shape_observations.py`; plugin version `shape-3`):**
> - **Passages:** consecutive keyframe detections of one moving blob become ONE row with a span.
>   - Timed at the first detection and lasting to the last.
>   - The class is the one most keyframes gave; every vote is kept in `shape_votes`.
>   - The box is the largest the blob was (`bbox_at_s` says when); `path_*` holds the first and
>     last centres; `recur_count` counts the detections.
>   - Linking: at most 2.5 measured keyframe steps apart (3 s if the step is unknown), near
>     enough. Passages are cut at 240 s, under the 300 s event-group span.
> - **Row budget 450:** past it, rows merge per shape class per 60 s bin, coarser until they fit.
>   Folded sources never merge with passages, and every detection is still counted exactly once.
> - **The recurrence fold (1.1.0) is unchanged** and runs first.
> - **The adapter** times a passage row from its `span_s` and refuses any span of 300 s or more.
>
> **worker-0.3.6:**
> - A unit dropped for making no progress, or whose process died, is **filed failed with why**
>   (cilex-vision's reply2 on the lanes): "stalled: no checkpoint for 10 min, its process was
>   killed" / "unit_process_died: …". Left to lapse, the ledger said "lease expired".
> - A unit the server took back is never filed.
>
> **Verified:**
> - A4-A6 self-test: 79 checks, 19 new. They include the crow replayed from its stored rows (one
>   row), a busy hour (1,200 detections → 349 rows) and a flood (7,200 → 372).
> - `labs-worker.py`: 364 checks.
> - 12 planted bugs, all caught.
> - **Real footage, read-only, same frames, 1.1.0 → 1.2.0:**
>   - 5 Улица 7 12:00Z: 401 → 131 rows (findings 331 → 61, detections 597 → 597). The crow's walk:
>     29 rows → 1 (12:57:24-59, compact, 36 detections).
>   - hiwatch-083bc17adca6 12:00Z: **FAILED 530 > 500 → 220 rows**, 966 detections, 0 schema
>     violations.
> - **What the operator will see:** Statistics for Object shapes counts passages, so the numbers
>   drop (cilex-vision: "reads better for an operator").
> - **Windows, per the Windows agent (1cb00ba, on the booth, launched as its guard launches the
>   worker; not measured here):**
>   - `labs-worker.py`: 349 pass, 0 fail; the 14 SKIP lines cover the 13 named pins and the /proc
>     pair, 15 checks, so 364 in all. A4-A6 self-test 79/79. The booth's real control.json was
>     byte-identical before and after.
>   - **Observed** on 6 real unit processes: 0 matched the guard's `Worker()` filter, all 6 ran at
>     Idle priority (inherited from `/low`), and there were 0 visible windows.
>   - **LIVE on the booth** since the operator's go (relayed by cilex-vision, 18:18). Clean over
>     15 min, 18:24:28-18:39:33 MSK: 6 units claimed, 6 done, 0 failed. 7 unit processes observed,
>     all Idle, 0 matched by the guard, 0 visible windows.
>   - **Load at slots=1, under the wall:** the Labs process tree used CPU p50 1.2 %, p90 2.1 %,
>     max 4.7 % of 12 logical CPUs, and RSS at most 295 MB. That is a lower bound: 15 s samples
>     miss ffmpeg children that live between them. The wall is the real measure: 427.7 frames/s
>     displayed during against 426.6 in the 30 min before, and no guard hold.
>   - **A unit's warning into worker.log:** the mechanism is proven in two halves.
>     1. Unit to worker, over the pipe: the suite passed on Windows.
>     2. Worker to the file: a stand-in script in the guard's EXACT launch shape
>        (`cmd /c start "" /low /b "python" -u "<script>" >> "<log>" 2>&1`) logged a WARNING, and
>        the file held that line.
>
>     There was no real worker warning to point at: the booth's worker.log was still 0 bytes, with
>     nothing warned since 16:52. The first real forwarded "[analyser camera hour]" line is still to
>     be pointed at.
>   - **The office:** 0.3.6 since 18:43:34 (the whole folder copied, restarted through the
>     wt-labs-start task), reconnected 18:44:32 with blob_geometry. By then the booth had done 8 of
>     8 units. **Both stations run 0.3.6;** the pilot box does too, held by cilex-vision's station
>     Stop.
>   - cilex-vision is watching hiwatch-083bc17adca6 12:00Z's rescan.
> - **Also seen, not changed:** the 1.1.0 recurrence fold can take dense unrelated traffic at one
>   spot for a "source". In a synthetic test, about 1 % of the picture around a spot collected 3
>   hits in 10 min at 1,200 detections an hour. Its effect on real walkways is not measured.

<!-- 2026-09-29 LABS: worker-0.3.5 — ONE LANE PER ANALYSER -->
> **2026-09-29 — worker-0.3.5: each analyser runs on its own** (the operator's requirement:
> *"other analyser must run in separate threads and if one analyser is stuck it should not affect
> others"*, relayed in `docs/letters/2026-09-29-each-analyser-runs-on-its-own-cilex-vision.md`).
>
> **What was wrong (the worker half; CV fixed the server half, 6a1e731):** one pass over the analysers
> in alphabetical order (`run_worker.py:359` at 2fd1b54), and the first busy claim ended the pass
> for a minute (`:337-340`, `:345-348`). CV measured, after the v17 reconnect, 11 claims in 8 min,
> 10 of them audio_energy, 9 timed out.
>
> **Now (`tools/labs/lanes.py`, `tools/labs/unit_proc.py`):**
> - **One lane per analyser:** its own claim, its own wait after a busy or refused claim, its own
>   unit. Busy: that lane waits `busy_s` (60 s). Retry-later: 2, 4, 8, 16, 32 s, then 60 s. An
>   unknown refusal: that lane rests. Only the station's own faults stop every lane: a refused
>   token, a decoder that will not start.
> - **Slots, first come first served:** a lane that just had its turn queues behind the others,
>   and the first order is shuffled at every start. `--slots N` (or `WT_LABS_SLOTS`), default 1,
>   the same one-unit-at-a-time load as 0.3.4.
> - **Each unit in a process of its own** (spawn). A stuck unit (no checkpoint for 10 min) is
>   told to stop, and killed 30 s later; its lane rests 15 min. A Stop kills that unit's
>   decoders only, and only after the unit has acknowledged why. The BLAS/OpenMP pools are held
>   to one thread per unit process. Measured here: 0.12-0.29 s and 56 MB per unit start with the
>   cap, 2.3-3.2 CPU-s without it.
> - **Reporter:** one `holding` list with every lane's units; each unit is dropped once, on its
>   own.
> - **status.json:** `current` is still one analyser (what the Labs screen shows). New keys:
>   `units`, `slots`, `lane_states` (each lane's state, note and until). They are not shown in
>   the app yet.
> - **Cost:** blob_geometry no longer carries its model into the next hour of the same camera
>   (every unit starts fresh). Claims go newest-first, so the carry rarely applied; a fresh model
>   costs its warm-up (1 row in minute 0, measured 2026-09-27). camera_health keeps its baselines
>   on disk, as before.
>
> **Verified (Linux, this box):**
> - `tools/tests/labs-worker.py`: 358 checks, all pass, in 12.8 s (10.4 s before).
> - The old loop tests were ported to the lanes, and new ones cover the letter's case,
>   turns, the shuffle, slots (2 → peak 2, 1 → peak 1), and a stuck lane resting.
> - Real unit processes: outcome round-trip; a Stop kills that unit's ffmpeg and not the other
>   lane's; a hang is killed; a crash is reported; an orphaned unit stops.
> - 17 planted bugs, all caught.
> - A read-only run on real footage (the production analysers and decoder, claims from a local
>   list, nothing claimed or submitted on the server): 5 units done, 0 failed, 5 unit PIDs, peak
>   2 on 2 slots, 0 schema violations.
> - **Not verified:** Windows (spawn, the guard's process filter, the booth's load). That is
>   the Windows agent's run. **Update:** run on 0.3.6. Spawn, the filter and the priority were
>   observed; the load was not yet. See the 0.3.6 block above.

<!-- 2026-09-29 LABS: FINDINGS VIEW -->
> **2026-09-29 — Labs Statistics rows open a Findings view, to WATCH what an analyser found**
> (operator request, same day). Click an analyser in Statistics and you get:
> - **Header:** its findings for the period (24 hours · 7 days · All, starting on Statistics' own).
> - **Filters:** the analyser's own one-button filters from the server, one at a time.
> - **List:** newest first, a page (40) at a time, asked for only as the list nears its end.
>   "All" is a period, never "load everything".
> - **Player:** the selected finding plays with the Events screen's own inline player
>   (`EvHeroPlayer`, on a `PlaybackClient` of this view's own; each camera's pre/post roll).
>   `LabsCard` sits under it with every field and metric.
> - **Row headline:** the finding's own measurement (e.g. "black · 63 % · then blue"), from its
>   metrics.
>
> **Code:** `qml/LabsFindings.qml`, `src/models/LabsFindingsModel.*`, `src/models/LabsFindingsData.h`;
> `qml/LabsSeg.qml` (the segmented control, now shared).
>
> **Data:** `GET /labs/findings`, asked of cilex-vision:
> `docs/letters/2026-09-29-labs-findings-list-cilex-watchtower-linux.md`. It is findings only, by
> the footage's hour, with a keyset cursor and the analyser's filters served by the server.
> **LIVE since query-api 1.0.98 (16:09:51 MSK), to the contract as written**
> (`...labs-findings-list.reply-cilex-vision.md`). Measured on the pilot, read-only, ~16:40 MSK:
> - colour_histogram, 24 h: total 338, 40 rows a page; page 2 by its cursor has 0 rows in
>   common with page 1 and continues newest-first.
> - Filters come with RU/EN labels and counts. An unknown filter gets `400 unknown_facet`.
> - blob_geometry, 7 d: 8,250 findings. image_embedding: total null, no rows, no filters.
> - **Under a filter the server's `total` stays the whole period's** (colour "black": total 338,
>   the black button's count 216, every row black). So the header counts the chosen filter's own
>   rows and names it ("216 findings … · Black").
> - Rows now name colours, shape classes and directions by the server's labels (Чёрный · 56 % ·
>   затем Синий), not the raw values; a value the server has no label for is shown as filed.
> - Screenshots in RU and EN against the live endpoint.
> - **Paging, live:** real Down-key presses over VNC walked past row 40, and query-api's access
>   log shows the second request carrying the cursor.
>
> **Verified:**
> - `tools/tests/labs-findings.cpp`: 20 checks; 3 mutants killed. The test also caught a real
>   bug before it shipped: a cursor's '+' was sent unencoded, and the server reads '+' as a space.
> - Screenshots in EN and RU:
>   - against the real server (the pending message);
>   - against a local stub serving the real DB read-only, with stand-in finding rules. They
>     showed the list, the chips, a filter ("Red": 6, one request), paging (a second request with
>     the cursor, rows continuing), and the player opening a review session (server log: POST
>     /review/sessions 200, playlist 200).
> - **Not verified:** a video frame on screen. Offscreen rendering draws none.
>
> **The list column** (same day; the operator asked for it "resizable and by default fit to width"):
> - **Fit:** each loaded row's time, camera and headline is measured in the row's own fonts. Only
>   rows new to the list are measured as pages arrive. While a list reloads the column keeps its
>   width, so a period or filter change moves it once.
> - **Resize:** drag the divider; double-click it to go back to the fit. A drag holds for the
>   session (switching analysers or screens keeps it); a restart begins fitted.
> - **Bounds:** never under 200 px; a drag stops where the player keeps 460 px; the fit alone takes
>   at most half the view.
> - **Verified** with the app on Qt's `vnc` platform and real pointer events from a small RFB
>   client. The divider's x was measured in each screenshot (rows y=600 and y=900):
>   - fitted: 293; dragged +300: 593; dragged, then double-clicked: 293;
>   - dragged to x=1550: 1143 (the player keeps 460 px); dragged to x=100: 275 (the 200 px floor).
>   - Hover: a MouseArea's `containsMouse` stayed false after a drag that outran the divider,
>     even after a 1 px move; the highlight now comes from a `HoverHandler` (amber after a drag,
>     measured). The tooltip sits beside the pointer, not above the divider's top.
>   - Offscreen screenshots of the fit: Colour and Object shapes (~220 px, time + camera);
>     Objects in view, RU, All (~290 px, the widest headline); Paths in a 1100×800 window.
> - **Also fixed, shipped wrong in `48031d8`:** the eight row-headline strings were missing from
>   the translations (RU showed "then"), and the EN plurals were unfilled (the header read
>   "264 finding(s)").

<!-- 2026-09-29 LABS: worker-0.3.4 — ROWS OUTSIDE THE CLAIMED HOUR -->
> **2026-09-29 — worker-0.3.4: rows starting outside the claimed hour are dropped before submitting.**
> - **The bug:** the server refuses a WHOLE submission (422 `observation_outside_claimed_hour`, not
>   retryable) for one such row. The Windows agent measured 16 blob_geometry units refused on
>   2026-09-28/29, some to their third attempt.
> - **The cause** (read in `plugins.ShapePlugin`): each row is timed from its own segment's start
>   plus the frame's offset, and an hour's last segment runs up to ~30 s past the hour. So a
>   shape seen in that tail was timed in the next hour. It is NOT the 0.3.1 join fix, which only
>   the window analysers use. track_linking already drops such rows, and audio_energy clamps
>   them.
> - **Fix:** `worker._within_hour` in `_finish`, the one submit path. Such rows are dropped for
>   every analyser, never moved, and counted in the unit's note and the log.
> - **Verified:** 329 checks; 3 mutants, all killed.

<!-- 2026-09-29 MAC: THE BUNDLE NEVER SAID WHAT IT WAS -->
> **2026-09-29 — Every Mac build until 1.1.701 shipped an EMPTY version, build number, executable
> name and bundle identifier.** Found while verifying the launch banner's version (bbdf97b, the Linux
> agent's, at the operator's request): on the Mac it read "version unknown".
>
> - **Cause:** `packaging/macos/Info.plist.in` wrote CMake's fields as `@MACOSX_BUNDLE_…@`. Qt runs
>   the template through `configure_file(@ONLY)` first, for its own `@FOO@` values
>   (`_qt_internal_copy_info_plist`, `QtPublicAppleHelpers.cmake:642-654` in Homebrew Qt 6.11.1).
>   In that scope those names are target properties, not variables, so they came out empty before
>   CMake's own pass ever saw them. Fixed by writing them as `${MACOSX_BUNDLE_…}`.
> - **Now, measured with `plutil -p` on the built bundle:** version `1.1.701`, build `1.1.701`,
>   executable `watchtower`, identifier `com.cilexvision.watchtower` (provisional until M4, as
>   `CMakeLists.txt` says).
> - **Settings do not move.** Qt derives the QSettings domain from the organization name, not the
>   bundle identifier. Measured with a probe app carrying the new identifier: it resolves to the same
>   `com.cilex-vision.Watchtower.plist`.
> - **May change, NOT verified:**
>   - `cilex://` routing. `run-macos.sh` notes LaunchServices refusing it with
>     `kLSApplicationNotFoundErr` (2026-08-22), and URL schemes are registered against a bundle
>     identifier, which was empty.
>   - macOS privacy prompts (Local Network and the like). They may ask once more under the new
>     identity.
> - **The banner also got a guard.** A missing or unreadable plist makes PlistBuddy print "File
>   Doesn't Exist, Will Create: …" or "Error Reading File: …" on stdout, with exit 1. The banner
>   showed that as the version. Now PlistBuddy counts only on exit 0, and only digits and dots pass.
>   Checked on the Mac: bash 5.3 and stock bash 3.2 (the checkout launcher) and zsh (the packaged
>   one). Cases: the real bundle, a missing plist, a garbage file, an unfilled placeholder, an empty
>   version, and a stage without the app.
>
> Not run end-to-end: `./run-macos.sh` itself. The operator's Watchtower was running from the same
> bundle, and the script renames the `run-last.log` it writes to.
>
> **Who answers `cilex://` on the operator's Mac, measured read-only with `lsregister -dump` (13:23):**
> 12 LaunchServices records claim the scheme, and the user's LaunchServices prefs set no default
> handler for it.
> - **9 Watchtower bundles, none with an identifier.** One is the live `build-macos/watchtower.app`,
>   registered at the 12:57 launch, before the fix. Eight are old `build-macos/dist/` packages
>   (1.1.328–1.1.528), and seven of those no longer exist on disk.
> - **3 Cilex Pro iOS-simulator apps from Xcode DerivedData, WITH identifiers.** The mobile app
>   claims the same scheme. Only a Mac with Xcode builds has these.
>
> So on this Mac, a link has nine anonymous claimants, some of them dangling. That fits the
> 2026-08-22 `kLSApplicationNotFoundErr`, without proving it. **If a `cilex://` link fails here:**
> - `lsregister -u` each gone `dist/` path;
> - remove or unregister the surviving 1.1.528 package;
> - `lsregister -f` the current bundle, which the next `run-macos.sh` start also does, now with an
>   identifier.
> Nothing was changed in LaunchServices.

<!-- 2026-09-29 LABS: worker-0.3.3 — THE KILL TOOK THE CONSOLE HOST -->
> **2026-09-29 — worker-0.3.3: a Stop kills decoders ONLY; a station that cannot start its decoder
> stops claiming.** An incident found by the Windows agent on the office.
>
> **What happened:**
> - At 02:13:36 MSK a revoke's kill (`vitals.kill_children`, which killed EVERY descendant)
>   took the worker's own `conhost.exe`. On Windows that is a console process's CHILD.
> - After that every ffmpeg died at DLL init: exit 3221225794 = 0xC0000142. Each unit was
>   filed failed as the footage's fault: ~25 failures by 02:25, when the Windows agent held
>   the office.
> - Measured here in the ledger (read-only): 9 units, all hour 2026-09-28T22:00Z, lost their
>   attempts. 7 are exhausted at 3, 1 is failed at 2, 1 was revoked at 3. Newest-first claiming
>   kept handing the same fresh hour back to a broken station.
>
> **Fix:**
> - `vitals.is_decoder`: kill only processes named ffmpeg/ffprobe (with `.exe` or a build
>   suffix). This holds on the psutil and `/proc` paths.
> - `run_worker.decoder_start_fault` (`ffmpeg -version`) is asked in two places:
>   - before any unit is filed failed (`worker.STATION_CHECK`). If the decoder cannot start, the
>     unit is filed as `station_fault: …` and the pass ends as fatal;
>   - before each pass's claims. While broken, nothing is claimed; the station shows "fatal"
>     with the reason and waits `FATAL_S`.
>
> **Verified:** 324 checks, including a REAL ffmpeg killed while a non-decoder child survives,
> on both paths. 7 mutants all killed, one of them the old kill-everything.
>
> **Asked of cilex-vision:** return those 9 units' attempts.

<!-- 2026-09-29 AUTH: TOKEN SIGN-IN OFF -->
> **2026-09-29 — «Token» sign-in is off the login screen** (the owner's decision, via Cilex Team:
> `docs/letters/2026-09-29-watchtower-hide-token-sign-in-keep-the-code-cilex-team.md`; reply
> beside it). Access must follow team.cilex.ru, and a pasted personal token goes around that.
> - **Off by ONE constant**, `AuthController::kPersonalTokenSignIn = false`
>   (`AuthController.h:105`). **Do not delete the code:** the tab, the panel, their strings,
>   `loginWithToken` and `attemptTokenLogin` all stay, by the owner's request. Turning it back on is
>   that line and a new build, never a setting.
> - With it off the login screen has no tab bar, and `loginWithToken` refuses, whoever calls it.
> - **Untouched:** the workstation key (`WT_STATION_TOKEN` → `loginWithStationToken`), the saved
>   session, and password sign-in.
> - `62fdb10`, 1.1.695. Live on the Linux box; Windows and Mac from their next build.

<!-- 2026-09-29 LABS: ONE SET OF ANALYSER NAMES -->
> **2026-09-29 — Labs analysers have one set of names, the operator's**, shared with cilex-vision
> (their `labs_names.py`, relayed ~01:35 MSK).
> - **Renamed:** Moving area → **Objects in view** (Объекты в кадре); Shapes of moving things →
>   **Object shapes** (Формы объектов); Tracks → **Paths** (Маршруты); Change detector → **Frozen
>   picture** (Зависший кадр; it finds a frozen feed, the opposite of "change"). Image search →
>   **Similar pictures** (Похожие кадры).
> - **Lane labels:** OBJECTS / PATHS / FROZEN / SIMILAR (ОБЪЕКТЫ / МАРШРУТЫ / ЗАВИСАНИЕ / ПОХОЖИЕ).
>   Screenshotted: every label fits the 120-px block in EN and RU.
> - **`qml/LabsNames.qml` is now the ONLY place a name lives.** The Labs screen's duplicate list is
>   gone (`LabsScreen.title()` asks `LabsNames`). The slug stays the key; nothing branches on a name.
> - The server's new `name`/`short_name` fields (with v17) carry the same table; the app keeps its
>   own copy, because the Playback lane has no analyser data from the server.
> - **Office live:** worker-0.3.2 since 01:40 MSK, its wall guard started first (01:38:48), psutil
>   installed. Per the Windows agent: governed, running, no report error. The booth still waits
>   for the operator's go.

<!-- 2026-09-28 LABS: STATISTICS VIEW -->
> **2026-09-28 — The Labs screen has a Statistics view** (operator request, same day). An
> **Analysers | Statistics** switch sits above the table. Statistics shows, per analyser, a stacked
> bar (checked · in progress · waiting · given up) in the analyser's own colour, the same as on the
> Playback lane (`LabsNames`). Beside each bar is its **findings**. Totals sit at the top.
> Periods: **24 hours · 7 days · All**. Code: `qml/LabsStats.qml`, `src/models/LabsStatsData.h`,
> `LabsModel` `stats` / `fetchStats`.
>
> **Operator decisions:**
> - **A period = footage recorded in it**, so each bar is a true progress bar.
> - **An event = a finding**, a record where the analyser found something. Routine readings don't
>   count, and which records are findings is cilex-vision's rule.
>
> **Data:**
> - `GET /labs/stats`, asked of cilex-vision today:
>   `docs/letters/2026-09-28-labs-statistics-by-period-cilex-watchtower-linux.md`.
> - Until it exists (404), **All** comes from `/labs/pipeline`: checked = `done`, waiting =
>   `queue_remaining`, in progress = only leases still live.
> - **24 h / 7 d** say "The server does not count by period yet", and **findings** say "waiting for
>   the server". No app update is needed when the endpoint lands.
> - Fetched with the pipeline: at most every 30 min or on Refresh, one request at a time.
>   Switching the period asks nothing.
>
> **Honest states:** absent = "—" with the reason, never 0. A bar with an uncounted segment is not
> drawn, not drawn as 0. A non-zero sliver stays ≥ 3 px. "At least" (≥) marks a total with uncounted
> parts.
>
> **Verified:**
> - `tools/tests/labs-stats.cpp`: 25 checks, including 2,000 random bars; 6 mutants, every one
>   killed. `labs-station.cpp` and `labs-timeline.cpp` still pass.
> - `build` and `build68` compile.
> - Screenshots in EN + RU against the real server (All + the waiting panel).
> - Screenshots against a **local stub** for `/labs/stats`: real read-only counts, and **test
>   values** for 24 h / 7 d waiting and for findings. Those previews are layout checks, not data.
>
> **Server side: BUILT by cilex-vision, NOT DEPLOYED** (their reply, same day:
> `docs/letters/2026-09-28-labs-statistics-by-period.reply-cilex-vision.md`; their `2c9da8e`,
> 1.0.85, and `9876f16`, 1.0.86).
> - It follows our contract, with six refinements. Records and findings are counted by
>   `hour_start`. Only ended-and-settled hours are counted. The bar adds up by construction. In
>   `all`, the bar covers stored footage while the counts cover everything. Switched-off
>   analysers get `null` bar totals. Findings are `null` only where no rule exists.
> - Finding rules are theirs, per analyser, in `services/query-api/labs_findings.py`. E.g.
>   foreground_mask needs `largest_blob_frac >= 0.01`, not a count; illumination needs a real light
>   change within the camera-hour.
> - Their code's response shape was read here (`routers/labs.py:3255-3345`, route at `:3363`) and
>   pinned by `tools/tests/labs-stats.cpp` using their measured figures: now 32 checks.
> - **The app needs no change; it switches over when the endpoint answers.**
> - A query-api restart blanks guard walls for ~7-16 s (their figure), so **the operator picks the
>   window.**
>
> **Verified against the deployed endpoint** (cilex-vision 1.0.87, live 20:07 MSK). Between 20:14 and
> 20:18 the app made six `GET /labs/stats`, all answered 200 (query-api log; the one 401 there is
> cilex-vision's own no-session check). They were rendered in 24 h, 7 days and All, EN and RU. Totals add up: at 20:14 the 24 h view showed 660 findings = 576 + 25 + 8 + 4 + 47 per analyser.
> Fixed on sight: a share under 0.1 % read "0.0 % checked" (12 of 24,388 h) and now reads "< 0.1 %".

<!-- 2026-09-28 LABS: EVERY INSTALL IS A STATION (operator decision) -->
> **2026-09-28 — Operator decision: every machine with Watchtower installed is a Labs station.**
> Verbatim: *"all machines where Cilex Watchtower is installed are lab stations, period. I decide
> which ones are activated and which ones are dormant. Compute is very expensive these days so we
> must use it on machines which sit idle."* It replaces the macOS agent's recommendation made
> earlier that day ("only the Linux box").
>
> **What follows from it, for every agent:**
> - **Installing Watchtower installs the Labs worker, dormant.** Only the operator activates a
>   station, through the server's control plane (cilex-vision's admin page, or the Labs screen's
>   Start on the machine itself). No install starts scanning by itself.
> - **Labs gets only CPU that nobody else is using**, as the Linux unit already does (`Nice=19`,
>   CPU and IO scheduling class `idle`). Every platform matches that.
> - **A machine with no worker is an incomplete install, not "not a station".** When the Labs
>   screen says "No Labs scanner has run on this computer", that is an installer fault, not an
>   errand for the operator.
>
> **Per machine, as recorded in this file on 2026-09-28:**
>
> | machine | worker today | missing before it is a dormant station |
> |---|---|---|
> | Linux box (pilot) | 0.3.1, `systemd --user`, governed, stopped by the server | nothing |
> | Office (Windows) | 0.3.1 staged in `C:\wt-labs`; has run real units | Windows agent: psutil on the visit (known); record how it runs (service or by hand) |
> | Booth (Windows) | Python suite passes on it (285 / 0 / 13 skip); no installed worker recorded | Windows agent: an installed worker, dormant, at idle priority |
> | Operator's MacBook | none | macOS agent: see below |
>
> **The MacBook needs three things, in this order** (measured on it, 2026-09-28):
> 1. **A station token, which on macOS can only come through Warden.** The app enrols a station
>    only under Warden (`StationEnrolment.h` `enrolmentWanted()`: `WT_UNDER_WARDEN`, and
>    `WT_WARDEN_TOKEN` missing), and Warden has no macOS port (`warden/` has Linux and Windows
>    installers only; `~/.config/watchtower-warden/` does not exist on the Mac). That is M3, which
>    has been **waiting on the operator's E2** (when the app hangs, does Warden kill and restart
>    it, or wait and log?).
> 2. **A stable machine identity.** `warden.py` `machine_id_hash()` reads `/etc/machine-id` or
>    `/var/lib/dbus/machine-id`, and macOS has neither, so it returns `""` and CV would key the Mac
>    on `host:<hostname>`. On the Mac that hostname is `macbook-pro.tail42029d.ts.net` today. No
>    `HostName` is set, so macOS derives the name from the network, and it is expected to change
>    as the laptop roams (expected, not measured). A macOS branch should hash the
>    `IOPlatformUUID` instead (present on the Mac).
> 3. **The worker itself**: a LaunchAgent at the lowest priority, like the Linux unit, with
>    `WT_API` taken from the app's saved server. It also needs numpy, OpenCV and psutil, none of
>    which the Mac's python.org Python 3.13 has.
>
> **Open, by owner:**
> - **cilex-vision:** confirm that a station the server has never heard from starts **stopped**,
>   and does not inherit a Start given at a higher level. Otherwise "dormant until the operator
>   says" does not hold for a fresh install.
> - **Labs screen: FIXED the same day by the macOS agent** (the operator: "this is a bug and has to
>   be fixed"). It was listed here for the Linux agent. Where no worker ran, the station button was
>   still offered; ungoverned, it wrote `control.json` for nobody and flipped to "Pause scanning".
>   Now the button shows only while a scanner that can work runs here (`LabsStation.h`
>   `Station::switchable`: a fresh status, not `stopped`, `unreadable` or `fatal`), or to release
>   a hold. `absent` reads "No Labs scanner has run on this computer · Start and Pause appear here
>   once the scanner runs".
>   - Verified: `labs-station.cpp` 46 → 55 checks, and six mutants of the rule, every one killed.
>     The strip was rendered in eight states, EN and RU, from the real `LabsScreen.qml` with a
>     stub model (the `qml` tool, offscreen).
>   - Not run: the full app, because the operator's soak instance was live. On macOS a second
>     instance shares its QSettings through cfprefsd; `HOME` and `CFFIXED_USER_HOME` do not
>     isolate it (measured: a probe key written that way landed in the real
>     `~/Library/Preferences`). Also not run: the Linux and Windows builds.
> - **macOS agent:** proposed default for a laptop: claim nothing while on battery. Not built yet.

<!-- 2026-09-28 LABS: worker-0.3.1 -->
> **2026-09-28 — worker-0.3.1: segment joins, "busy", and a stale state word.**
>
> - **foreground_mask and colour_histogram failed some hours on every retry.** The office
>   reported colour_histogram on hiwatch-083bc1df39e9, 02:00Z: `frame 100: t_s 89.000 is before
>   the previous frame's 89.126`. Cause, confirmed by cilex-vision: `start_time` is the recorder's
>   whole-second file name (recorder-service `main.py:255`, parsed at `:545-553`), and `end_time`
>   is that start plus the measured duration (`:607`). So each segment sits early by its own
>   fraction of a second, and a join can run back by under one.
>   **Rule** (`plugins._window_frames`, `JOIN_SLACK_S = 1.0`): a segment whose first frame falls
>   ≤ 1 s behind the previous frame is moved later **whole**, its own spacing kept, until that frame
>   is level with the previous one. B3 reads that zero step as a duplicate, not an interval. Further
>   back than 1 s is refused, with the segment named. A step back **inside** a segment is not
>   touched (B3 still refuses it).
> - **Measured on the real hour, read-only on this box** (catalogue SELECT, filer GETs, fake
>   client; nothing claimed or submitted):
>   - old code, both analysers: failed after 72 of 120 segments, with the office's exact message;
>   - new code: 120/120 segments and 30 rows each, 2 segments moved, by at most 0.126 s;
>   - CPU for that hour: colour 129.5 s, fm 105.6 s (nice 19).
> - **The other analysers** (read, not run): track_linking already shifts such segments in its own
>   clock (`labs_track_linking.SegmentClock`). perceptual_hash starts a new chain on a step back.
>   It does not fail, but a no-change run is cut at such a join (inferred, not measured; it is
>   cilex-vision's code). The rest do not compare times across a join.
> - **"busy" is its own state.** A claim answered 503 `labs_busy`, or a 5xx with no code, used to
>   show "Cannot reach the server" on the Labs screen, though the server had replied. Now:
>   "The server is busy — will retry" / «Сервер занят — повторим попытку». Same one-minute wait.
>   Screenshotted in EN and RU.
> - **The status word followed the server late.** Measured on the pilot at 08:49:59 MSK, after the
>   deploy: governed, `server_mode: "stopped"`, `report_error: null`, but the state still said
>   the old local "paused", and so did its reports to the server. The wait woke only when claiming
>   became *allowed*, so a new *reason* not to claim waited out `RECHECK_S` (15 min). It now wakes
>   on either.
> - **Verified:**
>   - `labs-worker.py`: 298 checks, 11 new; 14 mutants, every one killed;
>   - `build` and `build68` compile.
>
> **Rollout:**
> - **Pilot:** 0.3.1 has been the live worker since its restart at 08:58:16 MSK. Its status.json
>   read `worker-0.3.1`, governed, `stopped_by_server` from 08:58:32 on.
> - **Booth, per the Windows agent's run at `1eea50d`:**
>   - Python suite: 285 pass / 0 fail / 13 skip. The skips are the named vendored-source pins.
>   - The C++ station and timeline tests compiled but could **not run**. Smart App Control refused
>     every fresh build (09:01–09:12 MSK), though the same tests ran at 08:45 at `ca65299`.
>   - While SAC is in that phase no freshly built native binary runs on the booth, so the app half
>     of 0.3.1 (the "busy" wording) cannot reach its wall. The durable fix is code signing
>     (`packaging/windows/SIGNING.md`). The Python worker is unaffected.
>   - **Correction (2026-09-29, from the Windows agent; not measured here):** that phase had
>     ended at 09:12 MSK, before this was written, and "cannot reach its wall" was wrong. 1.1.680
>     (preflight PASS 15:33 09-28) and 1.1.692 (PASS 02:23 09-29) passed the booth's preflight and
>     were ALLOWED by the office's SAC probe, and both walls run 1.1.692. The "busy" wording
>     shipped in 1.1.679 (`1eea50d`), so it is on them. SAC acts per hash, with occasional
>     blocking phases; it is not a standing block.
> - **Office:** 0.3.2 is staged in `C:\wt-labs`, hash-verified by the Windows agent (23:00 MSK). The visit
>   needs `pip install psutil`.
>   - ⚠ **The server has the office set to RUNNING** (station control by "admin", 15:28:25 MSK, pilot
>     DB). No worker runs there, so nothing claims yet: both Windows workers last beat at 08:30,
>     per the Windows agent.
>   - **The moment the office worker is started, it claims at once, so its wall guard (guard3
>     -Office) must start with it.** Or stop the office on the server before the visit.
> - **worker-0.3.2 on Windows** (the Windows agent's run at `3b5e4da`): 295 pass / 0 fail / 13 skip,
>   the same named pins. Every new "revoked" race passes. The booth's checkout is at `3b5e4da`.
> - **Coming from cilex-vision:**
>   - **Tonight 02:00 MSK:** query-api 1.0.89. The Stop is scoped to its target, the claim drops
>     its post-lease count, and the segment list and fetch answer `scan_unit_revoked`. Expect an
>     API gap of about 7-16 s.
>   - **Later, the v17 admin page** (`5aefa39`, 1.0.90, not deployed, no date). A workstation ×
>     analyser pair runs only once an admin "connects its hose", default off, existing stations
>     included. Until then its lane reads `stopped`; claims get 409 `labs_lane_not_running` with
>     new `never_connected` / `unplugged` keys. **Unplugging is gentle:** units in hand stay
>     leased and are finished. **The worker needs no change.** Lanes gate claims only
>     (`run_worker.py:263-277`, `worker.py:1098`, and nothing between units at `:1139-1157`);
>     only `revoked` or a hold drops a unit (`reporter.py:113-120`, `:217-229`). Two new checks
>     pin both behaviours, each killed by its mutant; 310 checks.
>   - **So after v17 the office claims nothing** until someone connects a hose there, even with
>     its station row set to running.
>
> **The control-plane live test ran on the pilot, 2026-09-28 ~20:11 MSK** (operator-approved; driven
> by cilex-vision; the worker side watched read-only here). Measured:
> - **Timeline (MSK):**
>   - 20:11:39.101: lease written (ledger).
>   - 20:11:52.885: Stop, and the unit is revoked at .892 with attempts unchanged.
>   - 20:11:52.935: the worker's status shows server mode `stopped` (50 ms after the Stop).
>   - 20:12:06.187: the claim finally answers, **27 s after its lease**, behind the post-lease
>     queue count (query-api log).
>   - 20:12:06.4: the worker's first segment call gets `409 scan_unit_not_open` ("That unit is
>     'revoked'") and it drops the unit.
> - **Held:** nothing submitted, nothing filed as failed, 0 segments, no decoder ever started, and
>   the station ended `stopped_by_server`.
> - **NOT exercised:** the report reply's `revoked` list and the decoder kill. The worker did not
>   know it held the unit until after the Stop, so its reports said `holding=[]`.
> - **Two findings, sent to cilex-vision:**
>   1. The claim should answer before its best-effort count, or use the cached one.
>   2. For segment calls they should return their existing `scan_unit_revoked` code, not
>      `scan_unit_not_open` with the state only in the sentence. Until then the station records
>      such a unit as "abandoned" (the behaviour is right; only the word is wrong).
> - **Second run, 22:52 MSK** (operator-approved in this session). cilex-vision triggered the Stop on
>   the worker's first segment fetch. Its "armed" reached them 2.5 h late, and this box's
>   process monitor had ended, so the worker side is from its journal and status.json:
>   - 22:52:37.471: first fetch. 22:52:37.527: Stop.
>   - **22:52:39.014: the report reply named the unit revoked, and the worker logged "dropping …
>     taken back by the server" and ran its kill.** The revoked path works.
>   - 22:52:40.127: the second fetch, already in flight, was refused 403 and ended the unit,
>     recorded "abandoned". Nothing was submitted or filed; frame_difference was restored at
>     22:52:49.
>   - **Whether a decoder was running, and was killed, is unknown:** the kill count was not
>     logged.
> - **worker-0.3.2 fixes both:**
>   - A lease-lost refusal of a unit the server has already named revoked is recorded
>     "revoked" (`worker._taken_back`, at the list, all three fetch paths and submit).
>   - The kill logs how many decoders it stopped (`run_worker.stop_decoders`).
>   - 308 checks, 10 new; 8 mutants, all killed.
>   - cilex-vision will also answer `scan_unit_revoked` on segment calls, in tonight's batch.
>
> **Not yet verified:** a unit decoded and submitted under 0.3.1, and the `revoked` → kill path
> (above).

<!-- 2026-09-28 LABS: THE SERVER'S CONTROL PLANE (worker-0.3) -->
> **2026-09-28 — worker-0.3: cilex-vision's Labs control plane, station side.** The server deploys
> after 08:45 MSK. The worker **reports itself every ~2 s** (`POST /labs/station/report`: state,
> the unit in hand, the machine's and its own CPU/memory). The reply is its **orders**: station
> and lane modes, plus units the server took back. A taken-back unit is dropped at once: its
> decoders are killed, nothing is submitted, and it is not filed as a failure. Before the deploy
> (the endpoint answers 404) the local file governs exactly as before. The worker switches over by
> itself: it probes every 60 s, and at once on 409 `labs_worker_not_reporting`.
>
> **Operator decisions (2026-09-28, in this session):**
> - **The server is the only switch** once it answers. The local `paused` flag no longer
>   governs. The Labs screen's button calls `POST /labs/control` for this host (admin).
>   `run_worker.py --pause` refuses, and says where the switch is.
> - **The wall's safety check can HOLD Labs off on its computer.** `control.json` `hold`, set by
>   `station.write_hold` / `--hold "why"`. It beats a server Start, survives restarts, drops the
>   unit in hand, and is **sent in every report**, so it is never hidden. cilex-vision shows it
>   on the admin page. It is released locally (`--release`, or the Labs screen's
>   "Release hold").
> - **Nothing about Labs is shown to non-admins.** The safety check is silent on the wall
>   (verified on the booth: 0 visible windows).
>
> **Also handled:**
> - Changed refusals: `labs_lane_not_running` skips that lane; `labs_busy` ends the pass for 60 s
>   and is never retried in place; `scan_unit_revoked` is dropped.
> - `queue_remaining: null` (which would have crashed every claim).
> - `camera_health` still needs this station's local opt-in; the server doesn't enforce one
>   station.
> - Vitals come from psutil or `/proc`, and are null when unmeasurable. The booth has psutil. The
>   office does not: install it on the operator's visit. Until then its Labs figures are null and
>   a Stop can't kill a running decoder early.
>
> **Verified:**
> - `labs-worker.py`: 287 checks, 34 new, each new one killed by its mutant.
> - Station tests: the hold, read across languages.
> - Live probe at 04:47 MSK: 404, the legacy path.
> - Labs-screen strip screenshots: stopped by the server, and held.
>
> **Not yet verified:** against the deployed server (cilex-vision's live test after the deploy).

<!-- 2026-09-28 LABS: PLAYBACK EVENTS LANE -->
> **2026-09-28 — Labs on the Playback timeline: the LABS button and its lane exist** (single-camera
> Playback only; operator requests, same night). Preferences → **Labs** (admins only) → "Labs
> events button in Playback" (`labs/playbackButton`, default Off) offers a **LABS** cell in the
> navigator header, beside MOTION. It shows only when that setting is on AND the session is admin
> (`PlaybackScreen.labsAllowed`); the setting is per computer, not per account. The cell toggles a
> **Labs lane** (`labs/onScrubber`, persisted, default Off): ten rows, one per analyser
> (`wtlabs::laneKeys()` = `LabsNames.keys`, pinned equal by `tools/tests/labs-timeline.cpp`).
>
> - **Data:** `GET /labs/observations` (cilex-vision `routers/labs.py:1887`), ONE request per analyser
>   for the VISIBLE window. It is debounced 350 ms, 3 in flight, and each request is an index scan.
>   Per analyser because the endpoint returns only the newest ≤2,000 rows of a window.
> - **Honest states:**
>   - a row cut at the ceiling says "N+" and hatches the older part it did not load;
>   - "…" while loading, "ERR" on failure, 0 when nothing was filed;
>   - lane-wide: loading / no answer / not in scope / "nothing filed — may not have been scanned";
>   - a camera change clears at once.
> - **Painting:** `LabsLanesItem` is the app's first C++ painted item: observations merge into
>   pixel runs, because one camera filed 590 rows in one hour.
> - **Interaction:** hover shows `LabsCard`, the server's sentence (UI language) plus every typed
>   field and metric. Click seeks to the observation's start. When the pointer is inside several
>   observations, the smallest wins.
>
> **Verified by screenshots on real data** (hiwatch-083bc1df39d1):
> - 27 Sep 01:00–02:00: counts equal the DB (SHAPES 312, TRACKS 202, …);
> - 1-hour zoom; cards for shapes, tracks, colour and day/night;
> - Russian;
> - forced cut (`WT_LABS_LIMIT=40`);
> - setting off → no cell or lane;
> - real non-admin session → no cell or lane.
>
> **Not verified:** the refusal, unreachable and not-in-scope states (code only), and a
> camera_health card (no such rows in these windows). The running wall shows it after its next
> restart. Dev hooks: `--labs-hover-test=<analyser>`, `--pb-view-test=<minutes>`,
> `WT_LABS_LIMIT=<n>`.

<!-- 2026-09-27 LABS: FIRST LIVE UNIT OF EVERY ANALYSER -->
> **2026-09-27 — LABS: EVERY ANALYSER HAS RUN ONE LIVE UNIT. All ten done at attempt 1: 0
> failed, 0 abandoned.** This was the operator-approved plan, run 02:20–02:47 MSK on query-api
> **1.0.80** (CV's 02:17 deploy, which bounds claims to settled hours; the hold below is
> lifted). The runs were sequential and manual: `run_worker.py --live --analyzer X --units 1`
> under `nice 19`/`ionice idle`/`/usr/bin/time`. CV switched each of the eight test analysers
> off afterwards; **frame_difference and illumination stay ON**, as before. The station
> scanner was **PAUSED throughout and still is** (see the last paragraph).
>
> | analyser | camera-hour | segs | rows | work s | CPU-s (+ffmpeg) | max RSS MiB | claim s* |
> |---|---|---|---|---|---|---|---|
> | camera_health | 083bc1df39fa 09-17 12Z | 0 | 0 | 0.07 | 2.8 | 60 | 17.1 |
> | audio_energy | 083bc1df39d1 09-26 22Z | 120 | 1 | 84.0 | 6.4 | 61 | 35.3 |
> | blob_geometry | same | 120 | 312 | 212.8 | 173.6 | 186 | 27.0 |
> | colour_histogram | same | 120 | 30 | 174.8 | 141.5 | 422 | 25.4 |
> | foreground_mask | same | 120 | 30 | 171.6 | 134.3 | 309 | 31.3 |
> | optical_flow | same | 30 | 2 | 37.1 | 37.5 | 73 | 26.1 |
> | perceptual_hash | same | 12 | 12 | 10.0 | 8.9 | 66 | 31.7 |
> | track_linking | same | 120 | 202 | 130.1 | 142.4 | 88 | 22.9 |
> | frame_difference | same (main) | 4 | 1 | 3.8 | 6.3 | 291 | 18.5 |
> | illumination | 04eecdd44b03 09-26 22Z | 2 | 2 | 2.5 | 5.6 | 89 | 16.3 |
>
> *Claim = the worker's claim→submit time minus the unit's own work: DERIVED by subtraction,
> not timed directly. 16–35 s per claim is CV's to fix (their caching item).
>
> **Server-side defects found, all CV's:**
> - camera_health was handed an hour with no main footage. The fix is `labs_analyzers.stream_type`.
> - audio_energy is claimed on cameras without audio. It will be scoped to audio cameras.
> - The event layer (D1–D6) files a row per window whatever happened: foreground_mask 30 of 30
>   windows, perceptual_hash one per sampled segment. Its group sentence for the hour's one real
>   event gets the subject, the count and the place all wrong.
>
> **Eyes-on audit of that hour (hiwatch-083bc1df39d1, "10 Улица 13"; read-only; frames kept
> local, never committed).** It contains ONE real event: a car comes through the gate,
> 22:29:57–22:30:44Z. foreground_mask, optical_flow, perceptual_hash, track_linking and
> blob_geometry all caught it. Nearly everything else is two things:
> - **A pale streak close to the lens.** It accounts for 182 of 196 `shape_indeterminate`
>   rows, 20 of 30 foreground_mask boxes and 77 of 202 track entries.
> - **Wind in the foliage.**
>
> Consequences:
> - **B6 (track_linking)** links the streak to foliage a quarter frame away: 9 of the 10 long
>   tracks that start on the streak are false. CV is fixing the linker, and will announce the
>   pin change first.
> - **frame_difference's "25 s of activity"** is wind. I reproduced its row exactly with its
>   own decoder.
> - **A4–A6 (blob_geometry)** gets no size or fill floor: on the booth, blobs of the same size
>   were real people. It gets spatial recurrence suppression instead. That must span minutes,
>   not consecutive keyframes: the streak re-detects at a median gap of 11 s, and only 15 of
>   181 gaps are one keyframe. **Built: A4–A6 1.1.0 (4de3ba2, Windows agent)** folds a
>   recurring source into one counted row. Measured read-only on the same live hour through
>   `run_unit`: **312 → 98 rows**; every row is an original detection; Σ `recur_count` = 312.
>   Streak 188 → 21, foliage 77 → 30, and the car still files every detection. 1.0.0 run
>   the same way reproduced the live 312 rows exactly. Worker side: 642759b stops carrying
>   the background model backwards across units (measured at dawn: 10 extra rows in minute
>   0, none in minutes 3–6 where a fresh model files 12), and times each row from its own
>   segment. 78bbfa2 keeps every A4–A6 row a point in time, since an event group may never
>   exceed 300 s (cilex-vision `routers/labs.py:194`). blob_geometry stays OFF server-side
>   until cilex-vision and the operator decide.
> - **Physical:** something sits near that camera's lens. It's the operator's to check.
>
> **Station files are Windows-safe, verified on the booth** (9452c30 → 482f8cc; the Windows agent
> found the race and ran every fix). Windows briefly refuses both sides of an atomic replace.
> Unfixed, a flat-out writer failed 64% of its replaces and the reader 8% of its opens. Now both
> sides retry, 20 × 5 ms: 0 failures in every booth pair, in both directions. Four more defects
> fell out of that and are fixed:
> - a Pause could drop the camera_health opt-in;
> - on Linux, Qt's member `QFile::exists()` reported "missing" for a file that was always there
>   (~1.7% under a flat-out writer; Windows 0);
> - a paused worker never re-read the server, so the screen said "needs a server update"
>   against 1.0.80;
> - Windows phase times came in 15.6 ms steps.
>
> The station test now runs under a non-ASCII temp home (the booth's profile is "Охрана"), refuses
> to run unless isolated, and passes 40/40 there.
>
> **The scanner had been switched on.** `control.json` was set to `paused: false` at
> 2026-09-26 23:20 MSK by "watchtower app (admin)" (someone pressed Resume on the Labs screen).
> It claimed nothing, because the worker refuses servers older than 1.0.62. That would have
> stopped holding once the 15-minute recheck saw 1.0.80, so this box re-paused it at 02:20 MSK.
> Resume from the Labs screen when continuous scanning is wanted. It then claims for whatever
> the server has switched on. That is CV's design; a claim against a switched-off analyser has
> not been tested from here.

<!-- 2026-09-26 LABS: THE WORKER EXISTS, NOTHING HAS RUN -->
> **2026-09-26 — LABS: THE STATION WORKER EXISTS; NOTHING HAS EVER RUN.** Labs is cilex-vision's
> offline-analysis scheme: a station claims one camera-hour ("scan unit"), runs an analyser on
> its footage, and submits observations. The worker is `tools/labs/` — `worker.py` (claim,
> lease, fetch, retry, submit), `plugins.py` (analyser adapters), `run_worker.py` (entry point:
> a DRY RUN unless `--live`; token read from `warden.conf`). Hermetic tests in pre-commit:
> `tools/tests/labs-worker.py` (151 assertions), `tools/tests/b1-illumination.py` (40).
>
> **Measured 2026-09-26 07:20 MSK against the pilot (1.0.61):** `labs_analyzers` has
> `illumination` and `frame_difference` enabled, the other nine disabled; `labs_scan_units` has
> **0 rows** — no station has ever claimed a unit. **A live run is a globally visible write and
> waits for the operator's go-ahead in chat** (proposed first: B1 `illumination`, one camera,
> one hour).
>
> **Plugins built — ten, registered in `run_worker.PLUGINS`** (updated 2026-09-26 evening,
> 770719c): illumination (B1), blob_geometry (A4–A6), frame_difference (A1/A2; needs
> `window` on list_segments, CV a6671c5, announced for 2026-09-27 02:17 MSK — until then
> the worker skips it by itself), audio_energy, optical_flow, perceptual_hash,
> camera_health (B2), foreground_mask (B3), colour_histogram (B7), track_linking (B6).
> Not built: image_embedding. All ten ran on REAL footage through the worker, read-only
> (`tools/labs/smoke_real_footage.py`): every body passes the live schema and the server's
> metrics rules. **camera_health: EXACTLY ONE STATION may run it** (cilex-vision's rule —
> two stations would each teach its per-camera Baseline from alternate hours). Its state
> persists under `~/.local/state/watchtower-labs/camera_health/`. This box is that station
> unless the operator says otherwise.
>
> **The first live claim (2026-09-26 14:35 MSK) was REFUSED — correctly:** this box has
> never had a station token of its own. Its row (`8918c7c5…`, auto-registered 07-26)
> has `token_hash` NULL and its heartbeats pass through the shared bootstrap fallback,
> which Labs deliberately does not accept (`labs.py:547-553`). CV has been asked to issue
> one onto the EXISTING row, written straight into `warden.conf` — never through chat.
>
> **Cost, measured (smoke run, one camera-hour each, single runs on a host at load ~7 —
> own-decoder analysers moved ±50% between runs without any change):** illumination was
> 13.1 CPU-s and camera_health 22.9, against cilex-vision's 1.89 for camera_health on its
> own decoder. ~4.1 of ~5.0 CPU-s per main segment was `frame_source` measuring the
> keyframe interval by a full decode. **Fixed by the Windows agent in 933755f** (one
> demux pass; identical counts on 12/12 segments here, 28/28 on the booth): illumination
> now **1.5**, camera_health **3.2**, blob_geometry 14.1 → 4.6, colour_histogram 8.7 → 3.5.
>
> **The Labs screen and station scanning (2026-09-26 evening, 34d0416 → 1d0aece).** A
> **Labs** entry sits in the left menu, **admins only** (as CV's own /admin/labs): per
> analyser its server ON/OFF switch (PATCH, audited by CV), cost, and "done / waiting"
> counts from ONE `GET /labs/pipeline` — **at most every 30 min while open, or on
> Refresh** (CV measured the per-analyser `/labs/scan/status` it replaced at 5.26 s and
> ~1 GB of page reads per call; don't bring it back — their cached all-analysers coverage
> call is coming). Above that, THIS station: scanning state and Pause (anyone) / Resume
> (admins). The scanner is `run_worker.py --loop` as a **systemd --user service
> `wt-labs-worker`** (Nice 19, CPU+IO class idle), **installed on this box and PAUSED**:
> default-deny through `~/.local/state/watchtower-labs/control.json`, status in
> `status.json` (`tools/labs/station.py`; the app mirrors the path in `LabsStation.h`).
> It also claims nothing from a server older than 1.0.62. Windows/Mac have no packaged
> scanner yet: their Labs screen says "Scanning is not set up on this station".
>
> **First live unit, 2026-09-26 12:01Z** (after CV issued the token): illumination,
> hiwatch-083bc14f0009, hour 12:00Z — done, 2 rows (`day`, astronomy `day`), en/ru
> sentences and one event group, all confirmed in the database. **It exposed a server
> defect: the claim hands out the hour still in progress** (`routers/labs.py:996`,
> `newest_useful = now`, hours newest-first), so B1's two samples came from the hour's
> first minute and the hour is now marked done. **Newest-first claims are HELD until CV
> bounds the claim to ended hours.** Operator decision the same day: after that fix, CV
> switches the other eight analysers on for one live unit each, then off.
>
> **Three rules that have already cost something.** (0, 2026-09-27) **A test that writes
> station files must prove it is isolated first.** `labs-station.cpp` redirected only
> XDG_STATE_HOME. On Windows `stateDir()` reads LOCALAPPDATA, so the test wrote into the booth's
> REAL `%LOCALAPPDATA%\watchtower-labs`; on a station with a running scanner its control.json
> writes would pause or resume it. It now refuses to run unless the directory lands inside its
> own temp dir (c0affd6). The stress tools refuse the real directory too. (1) Vendored analysers (`labs_*.py`) are
> cilex-vision's, byte-identical, each pinned by sha256 and source commit in
> `labs-worker.py`'s `VENDORED` — never edit one; re-vendor from the named commit. (2) The
> worker must IMPORT ON WINDOWS: c934dda vendored a top-level `import resource`, which broke
> the worker — and, through pre-commit, every commit — on the booth PC. Fixed in 87674c6,
> verified here by simulation only (the booth's own run is pending). The test now checks
> load-time Unix-only imports from Linux; it cannot see Unix-only attributes (`os.fork`) —
> only a Windows run does.

<!-- 2026-09-20 STATION TOKENS ARE NO LONGER A HUMAN'S JOB -->
> **2026-09-20 — NOBODY HANDLES A STATION TOKEN ANY MORE, and wt-office-01 needs ONE ADMIN
> SIGN-IN (not a build).** Operator goal: *"decommission the token, if the user has logged in
> they are already authenticated."* Delivered without removing the credential, because removing
> it was measured unsafe — CV proved `machine_key` is `host:<hostname>` with registration
> upserting ON CONFLICT, and the booth's real row is keyed that way IN PRODUCTION, so a session
> merely asserting a hostname could upsert onto a live station's row and make a dead wall look
> alive. Pro Mobile refused to lose `warden_up` for the same reason. Both were right.
>
> **What shipped instead (c1d890f, 1737c78, fa624f7):** the app self-provisions. CV's
> `POST /client/stations` takes the operator's ORDINARY COOKIE SESSION (`get_current_user`) and
> mints server-side, so an admin who has signed in has already proved everything CV wants. The
> app calls it, writes `warden.conf` at 0600, and Warden picks the token up within a heartbeat.
> Gated hard: only under Warden, only when Warden reports NO token, only for an admin session,
> once per process, `WT_NO_STATION_ENROL=1` to disable. A station that already has a token is
> never re-minted. The plate now names the errand when the session cannot provision
> ("sign in once as an administrator and this station enrols itself") — the office wall signs in
> as `office`, a VIEWER, which is why it would otherwise have stayed silent forever.
>
> **Warden 1.4.4** re-reads `STATION_TOKEN` per beat, so enrolment needs no restart; below that
> the app SAYS so rather than succeeding silently (on Windows the task uses
> `MultipleInstances IgnoreNew`, so a running Warden never restarts itself). **Warden also takes
> its backend from the app's saved server now** (50eeaa9) — it used to default to a dead
> `192.168.1.79` that times out after 46 s rather than refusing, which is why that wall beat into
> nothing for days.
>
> **State of wt-office-01 as of 0f63f18 (Windows agent, measured on the box):** app 1.1.477,
> Warden 1.4.4, sends `wt-office-01`, `BACKEND_URL` corrected to `192.168.1.4`, `STATION_TOKEN`
> empty deliberately. **The only remaining act is one administrator sign-in at that wall.** CV's
> `cilex_station_hint_unmatched_total` climbing with that hostname means "correctly built,
> correctly addressed, nobody has signed in yet"; it stops at enrolment, and CV's derivation then
> records `identity_source='app'` (verified in their deployed image for both `wt-office-01` and
> `WT-OFFICE-01`). **Do not paste a token into that box** — that is the errand the whole change
> removed, and the operator declined it explicitly.

<!-- 2026-09-14 20:40 PURGE STOPPED SHORT -->
> **2026-09-14 20:40 — THE PURGE WAS ONLY PARTLY DONE, AND CV STOPPED DELIBERATELY. The ~2 TB
> of orphans was NOT deleted.** The operator's *"wipe it clean"* was executed for the
> pre-catalogue volumes (628 GB+, zero footage cost) but NOT for the orphan set, and the reason
> is the operator's to weigh: **`fsck` SILENTLY TRUNCATES.** CV gave it a 200-volume list
> containing five volumes they had individually confirmed at 95 % orphaned, and it reported none
> of the five — so the orphan set cannot be enumerated reliably and they would not delete from a
> list known to be incomplete. The alternative, whole-volume deletion, measures **683 MB of
> orphan against 358 MB of genuinely referenced footage per volume**, so reclaiming ~1.7 TB
> would destroy **~0.9 TB of catalogued footage**. CV judged that a bad trade and stopped rather
> than spend it. **That judgement is now the operator's to confirm or overrule.**
> **CORRECTION — VACUUM IS NOT DEAD.** CV told this box twice that compaction does nothing on
> this build, including a "0 of 10,995 volumes shrank" test offered as definitive. Every such
> test was run while the disk was below `minFreeSpace=5GiB`, which makes the volume server
> refuse compaction outright. With 250 GB free it works: vol 32 went 1,075,552,848 →
> 736,042,592 bytes, DeletedByteCount 337,979,104 → 0. **It is still the wrong instrument here**
> — 25 volumes per 16 minutes measured, so ~75 hours for the 7,027 volumes holding 763 GB, and
> it must rewrite 7.4 TB of live bytes to reclaim 0.76 TB; it also holds the admin `lock` for
> its whole run, blocking `volume.list` and reaping.
> **CAVEAT ON THE ModifiedAtSecond METHOD recorded above:** now that retention deletes actually
> LAND, a tombstone write updates a volume's `ModifiedAtSecond`, so an old volume receiving a
> delete today looks freshly written. **The heuristic degrades over time** — it was clean on
> 09-14 precisely because the deletes had been bouncing.
> **EINVAL DETECTION RULE, from the residue this box caught at a trickle:** `ReadOnly:false AND
> DeletedByteCount > 0` = marked writable but never compacted, i.e. the stale read-only handle
> that EINVALs on every write. `ReadOnly:false AND DeletedByteCount == 0` = vacuumed cleanly and
> safe. 27 such volumes were left by a vacuum job killed mid-batch; re-marked read-only and the
> trickle went to zero.
> State 20:40: 07fa 244 GB, 4fa8 394 GB, root 48 GB, uploads 224/min, drops 0, EINVAL 0,
> retention bounces 0.

<!-- 2026-09-14 15:50 PURGE RESULT -->
> **2026-09-14 15:50 — THE PURGE WORKED AND COST ZERO FOOTAGE. Verified from this box:
> 07fa 5 → 300 GB free, 4fa8 20 → 473 GB, drops 0, uploads 232/min, root 50 GB.** No drop
> window occurred; it beat the 15:48 floor. 628 GB reclaimed from 1,200 volumes with 492 still
> running, 0 errors.
> **THE METHOD IS THE THING TO KEEP — it trades no footage at all, unlike the garbage-ratio
> passes that cost up to 72.4 GB of live bytes.** The catalogue covers 2026-09-09..09-14 and
> nothing older. Every volume carries `ModifiedAtSecond`, its last write, already present in
> `volume.list`. **Any volume whose last write predates the catalogue's oldest day cannot hold
> a single referenced needle — pre-catalogue by construction.** That set was 1,692 volumes last
> written 2026-06-15..2026-08-25, a fifteen-day margin below the catalogue floor. No fsck, no
> vacuum, no writable volumes, no footage traded. **This is the reclaim instrument for this
> box; garbage ratio was the wrong one.**
> **What the orphans actually were:** day-directories for 2026-08-10..08-16 with no catalogue
> rows at all. Retention had deleted their rows weeks earlier and the S3 deletes bounced off
> read-only volumes — the leak this box's filer log line exposed. Those were the 2.77 TB.
> **CV's own correction, recorded because it runs against them:** they estimated 844 GB for all
> 1,692 volumes, but 1,200 have already yielded 628 GB — so `Size` in `volume.list` UNDERSTATES
> on-disk footprint for old volumes. Their estimate was low, not high.
> Still to come: a fresh orphan scan once this finishes, and any leftover orphan day-directories
> cleaned through the app path.

<!-- 2026-09-14 15:30 OPERATOR DECISION -->
> **2026-09-14 15:30 — OPERATOR AUTHORISED THE PURGE.** Verbatim: *"Get rid of as much stale
> data as possible wipe it clean"*. Relayed to CV with the scope stated explicitly, because the
> phrase is broad enough to be dangerous read literally. **Scoped as: (1) the 2.77 TB of
> unreferenced needles** — 3,313,872 on disk vs 1,728,560 the DB knows — **and (2) the ~950 GB
> of already-tombstoned garbage.** **Explicitly NOT scoped to** the 5.13 TB of footage inside
> retention that the catalogue references; nothing in the instruction shortens retention or
> drops live recordings, and CV was told to come back rather than assume if they read it
> otherwise. This reverses the earlier refusal of the app-level orphan path.
> Sequencing left to CV: the authorisation arrived ~18 min before the next floor (4fa8 at
> 24 GB, 53 GB/h, floor ≈15:48), so buying time with another garbage-ratio pass first and
> purging unhurried, versus going straight at the purge and accepting a possible drop window,
> is theirs to judge. This box has the drop-rate measurement armed either way.

<!-- 2026-09-14 12:15 pointer -->
> **2026-09-14 12:15 — WE ARE NOW DELETING REAL FOOTAGE TO KEEP RECORDING, AND THE CHEAP
> PASSES ARE EXHAUSTED.** CV's second deletion pass landed at 12:10, before the floor, so
> there were NO drops this time (this box flagged the approach at 23 minutes out rather than
> reporting drops after the fact — that is what made it clean). Verified here at 12:13:
> 07fa 16 GB free, 4fa8 152 GB, root 49 GB, uploads 288/min, drops 0, EINVAL 0, retention
> bounces 0. Runway on 4fa8 ≈ **3 hours** at 50 GB/h.
> **THE COST IS NO LONGER FREE.** To reach 170 GB, CV had to drop the garbage-ratio threshold
> from ≥70 % to ≥47 %: 234 volumes, 0 errors, **up to 72.4 GB of LIVE bytes in 17,264 needles
> destroyed**. Some fraction is DB-orphan junk rather than footage but it cannot be split
> per-volume, and CV is recording it as real footage rather than rounding it down. The
> high-garbage cohort is now thin, so **the next pass costs disproportionately more footage
> per GB**.
> **SO THE 2.77 TB IS THE FORK, NOT AN OPTION.** Every further hour of runway is now bought
> with recorded footage. The unreferenced 2.77 TB (7.90 TB live on disk vs 5.13 TB the DB
> knows; corroborated from this box at 7.87 TB) is the only source of space that costs
> nothing, and removing it needs an app-level orphan path — **the operator's call, declined
> once before**.
> **RUNNING TOTAL OF FOOTAGE LOST TO THIS INCIDENT:** 21.9 GB / 5,834 segments / 54 cameras
> (01:02–01:12, backpressure latch); ~16 minutes fleet-wide (10:28–10:44, both nodes full);
> up to 72.4 GB deliberately deleted (12:10, to prevent a third).

<!-- 2026-09-14 11:30 pointer -->
> **2026-09-14 11:30 — THE 2.77 TB IS FOUND, AND IT IS AN OPERATOR DECISION (declined once
> before).** CV reconciled disk against catalogue: **7.90 TB live bytes / 3,313,872 needles on
> disk against 5.13 TB / 1,728,560 segments the database knows about — 2.77 TB and 1.58 M
> needles the DB has no row for but the FILER still references.** Corroborated independently
> from this box: 8.91 TB used across both nodes minus 1.04 TB garbage = 7.87 TB live, against
> CV's 7.90. That is why `fsck` finds no orphans — from SeaweedFS's view they are legitimate
> files, so only an APP-LEVEL orphan path can remove them. **Deleting them is the operator's
> call.**
> **TWO CORRECTIONS THAT KILL EARLIER CONCLUSIONS.** (1) **Vacuum does nothing on this build** —
> CV tested it properly with `volume.list` snapshots either side of vacuum runs: **0 of 10,995
> volumes decreased in Size**. The 20 GB drop that looked like compaction was their 21 deleted
> volumes. So every "mark writable so vacuum can run" step, *including the one that caused the
> 02:35 outage and the 21.9 GB of lost footage*, bought nothing. (2) What DOES work is
> `volume.delete` on whole volumes targeted by garbage ratio — no free space and no writable
> volume needed; 50 volumes at ≥70 % garbage freed 41 GB + 2.7 GB.
> **THE DURABLE WIN:** retention deletion had been bouncing off read-only volumes on every pass
> — the ~40 GB/day leak — and is now **0 bouncing deletes in 5 minutes**. Leak closed.
> **FOOTAGE LOST SO FAR: 21.9 GB / 5,834 segments / 54 cameras (01:02–01:12), plus ~16 minutes
> fleet-wide at 10:28–10:44.** Both while spool and root stayed healthy: **the drop counter is
> the only instrument that catches this failure** — see `tools/storage-sample.py`.
> Gotcha for the next person: `fsck` needs `-filer=seaweed-filer:8888` passed explicitly or it
> dies with "received empty target in Build()".

<!-- 2026-09-14 pointer -->
> **2026-09-14 01:10 — THE PILOT'S STORAGE IS ~5.5 HOURS FROM ITS FLOOR AND THE ONLY
> REMAINING LEVERS ARE THE OPERATOR'S.** Node 07fa: 99 GB free (97 % used), falling
> 17 GB/h. Node 4fa8: 284 GB, 38 GB/h. Measured continuously by `tools/storage-sample.py`
> into `docs/perf/2026-09-12-rocknroll-soak/storage-watch.log`; the upload path has been
> clean on every counter for 32 hours. **All non-destructive options are exhausted, and
> that is CV's measurement, not a guess:** `volume.vacuum` is a confirmed NO-OP on this
> build under every invocation tried; the one-off sweep of 219 fully-dead volumes (191.8 GB,
> done by hand at 19:06–19:21 on 09-13) cannot repeat because zero fully-dead volumes
> remain; `volume.balance` works but moved one volume in twelve minutes. **1,140 GB is
> locked inside 6,459 READ-ONLY volumes (58 % of 11,044) that nothing on the box can
> reach — and that count only ratchets upward.** What remains is **lower retention, more
> disk, or the floor**, which is a FOOTAGE-POLICY decision and the operator's alone;
> neither agent is making it. Asked of CV so the choice is between measured outcomes:
> for retention of 5.0 / 4.5 / 4.0 / 3.5 days (current 5.5), how many volumes tip to
> fully-dead and how much disk that actually returns — **because with compaction broken,
> lowering retention does NOT free disk by itself**: it raises garbage inside volumes that
> stay the same size, and disk returns only when a whole volume tips and is deleted.
> **THE CLOCK, confirmed with CV 2026-09-14 02:30 — ACT BEFORE 06:25, and the 08:06
> failure is the 09-12 outage repeating rather than a clean stop.** The two nodes do not
> fail independently: the master is already load-aware (CV measured 40 assignments —
> 8/12 and 3/17 split toward the emptier node), so when 07fa reaches `minFreeSpace`
> around **06:25** everything routes to 4fa8, which then drains at the combined 53 GB/h
> instead of 35 and reaches its own floor around **08:06**. Quoting each node's own
> runway gives 08:56 and overstates the deadline by ~50 minutes. **The 06:25–08:06 window
> is not merely half capacity — it actively converts recoverable disk into PERMANENTLY
> frozen disk**, because everything landing on 4fa8 pushes more of its volumes read-only,
> and a read-only volume can never expire its contents on this build. **At 08:06 the
> recorder does not stop cleanly: it spools to the container-local disk, which is exactly
> what took the root filesystem to zero and wedged the filer on 09-12.** So fleet
> recording stopping is the SECOND failure, not the first. Expect a brief burst of upload
> failures at the 06:25 handover as in-flight uploads are reassigned — that is normal and
> clears; the signal that matters is failures that PERSIST (this box's alarm now requires
> two consecutive samples for exactly that reason).
> **If retention drops, this box owes one piece of work:** make the retention horizon
> legible in the timeline and coverage views, so a guard scrubbing past it sees a marker
> rather than silence they would report as missing footage.

<!-- 2026-09-12 pointer -->
> **2026-09-12 — rock-n-roll soak COMPLETE: 409 runs over 8 groups, 02:10–11:00,
> interrupted 08:09–09:51 by a HOST DISK FAILURE (not ours) and resumed once the
> backend agent cleared the box.** Full report + every number:
> `docs/perf/2026-09-12-rocknroll-soak/README.md`. Four client defects found,
> fixed and reproduced during the run: the live auto ladder took the HD rung
> first (4,349 → 185–260 ms, `2cdfe04`); on-page live opens did not adopt the
> parked pipeline (→ 135–239 ms, `ac8cfa1`); hero scrubber jumps stalled 6.2–6.8 s
> whenever the target landed in the last segment the player holds (median 6,251 →
> 54–269 ms, `1e2c4a2`, `2168826`); and our HLS proxy's read-ahead fetched
> segments OUT OF ORDER and cached the corrupt continuity joints that resulted —
> hardware-decode wall corrupt packets 116 → 4 → **0** over 71 segments
> (`1e2c4a2`). **HOST INCIDENT, CV's side, still open at the time of writing:**
> seaweed runs its volume servers with `-max=0`, whose allowable volume count is
> derived from free disk, so at 0 free slots every upload to `raw-video-warm`
> fails, the recorder spools to its container-local disk at ~750 MB/min and fills
> the box — which is what stopped this soak and left the Watchtower supervisor
> unable to start. **RESOLVED 09:04** by CV restarting one seaweed volume server:
> `-max=0` recomputes the ceiling only AT STARTUP (that node 4198 → 4307, topology
> free slots 0 → 109), uploads went clean and the 46 GB spool drained. CV fixed four
> comments in their codebase that documented `-max=0` as "unlimited" (`d9879e9`).
> **ROOT-CAUSED AND FIXED 2026-09-12 ~16:40 (CV, `b0a49eb`) — and the `-max` lever both
> boxes pushed to the operator for two days was WRONG.** The volume-server binary is a
> "30GB" build: with `-max=0` it sizes capacity in 30 GB units, while the master ran
> `-volumeSizeLimitMB=1024` — a 30× over-reservation, so it reserved 30 GB of disk for
> every volume the master would fill to 1 GB. An explicit `-max` does NOT fix it: CV
> recreated a node with `-max=6500` and it came back reporting 4322, because an explicit
> max is only an UPPER BOUND and the disk-derived figure binds first. The fix was
> `-volumeSizeLimitMB 1024 → 30000`, which raises no slot count at all — it makes the
> ~11,000 EXISTING volumes writable again (raw-video-warm averaged 1,072 MB, so every one
> had passed the old limit and read as full). **`Topology Free` is no longer a health
> signal: it reads 0 and that is now CORRECT.** Verified independently from this box at
> 16:35: `/dir/assign` returns valid fids for raw-video-warm and raw-video-hot with Free
> still 0, and the master logged zero "failed to pick" in three minutes. The real
> signals are the master's failed-to-pick count, s3 assign errors, and the recorder spool
> climbing off its ~1 GB steady state. **STILL OPERATOR DECISIONS, two:** (1) CV's question on 0-byte segments (my
> recommendation: 503 + retry, never a blank tile served as ready); (2) **NEW, with
> numbers, raised by CV 2026-09-12 ~17:00: whether to raise
> `maxParallelVacuumPerServer` above 2.** Retention deletion only TOMBSTONES needles —
> only vacuum returns disk — so free disk now declines monotonically at roughly the
> footage rate. Measured here 16:40: node 07fa 561 GB free with 622 GB of garbage, node
> 4fa8 1,258 GB free with 703 GB. CV's projection (their words, not a measurement): 07fa
> has on the order of 28 hours, 4fa8 perhaps 63, and vacuum reclaims ~12 GB/hour against
> 1,325 GB of garbage — about 110 hours to clear while new garbage arrives, so it falls
> behind rather than catches up. CV has NOT pulled the parallelism lever because vacuum
> IO is what drove the 07:25–08:09 storm this box measured; more parallelism means more
> of that IO. A second risk from their own fix, on the record from them: at 30 GB
> volumes, vacuuming one rewrites up to 30 GB instead of 1 — bigger IO spike per volume.
> This box samples all of it every 5 min via `tools/storage-sample.py` into
> `docs/perf/2026-09-12-rocknroll-soak/storage-watch.log`. **MEASURED OVER 26 HOURS
> (307 samples, 2026-09-12 16:40 → 2026-09-13 18:40): CV's projection held and the
> decision is now DUE.** Node 07fa went 561 → 118 GB free (−17 GB/h in the last hour),
> node 4fa8 1,258 → 403 GB (−36 GB/h): **6.6 hours and 11.1 hours respectively to
> `minFreeSpace=5GiB`**, at which point that node stops accepting writes and assignment
> fails for it. Reclaim is running at ZERO — no vacuum logged on either node, and 07fa's
> garbage ROSE 622 → 634 GB over the 26 hours — so the "12 GB/h vs 1,325 GB" figure is
> not even in play. Largest volume grew 1.10 → 2.01 GB, so the 30 GB trade is beginning
> to land (this box alarms at 4 GB). Upload path clean throughout: failed-to-pick, s3
> assign errors and recorder upload failures all zero for 26 hours. Measured: the soak was NOT driving it — spool growth was identical with the
> soak stopped. **Data-loss finding:** 147 orphaned spool files were the ONLY copy of
> their footage (zero `video_segments` rows) and sat on a container writable layer a
> rebuild destroys; CV archived them to `/mnt/cilex-storage/orphaned-spool/2026-09-12/`.
> The real class is **application data written to container writable layers**, not
> "the spool leaks".

<!-- 2026-09-08 pointer -->
> **2026-09-08 — live open from a lit wall: 128–212 ms (n=5 first opens, median
> 164 ms), operator target 500 ms MET; re-opens inside the grace 14–377 ms (n=20).
> Was 1.8–2.5 s. Fix is client-side: `RtspVideoSource` PARKS a lit pipeline for
> adoption instead of destroying it (`ParkingLot`). The two HISTORICAL targets
> (single-camera playback ≤1 s, 16-wall ≤2 s) still have ZERO measurements — the
> station credential is 403 on review/mosaic by design; an operator credential
> (`~/.config/watchtower-warden/ttff-soak.cred`, 0600, operator role) is the ask.**
>
> Cause, traced stage by stage (`docs/perf/2026-09-08-live-ttff/README.md`): a new
> RTSP consumer joins go2rtc's running producer mid-GOP; the cameras' keyframe
> period is 3.3 s on `-sub`, 4.0 s on main; the VA decoder emits empty surfaces
> until the keyframe and the sink rightly drops them. Opening from the wall tore
> the tile's pipeline down and built a fresh one — the slow path on every open.
> The morning probe's warm numbers (65–183 ms) are WITHDRAWN: `avdec_h264` counts
> corrupt pre-keyframe frames (+137 ms vs the parser's first keyframe at +1267 ms).
>
> Still slow, and why: HD promotion on a first open 4.5–4.7 s (fresh main-stream
> join, 4 s GOP, HEVC parameter sets in-band) with SD on screen from ~160 ms;
> tiles beyond `maxLiveDecodes` (default 64 — not a 16-wall case); cold opens of
> armed cameras (morning letter). Evening letter to CV: the keyframe period bounds
> every fresh join, three ways to shorten it, their call.
>
> Knobs: `WT_PARK_MS` (2500; 0 = old behaviour), `WT_PARK_MAX` (4),
> `WT_STATION_TOKEN`/`WT_CV_URL` (headless station mode), `WT_FOCUS_DELAY_MS`,
> `WT_FOCUS_CLOSE_MS`. All in `docs/DEVELOPMENT.md`.
>
> **Afternoon, with the operator's new `soak` account (operator role, the first
> review-scoped login this box has had): PLAYBACK and 16-WALL measured for the
> first time — `docs/perf/2026-09-08-ttff-soak/README.md`.** PLAYBACK meets 1 s
> when the pilot's database is idle (284, 690 ms; the request costs the server
> 155–163 ms) and misses or fails when it is not (1.8 s, 5.7 s, 23 s, two runs with
> no session answer in 70 s). The 16-WALL cannot meet 2 s from the client: on an
> idle server the mosaic create plus its on-demand first segment is 2.3–2.6 s
> before our player has a byte (measured by replay, `prewarm_at: 0` now sent —
> 2.0 s vs 3.0–4.1 s without), and the WALL CRASHED in 6 of the 7 runs that got a
> session: every mosaic segment's LAST two frames arrive flagged corrupt (`dts 525000 /
> 532500` of a 72-frame, 6 s segment — corrected 09-11: not the head; reproduced with
> ffmpeg alone, no Watchtower proxy: each segment is an independent TS with a per-segment
> discontinuity, so the demuxer flushes an unterminated PES at every joint; letter to CV
> asks for continuous segmentation), the VA-API decoder fails to sync on them and the
> process dies of heap corruption (SIGABRT ×3, SIGSEGV ×2 — backtraces kept). Our proxy's
> own framing defect (length-less close-delimited bodies → FFmpeg EIO per segment) found and
> fixed 09-11; it was real and it was not the corruption. `QT_FFMPEG_DROP_CORRUPT_FRAMES`
> did not help; **software decode did** (`WT_PB_SW_DECODE=1`, new: 150 s, zero VA
> errors, first frame 8.5 s). Default stays off until the overnight soak has priced
> it on 1440p HEVC single-camera playback.
>
> Why the database: `timescaledb` at 149–161 % CPU, every active backend in IO on
> three shapes — the coverage day-group scan (13–30 s of `serve;dur`), `SUM(bytes)
> FROM video_segments`, `COUNT(*)` events join — and a crashed client's 6 h mosaic
> chase runs on: two orphans took the SAME 61-fragment session from 0.6 s to 28 s
> for everyone (deleted by id, `204`). Client fixes shipped: mosaic session id
> persisted (`sync()`) and reaped at the next open; coverage refresh deferred
> behind the first frame on both surfaces; the proxy relays whole TS packets only;
> the wall's `[WALLTIME]` stage lines and a first-frame marker that fires on fresh
> opens (it was gated on `_settling` — every earlier wall `-1` was blind); the
> driver no longer boot-opens the day cold. Second letter to CV: the IO-bound
> database, five ranked asks. Overnight soak launched against this build.
>
> **Overnight result (154 cycles to 04:32 UTC 09-09, software decode): LIVE 153/153
> under 500 ms (median 182); PLAYBACK under 1 s in 19 (all in the 12:00 and 16:00 UTC
> hours), no answer in 80; WALL never under 2 s, a frame in 46 (5–47 s); 0 crashes in
> 288 logs.** From 17:00 UTC on, the pilot answered no historical open: nine concurrent
> event-list scans in disk reads held timescaledb at ~150 % all night. **Attribution
> corrected 09-11 (CV's 09-09 reply): NOT a nighttime motion storm — night is ~1,000×
> quieter than the morning peak; it was a feedback loop of unguarded `/events` polls
> against an unindexed 1.5M-row table that tipped at 17:00 and latched. Fixed at both
> ends: CV's index + capped count (`/events` 44–204 ms, timescaledb 152 % → 8 %, measured
> here 09-11: 4.8 %), our single-flight + backoff.** Third letter to CV (saturation,
> three asks) — answered; `events` has no retention (operator's call, CV's flag). Client: software decode is now the DEFAULT
> (`WT_PB_HW_DECODE=1` opts out — no measured first-frame cost, CPU cost unmeasured),
> and the four timer-driven `/events` polls are single-flight with proportional
> backoff. The wall's 2 s target is unreachable from the client on this backend
> (server floor 2.3–2.6 s idle); the playback target depends on the database's state.

<!-- 2026-08-29 pointer -->
> **2026-08-29 — the booth's direct LAN came up and the wall was STILL solid
> orange МЕДЛ on all 35 tiles. Cause: the WAN-era workaround was still in force.
> `-wall` is now RETIRED at the booth and the wall measures 15.03 fps/stream —
> the rate the cameras actually broadcast.**
>
> The link is real: `ping 192.168.1.79` → 4/4, 0 % loss, <1 ms, TTL=64. The wall
> did not improve because `WT_WALL_STREAM_SUFFIX=wall` was still set in the
> booth's `warden.conf` (untouched since 18 Aug). Every tile was pulling
> `{camera_id}-wall` — the 320×180 ffmpeg transcode
> (`src/models/CameraModel.cpp:451-452`) whose ONLY stated purpose (`:453-454`)
> is squeezing a wall through a 1.5–2 Mbit/s WAN. With the LAN up that purpose
> is gone, and its cost — 34 concurrent server-side transcodes — had become the
> binding constraint.
>
> **Measured, booth `[MEMTEL]`, same 33 streams, 30 s samples:**
>
> | | fps/stream | rss | badges |
> |---|---|---|---|
> | `-wall`, 34 consumers | **8.00** | 2602 MB | 35/35 МЕДЛ |
> | `-sub` (passthrough) | **15.03** | 787 MB | 35/35 ЭФИР |
>
> 15.03 is the configured fleet rate, so this is the 15-fps invariant being MET,
> not a speed-up. Sustained across 9 consecutive samples. GUI coalescing rose
> 0.03 % → ~5.5 % (there are now frames to coalesce — 495 fps arriving vs 264),
> so DISPLAYED rate is ~14.2/stream, still ~2× the `-wall` figure.
>
> Change is booth-local, NOT in-repo (the file carries a station token):
> `warden.conf` `APP_ENV` drops `,WT_WALL_STREAM_SUFFIX=wall`. Verified after an
> ordered restart: `[WT-URL] suffix='' … sub_after='…-sub'`, parentage
> watchdog→warden→app, `heartbeat: first beat accepted`, geometry APPLIED
> 1881x1009+28+19, `cilex://` unchanged. **This is the step `-wall` retirement
> predicted below** — `-wall` stays correct for any station still on a WAN.
>
> **Observed at the same moment, NOT proven causal:** fleet `НЕ В СЕТИ` 7 → 0,
> `ОНЛАЙН` 123 → 130, and CV had been returning 503 on snapshots (150 of 2 809
> fetches in the prior run). Dropping 34 transcodes off CV's box is the obvious
> mechanism; the booth cannot measure CV's CPU and did not.
>
> **METRIC TRAP — `drop%` is not a health signal.** It is CUMULATIVE
> (`coalesced/framesIn` over process life, `src/models/MemTelemetry.cpp:219`),
> so it reads LOW when nothing is flowing: a 24 Aug run sat at `dec=0/lit=0` for
> 18+ h reporting a comfortable `drop=0.2 %`. Use `dec`/`lit` and per-sample
> deltas. The "instance drifted to drop=19.6 %, swd=100 over 24.6 h" reading was
> wrong for the same reason — that instance reported `coal=0 drop=0.0 %
> dec=0/lit=0 swd=0` until 00:21 and produced those numbers only in its final
> ~10 minutes. No drift happened; nothing about 1.1.214 is credited or blamed.
>
> **ALL SEVEN `win/*` BRANCHES AUDITED AND DELETED 2026-08-29 — every one was
> already on main or superseded; merging any would have moved main BACKWARDS.**
> Recorded here so the tips stay recoverable:
>
> | branch | tip | verdict |
> |---|---|---|
> | `win/rtsp-diagnostics` | `b596539` | ancestor of main |
> | `win/wan-bandwidth-budget` | `0d259a1` | ancestor of main (PR #5) |
> | `win/watchdog-unbiased-clock` | `63136f9` | `git cherry -` = already upstream; merge would DELETE the macOS `CLOCK_UPTIME_RAW` fix and the `timeapi.h` include |
> | `win/warden-heartbeat-dead` | `3d28376` | would set `WARDEN_VERSION` **1.3.2 → 1.3.1** — the version whose heartbeat was dead (`8d83078` is the real fix) |
> | `win/marker-end-snap` | `4d6cd15` | its `refStart` fix is on main as `bandStart`, plus the tail-honesty rule, `tlEndMs` cap, MONOTONIC and `_endFinal`; merge would revert all of that |
> | `win/pb-soak` | `aa8fbef` | `WT_PB_SOAK` already on main |
> | `win/i18n-sort-severity` | `91d874f` | would DELETE 4 938 lines of `watchtower_ru.ts` including live translations (`Оповещения`, `Все камеры`, `ГРУППЫ КАМЕР`) — a stale `lupdate` from 60 commits back |
>
> **Salvaged from them before deletion** (the only content main lacked): the
> `qsTr()` translatability of `qml/LiveMonitor.qml`'s five sort labels and
> `qml/Sev.qml`'s severity levels, and the `[MSCAN] span end MEASURED` verdict
> log in `qml/EvHeroPlayer.qml`. **Follow-up for the Linux agent: these add NEW
> source strings with no `.ts` entries, so they render English until `lupdate`
> is re-run on current main.** The `.ts` regeneration was deliberately NOT taken
> from the branch — that was the poison.

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
> truly exits at ~0:30 — the clip is served at **640×360** and the walker's far
> phase drops under every detector gate at that scale. **CORRECTED 2026-08-26:
> this is NOT a platform split and NOT a playlist-ladder choice.** Both earlier
> claims are withdrawn — see `…hls…reply5.md`. (i) The review master emits ONE
> `#EXT-X-STREAM-INF` with no `RESOLUTION` attribute (CV, `review.py:909-963`):
> there is no ladder to reorder, so `2026-08-26-review-playlist-variant-order.md`
> is **withdrawn in full**. (ii) The "Linux gets 1440p" half rested on
> `[MSCAN] … 2560x1440`, which was printed by a **once-per-PROCESS static** that
> `reset()` never cleared — and whose frame can even belong to the PREVIOUS clip
> (measured 08-26 09:09:44: a feafb3e4 session reported 2560×1440, then 640×360
> 181 ms later). Fixed: the geometry line is now per-session and reports
> mid-session rendition changes. (iii) The real cause is **main-stream retention**:
> main on that camera is ~1 day deep, sub 5.5, and the edge swept past the event
> during 08-25. Measured on Linux 08-26, twice: feafb3e4 decodes **640×360**,
> lock at **pts=16487ms**, bucket maxima 0.0017–0.0608 — CV's account reproduced
> exactly. A recent event on the same camera still decodes 2560×1440.
> **36 fleet cameras have main shallower than sub by >12h; 10 have no main at
> all** — for windows older than main depth, 360p is the only footage that
> exists, on every platform. Remaining fix: (2) a speed-bounded small-mover
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
> **Also measured 08-25 — cause CORRECTED 2026-08-26:** the served stream's score
> statistics dropped 4–5× on the same event between morning and evening (both
> samplers agree). **The CRF-18 edge-re-encode hypothesis is WITHDRAWN.** CV
> disproved it from the RUNNING container (`…hls…reply4.md`): CRF is still 23 at
> both head-piece sites, zero trim symbols in the image, and
> `infra-playback-service:latest` was built 08-23 23:17 MSK and never rebuilt —
> it predates both measurements. The mid-day 08-25 container restart was a host
> reboot, not a deploy. The drop is the **retention edge** crossing the event:
> 2560×1440 → 640×360 is a 16× pixel drop, which through a 32×18 luma grid is
> exactly the observed 0.20 → 0.043–0.061 and the lock sliding 7843 → 16487 ms.
> The hypothesis was self-inconsistent before either side checked — CRF 23→18
> moves quality UP. Detector thresholds re-verified 08-25 remain valid; they were
> re-tuned against a lower-resolution SOURCE, not a new encode.
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

> **🟢 SHIPPED 2026-09-11 — Warden 1.4.2 (`af55ed1`), booth station.** The beat
> now carries `subsystems`, so CV's `subsystems_reported` gauge has a client.
> It reports **every subsystem the APP declares** through
> `[WT-DEGRADED] subsystem=<name> … state=FAULT|CLEARED` (newest-wins, read from
> the recorder tail) — so `playback`, the original P0, reaches CV with no further
> client work, and a future `storage` rides for free. Contract bounds are enforced
> client-side rather than discovered: name grammar, the 8-cap, and `"ok"` as the
> only healthy string.
>
> **Still owed to CV: the acceptance test.** Inject a deliberate fault (force the
> 25 s renewal again) and confirm the operator's phone pages within ~5 minutes.
> Not run here — it needs an operator credential this booth deliberately does not
> hold, and it pages a real phone. Whoever has both should run it.
>
> Riding along, from the same operator ask: the beat also carries
> **`app_last_beat_at` / `app_beat_age_s`** — *Watchtower's own* heartbeat,
> observed rather than vouched for. The app's `[MEMTEL]` tick is written from its
> GUI thread every 30 s, so a **frozen** wall stops it while `app_pid` and
> `app_state` still read healthy. That is the fleet page's own stated fear ("a
> freeze would be shown as a live picture"), and until now nothing on the beat
> could catch it.

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
