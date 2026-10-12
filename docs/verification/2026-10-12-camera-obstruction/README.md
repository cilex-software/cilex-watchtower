# Camera obstruction alert — Ubuntu implementation handoff

Cilex Vision's bounded pilot is active for **4.1.6 Холл / 192.168.1.109 only**. It compares fresh substream frames with a reviewed clear reference and protected historical clear images. Exact deployment/readiness, image hashes, rollback and detector evidence are in [the backend runbook](/home/cilex-vision/projects/cilex-vision/docs/verification/2026-10-12-camera-visibility/DEPLOYMENT.md). This is a single-camera pilot, not an all-camera or long-term accuracy certification.

## User workflow

A central slowly pulsing alert names the camera and opens its existing live tab (`qml/CameraObstructionAlert.qml:18`, `:76`; `qml/Main.qml:2525`). Opening an alert does not classify it. The live-view strip offers:

- False alarm: classify and suppress alerts for six hours; queue a report with the triggering thirty-second evidence proxy.
- Confirm true incident: acknowledge attention while leaving the obstruction active until measured recovery.
- After three distinct consecutive false incidents: an explicit seven-day suppression button with confirmation.

Controls: `qml/CameraObstructionReview.qml:56`; backend state transition: sibling `services/query-api/camera_visibility.py:177`. Recording and continuous monitoring are unaffected by suppression. Server camera scope and operator/admin capability govern actions and intrusive alerts (`src/models/CameraObstructionController.cpp:90`, `:201`; sibling `routers/camera_visibility.py:22`). Read-only viewers keep incident information without the intrusive popup. Polling uses the existing authenticated client and resets on account/server change (`CameraObstructionController.cpp:35`).

## Measured verification

Evidence root: `/media/cilex-vision/86761555761546F9/CilexLab/`.

- `camera-obstruction-ui-verification-20261012-v1/main-ui.log`, `run.json`, `requests.json`: sixteen full-application fixture checks passed, exercising actual auth, roster, central alert, A/B camera navigation, review actions and logout. Cameras and HTTP responses were synthetic; real video pixels were not verified by that test.
- Same directory: QML tests had five passes (three test scenarios plus setup/teardown), and qmllint exited zero. Source/binary hashes and exact argv are in `checks-and-identities.json`.
- The final role review found an actual defect: viewers could receive the central popup while review actions were disabled. `camera-obstruction-ui-permissions-20261012/before-1.log` preserves the new failing regression. Gating attention on server `can_manage` fixed it without hiding read-only review.
- Final role/controller run: four QtTest passes, zero failures (two substantive HTTP scenarios plus setup/teardown), in `camera-obstruction-ui-permissions-20261012/controller-tests.log`. Capability grant/revoke, viewer no-POST, and retained camera review were checked.
- Final primary build: `nice -n 10 cmake --build build --parallel 2`, exit zero, `camera-obstruction-ui-permissions-20261012/primary-build.log` and `after-commands.json`. Built binary SHA-256 `603305e7ada86534678cbf37828da88bfab8fcf348ec802b59a9c69c9b79f01e`.
- Backend final feature suites: fifty passed; real isolated report API/PostgreSQL/file ingestion accepted a thirty-second MP4 and idempotent retry. These are distinct from a real operator incident. Exact evidence in the backend runbook.

Screenshots of the earlier full-application fixture are in `camera-obstruction-ui-verification-20261012-v1/`; the alert and review layout were visually inspected. The final permission correction changes eligibility rather than layout. It was tested separately; the earlier full-application run is not relabelled as a new run of the final binary.

## Load the built client

The inspected operator process (PID3977323, started18:43:13MSK) predates the new build. Close its window normally, then:

```sh
cd ~/projects/cilex-watchtower && ./run.sh
```

No SIGTERM was sent: the current application routes it through the fatal signal handler (`src/main.cpp:164`). Normal close uses `win.close()` (`qml/TitleBar.qml:481`). Restoration of this particular open session's tabs was not tested. At the implementation checkpoint, the binary was local build1.1.773 with dirty working-tree changes; no commit/push or Mac build had been made at that implementation checkpoint. The operator subsequently authorised publication.

The continuous server monitor does not need Watchtower open. The central visual alert does need an updated, running, authenticated Watchtower client. Mobile push remains explicitly deferred. A real physical-cover-to-visible-alert drill and long-duration nuisance-alarm measurement remain outstanding; the supplied printed-paper clip triggered the detector at6.04seconds in local replay, not measured end-to-end UI latency.

Preserve all unrelated Labs/benchmark work. The original recognition expansion/topology tasks remain parked while this urgent feature is commissioned.
