# Obstruction alert and review design

The review strip and central alert now use Watchtower's graphite surfaces,
shared type and spacing, square buttons, and restrained severity accents
(`qml/CameraObstructionReview.qml:16`, `:22`, `:35`;
`qml/CameraObstructionAlert.qml:18`, `:27`, `:102`). Confirmed incidents retain
an amber warning state; recovered incidents use green
(`qml/CameraObstructionReview.qml:16`).

The scoped button uses Basic.Button keyboard/focus semantics and shared icons;
its natural width comes from unwrapped text metrics
(`qml/CameraObstructionButton.qml:7`, `:13`, `:24`, `:30`). Review actions stack
on narrow surfaces (`qml/CameraObstructionReview.qml:20`, `:38`, `:89`). The
seven-day confirmation shares the same treatment, starts with Cancel focused,
and rechecks permissions before enabling confirmation
(`qml/CameraObstructionReview.qml:163`, `:173`, `:212`).

## Measured verification

[Exact commands, source hashes and results](checks.json). Repository log copies
remove trailing whitespace; original bytes remain in the evidence directory.

- `bash tools/tests/camera-obstruction/run-ui.sh`: **9 passed, 0 failed**,
  including init/cleanup; wide/narrow containment, keyboard actions, disabled
  guards, confirmation focus, Escape and permission changes.
  [Log](component-tests.log).
- `python3 tools/tests/camera-obstruction/run-main-ui.py --binary ./run-watchtower.sh --output <evidence>/full-app-regression`:
  **16 checks, 0 failures**, actual process exit 0. [Log](main-regression.log).
- The saved `smoke-runner.py` runs the production application with the preview
  QML plus appended scenario/capture steps: **34 checks, 0 failures**, exit 0.
  English/Russian screenshots were rendered and visually inspected, including
  alert, review strip and seven-day confirmation. [Log](interactive-checks.log).
- `nice -n 10 cmake --build build --parallel 1`: Ubuntu build **exit 0**.
  [Final incremental build log](build.log). These verification runs preceded
  the publication hook's version bump.

Failed development iterations are preserved in the evidence directory:
initial QML syntax error, attempted assignment of read-only Flow.implicitWidth,
and a circular visibility dependency (3 passed / 6 failed). Corrected code
passed the final suite. A dialog sizing binding warning was also removed.
The full-application fixture logged a BrokenPipeError after a client request
was cancelled; its application checks and actual exit code passed. The initial
full build retained an unrelated FlightRecorder.cpp:509 write-return warning.

All application scenarios used **offscreen rendering and an isolated loopback
fixture**. Native desktop manual use, macOS rendering, actual camera pixels,
physical-cover detection and real report delivery were not measured. This task
changed client presentation; no backend deployment or real alarm action occurred.

## Preview and evidence

Close any older preview, then run from the rebuilt Ubuntu checkout:

```sh
cd ~/projects/cilex-watchtower
./tools/preview-camera-obstruction.sh
```

The simulation launcher is `tools/preview-camera-obstruction.sh:5`; the permanent
simulation controls are `tools/tests/camera-obstruction/preview-ui.qml:44`.

Full command receipts, screenshots, failed iterations and request logs:
`/media/cilex-vision/86761555761546F9/CilexLab/camera-obstruction-design-20261013-v1/`.
Primary visual evidence: `01-interactive-alert.png`,
`02-interactive-review-strip.png`, `07-disable-confirmation.png`,
`09-russian-review-strip.png`.
