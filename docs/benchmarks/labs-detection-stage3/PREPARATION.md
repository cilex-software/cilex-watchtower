# Preparation evidence — 2026-10-05

This records preparation of the common assignment, not a completed implementation
or detector evaluation. No Stage 3 analyser was run or graded.

## Inputs inspected

`ls -la /home/cilex-vision/Videos/Watchtower` found the eight supplied descriptive
filenames alongside other exports. The other files were excluded. Exact names,
byte counts and SHA-256 digests are in [dataset.json](dataset.json).

For each selected original, preparation ran:

```sh
ffprobe -v error -show_entries 'format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,start_time,duration,nb_frames' -of json '<source file>'
```

Observed container metadata:

| Clip | Duration (seconds) | Dimensions | Container-reported frames |
|---|---:|---|---:|
| WT3-001 | 52.90 | 2560 × 1440 | 796 |
| WT3-002 | 51.95 | 2560 × 1440 | 781 |
| WT3-003 | 60.00 | 2560 × 1440 | 902 |
| WT3-004 | 52.95 | 2560 × 1440 | 797 |
| WT3-005 | 48.95 | 2560 × 1440 | 736 |
| WT3-006 | 51.95 | 2560 × 1440 | 782 |
| WT3-007 | 69.95 | 2560 × 1440 | 1052 |
| WT3-008 | 60.00 | 2560 × 1440 | 902 |

These are ffprobe/container measurements, not a verified full-decode frame census.
The container reports `r_frame_rate=20/1`; average rates differ, with exact rational
values retained in dataset.json. No source rate was changed. Capture wall-clock
start/timezone and filename plate transcriptions were not independently verified.

The dataset preparer extracted one still at each fraction
`0.03, 0.15, 0.28, 0.42, 0.55, 0.68, 0.81, 0.94` of container duration using:

```sh
ffmpeg -v error -ss '<duration × fraction>' -i '<source file>' -frames:v 1 -vf scale=640:-1 -y '<local review jpg>'
```

All eight contact sheets were viewed and retained in the preparer's local evidence
archive. Each clip's sample_review records qualitative observations.
The still timestamps are seek requests, not claimed exact frame PTS. These samples
do not verify full action sequences, exhaustive negatives or bounding-box truth.

## Neutral preparation and validation

Executed `python3 tools/benchmarks/prepare_stage3_clips.py`, exit 0. It prepared
eight byte-identical copies plus inputs.json in
`/home/cilex-vision/Videos/Watchtower-Stage3/`. No originals were renamed or rewritten.
The executed preparation helper was `tools/benchmarks/prepare_stage3_clips.py`;
this is provenance of the prepared inputs, not an additional implementation input.

A subsequent Python consistency check read dataset.json and inputs.json, recomputed
SHA-256 over every original and neutral copy, checked all pairs against the saved
digest, checked that input entries have no descriptive filenames/targets, verified
that all eight review sheets exist, and validated each manifest clip against the
common helper using an explicitly empty **schema-check fixture**. It exited 0:

```text
PASS: eight original/copy SHA-256 pairs, neutral input metadata, review sheet availability, target counts, manifest/helper compatibility.
No detector was run by these preparation checks.
```

The manifest contains eight cases, 12 required person/car subjects and nine colour
requirements (counts checked from the JSON). These are specification counts, not
detected subjects or a claim about the exact number of objects in the videos.

## Common helper checks

Executed `python3 tools/tests/labs-stage3-evidence.py`: **13 tests, OK**, exit 0.
This is a development check of evidence validation, not footage recognition and
not proof of an implemented Labs integration. The implementation must expose the helper
through the actual Watchtower workflow under PROMPT.md.

Coverage includes malformed/nonfinite values, input identity, duplicate observations,
timestamp consistency, cross-object/cross-time colour borrowing, contradictory
colour regions, unknowns, stale output/review checksums, reviewer decisions,
distinct-subject reuse, incomplete runs and no-candidate results.

Executed `python3 -m py_compile tools/labs/stage3_evidence.py tools/benchmarks/prepare_stage3_clips.py`:
exit 0. `git diff --check` passed at final package validation.

An intermediate recursive-input unit fixture used insufficient nesting for this
Python JSON encoder and failed. The fixture depth was corrected; the final suite
exercises actual recursive/deep-input rejection and passes. This was a helper-test
fixture issue, not a measured detector failure or a removed requirement.

Public package hashes are saved in package-manifest.json. Preparation has not
changed the implementation checkout, launched an implementation session, committed/pushed, enabled
live analysers or written to a backend. Full detector tests, independent frame
annotation and independent detector evaluation remain future work.
