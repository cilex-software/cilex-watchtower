# Live camera tabs showing another camera's stream — identity fix

The wrong-camera cache reuse was reproduced with decoded pixels, corrected,
and verified in the rebuilt application. This work does not change camera
configuration or recordings. The operator subsequently authorized publication
of this fix and its tests; unrelated development changes are excluded.

The submitted reproduction was: wall → camera A tab → wall → camera B tab →
revisit A → open C → revisit earlier tabs and wall. Labels stayed correct while
video identities changed. The tests below use local red/green/blue RTSP streams,
so pixel identity is independently distinguishable without accessing real cameras.

## Cause and correction

In the preserved original source, `setUrl()` updated requested `m_url` before
`rebuild()` tore down the previous decoder ([before/RtspVideoSource.cpp:381](before/RtspVideoSource.cpp)).
Teardown parked that previous decoder under the new URL at line 603; adoption
looked up that same key at line 815. The wrong decoder could therefore be reused
both by the detail view and subsequently by a wall tile. The failing run below
establishes the resulting wrong-pixel behaviour.

The fix records the pipeline's actual URL and mode independently of requested
state in [RtspVideoSource.h:128](../../../src/models/RtspVideoSource.h#L128).
Teardown uses that actual identity for cache eligibility and its key
([RtspVideoSource.cpp:601](../../../src/models/RtspVideoSource.cpp#L601)).
Creation and adoption bind the identity at lines 757 and 840 respectively.
The current appsink is revoked before teardown and checked before publishing
frames, guarding against late samples from a previous source
([RtspVideoSource.cpp:569](../../../src/models/RtspVideoSource.cpp#L569),
[RtspVideoSource.cpp:964](../../../src/models/RtspVideoSource.cpp#L964)).

## Measured verification

| Check | Before | After |
|---|---|---|
| Identical decoded-pixel regression, 13 checks | 9 passed / 4 failed; exit 1 | 13 passed / 0 failed; exit 0 |
| Product wall/tab/detail sequence | not measured | 10 navigation legs; 45 assertions passed; app exit 0 |
| Product rendered video identities | not measured | 18/18 captured surfaces matched expected RGB; verifier exit 0 |
| Primary application build | not measured | exit 0 |

- Paired pixel evidence: [before-rapid-results.json](before-rapid-results.json),
  [after-results.json](after-results.json). Exact commands, environment overrides,
  source hashes and exits: [before-rapid-run-command.json](before-rapid-run-command.json),
  [after-run-command.json](after-run-command.json). The original 12-check
  `before-results.json` is also retained; use the 13-check pair for comparison.
- Product evidence: [execution.json](product/execution.json),
  [pixel-verification-recheck.json](product/pixel-verification-recheck.json),
  [raw application log](product/app.log) and [reproduction instructions](product/README.md).
  The roster and unauthenticated-shell visibility are fixtures; navigation,
  wall tiles, detail component, video sources and rendering are shipping code.
- Final build command: `nice -n 10 taskset -c 0,2 cmake --build build --parallel 2`.
  Output: [build-final.log](build-final.log); actual exit: [build-final.exit](build-final.exit).
- Root reviewer additionally opened the saved green-after-blue, red-after-blue
  and final-wall-blue images with the image-rendering tool and observed the
  expected colours. These are surface captures, not full-window screenshots.
- Local fixture cleanup: [fixture-cleanup.json](fixture-cleanup.json).

The originally verified Linux application SHA-256 is
`2460e821845340894dbfb8a348089c96f13f5c467b2f10884dd49e1f10ef407d`.
This binary was built before publication from the working checkout, which also
contained unrelated uncommitted Labs work. It is not the published commit's
binary. The two changed production source files match the recorded after-test
hashes; the unrelated Labs changes are not part of this fix.
The product run used the primary Qt 6.12 launcher on an X display; the standalone
pixel comparison used Qt 6.8.3. The source and harness identities are in the
command records. Reproduction sources are under
[tools/tests/live-stream-identity](../../../tools/tests/live-stream-identity/README.md)
and [live-stream-identity.qml](../../../tools/tests/live-stream-identity.qml).

## Limits and handoff

The operator's actual live cameras have not been retested. The pixel checks
establish the synthetic-stream navigation scenario and sampled transitions,
not every possible callback schedule or a long-duration fleet soak.
The product log retains a GStreamer plugin-scanner `CRITICAL` format assertion
and a QML `enabled` property override warning; the test did not resolve these
startup diagnostics and does not claim a warning-free launch.

Build the updated source in the target checkout. Launch with `./run.sh` on Linux
or `./run-macos.sh` on macOS (`run-macos.sh:7` expects `build-macos/watchtower.app`).
A macOS build was not performed during this Linux verification. An already-running instance retains its old executable and
in-memory cache until restarted. Camera-topology work remains paused pending
the operator's confirmation of the correct live views.
