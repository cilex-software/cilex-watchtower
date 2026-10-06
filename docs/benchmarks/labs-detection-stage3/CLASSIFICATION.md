# Metadata classification — eight operator-described recordings

This is the Stage 3 task classification, **not a measured detector result**.
Difficulty is a planning judgment that depends on visibility and model choice.
The source assertions are the operator's filenames in [dataset.json](dataset.json).
Typos such as “blu”, “plack” and “entrancer” are normalized in the extracted facts;
original filenames are preserved verbatim. Nothing in a filename is silently
promoted to an exhaustive annotation or a verified demographic inference.

## What is easy, medium or hard?

| Bucket | Meaning for this round | Examples from these clips |
|---|---|---|
| Easy | Visible broad object classes and clear broad colour attached to the correct object; mandatory cases select usable views | Person, car even when parked, dark/light car body, prominent dark/red clothing |
| Medium | Smaller/occluded objects, detailed regions or finer appearance; recorded for a later round | Dog, bag, scooter, tiny seated person, blue coat/pink trousers, specific garment or car subtype |
| Hard | Temporal interactions, fine text/material and detailed relations; recorded for later | Entering car, driving away, opening gate/door, moving luggage, right hand, exact plate text, leather |
| Not a detection target | Uncertain interpretation, demographic description or administrative provenance | “Supposedly grandma”, gender/age, filename camera label/date/time |

Dog detection is assigned medium for planning this dataset; it is not a universal
claim that a dog is harder than a person for every model. The dog is quite visible
in sampled WT3-005/006 frames. Action difficulty likewise depends on framing.
The categories are not promises about achieved accuracy. A foreground rider can
be scored simply as a person without recognizing a scooter or inferring age.

Broad colour first means **dark** (black/dark gray), **light** (white/light gray)
and red where specified. Exact shade, leather versus other fabric, garment type,
and separate lower-clothing colour are not interchangeable with that coarse task.
Brown jacket shade in WT3-004 and blue/pink garments in WT3-003 are medium for this
first pack because their region/visibility needs more care. An analyser may return
unknown instead of inventing colour, but unknown does not satisfy a required colour.

## Existing product capability versus new work

The current geometric analyser deliberately leaves semantic `object_class` unset;
it says a tall shape is not proof of a person
(`tools/labs/shape_observations.py:35`).
Existing object profiling measures one dominant passage colour, with its second
colour disabled (`tools/labs/object_profile.py:47`).
The existing palette sends pink/magenta/purple to `other`
(`tools/labs/labs_colour_histogram.py:122`).
The foreground model can absorb stationary objects
(`tools/labs/labs_foreground_mask.py:69`). These references describe the baseline
code; resolve them in your own checkout. They are code-read findings, not newly
measured accuracy results.

Consequently, person/car labels and object-linked clothing/body colour extraction
must be added as **new analysers alongside the existing set**. Reusing an existing
colour routine is permitted if its limitations are handled and current behaviour
is preserved. Renaming a motion-shape analyser does not satisfy Stage 3.

## Per-recording extraction

All entries below originate in the filenames. Bucket placement is the task author's
judgment; sampled review is recorded separately afterwards. “Easy” is evaluated
only on a visible occurrence, not through every occluded or absent frame.

### WT3-001 — Person through the gate

Camera label supplied: **Street Cam 10.16**. Neutral file: `clip-001.mp4`.

- **Easy / mandatory:** person; broad dark upper clothing.
- **Medium / later:** light lower clothing; jacket; T-shirt; person partly behind fence.
- **Hard / later:** leather material; walking behind fence; opens gate; walks past camera; ordered action sequence.
- **Preserved wording, not scored:** man (use person; gender is not a required label).

Sampled visual review: Sample at seek 14.812 s shows a near person with dark upper clothing and light trousers. Gate opening not verified by these stills.

### WT3-002 — Person near a parked dark car

Camera label supplied: **Street Cam 1.1**. Neutral file: `clip-002.mp4`.

- **Easy / mandatory:** person when visible; car including when stationary; broad dark vehicle body.
- **Medium / later:** small saloon/sedan subtype; person occluded by car.
- **Hard / later:** exact plate B595CO198; walks past and behind car (spatial/action relationship).
- **Preserved wording, not scored:** man (use person).

Sampled visual review: Samples show the dark car while stationary; person visible behind it at seek 14.546 s and farther away at 21.819 s. Plate not transcribed independently.

### WT3-003 — Foreground scooter rider and distant seated person

Camera label supplied: **Street Cam 10.2**. Neutral file: `clip-003.mp4`.

- **Easy / mandatory:** foreground rider as person, at its clearest visible part of the clip.
- **Medium / later:** small distant person; bench; scooter; blue upper clothing; pink lower clothing; coat.
- **Hard / later:** sitting on bench; riding scooter; ordered scene description.
- **Preserved wording, not scored:** supposedly grandma (explicitly uncertain; relationship not visually established); little girl (age/gender not required; detect person).

Sampled visual review: Seek 25.200 s shows a foreground person partly occluded by the hedge near the left edge. Distant figures are much smaller. The person target is provisional easy at best visibility; no claim that every frame is easy.

### WT3-004 — Person approaches dark car; car leaves

Camera label supplied: **Street Cam 1.1**. Neutral file: `clip-004.mp4`.

- **Easy / mandatory:** person; car including when stationary; broad dark vehicle body.
- **Medium / later:** brown jacket (shade/garment association); bag; small saloon/sedan subtype.
- **Hard / later:** exact plate B595CO198; bag in right hand; exits building; gets into car; car drives off; ordered interactions.
- **Preserved wording, not scored:** woman (use person).

Sampled visual review: Seek 14.826 s shows a person beside the entrance and the dark car. Later samples show the car in a different position and then absent; these stills do not independently establish the entire entry action.

### WT3-005 — Red clothing, dog and bag on path

Camera label supplied: **Street Cam 10.1**. Neutral file: `clip-005.mp4`.

- **Easy / mandatory:** person; broad red clothing.
- **Medium / later:** dog; white dog fur; bag; blue bag colour; jumpsuit garment type.
- **Hard / later:** walks with dog (relationship); bag in right hand.
- **Preserved wording, not scored:** woman (use person).

Sampled visual review: Seek 13.706 s shows a person in red and a light-coloured dog. Blue bag/right hand not independently confirmed by the contact sheet.

### WT3-006 — Red clothing and dog at gate

Camera label supplied: **Street Cam 10.16**. Neutral file: `clip-006.mp4`.

- **Easy / mandatory:** person; broad red clothing.
- **Medium / later:** dog; white dog fur; bag; blue bag colour; jumpsuit garment type.
- **Hard / later:** bag in right hand; walking with dog; opens gate; walks away with dog; ordered interactions.
- **Preserved wording, not scored:** woman (use person).

Sampled visual review: Seek 14.546 s shows a near person in red, a light-coloured dog and a blue accessory. Gate action/right-hand claim not established by these samples.

### WT3-007 — Two foreground passages in opposite directions

Camera label supplied: **Street Cam 10.2**. Neutral file: `clip-007.mp4`.

- **Easy / mandatory:** foreground person in dark clothing; broad dark upper clothing; foreground person in red clothing; broad red clothing.
- **Medium / later:** distant seated person; bench; dog; white dog fur; bag; blue bag colour; sporty clothing style; jumpsuit garment type.
- **Hard / later:** sitting on bench; opposite movement directions; person-dog association; ordered passages.
- **Preserved wording, not scored:** man/woman (use person; distinguish two visible subjects without demographic classification).

Sampled visual review: Seek 10.492 s shows a near person in dark clothing; 29.379 s shows a different near person in red partly behind the hedge. More than one person target is required, not one generic clip-level person flag.

### WT3-008 — Light car and person moving luggage at entrance

Camera label supplied: **Entrance Cam 10.2**. Neutral file: `clip-008.mp4`.

- **Easy / mandatory:** car; broad light vehicle body; person; broad dark upper clothing.
- **Medium / later:** mid-sized sedan subtype; black jacket; black trousers; bags/luggage; entrance door; porch.
- **Hard / later:** exact plate P910KE178; moves bags towards entrance door; opens door; ordered interactions.
- **Preserved wording, not scored:** woman (use person).

Sampled visual review: Seek 1.800 s shows a light car; 33.000 s shows a near person in dark clothing and luggage. Plate not transcribed independently.

## Review boundary

The dataset preparer viewed eight seek stills per clip, prepared with ffmpeg. The
contact sheets remain in the preparation archive; qualitative notes are in
dataset.json. They are review aids, not full video playback, detector output,
exact frame PTS, action timing or spatial ground truth. No negative labels, exact
object counts, bounding boxes or detection scores were inferred from the names.

`ffprobe` metadata and byte hashes are recorded in dataset.json. In particular,
nominal `r_frame_rate` and `avg_frame_rate` differ in these files, so use actual
decoded timestamps for evidence rather than assuming a fixed source frame rate.
The clips have not been transcoded, trimmed or rate-adjusted. Their date/time
suffixes are preserved as text; capture start and timezone remain unverified.

The complete test requirements are in [CASES.md](CASES.md), and the common
implementation assignment is [PROMPT.md](PROMPT.md).
