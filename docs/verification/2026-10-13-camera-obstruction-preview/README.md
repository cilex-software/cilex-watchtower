# Interactive obstruction warning preview

On this Ubuntu machine, run:

```sh
cd ~/projects/cilex-watchtower
./tools/preview-camera-obstruction.sh
```

The launcher requires the existing Watchtower binary and uses the canonical Qt runtime launcher (`tools/preview-camera-obstruction.sh:5`). It opens a separate session with fresh settings and a local HTTP fixture (`tools/tests/camera-obstruction/run-main-ui.py:123`). Existing operator sessions are not used.

The preview uses the shipping application shell (`tools/tests/camera-obstruction/preview-ui.qml:8`) and its actual alarm/review components (`qml/Main.qml:2525`, `qml/Main.qml:2073`). A permanent SIMULATION panel distinguishes it from normal operation (`tools/tests/camera-obstruction/preview-ui.qml:44`). Synthetic cameras have no video URLs; incident actions only mutate the fixture, with explicit simulation-only report status (`tools/tests/camera-obstruction/run-main-ui.py:61`, `:83`). The video areas are empty. This previews UI states, not detector performance or physical obstruction.

## Try the workflow

1. The central pulsing warning appears automatically. Click **Open camera live stream** to enter the simulated camera tab and see its review strip.
2. Try **False alarm — snooze 6 hours**, or use **Trigger alarm** and then **Confirm true incident**.
3. Choose **Repeated false alarms** to seed two earlier false incidents, open the alarm camera, then mark this third incident false. The **Disable this camera's alerts for 7 days** button appears and asks for confirmation.
4. **Restore visibility** shows recovery. **Reset** clears the simulated incidents. **Close preview** exits normally.

These scenario controls are implemented at `tools/tests/camera-obstruction/preview-ui.qml:16`; production review actions remain in `qml/CameraObstructionReview.qml:56`. The seeded history is a UI fixture, not elapsed real incidents.

## Measured checks and limits

[Checks/identities](checks.json), [interactive log](interactive-checks.log), [existing regression log](default-regression.log). The new workflow passed 27 checks; the unchanged automated workflow passed 16. Both application runs exited 0. Rendered offscreen with the existing Ubuntu binary; no rebuild was needed for these external tools. Native desktop manual operation and macOS operation were not measured.

Two initial temporary test wrappers failed to capture the window and timed out with exit 1: a zero-sized/hidden Loader was the cause. Their logs remain in the evidence directory. Appending test checks to the actual preview Window fixed the test harness; no product UI change was required.

Full commands, failed attempts, six screenshots and request logs:
`/media/cilex-vision/86761555761546F9/CilexLab/camera-obstruction-preview-20261013-v1/`.

The coordinator visually inspected the alert, ordinary review and seven-day-eligible screenshots. Detector accuracy, real video playback, report delivery and end-to-end alarm latency were not tested in this preview task. No live alarms were classified and no backend deployment was performed.
