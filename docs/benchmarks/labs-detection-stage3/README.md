# Stage 3 — real-recording semantic analyser assignment

**Prepared; implementation and acceptance remain pending.**
No Stage 3 detector accuracy is claimed.

The operator supplied eight manually described Watchtower exports and requested
metadata classification, then new analysers for the easiest useful metadata.
The new analysers must sit alongside the current set inside Cilex Watchtower Labs.
The finished implementation must include reproducible evidence for operator review.

## Read and launch

- [Classification and per-clip metadata](CLASSIFICATION.md): easy, medium, hard,
  uncertain descriptions and provenance; current analyser capability versus new work.
- [Cases](CASES.md): eight recording cases, 12 specified person/car targets and
  nine attached broad-colour requirements; product controls and later annotation plan.
- [Implementation assignment](PROMPT.md): current-checkout scope,
  in-app acceptance and submission instructions.
- [Protocol](PROTOCOL.md): evidence rules, current limitations and future unseen clips.
- [Common result format](RESULT_FORMAT.md) and [dataset](dataset.json).
- [Preparation evidence](PREPARATION.md): what was actually checked now.

Use this in the existing session, from its current working checkout:

```text
Implement the Stage 3 assignment in:
/home/cilex-vision/projects/cilex-watchtower/docs/benchmarks/labs-detection-stage3/PROMPT.md

Read the task files it names, record your current checkout and branch, and
complete the new analysers, tests and evidence workflow inside Cilex Watchtower.
Preserve the current analysers and earlier submissions. Use my selected model and
mode. Work through failures until the assignment is complete, then write the
Stage 3 submission report with exact results and remaining limitations.
```

This launch text does not authorize commit/push. The user can add explicit
current-branch commit/push instructions if desired. Preparation did not include
publication or launching an implementation session.

## Recordings and labels

The originals remain in `/home/cilex-vision/Videos/Watchtower/`.
The prepared byte-identical copies are in
`/home/cilex-vision/Videos/Watchtower-Stage3/clip-001.mp4` through `clip-008.mp4`.
That directory's `inputs.json` contains no descriptions or expected target labels.
The public dataset.json preserves original annotations for specification/review;
it must not be consumed by the runtime detector. No footage is placed in the repo.

The neutral clips are public development recordings. Their results are not unseen
accuracy. Later new videos will be analysed by the frozen implementation before
tuning. Filename omissions are not negative labels, and person/car counts in the
target list are not exhaustive scene counts.

## Completion record

Write STAGE3_SUBMISSION.md as required by PROMPT.md and preserve the submitted
tree/revision, configuration, weights and dependencies. Record measured behaviour,
failures and remaining limits. Later independent evaluation will use the saved
implementation and the annotation rules in CASES.md; development checks alone
do not establish unseen-video accuracy.
