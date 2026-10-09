import QtQuick
import Watchtower

// WT_TEST_QML harness for the Labs Tracking view (dev-only; main.cpp loads this
// file as root instead of the app shell). Pair with WT_LABS_TRACKS_OPEN=<run_id>
// to open an existing evidence record, and WT_SCREENSHOT to render a PNG.
Window {
    width: 1500
    height: 940
    visible: true
    color: Theme.bg
    LabsTracks { anchors.fill: parent }
}
