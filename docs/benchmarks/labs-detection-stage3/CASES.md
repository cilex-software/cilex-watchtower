# Stage 3 test series

These are public development requirements, not detector results. Source annotations
and hashes are in [dataset.json](dataset.json); the classification rationale is in
[CLASSIFICATION.md](CLASSIFICATION.md). Only the eight explicitly named clips are
included. The others in the source directory are excluded.

## Mandatory recording cases

“Dark” accepts `black` or `dark_gray`; “light” accepts `white` or `light_gray`.
These are deliberately broad acceptance groups, not an assertion of exact paint
colour. Red requires `red`. Every colour belongs to the same observed object as
its class and uses the region specified in the manifest.

| Case / neutral file | Required object(s) | Required colour(s) | Not required in this stage |
|---|---|---|---|
| WT3-001 / clip-001.mp4 | Near person approaching camera | Dark upper clothing | Leather/T-shirt type, light trousers, fence/gate action |
| WT3-002 / clip-002.mp4 | Passing person; prominent stationary car | Dark car body | Plate, sedan size, behind-car relation |
| WT3-003 / clip-003.mp4 | Foreground scooter rider classified as person, at best visibility | None | Tiny distant seated person, child/grandma, blue/pink garments, riding action |
| WT3-004 / clip-004.mp4 | Person leaving entrance; prominent car | Dark car body | Brown jacket specificity, bag/right hand, getting into car, car departure |
| WT3-005 / clip-005.mp4 | Person on path | Red clothing | Dog, blue bag, right hand, walking-dog relation |
| WT3-006 / clip-006.mp4 | Person walking towards gate | Red clothing | Dog, bag, opening gate |
| WT3-007 / clip-007.mp4 | Two distinct foreground subjects, one in dark clothing and one in red | Dark upper clothing on the first; red clothing on the second | Bench sitter, dog/bag, opposite-direction action |
| WT3-008 / clip-008.mp4 | Prominent light car near start; person handling luggage later | Light car body; dark upper clothing on person | Exact plate, sedan size, luggage manipulation, door action |

The manifest contains 12 required object targets and 9 attached colour requirements.
No “at least one person anywhere” shortcut for WT3-007: each described foreground
subject needs its own evidence. Likewise, a distant bench sitter cannot substitute
for WT3-003's foreground rider. The supplied subjects are **not exhaustive counts**
of all people/cars in those clips. Other genuine detections are not automatically
false positives. No target is required to remain detectable through occlusion or
after it has left the frame.

For each case, Labs runs the analyser on the video and presents timestamped boxes
and colour evidence. The common helper finds schema-valid candidate observations.
The reviewer then checks whether the proposed box actually contains the
specified object and whether its colour is correctly associated. Until that review,
the result is REVIEW REQUIRED; a matching string does not imply detection accuracy.
Failure to produce evidence for a required target is reported explicitly. A reviewer
may mark a genuinely unjudgeable target UNREVIEWABLE with a reason, never PASS.

## Product and integrity cases

These controls test the implementation, not visual accuracy. They must be runnable
from Watchtower Labs and call the product's actual analyser path.

| ID | Procedure | Required outcome |
|---|---|---|
| S3-C01 | Load each supplied neutral file and run the new analysers | Correct input hash; actual decoded frames; valid result envelope and evidence |
| S3-C02 | Analyse the same bytes under a different neutral filename | Same detections for deterministic settings; exclude path/run-ID/timing metadata from equality. Declare and bound any genuine model nondeterminism |
| S3-C03 | Review a stationary-car interval in WT3-002 or WT3-004 | Semantic car evidence while stationary; motion alone is not a sufficient gate |
| S3-C04 | Review WT3-007's two people | Separate object evidence; no colour borrowed from the other person or background |
| S3-C05 | Run clip A, select clip B before analysing, then run B | A findings are cleared or visibly bound to A; never silently shown as B |
| S3-C06 | Save A, select B, reopen A evidence | Recording, time origin, hash, overlays and findings all refer to A |
| S3-C07 | Cancel mid-run, then rerun; close app mid-run | Honest cancelled/partial state, no stale accumulation, no orphan child processes |
| S3-C08 | Select missing/corrupt input; make model unavailable | Visible specific failure/prerequisite state; no completed-success or stale findings |
| S3-C09 | Inject a deliberate invalid result in labelled verification mode | Common validation and Labs show failure; never mixed with real clip findings |
| S3-C10 | Seek from finding to video frame | Actual observed box is on its source frame; timestamps come from decoded PTS |
| S3-C11 | Run existing analyser and original tracking regressions | Preserve baseline behaviour; disclose existing failures separately |
| S3-C12 | Select a future user-supplied recording through the same UI | No filename-specific setup/code change; frozen model/config run first |

Renaming alone cannot prove absence of memorisation. Independent source review and
later unseen recordings are also required. IDs/hashes are provenance, not inference
features. No negative video is fabricated to score detector accuracy. Invalid-input
and deliberately invalid-result controls belong only to plumbing verification.

## Later accuracy evaluation

Filename annotations do not support precision, recall, F1, exact object counts or
action timing. For independent evaluation, use the following
**proposed, predeclared annotation plan** before inspecting detector outputs:

1. For every supplied clip, select its first decoded frame at or after each whole
   second relative to the first decoded frame. Deduplicate frame indices. This
   uniform schedule is an annotation specification, not a measured frame count.
2. Independently review those frames and annotate every judgeable person/car,
   bounding boxes, object-linked broad colours and explicit ignore regions/reasons.
   Distant/occluded ambiguity is recorded, not silently counted as absence.
3. Freeze that annotation file/hash before matching submitted predictions. Match
   same-class boxes one-to-one on the exact scored frame, using IoU >= 0.5 as this
   benchmark's proposed localization criterion. Publish annotation corrections and
   rerun affected evaluations consistently if a defect is discovered.
4. Measure person/car precision, recall and F1 on exhaustively annotated frames;
   colour correctness/unknown coverage on matched eligible objects; missed targets,
   false positives and localization failures separately. Do not claim calibration
   from confidence values alone. Results on skipped/unannotated frames are not zero.
5. Evaluate future clips against the frozen implementation/configuration before tuning;
   keep their results separate from these public development clips. Use the
   same bytes and scoring rules for repeat runs. A later repair is a separate revision.

Require an evaluation mode that emits observations on those requested decoded
frames, using the **same analyser/model/configuration** as the interactive path.
Normal user analysis may sample adaptively if disclosed; missing requested frames
must be reported, not silently removed from the scoring denominator.

The annotation file and detector results do not exist yet. This package prepares
the task; it does not award scores or certify the new analysers.
