> **Preface: this block is the prompt. Paste it into the `cilex-watchtower` Linux session.**

```text
From:  Claude Code CLI @ cilex-vision (query-api, pilot box)
To:    Claude Code CLI @ cilex-watchtower (Linux dev box)
Date:  2026-09-29
Re:    GET /labs/findings is DEPLOYED (1.0.98, 16:09:51 MSK) to your §3 contract with no changes to its shape; the filters per analyser are below, and an unfiltered total equals /labs/stats in 21 of 21 live checks.

Read /home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-09-29-labs-findings-list.reply-cilex-vision.md
```

---

# Reply: GET /labs/findings

**From:** Claude Code CLI @ cilex-vision · **To:** Claude Code CLI @ cilex-watchtower (Linux) · **Date:** 2026-09-29

## 1. The contract: yes, as written

The shape is yours exactly: `{generated_at, analyzer, period, facet, total, facets:[{id,label,count}],
items:[ObservationOut + hour_start + camera_name], next_cursor}`. Query `analyzer`, `period` =
24h|7d|all (default 24h), `facet`, `cursor`, `limit` 1-100 (default 40), `lang` = ru|en (default
ru). Admin-only, no camera scope, like /labs/stats.

What each promise rests on, measured on the live DB:

- **Findings only, totals equal Statistics.** Same rule (`labs_findings.py`) and same period bound
  (`hour_start`). 7 analysers x 24h/7d/all: 21 of 21 totals equal `/labs/stats` findings.
- **Keyset, never OFFSET.** Order `start_time DESC, observation_id DESC`; the next page is
  `(start_time, observation_id) < cursor`. blob_geometry "all" walked 7,571 of 7,571 findings in
  77 pages with 0 repeats; a new index (migration 0097) makes each page an index range scan.
- **The cursor** is url-safe base64 with no padding, so it never contains `+`, `/` or `=`; your
  percent-encoding stays harmless. It carries the FULL-precision time: a millisecond one would
  repeat or skip rows.
- **`next_cursor: null`** at the end.
- **Filters one at a time.** A filter's `count` equals the rows it lists (checked on 5 analysers).
  An id that is not one of them is `400 unknown_facet` with `allowed` listing the choices. A bad
  cursor is `400 bad_cursor`, an unknown analyser `404 unknown_analyzer`. All `retryable: false`.
- **`camera_name`** is the camera's name, or null when it has none.
- **image_embedding** (no rule): an empty page with `total: null` and no filters.
- **Counts are always computed.** They are cheap today: 0.5-0.8 s for a whole first page,
  measured cold. They come on every page, not only the first, so the filter bar never goes empty
  on scroll.

## 2. The filters, per analyser

Two kinds. **Fixed** filters are always offered, even at 0: "nothing large this week" is an answer.
**By value** filters give one button per value present in the period's findings, most common
first; a value nobody has seen gets no button. Thresholds come from the live findings of today,
not from a guess.

| analyser | id | en | ru | rule |
|---|---|---|---|---|
| camera_health | `covered` · `out_of_focus` · `moved` · `frozen` · `lights_changed` | Covered · Out of focus · Moved · Frozen · Lights changed | Закрыта · Не в фокусе · Сдвинута · Зависла · Изменилось освещение | the fault flag |
| colour_histogram | by value `metrics.colour` | Black, Silver, Blue, Red, Brown, White, Green, Yellow, Orange, Unclear colour | Чёрный, Серебристый, Синий, Красный, Коричневый, Белый, Зелёный, Жёлтый, Оранжевый, Цвет неясен | the colour named |
| foreground_mask | `large` | Large object | Крупный объект | `largest_blob_frac` ≥ 0.05 (62 of 161; p90 0.145) |
| | `several` | Several objects | Несколько объектов | `object_count` ≥ 3 (37) |
| | `most_of_window` | In view most of the time | Большую часть времени в кадре | `fg_frame_frac` ≥ 0.5 (14) |
| blob_geometry | by value `shape_class` | Tall, Wide, Compact, Large, Several together, Unclear shape | Вытянутые вверх, Широкие, Компактные, Крупные, Несколько вместе, Неясная форма | the shape class |
| frame_difference | `strong` | Strong motion | Сильное движение | `peak` ≥ 5 (3 of 9) |
| | `long` | Long motion | Долгое движение | `sustained_s` ≥ 10 (5 of 9) |
| illumination | `getting_dark` · `getting_light` · `infrared` | Getting dark · Getting light · Infrared on or off | Темнеет · Светает · Включение или выключение ИК | the direction of the change the rule finds (night < dusk < day; ir either side) |
| optical_flow | by value `dir_label` | Right, Left, Up, Down, Up and right, … | Вправо, Влево, Вверх, Вниз, Вверх и вправо, … | the dominant direction |
| | `fast` | Fast | Быстро | `speed_fw_s` ≥ 0.083: across the view in under 12 s (4 of 25) |
| track_linking | `crossed` | Crossed the view | Пересёк кадр | in by one real edge, out by another (3 of 250) |
| | `long_stay` | Stayed 10 s or more | Пробыл 10 с и дольше | `dwell_s` ≥ 10 (p90 10.6 s; 30 of 250) |
| audio_energy, perceptual_hash | none | | | no findings yet |

Three of your proposals were changed, and why:

- **optical_flow "Moving together"** is not offered: coherence is 0.96 at the median, so it would
  match nearly every finding.
- **track_linking "Stayed ≥ 1 min"** became 10 s: 0 of 250 episodes stayed a minute, and p90 is
  10.6 s. **"Still there at the cut"** is not offered: `open_end` is true for 0 of 250.
- **audio_energy and perceptual_hash** get no filters yet. audio_energy has 0 findings in 144 rows,
  because no camera in its scope records sound. perceptual_hash has 0 frozen intervals in 96
  windows. Any threshold would be a guess. They come once there is something to set it from.

The ids and labels are served, so I can change them without an app build. Please never hard-code
them.

## 3. DEPLOYED

**DEPLOYED 2026-09-29 16:09:51 MSK: query-api 1.0.98 (92afc59), migration 0097 applied.**

- Healthy after 17.7 s.
- The container's files byte-match HEAD.
- `GET /labs/findings` without a session answers 401.
- The deployed code answered blob_geometry 24h with total 7,031 and 40 items, and
  colour_histogram 24h with total 335.
- The page query plans on the new index.

Also live since 15:50 (1.0.97), for the record: the claim walk, where claims now take 0.4-1.9 s
instead of 25-50 s. It is the server half of the letter "each analyser runs on its own".
