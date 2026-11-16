# Health column filter tests

This suite renders the shipping HealthScreen and shell QML with 133 synthetic
cameras and inert services. It never connects to Vision, uses saved credentials,
starts the installed application or changes a service. Qt Quick Test drives the
native controls and captures the window, including popup overlays.

Install Qt 6 with Qt Quick Test and Linguist. On this Mac, its commands are in
`/opt/homebrew/bin`. Run from the repository root. Each output directory must be
new; it contains disposable fixtures, screenshots and local test diagnostics.
Those diagnostics are not repository inputs.

START OF PROMPT
```sh
python3 -B tools/tests/health-column-filters/run-ui.py --qt-bin /opt/homebrew/bin --output /tmp/watchtower-health-en --language en --width 1440 --panel closed
python3 -B tools/tests/health-column-filters/run-ui.py --qt-bin /opt/homebrew/bin --output /tmp/watchtower-health-ru --language ru --width 1200 --panel open
```
END OF PROMPT

`--qt-bin` is the directory containing `qmltestrunner` and `lrelease`.
`--output` is a new directory for the run. `--language` accepts `en` or `ru`;
`--width` accepts `1200` or `1440`; `--panel` accepts `open` or `closed`.
Height is always 900. Defaults are English, 1440 wide and a closed detail panel.
`--case` optionally selects a named test function, such as `test_matrix`.

Run the full suite in all eight language/width/panel combinations for acceptance.
Every full run also contains four layout data cases, checks the five popup
widths and table bounds, and captures each layout. Two real 15-second background
polls are included, so a run takes at least 30 seconds.

Coverage includes instant application, null/empty inclusion states, cascading
counts, hidden selected keys, duplicate camera names, ID/name search, Enter,
tri-state Select all, Only hover/click, popup closing, metric AND semantics,
selection lifetime, empty-state clearing, scroll anchoring and new category
exclusion. Recording classification is compared with the unchanged shipping
RecordingStatusBadge over 735 state/health/freshness combinations plus age/motion edges.
All seven live categories are compared with LiveStatusBadge.

The fixture copies production QML and fonts into the output directory. Only the
shell logo resource URL is mapped to the original local PNG because the
standalone test runner does not contain the application's compiled resources.
Settings, authentication, Watch and camera data are isolated test doubles.

Reviewed screenshots and the acceptance checklist are in
[the verification record](../../../docs/verification/2026-11-16-health-column-filters/README.md).
