# Recording health: capture and archive are separate

Client engineering is verified on Linux Qt 6.8.3 using isolated loopback
fixtures. Publication uses the repository's normal hooks and non-force main
integration; its exact commit/remote receipt is recorded separately in
`watchtower/publication.json` under the evidence directory below. Native station
rollout and production acceptance remain separate gates, not established by
these fixtures.

## Change and compatibility

The additive `/streams` `recording_health` v1 observation is normalized with
mandatory timezone-aware `observed_at` and `valid_until`; expired, malformed,
materially future (beyond the explicit 30-second clock-skew allowance) or
unsupported observations cannot certify current capture. Required
main/sub lanes are aggregated conservatively, including the largest observed
required-lane archive delay. Source: `src/models/RecordingHealth.h:21`,
`src/models/RecordingHealth.h:57`.

The client expires observations locally even when `/streams` refresh fails.
It preserves the live roster and existing stream identities; health-only changes
use their own revision signal. Source:
`src/models/CameraModel.cpp:122`,
`src/models/CameraModel.cpp:750`.

Legacy `stalled`, `not_recording` and catalogue-gap inputs remain visible as
archive warnings with unverified capture. They are not counted as confirmed
capture stops. Fresh v1 `stopped` is the confirmed-stop counter input. Source:
`src/models/CameraModel.cpp:896`,
`src/models/CameraModel.cpp:1123`.

All fleet counts use loaded, authorized camera identities, not stream totals.
Connectivity, capture and archive dimensions can overlap. The status-unknown
header/sidebar count is the union of capture-unknown and archive-unknown
cameras, counted once per camera. Health retains the two individual unknown
counts and their filters. Source:
`src/models/CameraModel.cpp:939`,
`src/models/CameraModel.cpp:1145`,
`qml/TopBar.qml:213`.

Live tiles, focused-camera view, Health and Groups distinguish capture stops,
archive delays and unknown observations in English and Russian. A catalogue
start/end is not displayed as an invented incident onset. The Health explanation
no longer asserts that a stale catalogue proves capture stopped or that an
automatic restart occurred. Source:
`qml/RecordingStatusBadge.qml:28`,
`qml/RecordingStatusBadge.qml:54`,
`qml/HealthScreen.qml:127`,
`qml/GroupsStatus.js:75`,
`qml/SingleCameraDetail.qml:502`.

`last_available_end` is a catalogue observation supplied by the API. Recorder
progress and catalogue freshness do not prove durable, complete, readable media;
that requires the backend/playback operational checks. The client states this
limit explicitly (`qml/HealthScreen.qml:139`).

## Measured verification

Evidence directory:
`/media/cilex-vision/86761555761546F9/CilexLab/archive-lag-remediation-20261028/watchtower`

Exact argv, selected environment, actual exits and output paths are in
`commands.jsonl`. `commands.jsonl.timestamp-corrected` retains the journal with
an explicit correction for two early wrapper timestamps that were recorded
*after* command completion; those are not start times. Original files remain.

- Before: the preserved pre-change Qt 6.8 binary
  SHA-256 `6be5562bbf2a8690532e76eeb2f42f5bc4c2df1ff4186964389e328a79411fcb`
  actually counted one legacy catalogue-only stalled camera as one confirmed
  NOT REC. The regression exited 1. Evidence: `before-ui-v2/ui.log` and
  `before-ui-v2/run.json`. This was an existing binary, not a newly built
  origin/main baseline.
- After: the same legacy-only fixture reports zero confirmed capture stops,
  one archive warning and one unverified capture. Evidence:
  `publication-ui-en/ui.log` initial checks.
- Pure QtCore contract: **18 checks, 0 failures**, exit 0 (`final-contract.log`).
- Shared Groups classifier: **24 checks passed**, exit 0
  (`final-groups.log`). The previous motion/catalogue mismatch assertion is
  retained as an archive fault, rather than a claimed capture stop.
- Shipping shell/model/widget integration: **31 checks / 0 failures EN**,
  **31 checks / 0 failures RU**, both exit 0.
  Evidence: `publication-ui-en/` and `publication-ui-ru/`.
- Existing obstruction UI regression: **16 checks / 0 failures**,
  exit 0 (`final-obstruction/`). All incident actions used a loopback fixture.
- The recording vocabulary guard and `git diff --check` exited 0
  (`vocab-acceptance.log`, `final-diff-check.log`).
- Linux Qt 6.8.3 Release build exited 0 (`publication-build.log`). Candidate binary
  SHA-256: `45acaed923eb99be41ea4625119d28e3ba6f6f9702885c31dae6e52dadfe32b8`. It is a pre-publication build from the
  isolated worktree, not an installed station build.

The UI fixture covers an archive-only unknown while capture progresses,
required-main failure hidden by a healthy sub/optimistic aggregate, source
expiry during failed refresh, deliberate recording disablement, motion idle,
offline reachability, counters/filters and Groups agreement. It opens and
captures shipping Live, Health and Groups screens. The synthetic fixture does
not connect to cameras or prove actual video recording/playback.

1280×960 RU offscreen Live/Health/Groups images were opened with the
image-rendering tool. EN images were also generated. This is offscreen visual
verification, not native Windows admission or real-camera pixel verification.

The initial baseline harness incorrectly printed `shipping_widgets=true` even
though that old binary stopped at model checks. The original `before-ui/`
files are retained. Corrected `before-ui-v2/` explicitly records
`shipping_widgets_exercised=false`; the measured NOT REC=1 failure is unchanged.

## Remaining deployment gates

No live Watchtower process, Warden, camera configuration or guardstation
installation was changed by this subtask. Native access preflight results are
saved in `native-access-preflight.json`; it did not authenticate or modify a
station. The intended station must run its existing verified Windows build and
update workflow, including private admission/preflight and rollback. Do not
substitute Linux offscreen success for that result.

Backend publication/enablement, exact deployed source/version, actual media
retrieval/playback, coverage gaps and representative production observation
belong to the parent end-to-end task. The client implementation alone cannot
establish that archive lag has recovered.
