# Recording idle display correction — 2026-11-16

The recording-warning recovery remains `REC-ARCHIVE-20261028`. This is a client
display repair; it does not change recorder capture, archive publication,
health deadlines, retention, camera settings or server admission.

## Cause and change

Published main was measured with `git ls-remote` as
`21b4c8a4a08546d75c82e616e644a13c6ba26d5d`, version 1.1.803. Its badge,
normalizer, Health screen, CameraModel and AuthController were byte-identical
to the older locally tracked 1.1.799 files. The installed Mac binary was not
attested by this source check. Unrelated work in the primary checkout was
preserved; the repair uses an isolated shared clone based on that published SHA.

`RecordingStatusBadge.qml:17` identifies current normalized v1 observations.
The label gives explicit fresh idle precedence over legacy
Recording/Stalled/Disabled values. A fresh unknown cannot become legacy ARMED
or OFF. Actual stopped/delayed states keep higher priority, and an idle
camera's explicit motion-not-ready qualifier keeps its fault color. Motion-event
age, silence information and density behavior share the existing ARMED label
path. An actual fresh archive delay still takes precedence; the legacy
VMD/catalogue heuristic is not applied over current v1 health. Legacy-only
observations retain their existing conservative fallback.

`HealthScreen.qml:56` refreshes the selected map through
`cameraByBackendId(sel.camId)`, including health updates that do not change the
table signature. Missing identities and a removed model clear selection; names
never select a replacement. A camera filtered out of the table can remain
selected only while that exact canonical identity still exists.

## Actual verification

The new `tools/tests/recording-idle-display/` fixture loads the production QML
components, production enum and production health normalizer. The roster and
badge-timer settings are synthetic; no Watchtower main, operator settings or
production API/camera connection is used. See its README for the CMake/CTest
entry points. It is not a native station or real-video workload.

On the recording host, normal admission and a finite owned USER unit enforced
384 MiB, zero swap, 25% CPU and 64 tasks. Qt 6.8.3 configure and compilation
passed. The same harness against preserved original QML produced **7 passes,
15 failures, zero skips**; against the repair it produced **22 passes, zero
failures/skips**. The fixed output has no QML warnings. Public CTest entry-point
verification passed **1/1** before the age/color refinement; the final 22-case
run directly invokes the same fixture executable. The final Health PNG was opened and
shows ARMED in both table and selection, with consistent idle details.

Private evidence on the recording host:

- `~/.local/state/cilex-vision/watchtower-idle-display-window-fixed-prepared-20261116-330f14a5d7e14ea19e5880d3b1298372/INDEPENDENT-CLOSURE.json`:
  13 evidence files and 97 source pins, equal before/after/current source,
  normal/kernel/OOM brackets, and independently collected test units.
- The first run compiled and reproduced the baseline defects, then its outer
  log reader failed `UnicodeDecodeError` on Qt's text output before the fixed
  run. Its original evidence remains in
  `watchtower-idle-display-qualification-20261116-8eebdd8c4ab34ca1966021ba8c491043`.
- The second run refused at initial normal admission (`RuntimeError`), before
  any Qt command; the exact guard reason was not saved. Root free space was
  observed close to its unchanged floor. That result is preserved in
  `watchtower-idle-display-qualification-r2-20261116-c70c0e479e944e509693930bdb001aaf`.
  No guard was waived. The final run admitted and closed normally.
- The first normal commit hook refused because the sparse checkout omitted its
  unchanged B1 replay JSON. The exact base-revision fixture was materialized;
  hook tests are not disabled. The failed hook output remains in the private
  `watchtower-idle-display-commit-prepared-20261116-d4b648f95f594a7bb57ab1039ae441ac` directory.
- A second hook attempt reported two unchanged Labs import/thread-pin probe
  failures. Both direct import-only controls subsequently passed, so the cause
  was not established. Those outputs remain in
  `watchtower-idle-display-commit-r2-prepared-20261116-60c843e2d1b64b40a681048eae77b2ae`.
  No worker source or test was changed to accept them.
- The third hook passed those import probes but refused its existing real-clip
  frame-difference case: FFmpeg reported `ff_frame_thread_encoder_init failed`.
  Its output remains in
  `watchtower-idle-display-commit-r3-prepared-20261116-e46e63a140504a94afc318ea956e2885`.
  A subsequent hook run restricts its own CPU affinity to one allowed core and
  sets `OPENBLAS_NUM_THREADS=1`, retaining the same resource caps and every hook.
  The failure alone does not establish its underlying resource cause.
- The offscreen fixture needed explicit dimensions for its own test window.
  One setup attempt incorrectly waited for an empty Item to render and refused
  before the fixed cases. Its evidence remains in
  `watchtower-idle-display-window-final-prepared-20261116-90672d1c741443fb8488a801973d2c84`.
  The final fixture checks its window dimensions and renders the full screen.

## Publication and native rollout

Engineering is verified as above. Integration/push and native deployment are
owned by the coordinating parent; they are not claimed complete here. The
normal version hook must run. No complete Watchtower app or SDK was built on
the recording host; the small fixture reuses its installed Qt kit.

For the Mac, use the published committed-source builder described in
`packaging/BUILDING.md` (`packaging/macos/build-installer.sh` for the normal DMG,
or the existing thin-build workflow). Verify the actual source commit and output
hash, preserve installer/signature/video gates, and follow the existing managed
handoff. The published packaging notes still record native DMG/export failures;
this display fixture does not waive or resolve them. Do not start a second
Watchtower instance beside the operator's merely to test QML/settings.

For the existing Booth, use its Windows native build/update path
`packaging/windows/deploy/build-and-update.ps1`, with the published repair SHA
as `SourceRef` and **Targets Booth only**. Build-only qualification precedes the
normal managed update; preserve its watchdog, backup, startup and rollback
checks. Do not update Office by accepting the controller's default two targets.
The ordinary operator flow remains the existing GUI update rather than a new
manual configuration procedure.

After each native update, verify the running binary/version/source and live
wall health; select a motion camera, keep it selected across a refresh, and
check that idle text, badge and counters agree. Genuine unknown/stopped/archive
fault cases must remain visible. Recheck recent/event playback and the requested
native export separately. No Mac/Booth installation, native screenshot, export
or representative production acceptance was performed by this subtask.
