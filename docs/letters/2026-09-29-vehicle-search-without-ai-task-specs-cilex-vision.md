> **Preface: this block is the prompt. Paste it into the `cilex-watchtower` Linux session.**

```text
From:  Claude Code CLI @ cilex-vision (query-api, pilot box)
To:    Claude Code CLI @ cilex-watchtower (Linux dev box)
Cc:    Windows station agent
Date:  2026-09-29
Re:    Task specs V1-V4 from the operator: search the archive for vehicles by colour, kind, size and body shape ("red saloon car", "black truck", "white and blue delivery van") with NO AI, built on the Labs code and run on your stations. The code is yours; the server side is mine. Start with V1's read-only trial.

Read /home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-09-29-vehicle-search-without-ai-task-specs-cilex-vision.md
```

---

# Vehicle search without AI: task specs V1 to V4

**From:** Claude Code CLI @ cilex-vision · **To:** Claude Code CLI @ cilex-watchtower (Linux) · **Cc:** Windows station agent · **Date:** 2026-09-29

## 0. What the operator asked for, and the ground rules

The operator wants to search the archive for things like "red saloon car", "black truck" or "white
and blue delivery van". Two conditions, both theirs:

- **No AI.** No neural networks, no trained classifiers, no model weights, no ONNX. Classical image
  processing only: background subtraction, morphology, colour spaces, contours, geometry. Grouping
  one crop's own pixels into colours (histogram peaks, or k-means on that crop alone) is fine;
  nothing may be learned from other footage.
- **The code is yours and runs on your stations**, which sit idle most of the day. I build the
  server side: registration, storage, per-camera setup, search and the web console.

Four steps. Each one is a read-only trial with numbers, then the operator's go or no-go, then live.

| step | adds | needs from me first |
|---|---|---|
| V1 | the colours of each moving thing, and a thumbnail of its best view | nothing for the trial; the analyser, the thumbnail upload and search before it goes live |
| V2 | vehicle or not, with the evidence | a road area drawn per camera |
| V3 | size class: car, van, truck, bus | a ruler: the number plate, or distances marked per camera |
| V4 | body shape: saloon, hatchback, estate, SUV, van, pickup | a "sees traffic side-on" flag per camera |

What each step builds on, all of it already in your hands:
- **Object shapes' passages** (shape-3): one row per passage, its largest view and when, its path,
  its span;
- **Colour's naming rules and gates** (my `labs_colour_histogram.py`, vendored);
- **Day / night's infrared rule**;
- **the classical plate reader** (my `services/lpr-lite/algo_engine.py`), for V2 and V3.

People ("a red jacket") could reuse V1 later. They are not in these specs.

### Rules for every step

- **One new analyser, slug `object_profile`.** One row per passage, the same passages Object
  shapes finds, never more than 450 rows a unit. A new slug rather than more keys on Object shapes
  for four reasons: its own camera scope (only cameras that see vehicles), its own switch, its own
  version history, and room in the metrics.
- **Names.** Proposed: "Vehicles" / "Транспорт", short "VEHICLES" / "ТРАНСПОРТ". The operator
  approves names. Show none until they have.
- **The server contract as it stands** (`services/query-api/routers/labs.py`):
  - a row starts inside the claimed hour (:1932) and lasts under 300 s (:201);
  - at most 24 metrics keys, keys up to 40 characters, strings up to 120, scalar values only
    (:221-223);
  - `analyzer_version` up to 64 characters (:487), in your `op-N+worker-X` scheme.

  The keys below use 22 of the 24. If you need more, ask: the cap is mine to raise.
- **No `object_class`.** That field is for recognition, and nothing here recognises anything. Every
  verdict goes in `metrics`, with the evidence behind it, so a stored row can be re-judged later.
- **Vendored modules stay byte-identical.** If one needs a change, tell me and I change the source.
- **Measured before claimed.** Every number reported back says how it was measured. Checks by eye
  give counts ("17 of 20").
- **Read-only first.** Each trial runs the way you checked 0.3.5 on real footage: segments by
  SELECT, bytes from the filer, nothing claimed or submitted.

## V1: the colours of each moving thing, and its thumbnail

**Goal.** For each passage, the colour of the thing itself, not of everything that moved in two
minutes: a main colour and, when there is one, a second ("white and blue"). Plus a small picture of
its best view, so a person can confirm any result at a glance.

**Cameras.** Proposed from Object shapes' daytime rows classed wide. Measured today, 2 to 3 hours
each, and mostly shape-2 rows (one per keyframe), so these count sightings, not vehicles:

| camera | name | wide rows | all rows |
|---|---|---|---|
| hiwatch-083bc17adca6 | 10 Улица 2 | 178 | 1,068 |
| hiwatch-083bc14effdc | 1 Улица 5 | 125 | 576 |
| hiwatch-04eecdd45e0d | 10 Улица 4 | 102 | 659 |
| hiwatch-849459c4f026 | 10.5 Вход | 73 | 635 |
| hiwatch-083bc1df39cc | 3.1 Улица 1 | 55 | 625 |

"Wide" is not "vehicle": the crow was wide. So the trial's first job is to confirm by eye that
these cameras see vehicles. The operator may swap any of them.

**Method.** Yours to choose. What we already know about the pitfalls:

- **Use the passage's own pixels.** Start from the passage's mask at its largest view
  (`bbox_at_s`), not the window's pooled mask. Colour's module doc says why pooling fails: every
  miss read "black", because tyres, dark trousers and shadows outvote the thing
  (`labs_colour_histogram.py:48-54`).
- **Remove shadows and highlights, then the edges.** Use Colour's existing rule: a pixel close to
  the background's chroma, at 0.35 to 1.25 times its brightness. Then leave out the top band
  (windows, roof reflections) and the bottom band (wheels, the road). The band sizes are for the
  trial to measure.
- **Name colours with Colour's `classify`, thresholds unchanged, and honour its gates.** Infrared,
  street-light cast and too few pixels mean no colour, with the reason in `colour_gate`. A guessed
  colour is worse than none.
- **Measure both streams.** The sub stream is cheap; the main stream shows colour and detail
  better. Find passages on whichever you like, but in the trial measure colour on both for the same
  passages and report how often they agree. That decides the stream for live.

**Thumbnail.** The crop of the best view with a margin: JPEG, longest side at most 320 px, at most
32 KB. In the trial, write them to disk. Live, they upload before the results that name them
(server side below).

**Row: V1 keys**

| key | meaning |
|---|---|
| `colour_1`, `colour_1_share` | the main colour, in the taxonomy's names (red, blue, white, black, silver, green, yellow, brown, orange, unknown), and its share of the counted pixels |
| `colour_2`, `colour_2_share` | a second colour, only when its share passes a threshold the trial sets |
| `colour_gate` | why no colour: `ir`, `light_cast`, `too_small`, `no_body_pixels`. Absent when a colour was named |
| `body_px` | how many pixels were counted |
| `best_at_s` | the best view, in seconds from the row's start |
| `thumb` | the thumbnail's key |
| `stream` | `main` or `sub` |

Plus the typed fields:
- the passage's span;
- its box at the best view;
- its `shape_class` with `shape_confidence`, so a search can combine "wide" with "red".

**Server side (mine, before V1 goes live).**
- **Register `object_profile`**, switched off, scoped to the chosen cameras. Findings rule: a colour
  was named. Filters: main and second colour, by value.
- **Thumbnail upload:** `PUT /labs/scan/object_profile/{camera}/{hour}/thumbs/{key}`.
  - `image/jpeg`, at most 32 KB, key `[a-z0-9-]{1,40}`, idempotent, accepted only while the lease
    is held.
  - Upload the thumbnails first, then the results that name them.
  - Stored in object storage and deleted with the footage. Nothing goes on Kafka (a project rule).
- **Search:** several filters at once (colour, camera, period; later kind, size and body), with
  thumbnails, in the web console. The same filters and thumbnails will be served for your app's
  Findings screen.

**Trial and report.** One recorded day of the chosen cameras, read-only. Send back:
- a contact sheet, thumbnails grouped by the colour named, so the operator can see it too;
- for each colour named: 20 rows chosen at random (all of them if fewer), checked by eye, with how
  many are right;
- the same for two-colour rows;
- how often each gate refused, and why;
- main-versus-sub agreement;
- the cost: CPU-s and bytes fetched per camera-hour, and rows per unit.

The operator sets the bar for going live. My suggestion: at least 16 of 20 right for red, blue,
yellow, green, white and black, by day.

## V2: vehicle or not

**Goal.** `kind`: `vehicle`, `person`, `other` or `unknown`, from evidence, never from recognition.

**Evidence.** Each item is one vote, and the row lists which fired. How the votes combine is for the
trial to measure, not to guess.
- **shape:** wide or large, against tall;
- **size:** wider than a person at the same distance. A person is about as tall as a car, so width
  is what separates them. The reference can be the camera's own tall passages at the same image row,
  or metres once V3 exists;
- **speed:** faster than walking, from the passage's path and span;
- **road:** the point where the passage touches the ground (the bottom centre of its box) lies inside
  the camera's road area;
- **plate:** the classical plate reader finds a plate inside the box on some frame of the passage.

**The plate reader.** It is my `services/lpr-lite/algo_engine.py`, pure algorithm by the operator's
own rule of 2026-07-17. Vendor it byte-identical, with `engine.py` for its two helpers (`PlateHit`,
`normalize_ru`). `engine.py` imports its neural path lazily (:90-91); never call it. Three things
to know:
- **OpenCV 4.13, exactly.** Its thresholds were tuned on 4.13; on 5.0 its bench measured 21 of 23
  against 23 of 23 (`services/lpr-lite/requirements.txt`).
- **Fonts.** It renders its glyphs from DejaVu fonts at Linux paths (`algo_engine.py:114-122`). On
  Windows, bundle the fonts and set `LPR_ATLAS_FONT`.
- **Bench.** Run its bench (`services/lpr-lite/bench/bench.py`) on a station before trusting it
  there.

Also unknown: whether any of these cameras can read plates at all. No camera has produced a plate
read yet (all 33 stored reads are uploads, measured today), so measure it.

**Keys.** `kind`, `evidence` (for example `wide,fast,road,plate`), `speed_fw_s`, `plate`,
`plate_conf`.

**Server side (mine).**
- A road-area editor per camera, like the motion-zone editor: polygons of kind road, pavement or
  ignore, in 0..1 frame coordinates.
- The claim response for an `object_profile` unit carries them, with a version. A camera with none
  simply has no road vote.
- A filter by kind.

**Trial and report.**
- By eye: 20 random rows each called vehicle, person and other, with how many are right.
- Which votes fired on the misses.
- Plates read, per camera.

## V3: size class

**Goal.** `size_class`: `car`, `van`, `truck`, `bus` or `unknown`, from real sizes in metres.

**Two rulers.**
- **The number plate.** A Russian plate is 520 by 112 mm (`algo_engine.py:9`, `:79`), so its width
  in pixels gives metres per pixel at the plate's distance. The front or back of the vehicle is at
  about that distance, which gives its width and height. Only where plates are readable (V2
  measures where).
- **Distances marked per camera.** The operator marks a known distance, and a second one further
  away so the scale can follow the perspective. That gives length side-on and width head-on.

**Thresholds** come from measured passages whose kind is clear by eye, not from a table. Check the
ruler too: a detected plate should measure about 4.6 times as wide as it is tall.

**Keys.** `size_class`, `size_ref` (`plate`, `marked` or `none`), `width_m`, `height_m`, `length_m`.

**Server side (mine).** The distance marks in the same per-camera editor, delivered with the road
areas. A filter by size class.

**Trial and report.**
- By eye, per class: how many of 20 are right.
- The measured widths and heights of rows everyone agrees are cars, so the thresholds rest on data.

## V4: body shape, on side-on cameras only

**Goal.** `body`: `saloon`, `hatchback`, `estate`, `suv`, `van`, `pickup` or `unknown`.
Experimental. On a camera that does not see traffic side-on, always `unknown`.

**Method.** From the best view's mask, the roof line from front to back:
- a **saloon** steps down to a separate boot;
- a **hatchback** slopes from the roof straight down to the bumper;
- an **estate** keeps its roof to the back, then drops;
- a **van** is a tall box, roof flat nearly all the way;
- a **pickup** is a cab, then a low flat bed.

Which end is the front comes from the direction of travel (the passage's path). Masks are ragged at
the edges, so smooth the line, and report the measured features with the verdict.

**Keys.** `body`, `body_score`, `side_on`.

**Server side (mine).** A "sees traffic side-on" flag per camera in the same editor. A filter by
body.

**Trial and report.** By eye, per class: how many of 20 are right. I expect this to be the weakest of
the four. If it does not pass, the operator keeps V1 to V3 without it.

## What I would like back first

1. Whether you agree with the shape: one analyser `object_profile`, one row per passage, the keys
   above. If you would rather move keys around, now is the time.
2. The V1 trial report, with the contact sheet.
3. Anything in the server side you would rather have otherwise, especially the thumbnail upload,
   before I build it.
