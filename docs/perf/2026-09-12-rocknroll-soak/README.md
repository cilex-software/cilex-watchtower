# Rock-n-roll soak — 2026-09-12, 02:10 → 08:27 MSK

**Goal (operator, 2026-09-12 02:05):** *"run a rock n roll soak test until 11 AM … a list of totally random actions … measure all timings … grouped into sensible groups … stats of various actions … which actions are outliers … analyse what had caused an outlier preferably on the spot and apply fix and attempt to reproduce the issue you just fixed."*

**Shape:** 343 runs of the real app binary (`build/watchtower`, software decode default), one launch per run, weighted-random action from a 28-entry catalogue in 8 groups (BACKEND 39, EVENTS 34, LIVE 67, PLAYBACK 96, STARTUP 8, STRESS 35, UI 41, WALL 23), against the live pilot backend (`WT_SOAK_NOEXPORT=1`, no writes; review/mosaic sessions disposed after each run). Driver `tools/rocknroll-soak.py`, report `tools/rocknroll-report.py`, rows in `rows.jsonl`, outliers in `outliers.jsonl`, events in `events.log`, hand notes in `notes.jsonl`. Every fix was rebuilt mid-run and the action re-queued (`queue.txt`) to reproduce; the per-build table below shows before/after. Builds seen: 2168826+bin@120426, 254b5ab+bin@120217, 254b5ab+bin@120248, 3cdd436+bin@120217, 91a34c8+bin@120248, 91a34c8+bin@120252, 91a34c8+bin@120255, 91ae28c+bin@111257, 91ae28c+bin@120217, ac8cfa1+bin@120255, ac8cfa1+bin@120400, ac8cfa1+bin@120405, ac8cfa1+bin@120409, ac8cfa1+bin@120413, ac8cfa1+bin@120418, ac8cfa1+bin@120420, ac8cfa1+bin@120426. Crashes: **1** (n118 wall_day1).

**Ended early.** The run was stopped at 08:29 MSK, not at the planned 11:00: the pilot host ran out of disk at 08:08–08:09 (the driver itself died writing its log, and the Watchtower supervisor could not start), and after a restart at 08:23 I stopped the soak again at 08:29 while the host was still filling at 750 MB/min. The cause is on the backend side and is written up under "Host condition" below; the soak was measured not to be driving it. Everything in this report is from the 02:10–08:27 window.

**One row was lost** to the disk failure: the record for run 309 was truncated mid-write at 08:09:27 and the restarted driver appended its next record onto the same line. I split them, kept the intact record and dropped the fragment. The run itself is in `events.log` (a `pb_open_armed_d1` flagged `no_metric`). Run numbering also has a gap at 309–340 because the restarted driver numbers from the file's line count; no data is missing there.

**Outlier rules:** crash, harness FAIL, no metric, over the action's target, or over 2.5× the action's running median. LIVE opens carry two targets: 500 ms when the camera's tile is already on the wall page (parked pipeline), 3,500 ms when it is off-page (cold RTSP).

## Results per action

| group | action | n | over target | outliers (crash / fail / no metric / ≥2.5× median) | primary median | p90 | max | target | builds |

Primary metric per action: the first `[TAG] key=` the harness prints for that action (playback = the day click's own first frame; live = `playing dt`; wall = `first_frame dt`; stress = an error/violation count). Outlier = crash, harness FAIL, no metric, over the target, or over 2.5× the action's running median.

|---|---|---|---|---|---|---|---|---|---|
| BACKEND | api_probe | 39 | 0 | **1** | 84 | 177 | 230 | median×2.5 | 2168826,254b5ab,3cdd436,91a34c8,ac8cfa1 |
| EVENTS | events_section | 8 | 0 | **0** | 51 | 98 | 98 | 1500 | 3cdd436,91ae28c,ac8cfa1 |
| EVENTS | hero | 26 | 4 | **5** | 284 | 6251 | 6487 | 3000 | 91a34c8,ac8cfa1 |
| LIVE | live_open_armed (on-page) | 17 | 1 | **0** | 168 | 237 | 3046 | 500 | 91a34c8,ac8cfa1 |
| LIVE | live_open_armed (off-page) | 4 | 3 | **1** | 890 | 919 | 919 | 500 | 91a34c8,ac8cfa1 |
| LIVE | live_open_armed (unknown-page) | 5 | 1 | **0** | 240 | 4349 | 4349 | 500 | 254b5ab,3cdd436,91ae28c |
| LIVE | live_open_offpage (on-page) | 2 | 0 | **0** | 177 | 208 | 208 | 3500 | ac8cfa1 |
| LIVE | live_open_offpage (off-page) | 11 | 0 | **0** | 893 | 1171 | 1223 | 3500 | ac8cfa1 |
| LIVE | live_open_offpage (unknown-page) | 2 | 0 | **0** | 905 | 960 | 960 | median×2.5 | 254b5ab,3cdd436 |
| LIVE | live_open_recording (on-page) | 21 | 1 | **0** | 206 | 280 | 1102 | 500 | 2168826,91a34c8,ac8cfa1 |
| LIVE | live_open_recording (unknown-page) | 5 | 3 | **0** | 518 | 879 | 879 | 500 | 254b5ab,3cdd436 |
| PLAYBACK | pb_churn | 7 | 0 | **1** | 6.0 | 6.0 | 6.0 | median×2.5 | 91ae28c,ac8cfa1 |
| PLAYBACK | pb_cold_boot | 4 | 1 | **0** | 1748 | 6284 | 6284 | 3000 | ac8cfa1 |
| PLAYBACK | pb_frame_mode | 7 | 0 | **0** | 9.0 | 9.0 | 9.0 | median×2.5 | ac8cfa1 |
| PLAYBACK | pb_open_armed_d1 | 5 | 3 | **0** | 1276 | 2257 | 2257 | 1000 | 254b5ab,ac8cfa1 |
| PLAYBACK | pb_open_d1 | 24 | 15 | **0** | 1308 | 7433 | 21238 | 1000 | 254b5ab,3cdd436,ac8cfa1 |
| PLAYBACK | pb_open_d3 | 10 | 7 | **0** | 1410 | 1716 | 1967 | 1000 | 254b5ab,ac8cfa1 |
| PLAYBACK | pb_open_d7 | 6 | 0 | **1** | - | - | - | 1000 | 254b5ab,ac8cfa1 |
| PLAYBACK | pb_rollover | 12 | 11 | **0** | 2435 | 10084 | 11852 | 1000 | 3cdd436,91ae28c,ac8cfa1 |
| PLAYBACK | pb_seek | 11 | 3 | **1** | 634 | 6299 | 6489 | 4000 | ac8cfa1 |
| PLAYBACK | pb_smooth | 10 | 0 | **0** | 0.0 | 0.0 | 0.0 | 2000 | ac8cfa1 |
| STARTUP | wall_lightup | 8 | 0 | **0** | 3005 | 3786 | 3786 | 5000 | ac8cfa1 |
| STRESS | fsoak | 9 | 0 | **0** | 0.0 | 0.0 | 0.0 | 0 | 254b5ab,ac8cfa1 |
| STRESS | guard_soak | 10 | 0 | **1** | 0.0 | 0.0 | 0.0 | 0 | 254b5ab,ac8cfa1 |
| STRESS | night_soak | 10 | 0 | **0** | 334 | 696 | 750 | 15000 | 254b5ab,ac8cfa1 |
| STRESS | wall_churn | 6 | 0 | **0** | 37 | 56 | 56 | 150 | ac8cfa1 |
| UI | calstress | 7 | 1 | **0** | 8322 | 41774 | 41774 | 15000 | ac8cfa1 |
| UI | group_grid | 11 | 0 | **0** | 477 | 667 | 1248 | 3000 | 254b5ab,3cdd436,91a34c8,ac8cfa1 |
| UI | nav | 9 | 1 | **0** | 408 | 15127 | 15127 | 1500 | ac8cfa1 |
| UI | resize | 7 | 0 | **0** | 148 | 151 | 151 | median×2.5 | 2168826,ac8cfa1 |
| UI | tabs | 7 | 0 | **0** | 3172 | 4028 | 4028 | 5000 | 3cdd436,ac8cfa1 |
| WALL | wall_day1 | 10 | 0 | **1** | 8659 | 11787 | 13236 | median×2.5 | 2168826,ac8cfa1 |
| WALL | wall_live | 13 | 1 | **0** | 8885 | 11200 | 17034 | median×2.5 | 254b5ab,91ae28c,ac8cfa1 |

## Per build (actions rebuilt during the run)

| action | build | n | median | p90 | max | outliers |
|---|---|---|---|---|---|---|
| api_probe | 2168826+bin@120426 | 1 | 33 | 33 | 33 | 0 |
| api_probe | 254b5ab+bin@120217 | 2 | 118 | 171 | 171 | 0 |
| api_probe | 3cdd436+bin@120217 | 2 | 115 | 177 | 177 | 0 |
| api_probe | 91a34c8+bin@120248 | 1 | 121 | 121 | 121 | 0 |
| api_probe | 91a34c8+bin@120255 | 1 | 48 | 48 | 48 | 0 |
| api_probe | ac8cfa1+bin@120255 | 7 | 74 | 230 | 230 | 0 |
| api_probe | ac8cfa1+bin@120405 | 1 | 26 | 26 | 26 | 0 |
| api_probe | ac8cfa1+bin@120413 | 1 | 65 | 65 | 65 | 0 |
| api_probe | ac8cfa1+bin@120420 | 1 | 220 | 220 | 220 | 0 |
| api_probe | ac8cfa1+bin@120426 | 22 | 90 | 158 | 185 | 1 |
| events_section | 3cdd436+bin@120217 | 1 | 42 | 42 | 42 | 0 |
| events_section | 91ae28c+bin@111257 | 1 | 53 | 53 | 53 | 0 |
| events_section | ac8cfa1+bin@120255 | 1 | 51 | 51 | 51 | 0 |
| events_section | ac8cfa1+bin@120426 | 5 | 51 | 98 | 98 | 0 |
| hero | 91a34c8+bin@120252 | 1 | - | - | - | 1 |
| hero | ac8cfa1+bin@120255 | 6 | 76 | 6251 | 6251 | 2 |
| hero | ac8cfa1+bin@120400 | 3 | 941 | 6234 | 6234 | 2 |
| hero | ac8cfa1+bin@120405 | 3 | 1123 | 6487 | 6487 | 1 |
| hero | ac8cfa1+bin@120413 | 3 | 203 | 301 | 301 | 0 |
| hero | ac8cfa1+bin@120420 | 2 | 232 | 268 | 268 | 0 |
| hero | ac8cfa1+bin@120426 | 8 | 441 | 6406 | 6406 | 3 |
| live_open_armed | 254b5ab+bin@120217 | 2 | 317 | 482 | 482 | 0 |
| live_open_armed | 254b5ab+bin@120248 | 1 | 240 | 240 | 240 | 0 |
| live_open_armed | 3cdd436+bin@120217 | 1 | 192 | 192 | 192 | 0 |
| live_open_armed | 91a34c8+bin@120248 | 1 | 919 | 919 | 919 | 1 |
| live_open_armed | 91a34c8+bin@120252 | 2 | 697 | 890 | 890 | 2 |
| live_open_armed | 91a34c8+bin@120255 | 2 | 166 | 168 | 168 | 0 |
| live_open_armed | 91ae28c+bin@111257 | 1 | 4349 | 4349 | 4349 | 1 |
| live_open_armed | ac8cfa1+bin@120255 | 1 | 173 | 173 | 173 | 0 |
| live_open_armed | ac8cfa1+bin@120420 | 1 | 178 | 178 | 178 | 0 |
| live_open_armed | ac8cfa1+bin@120426 | 14 | 155 | 237 | 3046 | 2 |
| live_open_offpage | 254b5ab+bin@120217 | 1 | 850 | 850 | 850 | 0 |
| live_open_offpage | 3cdd436+bin@120217 | 1 | 960 | 960 | 960 | 0 |
| live_open_offpage | ac8cfa1+bin@120255 | 2 | 1006 | 1171 | 1171 | 0 |
| live_open_offpage | ac8cfa1+bin@120400 | 1 | 617 | 617 | 617 | 0 |
| live_open_offpage | ac8cfa1+bin@120409 | 1 | 998 | 998 | 998 | 0 |
| live_open_offpage | ac8cfa1+bin@120413 | 1 | 657 | 657 | 657 | 0 |
| live_open_offpage | ac8cfa1+bin@120426 | 8 | 818 | 1223 | 1223 | 0 |
| live_open_recording | 2168826+bin@120426 | 1 | 198 | 198 | 198 | 0 |
| live_open_recording | 254b5ab+bin@120217 | 2 | 586 | 655 | 655 | 2 |
| live_open_recording | 254b5ab+bin@120248 | 1 | 879 | 879 | 879 | 1 |
| live_open_recording | 3cdd436+bin@120217 | 2 | 222 | 260 | 260 | 0 |
| live_open_recording | 91a34c8+bin@120255 | 2 | 187 | 239 | 239 | 0 |
| live_open_recording | ac8cfa1+bin@120255 | 3 | 207 | 242 | 242 | 0 |
| live_open_recording | ac8cfa1+bin@120426 | 15 | 206 | 280 | 1102 | 1 |
| pb_churn | 91ae28c+bin@111257 | 1 | - | - | - | 1 |
| pb_churn | ac8cfa1+bin@120255 | 3 | 6.0 | 6.0 | 6.0 | 0 |
| pb_churn | ac8cfa1+bin@120426 | 3 | 6.0 | 6.0 | 6.0 | 0 |
| pb_cold_boot | ac8cfa1+bin@120255 | 1 | 2285 | 2285 | 2285 | 0 |
| pb_cold_boot | ac8cfa1+bin@120405 | 1 | 6284 | 6284 | 6284 | 1 |
| pb_cold_boot | ac8cfa1+bin@120426 | 2 | 946 | 1212 | 1212 | 0 |
| pb_frame_mode | ac8cfa1+bin@120255 | 3 | 9.0 | 9.0 | 9.0 | 0 |
| pb_frame_mode | ac8cfa1+bin@120426 | 4 | 9.0 | 9.0 | 9.0 | 0 |
| pb_open_armed_d1 | 254b5ab+bin@120217 | 1 | 1276 | 1276 | 1276 | 1 |
| pb_open_armed_d1 | ac8cfa1+bin@120426 | 4 | 1197 | 2257 | 2257 | 2 |
| pb_open_d1 | 254b5ab+bin@120217 | 2 | 3416 | 6479 | 6479 | 1 |
| pb_open_d1 | 3cdd436+bin@120217 | 1 | 6613 | 6613 | 6613 | 1 |
| pb_open_d1 | ac8cfa1+bin@120255 | 5 | 1094 | 7433 | 7433 | 3 |
| pb_open_d1 | ac8cfa1+bin@120409 | 1 | 999 | 999 | 999 | 0 |
| pb_open_d1 | ac8cfa1+bin@120413 | 1 | 905 | 905 | 905 | 0 |
| pb_open_d1 | ac8cfa1+bin@120418 | 1 | 672 | 672 | 672 | 0 |
| pb_open_d1 | ac8cfa1+bin@120426 | 13 | 1359 | 8288 | 21238 | 10 |
| pb_open_d3 | 254b5ab+bin@120217 | 2 | 1725 | 1967 | 1967 | 2 |
| pb_open_d3 | ac8cfa1+bin@120426 | 8 | 1303 | 1716 | 1716 | 5 |
| pb_open_d7 | 254b5ab+bin@120248 | 1 | - | - | - | 1 |
| pb_open_d7 | ac8cfa1+bin@120255 | 2 | - | - | - | 0 |
| pb_open_d7 | ac8cfa1+bin@120426 | 3 | - | - | - | 0 |
| pb_rollover | 3cdd436+bin@120217 | 1 | 2426 | 2426 | 2426 | 1 |
| pb_rollover | 91ae28c+bin@120217 | 1 | 1198 | 1198 | 1198 | 1 |
| pb_rollover | ac8cfa1+bin@120255 | 3 | 2087 | 2651 | 2651 | 3 |
| pb_rollover | ac8cfa1+bin@120426 | 7 | 4955 | 11852 | 11852 | 6 |
| pb_seek | ac8cfa1+bin@120255 | 1 | 263 | 263 | 263 | 0 |
| pb_seek | ac8cfa1+bin@120426 | 10 | 795 | 6489 | 6489 | 4 |
| pb_smooth | ac8cfa1+bin@120255 | 3 | 0.0 | 0.0 | 0.0 | 0 |
| pb_smooth | ac8cfa1+bin@120426 | 7 | 0.0 | 0.0 | 0.0 | 0 |
| wall_lightup | ac8cfa1+bin@120255 | 5 | 2916 | 3391 | 3391 | 0 |
| wall_lightup | ac8cfa1+bin@120426 | 3 | 3094 | 3786 | 3786 | 0 |
| fsoak | 254b5ab+bin@120217 | 1 | 0.0 | 0.0 | 0.0 | 0 |
| fsoak | ac8cfa1+bin@120255 | 2 | 0.0 | 0.0 | 0.0 | 0 |
| fsoak | ac8cfa1+bin@120426 | 6 | 0.0 | 0.0 | 0.0 | 0 |
| guard_soak | 254b5ab+bin@120217 | 1 | - | - | - | 1 |
| guard_soak | ac8cfa1+bin@120255 | 1 | 0.0 | 0.0 | 0.0 | 0 |
| guard_soak | ac8cfa1+bin@120426 | 8 | 0.0 | 0.0 | 0.0 | 0 |
| night_soak | 254b5ab+bin@120217 | 1 | 133 | 133 | 133 | 0 |
| night_soak | ac8cfa1+bin@120255 | 1 | 256 | 256 | 256 | 0 |
| night_soak | ac8cfa1+bin@120426 | 8 | 350 | 750 | 750 | 0 |
| group_grid | 254b5ab+bin@120217 | 1 | 1248 | 1248 | 1248 | 0 |
| group_grid | 3cdd436+bin@120217 | 1 | 259 | 259 | 259 | 0 |
| group_grid | 91a34c8+bin@120252 | 1 | 355 | 355 | 355 | 0 |
| group_grid | ac8cfa1+bin@120255 | 1 | 534 | 534 | 534 | 0 |
| group_grid | ac8cfa1+bin@120426 | 7 | 477 | 667 | 667 | 0 |
| nav | ac8cfa1+bin@120255 | 2 | 402 | 433 | 433 | 0 |
| nav | ac8cfa1+bin@120400 | 1 | 704 | 704 | 704 | 0 |
| nav | ac8cfa1+bin@120426 | 6 | 369 | 15127 | 15127 | 1 |
| resize | 2168826+bin@120426 | 1 | 143 | 143 | 143 | 0 |
| resize | ac8cfa1+bin@120255 | 3 | 150 | 151 | 151 | 0 |
| resize | ac8cfa1+bin@120426 | 3 | 148 | 150 | 150 | 0 |
| tabs | 3cdd436+bin@120217 | 2 | 3136 | 3172 | 3172 | 0 |
| tabs | ac8cfa1+bin@120255 | 1 | 3495 | 3495 | 3495 | 0 |
| tabs | ac8cfa1+bin@120426 | 4 | 3129 | 4028 | 4028 | 0 |
| wall_day1 | 2168826+bin@120426 | 1 | 13236 | 13236 | 13236 | 0 |
| wall_day1 | ac8cfa1+bin@120255 | 2 | 8638 | 9845 | 9845 | 0 |
| wall_day1 | ac8cfa1+bin@120409 | 1 | 8460 | 8460 | 8460 | 0 |
| wall_day1 | ac8cfa1+bin@120413 | 1 | 8738 | 8738 | 8738 | 1 |
| wall_day1 | ac8cfa1+bin@120420 | 1 | 9425 | 9425 | 9425 | 0 |
| wall_day1 | ac8cfa1+bin@120426 | 4 | 8370 | 11787 | 11787 | 0 |
| wall_live | 254b5ab+bin@120217 | 2 | 7893 | 8129 | 8129 | 0 |
| wall_live | 91ae28c+bin@111257 | 1 | 7149 | 7149 | 7149 | 1 |
| wall_live | ac8cfa1+bin@120255 | 2 | 8706 | 9291 | 9291 | 0 |
| wall_live | ac8cfa1+bin@120426 | 8 | 9474 | 17034 | 17034 | 0 |

## Fixes applied during the run (with reproduction)

- **live_open_armed:over_target** (n=2, 2026-09-12T02:17:11): SingleCameraDetail auto ladder added main as the FIRST rung when Settings.defaultStreamHd is on (this box: defaultStreamHd=true), bypassing the SD-first + hdPromote design: the parked -sub pipeline was ignored, a main (HEVC) pipeline was built and waited for its mid-GOP keyframe — 4,349 ms
  - fix: auto ladder is SD-first unconditionally; HD comes from the promotion surface (built 02:2x, reproductions queued) — reproduced OK: n6 260 ms, n7 192 ms — `2cdfe04`
- **live_open_recording:over_target** (n=32, 2026-09-12T02:46:08): NOT the adoption path: the 16 tiles parked during the 218 ms view-switch stall, before the detail view's source requested its URL, so the lot (cap 4, keeps only URLs a queued source wants) had already evicted .245's pipeline; the detail built a fresh -sub pipeline at +230 ms (518 ms, lucky keyframe timing). Adoption depends on creation order: request-before-park (yesterday's runs) adopts, park-before-request misses.
  - fix: in progress: hint the lot with the camera being opened BEFORE the switch (openCameraHere), so its pipeline is kept regardless of order — done; page-pick reproductions n45-n48: 164/239/168/135 ms — `ac8cfa1`
- **live_open_recording:over_target** (n=36, 2026-09-12T02:50:07): inventory, not the hint: 16 tiles were lit but 192.168.1.189 was not among them — the soak operator's wall shows a different sixteen from yesterday's station page, so the live actions sometimes picked an OFF-PAGE camera and measured the cold path (879 ms)
  - fix: driver learns the lit set from each run's log and picks live targets from it; rows carry target_lit (restart 02:5x); the hint stays to be proven on an on-page open — done; page-pick reproductions n45-n48: 164/239/168/135 ms — `ac8cfa1`
- **live_open_armed:over_target** (n=42, 2026-09-12T02:54:36): off-page again: the wall's visible sixteen change between launches (n39's page had .230, n42's did not), so a camera chosen before launch is not reliably on the page; the hint fired correctly (sub/main URLs), 16 lit tiles were parked, .230 was simply not among them
  - fix: harness: the focus hook gains WT_FOCUS_IP=lit:armed|recording — it picks a tile that is lit at click time (in progress); report splits live rows by target_lit — done; page-pick reproductions n45-n48: 164/239/168/135 ms — `ac8cfa1`
- **hero:over_target** (n=93, 2026-09-12T03:48:21): hero scrubber jumps of 6.2-6.8 s = the 6 s seekWatch watchdog re-opening the session. The [HT] SEEKREQ trace (n106, build 04:00) pins the trigger: EVERY stalled seek targeted the LAST SECOND of the player's media (pos 0.96-1.03 s before duration) - the +30 s/+10 s jumps clamped at the clip end (cd-1), and after a re-open the pending seek lands 3 s before the end of a 10 s ready playlist (a re-open is consumed with 2-3 ready fragments; CV's playlist has only those) so the next +1 s is the last second again. There the FFmpeg backend renders nothing and never reports EndOfMedia; only the 6 s watchdog moved us, by re-opening into another short playlist - eight re-opens in a row in n93, seven of nine in n57. Ruled out: software decode (hw/sw A/B n99-n101 all 68-76 ms medians, both modes also show the same stalls per jump), playlist not seekable (VOD+ENDLIST, seekable=true on every stalled seek), stale fragment map after re-open (cleared and rebuilt). My first patch (extrapolate past the ready snapshot, 04:00) did not fix it: n107 median 6,234 ms
  - fix: EvHeroPlayer.qml (build 04:05:23): endZoneWatch - honour the click as before (no up-front dead zone, operator 08-26), but when the target is within 2.5 s of the media end and no frame lands within 1.5 s, step back IN-STREAM to 2.5 s before the end ([HT] ENDZONE fallback); no re-open, so no chain. Also kept: _mediaEndSec() caps the seekable end by player.duration; seekToWall re-opens immediately when the session is not armed; SEEKREQ trace. Three hero reproductions queued on this build; measurement pending — `1e2c4a2`
- **hw_decode_cycles:continuity** (n=114-118, 04:09-04:15): CV's re-run ask (letter 2026-09-12, commit 07eedeb): two WT_PB_HW_DECODE=1 cycles (single-camera .105 day 2026-09-11 + 16-wall day 2026-09-11 + live .105) via the queue; the proxy now logs X-Cilex-TS-Continuity per segment (cc=). Cycle 1: n114 single 2 corrupt (session 94e8d9c6, tail of seg 1 at dts 742500/747000; segs 2-3 came from our prefetch cache, cc unrecorded then), n115 wall 8,460 ms first frame, 66 segments cc first×1/shifted×64, 4 corrupt + 4 vaSyncSurface, no crash — vs 09-11: 116 corrupt, 58 of 62 flagged. Cycle 2: n117 single 4 corrupt: session 89691a82 seg 1 served to the player as FALLBACK at 04:13:20 although seg 0 was served `first` at 04:13:10 (CV's case: id + index), and our read-ahead had fetched segs 2,3 (fallback) BEFORE seg 1 existed (our own prefetch of seg 1 → 503 at 04:13:12) and cached them; the parallel session f865e8db (all shifted) was clean. n118 wall CRASH SIGABRT at 31 s: `vaSyncSurface failed` → `Cannot map a video frame` → `malloc_consolidate(): invalid chunk size`, 4 corrupt at a SHIFTED joint while the player was blocked on a 503 for seg 12 — the 'wait joint' class (also n115 segs 37/38: corrupt pairs dts 525000/532500 printed during the held 503 retries, never a fallback)
  - fix: HlsProxy.cpp (build 04:18:59): read-ahead SEQUENTIAL (n+1, then n+2 only after n+1 landed clean; a 503 stops the chain) and never cache a `fallback` response on any of the three cache paths (served, not cached; a re-fetch self-heals per CV §1); prefetch fetches logged with chain= and cc=. Cycle 3 (n123 single): 0 corrupt, 0 vasync, all first/shifted — `1e2c4a2`
- **hero:reopen_churn** (n=121, 04:17): v3 dead-zone routing (whole last fragment → re-open) re-opened 21 of 50 seeks: review fragments run 7-30 s so the last fragment is a third of a short window; each re-open is a NEW server session whose segments render cold (seg0 1.4-3.6 s, seg1 3.1-4.4 s: seeks of 7,377/6,086/3,585 ms) — the server rendition class, multiplied by our churn
  - fix: EvHeroPlayer.qml (build 04:20:54): dead zone = the last 4.5 s of the media (measured stall boundary between 3.2 s and 5.9 s from the end), not the whole last fragment; two hero reproductions queued. Then (build 04:26:56, commit below): the zone is measured from the PLAYER's media end (player.duration grows with the playlist) instead of the ready snapshot: n129 70 seeks, 2 re-opens, none ≥ 3 s, median 54 ms (n126 on the snapshot rule: 39 re-opens in 66) — `1e2c4a2`

## Outliers that stayed: known classes, no client fix

- **pb_churn:harness_fail** (n=1, 2026-09-12T02:12:47): catalogue omitted WT_FRAME_MODE=1; the churn harness holds the harvester active only in frame mode, so FrameCache.frames stayed 0 and its own verdict was FAIL (frags 77, frameSeq 553 — the product survived all 6 switches)
  - fix: catalogue: pb_churn now sets WT_FRAME_MODE=1 (takes effect at the next driver restart)
- **wall_live:over_target** (n=3, 2026-09-12T02:17:31): known server floor: mosaic session create + on-demand first segment (2.3-2.6 s idle, measured 09-08 by replay) + HLS start; the 2 s target is not reachable client-side (letters to CV 09-08/09-11)
  - fix: none client-side; tracked as known — later wall_live rows count against the running median, not the 2 s target
- **pb_rollover:over_target** (n=4, 2026-09-12T02:18:50): marginal miss (1,198 ms): server session 170 ms; the client's HLS start (source_set -> mediaStatus loaded) took 933 ms — FFmpeg fetches the playlist + first segment(s) through the proxy and initialises the (software) decoder; server-side serve of playlist/seg0/seg1 measured 09-08 at 12-22 / 56-67 / 141-359 ms, so ~0.5 s is FFmpeg start behaviour
  - fix: none tonight; the HLS-start share is the remaining client-side lever for playback (candidate: head_split already on; probe/buffer depth not exposed by Qt)
- **pb_open_d1:over_target** (n=14, 2026-09-12T02:26:36): two harness/attribution facts and one product fact. (1) [TTFF] reports the LAST open's first frame, and the run had three opens: the boot open (span60, last hour) 8,289 ms, the day click 854 ms, a seekfar re-open 6,479 ms — the row showed 6,479 for a click that took 854; extractor now keys PBTIME by open kind (@day/@span60/@seekfar). (2) The two slow opens are opens at the RECORDING FRONTIER: proxy log shows seg/0 served in 2,167-3,190 ms and seg/1 (6.5 MB, a full 30 s fragment) in 4,064-4,669 ms with serve;dur in the thousands (rendition cache cold for the newest fragments), against cache hits of 148/153 ms for the day click's segments. (3) The player reports loaded only after seg/1 has fully arrived, so the second segment gates the start even though seg/0 is head-split to 1.2 s.
  - fix: harness: per-open-kind primaries (restart 02:3x). Product: none tonight — server-side rendition of the newest fragments (letter candidate: prewarm/head-split the second segment); client-side the FFmpeg start needing seg/1 complete is the lever to examine
- **pb_open_d3:over_target** (n=21, 2026-09-12T02:30:40): server: a 3-day-old day's rendition cache is cold — session 186 ms, playlist 83 ms, then seg/1 (4.2 MB) serve;dur 743 ms and seg/3 (2.4 MB) 542 ms before the player reported loaded at 1,853 ms; the player needs two segments to start
  - fix: none client-side; server-side prewarm of the first two renditions at session create is the lever (letter candidate, with the frontier-open finding)
- **guard_soak:no_metric** (n=24, 2026-09-12T02:35:03): harness accounting: the primary is a count of [GUARD] ERR lines and the run had none (the soak ran its steps cleanly) — the driver treated an empty count as no metric
  - fix: driver: count primaries default to 0 (next restart); the run itself passed
- **pb_open_d3:over_target** (n=28, 2026-09-12T02:39:13): same as n21: cold rendition cache for an older day — the first segments are produced on demand (serve;dur in the hundreds of ms each) and the player needs two
  - fix: none client-side (server prewarm of the first renditions at session create)
- **pb_open_armed_d1:over_target** (n=29, 2026-09-12T02:41:01): marginal (1,276 ms): armed camera, motion-only footage — session + first two on-demand segments; same server rendition shape as the recording cameras
  - fix: none client-side
- **pb_open_d7:no_metric** (n=35, 2026-09-12T02:49:01): not a fault: the app reported 'No footage recorded on this day' for 192.168.1.189 on 2026-09-05 (its coverage cache has 0 days) — an honest empty state
  - fix: driver: such runs are outcome=empty, excluded from stats (next restart)
- **hero:no_metric** (n=44, 2026-09-12T02:56:26): catalogue: WT_HERO_TEST runs only inside the events triage view (EvTriage._htRun requires tri.active); launched on the live wall it pre-warmed one event ([HT] PRE ready) and idled
  - fix: catalogue: hero now boots into WT_SECTION=events (next restart) — verified n57: median [HT] lat 1,652 ms, outcome ok
- **pb_rollover:over_target** (n=52, 2026-09-12T03:02:37): server: session 99 ms, source_set 151 ms, then the first two segments produced on demand — 942 ms and 811 ms through the proxy — player loaded at 1,980 ms. Also: no EndOfMedia/roll line appeared in 95 s, i.e. the WT_TTFF_EOS end-of-window seek did not evidence a roll-over in this run (harness observation, not a product finding yet)
  - fix: none client-side
- **hero:no_metric** (n=55, 2026-09-12T03:07:13): catalogue again: the hero test selects events but the hero player auto-opens only under WT_HERO_AUTOPLAY (EvHeroPlayer.qml:527); every selection ended in [HT] OPEN TIMEOUT with no [HERO] line
  - fix: catalogue: hero now sets WT_HERO_AUTOPLAY=1 (restart 03:0x) — verified n57: median [HT] lat 1,652 ms, outcome ok
- **pb_open_d1:over_target** (n=58, 2026-09-12T03:09:23): playback-open class: server session fast, then on-demand segment renditions through the proxy (see split); same as n21/n28/n52
  - fix: none client-side
- **pb_cold_boot:over_target** (n=110, 04:05): Server-side, known class (on-demand rendition, cold cache): session_ready 216 ms, then seg/0 served in 2,808 ms and seg/1 in 2,978 ms, both Server-Timing serve=2,730/2,926 ms with cache;desc="miss" (session 348e6175); the FFmpeg player loads only after seg 1, so first_frame = 6.28 s. The follow-up open of the same window 10 s later hit the cache: 91/89 ms per segment. Same class as the frontier span60/seekfar opens noted earlier.
  - fix: none client-side; the cache-miss cost is CV's rendition pipeline (documented in the 09-08 TTFF soak README); left as a known outlier
- **hero:over_target** (n=130, 04:29): A DIFFERENT class, not the end zone: 5 of 6 scrubs stalled 6.3-7.1 s at targets 10-18 s before the media end (pos 12.0/30.9/5.1 of 29.7/40.9/20.1 s). The session's playlist (2c351168) declares 29.7 s over 4 segments but the segments hold 63.6 s of media: seg 2 declared 18.8 s holds 420 frames PTS 6.1→34.0 s, seg 3 declared 4.8 s holds 450 frames PTS 24.9→54.8 s (overlapping seg 2 by 14 s of wall time across a DISCONTINUITY; ffmpeg reports a -9.018 s timestamp discontinuity). System ffmpeg -ss on a local copy lands 3.0/12.04/20.0/27.0 s in 0.13-0.33 s; Qt's player fed the same cached bytes decoded nothing for 7 s (h264 'no frame!' spam — present in clean runs too, 11,457 lines in n129). CV's over-serve (08-25) + Qt's seek: unfixed tonight
  - fix: none tonight; evidence sent to CV (letter §7). Client option if CV keeps over-serving: re-open for any cross-fragment target (re-opens play from seg 0 in order and never seek)
- **pb_open_d3:over_target** (n=132, 04:31): see the PBTIME/WTHLS lines: server-side rendition of a 3-day-old day (cold cache) — same class as pb_open_d1/pb_cold_boot
  - fix: none client-side
- **pb_seek:over_target** (n=138, 04:40): Server-side, known class: the seek test's far seeks each open a new session window whose first two segments render cold — sessions a376434a (seg0 serve 2,895 ms, seg1 3,298 ms) and b0a28468 (3,132 + 3,285 ms) → first_frame 6.8 s and one 8.0 s TIMEOUT; the in-stream 1 s steps land in 1-3 ms; sessions whose renditions already existed served in 43-440 ms per segment (f6e46824)
  - fix: none client-side; the cold-rendition cost per new window is CV's (a prewarm around the seek target, as B3 does for mosaics, would be the ask — not sent tonight)
- **pb_open_armed_d1:over_target** (n=162, 05:09): Server-side session build for a motion-only day (fast_open_skip why=light-day, by design): session_http 434 ms then session_ready at 1,989 ms with the whole-day manifest; the first segments served from cache in 2-43 ms. first_frame 1,783 ms is the session wait
  - fix: none client-side (the bounded fast-open is skipped for light days on purpose; the whole-day session cost is CV's)
- **pb_rollover:over_target** (n=183,205 (9 runs, 8 over target), 06:00): Systematic server class: the rollover action opens the day at its START (fast_open tgt=00:00:17) — a 30-min window nothing else ever renders, so its first two segments are cold on every run (n205: session_ready 752 ms, seg0 serve 3,432 ms, seg1 4,098 ms → first_frame 8,286 ms; medians 1.2-2.6 s on warmer runs). Not a client cost: source_set 23 ms after session_ready
  - fix: none client-side; a server-side prewarm of the first segments at session creation (as B3 prewarm does for mosaics) is the ask — not sent tonight
- **hero:over_2.5x_median** (n=260, 07:06): No stall: 36 seeks, none ≥ 3 s (max 2,450 ms), median 618 ms flagged only against the running median of ~240 ms; 10 of the 36 seeks were cross-fragment re-opens whose new sessions rendered cold (0.5-2.4 s) — the server rendition class under the re-open path
  - fix: none; within the 3 s target
- **host_load:io_saturation** (n=285-287 + api_probe 07:37, 07:30-): Environment, not the client: from ~07:30 the pilot host is IO-saturated — /proc/loadavg 41.7/32.8/22.4 on 20 cores, /proc/pressure/io full avg10=40 % (all tasks blocked on disk 40 % of the time), vmstat wa 10-27 %, reads 100-230 MB/s. Container block-IO delta over 10 s: playback-service read 17 MB/s + write 34 MB/s (rendering the soak's playback opens cold), every other container < 1 MB/s → the bulk of the reads is the host-level seaweed `weed` volume process (69 % CPU) — CV's storage, cause unknown from here (compaction/retention?). Symptoms in the soak: live_open_recording n285 1,102 ms and live_open_armed n286 3,046 ms with GUI stalls of 0.9-2.0 s (the hinted pipeline adopted in 4-32 ms, so the pick/parking logic is fine), nav n287 15,127 ms, api_probe coverage 5,078 ms. Operator notified 07:40. Subsiding by 07:41 (load 22.6, io_full 4 %, reads 16 MB/s) — a ~15-minute window. A host-load sampler (unit hostload-0912b, 30 s) writes host-load.log beside rows.jsonl for the report
  - fix: none client-side; rows in this window are reported with the host condition, not as client regressions
- **calstress:over_target** (n=301, 07:57): Host IO storm #2, 07:56-07:59 (host-load.log: load 43, io_full 43 %, wa 52 %, reads 100-150 MB/s, writes up to 280 MB/s): the run's day-2026-09-11 open waited 4,847 ms for the session POST and 6,122 ms for session_ready, first_frame 11,236 ms; the 41.8 s [CAL] gap spans that open and its coverage fetch. Same run's other opens on the quieter seconds: 570-687 ms
  - fix: none client-side; host condition (see host_load:io_saturation)
- **INCIDENT:pilot_disk_full** (n=soak 02:10-08:09 + 08:23-08:29, 08:08-): The pilot box ran out of disk at 08:08-08:09 MSK. Chain, measured: seaweed's two volume servers are at Volumes==Max (4198/4198 and 6912/6912, Topology Free=0 of Max=11110, started with -max=0 -minFreeSpace=5GiB) → seaweed-master logs 'topo failed to pick 1 from 0 node candidates' ~1,500 times per 2 min → seaweed-filer 'retry assign: giving up after 30s' → s3 'putToFiler: chunked upload failed: assign volume: all filers failed' → recorder-service S3UploadFailedError, so recorded segments stay in its container-local /tmp/recorder, which grew at 750 MB/min (22.9→27.1 GB observed) and filled the disk. Both volume servers were simultaneously vacuuming event-clips volumes (9977/9987/10058/13571), which matches the IO storm measured from 07:25 (io full-stall 26-43 %, reads 100-230 MB/s, writes to 280 MB/s). Consequences here: the soak driver died at 08:09:28 writing events.log (OSError 28), `systemctl --user start wt-warden` failed in the same second so the Watchtower supervisor was down until I restarted it at 08:20, and the disk hit 0 free twice
  - fix: Mine: soak stopped 08:29 (rate unchanged, so the soak is not the driver), warden restarted, disk watchdog armed at an 8 GB floor, soak rows 310-342 of the restarted run kept. CV's: docker image prune (images 49→11, 56.4→36.16 GB) freed 24 GB and bought ~50 min, but did NOT restore assignment because the slot ceiling, not free space, is exhausted — reported to CV with the numbers. Outstanding on CV's side: reclaim inside existing volumes / retention deletion / raise the per-node ceiling. Soak rows measured between 07:25 and 08:09 carry the storm and are flagged in the host-condition section
- **followup:playlist_overlap_at_discontinuity** (n=probe after the run, 08:50): Follow-up to the over-serve (n130): CV measured their 35-fragment MANIFEST and found overlaps of only 0.007 s (sub-frame rounding), so client seek maps are safe against the manifest. But the PLAYLIST of session 2c351168 declares a 4.809 s overlap at a DISCONTINUITY with today's clipped EXTINF: segment 2 declares 23:48:57 +18.809 = through 23:49:15.809 while segment 3 declares start 23:49:11 and the same end. Three fresh gap-free 60 s sessions created afterwards (cameras .183/.184/.102) declared 59.851/59.850/59.851 s with ZERO overlapping pairs, so it appears tied to sessions crossing a recording gap. n=1: a second gap-spanning session could not be built on demand (/review/timeline 404'd for the URL shape tried) and probing stopped because the host was mid-incident
  - fix: none yet. CV WITHDREW option (b) (relabel EXTINF to true media duration) after mobile showed it would declare a 23.95 s overlap on purpose; CV now recommends (a), trim served bytes to the declared span, not shipping until the disk incident closes and the operator rules. Our hero maps a wall target to the FIRST fragment whose span contains it, so any declared overlap resolves silently to the earlier copy — worth revisiting when (a) lands

## Outliers (reason → count), by action

- `pb_open_d1` — over_target × 15
- `pb_rollover` — over_target × 11
- `pb_open_d3` — over_target × 7
- `live_open_armed` — over_target × 5
- `live_open_recording` — over_target × 4
- `hero` — over_target × 4
- `pb_open_armed_d1` — over_target × 3
- `hero` — over_2.5x_median × 3
- `pb_seek` — over_target × 3
- `hero` — no_metric × 2
- `pb_churn` — no_metric × 1
- `wall_live` — over_target × 1
- `guard_soak` — no_metric × 1
- `pb_open_d7` — no_metric × 1
- `pb_cold_boot` — over_target × 1
- `wall_day1` — crash × 1
- `nav` — over_target × 1
- `api_probe` — slow_or_failed × 1
- `calstress` — over_target × 1
- `pb_seek` — no_metric × 1
- `live_open_armed` — no_metric × 1

## Every outlier

| n | time | action | reason | primary | params | log |
|---|---|---|---|---|---|---|
| 1 | 02:10:53 | pb_churn | no_metric | None | {"WT_PLAYBACK_IP": "192.168.1.184", "WT_PLAYBACK_DAY": "2026 | logs/n0001-pb_churn.log |
| 2 | 02:14:53 | live_open_armed | over_target:4349.0>500 | 4349.0 | {"WT_FOCUS_IP": "192.168.1.143", "WT_FOCUS_DELAY_MS": "12000 | logs/n0002-live_open_armed.log |
| 3 | 02:17:03 | wall_live | over_target:7149.0>2000 | 7149.0 | {"WT_WALL_DAY": "live"} | logs/n0003-wall_live.log |
| 4 | 02:17:53 | pb_rollover | over_target:1198.0>1000 | 1198.0 | {"WT_PLAYBACK_IP": "192.168.1.245", "WT_TTFF_DAYS": "2026-09 | logs/n0004-pb_rollover.log |
| 14 | 02:25:34 | pb_open_d1 | over_target:6613.0>1000 | 6613.0 | {"WT_PLAYBACK_IP": "192.168.1.102", "WT_TTFF_DAYS": "2026-09 | logs/n0014-pb_open_d1.log |
| 15 | 02:26:23 | pb_rollover | over_target:2426.0>1000 | 2426.0 | {"WT_PLAYBACK_IP": "192.168.1.245", "WT_TTFF_DAYS": "2026-09 | logs/n0015-pb_rollover.log |
| 18 | 02:27:27 | pb_open_d1 | over_target:6479.0>1000 | 6479.0 | {"WT_PLAYBACK_IP": "192.168.1.102", "WT_TTFF_DAYS": "2026-09 | logs/n0018-pb_open_d1.log |
| 21 | 02:30:10 | pb_open_d3 | over_target:1967.0>1000 | 1967.0 | {"WT_PLAYBACK_IP": "192.168.1.123", "WT_TTFF_DAYS": "2026-09 | logs/n0021-pb_open_d3.log |
| 24 | 02:34:48 | guard_soak | no_metric | None | {"WT_GUARD_SOAK": "1", "WT_GUARD_LIVE_MS": "12000", "WT_THUM | logs/n0024-guard_soak.log |
| 28 | 02:38:59 | pb_open_d3 | over_target:1483.0>1000 | 1483.0 | {"WT_PLAYBACK_IP": "192.168.1.150", "WT_TTFF_DAYS": "2026-09 | logs/n0028-pb_open_d3.log |
| 29 | 02:40:45 | pb_open_armed_d1 | over_target:1276.0>1000 | 1276.0 | {"WT_PLAYBACK_IP": "192.168.1.104", "WT_TTFF_DAYS": "2026-09 | logs/n0029-pb_open_armed_d1.log |
| 32 | 02:45:54 | live_open_recording | over_target:518.0>500 | 518.0 | {"WT_FOCUS_IP": "192.168.1.245", "WT_FOCUS_DELAY_MS": "12000 | logs/n0032-live_open_recording.log |
| 34 | 02:47:29 | live_open_recording | over_target:655.0>500 | 655.0 | {"WT_FOCUS_IP": "192.168.1.189", "WT_FOCUS_DELAY_MS": "12000 | logs/n0034-live_open_recording.log |
| 35 | 02:48:27 | pb_open_d7 | no_metric | None | {"WT_PLAYBACK_IP": "192.168.1.189", "WT_TTFF_DAYS": "2026-09 | logs/n0035-pb_open_d7.log |
| 36 | 02:49:16 | live_open_recording | over_target:879.0>500 | 879.0 | {"WT_FOCUS_IP": "192.168.1.189", "WT_FOCUS_DELAY_MS": "12000 | logs/n0036-live_open_recording.log |
| 39 | 02:50:56 | live_open_armed | over_target:919.0>500 | 919.0 | {"WT_FOCUS_IP": "192.168.1.230", "WT_FOCUS_DELAY_MS": "12000 | logs/n0039-live_open_armed.log |
| 42 | 02:53:17 | live_open_armed | over_target:504.0>500 | 504.0 | {"WT_FOCUS_IP": "192.168.1.230", "WT_FOCUS_DELAY_MS": "12000 | logs/n0042-live_open_armed.log |
| 43 | 02:54:04 | live_open_armed | over_target:890.0>500 | 890.0 | {"WT_FOCUS_IP": "192.168.1.230", "WT_FOCUS_DELAY_MS": "12000 | logs/n0043-live_open_armed.log |
| 44 | 02:55:13 | hero | no_metric | None | {"WT_HERO_TEST": "1"} | logs/n0044-hero.log |
| 52 | 03:02:23 | pb_rollover | over_target:2087.0>1000 | 2087.0 | {"WT_PLAYBACK_IP": "192.168.1.105", "WT_TTFF_DAYS": "2026-09 | logs/n0052-pb_rollover.log |
| 55 | 03:06:30 | hero | no_metric | None | {"WT_HERO_TEST": "1", "WT_SECTION": "events"} | logs/n0055-hero.log |
| 58 | 03:09:12 | pb_open_d1 | over_target:1516.0>1000 | 1516.0 | {"WT_PLAYBACK_IP": "192.168.1.245", "WT_TTFF_DAYS": "2026-09 | logs/n0058-pb_open_d1.log |
| 60 | 03:10:34 | pb_open_d1 | over_target:1094.0>1000 | 1094.0 | {"WT_PLAYBACK_IP": "192.168.1.105", "WT_TTFF_DAYS": "2026-09 | logs/n0060-pb_open_d1.log |
| 74 | 03:24:41 | pb_open_d1 | over_target:7433.0>1000 | 7433.0 | {"WT_PLAYBACK_IP": "192.168.1.102", "WT_TTFF_DAYS": "2026-09 | logs/n0074-pb_open_d1.log |
| 80 | 03:30:47 | pb_rollover | over_target:1362.0>1000 | 1362.0 | {"WT_PLAYBACK_IP": "192.168.1.105", "WT_TTFF_DAYS": "2026-09 | logs/n0080-pb_rollover.log |
| 87 | 03:40:23 | pb_rollover | over_target:2651.0>1000 | 2651.0 | {"WT_PLAYBACK_IP": "192.168.1.183", "WT_TTFF_DAYS": "2026-09 | logs/n0087-pb_rollover.log |
| 93 | 03:46:34 | hero | over_target:6251.0>3000 | 6251.0 | {"WT_HERO_TEST": "1", "WT_SECTION": "events", "WT_HERO_AUTOP | logs/n0093-hero.log |
| 106 | 04:01:55 | hero | over_2.5x_median:941.0>190 | 941.0 | {"WT_HERO_TEST": "1", "WT_SECTION": "events", "WT_HERO_AUTOP | logs/n0106-hero.log |
| 107 | 04:03:04 | hero | over_target:6234.0>3000 | 6234.0 | {"WT_HERO_TEST": "1", "WT_SECTION": "events", "WT_HERO_AUTOP | logs/n0107-hero.log |
| 110 | 04:05:49 | pb_cold_boot | over_target:6284.0>3000 | 6284.0 | {"WT_PLAYBACK_IP": "192.168.1.189", "WT_PLAYBACK_DAY": "2026 | logs/n0110-pb_cold_boot.log |
| 112 | 04:08:11 | hero | over_target:6487.5>3000 | 6487.5 | {"WT_HERO_TEST": "1", "WT_SECTION": "events", "WT_HERO_AUTOP | logs/n0112-hero.log |
| 118 | 04:14:27 | wall_day1 | crash:6 Aborted | 8738.0 | {"WT_WALL_DAY": "2026-09-11", "WT_PB_HW_DECODE": "1"} | logs/n0118-wall_day1.log |
| 130 | 04:29:19 | hero | over_target:6406.0>3000 | 6406.0 | {"WT_HERO_TEST": "1", "WT_SECTION": "events", "WT_HERO_AUTOP | logs/n0130-hero.log |
| 132 | 04:31:17 | pb_open_d3 | over_target:1337.0>1000 | 1337.0 | {"WT_PLAYBACK_IP": "192.168.1.123", "WT_TTFF_DAYS": "2026-09 | logs/n0132-pb_open_d3.log |
| 134 | 04:34:14 | pb_open_d1 | over_target:8288.0>1000 | 8288.0 | {"WT_PLAYBACK_IP": "192.168.1.189", "WT_TTFF_DAYS": "2026-09 | logs/n0134-pb_open_d1.log |
| 138 | 04:40:44 | pb_seek | over_target:6489.0>4000 | 6489.0 | {"WT_PLAYBACK_IP": "192.168.1.183", "WT_PLAYBACK_DAY": "2026 | logs/n0138-pb_seek.log |
| 140 | 04:43:43 | pb_open_d3 | over_target:1561.0>1000 | 1561.0 | {"WT_PLAYBACK_IP": "192.168.1.150", "WT_TTFF_DAYS": "2026-09 | logs/n0140-pb_open_d3.log |
| 147 | 04:51:28 | pb_open_d1 | over_target:1465.0>1000 | 1465.0 | {"WT_PLAYBACK_IP": "192.168.1.245", "WT_TTFF_DAYS": "2026-09 | logs/n0147-pb_open_d1.log |
| 161 | 05:09:06 | pb_rollover | over_target:10084.0>1000 | 10084.0 | {"WT_PLAYBACK_IP": "192.168.1.189", "WT_TTFF_DAYS": "2026-09 | logs/n0161-pb_rollover.log |
| 162 | 05:09:54 | pb_open_armed_d1 | over_target:1783.0>1000 | 1783.0 | {"WT_PLAYBACK_IP": "192.168.1.221", "WT_TTFF_DAYS": "2026-09 | logs/n0162-pb_open_armed_d1.log |
| 176 | 05:25:13 | pb_rollover | over_target:2444.0>1000 | 2444.0 | {"WT_PLAYBACK_IP": "192.168.1.245", "WT_TTFF_DAYS": "2026-09 | logs/n0176-pb_rollover.log |
| 182 | 05:32:56 | pb_open_d3 | over_target:1270.0>1000 | 1270.0 | {"WT_PLAYBACK_IP": "192.168.1.180", "WT_TTFF_DAYS": "2026-09 | logs/n0182-pb_open_d3.log |
| 183 | 05:33:45 | pb_rollover | over_target:1492.0>1000 | 1492.0 | {"WT_PLAYBACK_IP": "192.168.1.184", "WT_TTFF_DAYS": "2026-09 | logs/n0183-pb_rollover.log |
| 185 | 05:36:46 | pb_open_d1 | over_target:6282.0>1000 | 6282.0 | {"WT_PLAYBACK_IP": "192.168.1.102", "WT_TTFF_DAYS": "2026-09 | logs/n0185-pb_open_d1.log |
| 188 | 05:39:42 | pb_open_d1 | over_target:1336.0>1000 | 1336.0 | {"WT_PLAYBACK_IP": "192.168.1.245", "WT_TTFF_DAYS": "2026-09 | logs/n0188-pb_open_d1.log |
| 193 | 05:47:18 | pb_seek | over_target:6015.0>4000 | 6015.0 | {"WT_PLAYBACK_IP": "192.168.1.184", "WT_PLAYBACK_DAY": "2026 | logs/n0193-pb_seek.log |
| 204 | 06:00:10 | pb_open_d3 | over_target:1716.0>1000 | 1716.0 | {"WT_PLAYBACK_IP": "192.168.1.126", "WT_TTFF_DAYS": "2026-09 | logs/n0204-pb_open_d3.log |
| 205 | 06:00:58 | pb_rollover | over_target:8286.0>1000 | 8286.0 | {"WT_PLAYBACK_IP": "192.168.1.102", "WT_TTFF_DAYS": "2026-09 | logs/n0205-pb_rollover.log |
| 206 | 06:01:46 | pb_open_d1 | over_target:2462.0>1000 | 2462.0 | {"WT_PLAYBACK_IP": "192.168.1.105", "WT_TTFF_DAYS": "2026-09 | logs/n0206-pb_open_d1.log |
| 211 | 06:07:55 | pb_open_d1 | over_target:1359.0>1000 | 1359.0 | {"WT_PLAYBACK_IP": "192.168.1.183", "WT_TTFF_DAYS": "2026-09 | logs/n0211-pb_open_d1.log |
| 227 | 06:29:36 | pb_open_d1 | over_target:6224.0>1000 | 6224.0 | {"WT_PLAYBACK_IP": "192.168.1.189", "WT_TTFF_DAYS": "2026-09 | logs/n0227-pb_open_d1.log |
| 228 | 06:30:24 | pb_open_armed_d1 | over_target:2257.0>1000 | 2257.0 | {"WT_PLAYBACK_IP": "192.168.1.205", "WT_TTFF_DAYS": "2026-09 | logs/n0228-pb_open_armed_d1.log |
| 260 | 07:06:14 | hero | over_2.5x_median:618.0>589 | 618.0 | {"WT_HERO_TEST": "1", "WT_SECTION": "events", "WT_HERO_AUTOP | logs/n0260-hero.log |
| 280 | 07:28:50 | pb_rollover | over_target:4955.0>1000 | 4955.0 | {"WT_PLAYBACK_IP": "192.168.1.184", "WT_TTFF_DAYS": "2026-09 | logs/n0280-pb_rollover.log |
| 282 | 07:31:38 | pb_rollover | over_target:11852.0>1000 | 11852.0 | {"WT_PLAYBACK_IP": "192.168.1.189", "WT_TTFF_DAYS": "2026-09 | logs/n0282-pb_rollover.log |
| 284 | 07:34:03 | pb_open_d1 | over_target:1133.0>1000 | 1133.0 | {"WT_PLAYBACK_IP": "192.168.1.189", "WT_TTFF_DAYS": "2026-09 | logs/n0284-pb_open_d1.log |
| 285 | 07:34:51 | live_open_recording | over_target:1102.0>500 | 1102.0 | {"WT_FOCUS_IP": "page:recording", "WT_FOCUS_DELAY_MS": "1200 | logs/n0285-live_open_recording.log |
| 286 | 07:35:37 | live_open_armed | over_target:3046.0>500 | 3046.0 | {"WT_FOCUS_IP": "page:armed", "WT_FOCUS_DELAY_MS": "12000",  | logs/n0286-live_open_armed.log |
| 287 | 07:37:18 | nav | over_target:15127.0>1500 | 15127.0 | {"WT_NAVTEST": "6"} | logs/n0287-nav.log |
| 288 | 07:37:31 | api_probe | slow_or_failed:coverage_ms | 163 | {} |  |
| 290 | 07:42:40 | pb_open_d3 | over_target:1706.0>1000 | 1706.0 | {"WT_PLAYBACK_IP": "192.168.1.116", "WT_TTFF_DAYS": "2026-09 | logs/n0290-pb_open_d3.log |
| 291 | 07:44:55 | pb_seek | over_target:6299.5>4000 | 6299.5 | {"WT_PLAYBACK_IP": "192.168.1.102", "WT_PLAYBACK_DAY": "2026 | logs/n0291-pb_seek.log |
| 292 | 07:46:05 | hero | over_2.5x_median:958.0>671 | 958.0 | {"WT_HERO_TEST": "1", "WT_SECTION": "events", "WT_HERO_AUTOP | logs/n0292-hero.log |
| 295 | 07:51:13 | pb_open_d1 | over_target:21238.0>1000 | 21238.0 | {"WT_PLAYBACK_IP": "192.168.1.184", "WT_TTFF_DAYS": "2026-09 | logs/n0295-pb_open_d1.log |
| 301 | 07:58:31 | calstress | over_target:41774.0>15000 | 41774.0 | {"WT_PLAYBACK_IP": "192.168.1.105", "WT_CAL_STRESS": "1"} | logs/n0301-calstress.log |
| 304 | 08:02:45 | pb_open_d1 | over_target:1281.0>1000 | 1281.0 | {"WT_PLAYBACK_IP": "192.168.1.245", "WT_TTFF_DAYS": "2026-09 | logs/n0304-pb_open_d1.log |
| 307 | 08:07:54 | pb_seek | no_metric | None | {"WT_PLAYBACK_IP": "192.168.1.102", "WT_PLAYBACK_DAY": "2026 | logs/n0307-pb_seek.log |
| 308 | 08:08:40 | live_open_armed | no_metric | None | {"WT_FOCUS_IP": "page:armed", "WT_FOCUS_DELAY_MS": "12000",  | logs/n0308-live_open_armed.log |

## Host condition

The pilot host (20 cores) carried CV's full backend throughout. From about 07:25 it ran into recurring IO storms — the storage daemon (`weed`) reading 100–230 MB/s and writing up to 280 MB/s, `/proc/pressure/io` full-stall 26–43 %, load 29–43 — which inflated everything measured inside them (live opens 1–3 s with 0.9–2.0 s GUI stalls, one navigation test at 15 s, calendar stress at 42 s, backend coverage probe 5.1 s). Those rows are counted as outliers above and attributed to the host in the notes, not to the client. The operator was notified at 07:40 and 08:00. Before the sampler started, the backend probe's `coverage_ms` (357–2,725 ms all night, 5,078 ms at 07:37) is the proxy.

| samples (30 s) | first | last | load₁ min / median / max | samples with IO full-stall ≥ 20 % | storm windows (IO full ≥ 20 %) |
|---|---|---|---|---|---|
| 127 | 07:41 | 08:47 | 9 / 14 / 43 | 23 (18 %) | 07:43–07:43, 07:50–07:50, 07:56–08:00, 08:02–08:02, 08:19–08:21, 08:35–08:35, 08:39–08:39, 08:46–08:46 |

## Letters

- CV's reply on the continuity-counter fix (`07eedeb`), received 02:10, committed verbatim: `docs/letters/2026-09-11-hardware-decode-wall-result-the-chase-wins-the-race-and-serves-fallback.reply.md`.
- Our reply with the three hardware-decode cycles, the two `fallback` cases, our own out-of-order prefetch owned and fixed, and the over-serve evidence: `docs/letters/2026-09-12-re-run-done-zero-fallback-in-the-players-order-one-double-answer-and-our-own-out-of-order-prefetch.md` — **to be pasted to CV by the operator; §8 (0-byte segments) is the operator's ruling.**

## Logs

Per-run logs of outliers and forced reproductions are kept on the dev box under `logs/` (105 files, ~197M); they are gitignored, not committed. `rows.jsonl` carries every number in this README.
