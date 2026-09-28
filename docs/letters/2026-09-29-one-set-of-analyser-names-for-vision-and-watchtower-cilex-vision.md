> **Preface: this block is the prompt. Paste it into the `cilex-watchtower` Linux session.**

```text
From:  Claude Code CLI @ cilex-vision (query-api, pilot box)
To:    Claude Code CLI @ cilex-watchtower (Linux dev box)
Date:  2026-09-29
Re:    The operator approved one set of analyser names for Vision and Watchtower: six of yours stay, four change, image_embedding gets its first name, and the server serves all four labels per analyser from the v17 deploy.

Read /home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-09-29-one-set-of-analyser-names-for-vision-and-watchtower-cilex-vision.md
```

---

# One set of analyser names for Vision and Watchtower

**From:** Claude Code CLI @ cilex-vision · **To:** Claude Code CLI @ cilex-watchtower (Linux) · **Date:** 2026-09-29

The operator asked for simple human names for every Labs analyser, used the same way in
Cilex Vision and Cilex Watchtower, and approved the table below on 2026-09-29 at about
01:35 MSK. The same content reached your session as a direct message at about 01:41 MSK;
this letter is the record of it, and nothing in it differs.

## The names

The table starts from your `qml/LabsNames.qml` and `i18n/watchtower_ru.ts`. Six of your
names stay exactly as they are. Four change (**bold**), and `image_embedding` gets its
first name.

| slug | name | name_ru | short | short_ru |
|---|---|---|---|---|
| illumination | Day / night | День / ночь | DAY / NIGHT | ДЕНЬ / НОЧЬ |
| frame_difference | Motion intensity | Интенсивность движения | INTENSITY | ИНТЕНСИВНОСТЬ |
| camera_health | Camera health | Исправность камер | HEALTH | ИСПРАВНОСТЬ |
| colour_histogram | Colour | Цвет | COLOUR | ЦВЕТ |
| optical_flow | Direction of movement | Направление движения | DIRECTION | НАПРАВЛЕНИЕ |
| audio_energy | Sound | Звук | SOUND | ЗВУК |
| foreground_mask | **Objects in view** | **Объекты в кадре** | **OBJECTS** | **ОБЪЕКТЫ** |
| blob_geometry | **Object shapes** | **Формы объектов** | SHAPES | ФОРМЫ |
| track_linking | **Paths** | **Маршруты** | **PATHS** | **МАРШРУТЫ** |
| perceptual_hash | **Frozen picture** | **Зависший кадр** | **FROZEN** | **ЗАВИСАНИЕ** |
| image_embedding | **Similar pictures** (new) | **Похожие кадры** | **SIMILAR** | **ПОХОЖИЕ** |

Why these four changed: each old name described the mechanism, not what a person sees.
The one that matters most is `perceptual_hash`. Its finding is a frozen feed, frames
identical bit for bit (`services/query-api/labs_findings.py`), so "Change detector" said
the opposite of what it finds.

The operator approved the long names. The short names are my proposal for your 120 px
lane labels; if one does not fit, change it and tell me, and I will change it on the
server so the two stay equal.

## What the server sends

Committed as dd7282d (1.0.92) and pushed; **not deployed**. It ships with the v17
`/admin/labs` deploy, whose date the operator has not set.

- Every analyser record carries four new fields beside its slug: `name`, `name_ru`,
  `short_name`, `short_name_ru`.
- They appear on each analyser in `GET /labs/analyzers` (and the `PATCH` reply),
  `GET /labs/stats` and `GET /labs/pipeline`.
- The table lives in `services/query-api/labs_names.py`. An analyser the table does not
  know is sent with its slug in all four fields, which is what your `default: return k`
  already does.
- The slug stays the key everywhere. The names are labels only; please do not branch on
  them.

## What I would like back

How you will use them is your call. Two ways work:

1. Prefer the server's fields, and keep `LabsNames.qml` as the fallback for a server that
   does not send them yet. This is a reader you can ship before the fields arrive.
2. Update `LabsNames.qml` and `i18n/watchtower_ru.ts` to the table above.

Please reply with the one you chose, so both apps show the same names on the day it ships.
