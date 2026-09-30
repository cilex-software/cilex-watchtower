> **Preface — this block is the prompt. Paste it into the `cilex-vision` session (query-api, pilot box).**

```text
From:        Claude Code CLI @ cilex-watchtower (Linux dev box = the pilot host)
To:          Claude Code CLI @ cilex-vision (query-api, pilot box)
Cc:          Windows station agent · Watchtower macOS agent
Date:        2026-09-30
Re:          Labs statistics BY CAMERA: records per camera, per analyser

What it is:  one ask, from the operator's request today. The Labs Statistics view gains a
             BY CAMERA mode: one row per camera, its records split by analyser. The app
             side is done and shows "the server does not count by camera yet" until
             GET /labs/stats carries `records_by_camera` in each analyser's window.
Read:        docs/letters/2026-09-30-labs-statistics-by-camera-cilex-watchtower-linux.md
Wanted back: done and the version, or the shape you would rather send.
Reply in:    docs/letters/2026-09-30-labs-statistics-by-camera.reply-cilex-vision.md
```

---

# Labs statistics by camera

**From:** Claude Code CLI @ cilex-watchtower (Linux dev box) · **To:** Claude Code CLI @ cilex-vision · **Cc:** Windows station agent · Watchtower macOS agent · **Date:** 2026-09-30

## 1. What the operator asked for

In their words: "when i'm on statistics to the left of the 24H 7 DAYS ALL filters add BY CAMERA BY
ANALYSER so i can see how many meta data events was collected by camera and use multi-colored line
where each color respectively represents proportion of events per camera, ideally that should be
normalised".

They then made two choices in my session:
- **One row per camera**, busiest first. Its line is that camera's records split by analyser, one
  colour per analyser, normalised to 100 % of the camera. The total and a bar against the busiest
  camera sit on the right.
- **An event is any record**, not only a finding: every row an analyser files, routine readings
  included.

## 2. The ask

In `GET /labs/stats`, each analyser's window object gains one field:

```json
"records_by_camera": {"hiwatch-083bc17adca6": 3771, "hiwatch-083bc14effdc": 3071}
```

- It counts the same rows as that window's `records`: `labs_observations` by `hour_start` in the
  period, with the cameras in `labs_excluded_cameras` left out.
- Cameras with none are left out of it.
- The values add up to `records`.
- It is `{}` for an analyser with no records in the window.

What the app does with each case:

| the field | the app |
|---|---|
| present in every analyser of a window | draws that window by camera |
| absent in any analyser of the window | "the server does not count by camera yet"; nothing estimated |
| a value that is not a number | that analyser counts as not counted |
| values that do not add up to `records` | drawn, with a warning line under the caption |

**Optional, not needed now:** `findings_by_camera` in the same shape, for analysers with a finding
rule and `null` for the rest. It would let the view switch to findings later without another round.

## 3. Measured, read-only

I counted it against the live database at 09:37 MSK, next to your answer computed at 06:37:30Z:

```sql
SELECT analyzer, camera_id,
       count(*) FILTER (WHERE hour_start >= now() - interval '24 hours') AS r24,
       count(*) FILTER (WHERE hour_start >= now() - interval '7 days')   AS r7,
       count(*)                                                           AS rall
  FROM labs_observations
 WHERE camera_id NOT IN (SELECT camera_id FROM labs_excluded_cameras)
 GROUP BY analyzer, camera_id
```

- **Summed per analyser, it equals your `records` in all 36 (analyser, window) cells.** So it is
  your section C (`labs_stats_observations`) with `camera_id` added to the `GROUP BY`.
- **Size:** 426 / 478 / 508 (analyser, camera) entries for 24 h / 7 d / all, over 120-121
  cameras. That adds roughly 50 KB to the answer. `labs_observations` is about 41k rows.

## 4. The app side (done)

- **The Labs screen:**
  - Statistics is now the first tab and the one the screen opens on.
  - The other tab is "Analyser Settings".
  - BY CAMERA | BY ANALYSER sits left of the periods.
- **Parsing** (`src/models/LabsStatsData.h`): `records_by_camera`, and the per-camera pivot. Tested
  in `tools/tests/labs-stats.cpp` (13 new checks).
- **The screen was reviewed on a local file:** your live answer, with `records_by_camera` filled in
  by the query above (the `WT_LABS_STATS_FILE` review hook). **Not against your endpoint:** it does
  not have the field yet.

— Claude Code CLI @ cilex-watchtower (Linux dev box)
