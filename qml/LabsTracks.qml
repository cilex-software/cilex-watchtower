import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import QtQuick.Dialogs
import Watchtower

// LabsTracks — the Labs "Tracking" view. Everything here is LOCAL to this
// computer: the helper process (tools/labs/track_run.py) decodes a recording the
// operator picks, extracts foreground detections with the existing pipeline, and
// runs the temporal tracking engine; evidence records persist under the Labs
// state dir and can be reopened after a restart. Nothing is written to the
// server. The verification panel runs the real check suites live and labels
// them as self-checks, not camera findings.
Item {
    id: root

    LabsTrackRunner { id: runner }

    property var probeInfo: null
    property string filePath: ""
    property string cameraId: ""
    property string startIso: ""
    property string configJson: ""
    property string origin: "operator"

    Connections {
        target: runner
        function onProbeReady(info) {
            root.probeInfo = info;
            root.filePath = info.path;
            // Suggestions from the file name are prefilled and marked by origin;
            // the operator confirms or corrects them before running.
            if (info.suggested && info.suggested.camera_id && root.cameraId === "") {
                root.cameraId = info.suggested.camera_id;
                root.origin = "filename";
            }
            if (info.suggested && info.suggested.start_time && root.startIso === "") {
                root.startIso = info.suggested.start_time;
                root.origin = "filename";
            }
            // The dev validation hook (WT_LABS_RUN_*) drives the same startRun the
            // operator's button calls.
            if (root.autoRun) {
                root.autoRun = false;
                var cam = (typeof wtLabsRunCamera !== "undefined" && wtLabsRunCamera !== "")
                          ? wtLabsRunCamera : camField.text;
                var start = (typeof wtLabsRunStart !== "undefined" && wtLabsRunStart !== "")
                            ? wtLabsRunStart : startField.text;
                runner.startRun(root.filePath, cam, start, root.origin, cfgField.text,
                                false);
                // WT_LABS_RUN_CANCEL_MS: cancel the run that many milliseconds in —
                // the cancellation path's validation hook.
                if (typeof wtLabsRunCancelMs !== "undefined" && wtLabsRunCancelMs > 0) {
                    cancelHookTimer.interval = wtLabsRunCancelMs;
                    cancelHookTimer.start();
                }
            }
        }
        function onProbeFailed(message) {
            root.probeInfo = null;
            runner.clearError();
            errorText = message;
            errBanner.visible = true;
        }
        function onRunFinished(runId, status) { runner.refreshRuns(); }
        function onVerifyFinished(suite, failed) { }
    }
    property string errorText: ""
    property bool autoRun: false

    // ---- shared pieces (the Labs screen's idiom) -----------------------------
    component Btn: Rectangle {
        id: b
        property string label: ""
        property bool enabledLook: true
        property bool danger: false
        signal clicked()
        implicitHeight: 28
        implicitWidth: bt.implicitWidth + 24
        color: bma.containsMouse && b.enabledLook ? Theme.panel : Theme.bg
        border.width: 1
        border.color: bma.containsMouse && b.enabledLook ? Theme.accent : Theme.line2
        opacity: b.enabledLook ? 1.0 : 0.45
        Text { id: bt; anchors.centerIn: parent; text: b.label
               color: b.danger ? Theme.bad : Theme.ink
               font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true
                    cursorShape: b.enabledLook ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (b.enabledLook) b.clicked() }
    }
    component Label10: Text {
        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
    }
    component Field: Rectangle {
        id: f
        property string label: ""
        property alias text: input.text
        property alias placeholder: input.placeholderText
        implicitHeight: 40
        color: Theme.bg; border.width: 1; border.color: Theme.line2; radius: 2
        Column {
            anchors.left: parent.left; anchors.right: parent.right; anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter; spacing: 0
            Text { text: f.label; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8
                   font.capitalization: Font.AllUppercase; font.letterSpacing: 1.0 }
            QC.TextField {
                id: input
                width: parent.width; padding: 0
                color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                background: Item {}
                onTextChanged: f.textEdited()
            }
        }
        signal textEdited()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== header =======================================================
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 8
                Rectangle { width: 7; height: 7; radius: 4
                            color: runner.helperAvailable ? Theme.good : Theme.bad }
                Label10 { text: qsTr("Tracking — local review") }
                Text {
                    text: runner.helperAvailable
                          ? qsTr("Runs on this computer only; nothing is sent to the server")
                          : qsTr("Unavailable: %1").arg(runner.helperProblem)
                    color: runner.helperAvailable ? Theme.ink3 : Theme.bad
                    font.family: Theme.fontMono; font.pixelSize: 11
                    elide: Text.ElideRight; Layout.fillWidth: true
                }
            }
        }

        // ===== error banner ==================================================
        Rectangle {
            id: errBanner
            visible: runner.lastError !== "" || root.errorText !== ""
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 34 : 0
            color: Theme.badSoft
            Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 3; color: Theme.bad }
            Text {
                anchors.left: parent.left; anchors.leftMargin: 18; anchors.right: parent.right; anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                text: root.errorText !== "" ? root.errorText : runner.lastError
                color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
            }
            MouseArea { anchors.fill: parent; onClicked: { root.errorText = ""; runner.clearError() } }
        }

        // ===== body ===========================================================
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ---- left: new run + runs + verification -----------------------
            Item {
                Layout.preferredWidth: 400
                Layout.fillHeight: true
                Rectangle { anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                Flickable {
                    anchors.fill: parent
                    contentWidth: parent.width
                    contentHeight: leftCol.implicitHeight
                    clip: true
                    QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }
                    ColumnLayout {
                        id: leftCol
                        width: parent.width
                        spacing: 0

                        // --- new run -----------------------------------------
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.margins: 14; spacing: 8
                            Label10 { text: qsTr("New run") }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: root.filePath === "" ? qsTr("No recording selected") : root.filePath
                                    color: root.filePath === "" ? Theme.ink3 : Theme.ink
                                    font.family: Theme.fontMono; font.pixelSize: 10
                                    elide: Text.ElideMiddle
                                }
                                Btn {
                                    label: qsTr("Choose recording…")
                                    enabledLook: runner.helperAvailable && runner.state !== "running"
                                    onClicked: fileDialog.open()
                                }
                            }
                            FileDialog {
                                id: fileDialog
                                title: qsTr("Choose a recorded clip")
                                nameFilters: [qsTr("Recordings (*.mp4 *.ts *.mkv *.avi)"), qsTr("All files (*)")]
                                onAccepted: {
                                    var p = fileDialog.selectedFile.toString();
                                    root.errorText = "";
                                    errBanner.visible = false;
                                    runner.probeFile(p.replace(/^file:\/\//, ""));
                                }
                            }
                            // The recording's measured identity — never invented.
                            Column {
                                Layout.fillWidth: true; spacing: 2
                                visible: root.probeInfo !== null
                                Text {
                                    visible: root.probeInfo !== null
                                    text: root.probeInfo === null ? "" :
                                          qsTr("%1 · %2×%3 · %4 fps · %5 s · sha256 %6…")
                                          .arg(root.probeInfo.probe.codec || "?")
                                          .arg(root.probeInfo.probe.width).arg(root.probeInfo.probe.height)
                                          .arg(root.probeInfo.probe.fps || 0)
                                          .arg(root.probeInfo.duration_s === null ? "?" : Number(root.probeInfo.duration_s).toFixed(1))
                                          .arg(root.probeInfo.sha256.slice(0, 16))
                                    color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10
                                    wrapMode: Text.WrapAnywhere; width: parent.width
                                }
                                Text {
                                    visible: root.probeInfo !== null && root.origin === "filename"
                                    text: qsTr("Camera and start were read from the file name — confirm before running")
                                    color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10
                                    wrapMode: Text.WordWrap; width: parent.width
                                }
                            }
                            Field {
                                id: camField
                                Layout.fillWidth: true
                                label: qsTr("Camera label (this clip's scope)")
                                placeholder: "cam-id"
                                text: root.cameraId
                                onTextEdited: { root.cameraId = text; root.origin = "operator"; }
                            }
                            Field {
                                id: startField
                                Layout.fillWidth: true
                                label: qsTr("Start of the recording (ISO, with timezone)")
                                placeholder: "2026-10-05T12:00:00+03:00"
                                text: root.startIso
                                onTextEdited: { root.startIso = text; root.origin = "operator"; }
                            }
                            Field {
                                id: cfgField
                                Layout.fillWidth: true
                                label: qsTr("Engine config (JSON, empty = defaults)")
                                placeholder: '{"max_gap_ms": 2000}'
                                text: root.configJson
                                onTextEdited: root.configJson = text
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Btn {
                                    label: qsTr("Run tracking")
                                    enabledLook: runner.helperAvailable && runner.state !== "running"
                                                 && root.probeInfo !== null
                                                 && camField.text !== "" && startField.text !== ""
                                    onClicked: {
                                        root.errorText = "";
                                        runner.startRun(root.filePath, camField.text, startField.text,
                                                        root.origin, cfgField.text, false);
                                    }
                                }
                                Btn {
                                    label: qsTr("Cancel")
                                    danger: true
                                    enabledLook: runner.state === "running"
                                    onClicked: runner.cancel()
                                }
                                Item { Layout.fillWidth: true }
                            }
                            // Progress — real, from the helper; indeterminate bar sweeps.
                            Rectangle {
                                Layout.fillWidth: true; height: 4
                                visible: runner.state === "running"
                                color: Theme.panel2
                                Rectangle {
                                    visible: runner.progress >= 0
                                    height: parent.height
                                    width: parent.width * Math.max(0, Math.min(1, runner.progress))
                                    color: Theme.accent
                                }
                                Rectangle {
                                    visible: runner.progress < 0
                                    height: parent.height; width: parent.width * 0.3; color: Theme.accent
                                    NumberAnimation on x {
                                        running: runner.state === "running" && runner.progress < 0
                                        from: 0; duration: 900; loops: Animation.Infinite
                                        to: parent.width * 0.7
                                    }
                                }
                            }
                            Text {
                                visible: runner.state === "running"
                                text: runner.progressDetail
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                            }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.line }

                        // --- past runs ---------------------------------------
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.margins: 14; spacing: 6
                            Label10 { text: qsTr("Runs on this computer") }
                            Repeater {
                                model: runner.runs
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property var r: modelData
                                    width: leftCol.width - 28
                                    height: 46
                                    color: runMa.containsMouse ? Theme.panel : "transparent"
                                    Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                                                width: 3
                                                color: r.status === "completed" ? Theme.good
                                                     : r.status === "cancelled" ? Theme.warn : Theme.bad }
                                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                                    MouseArea { id: runMa; anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: runner.openRun(r.run_id) }
                                    Column {
                                        anchors.left: parent.left; anchors.leftMargin: 12; anchors.right: delText.left; anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                        Row {
                                            spacing: 8
                                            Text {
                                                text: (r.camera_id || "?") + "  ·  " + (r.start_time || "").replace("T", " ").slice(0, 19)
                                                color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold
                                            }
                                            Text {
                                                visible: r.synthetic === true
                                                text: qsTr("synthetic")
                                                color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 9; font.weight: Font.DemiBold
                                            }
                                        }
                                        Text {
                                            text: (r.status === "completed"
                                                   ? qsTr("completed · %1 track(s) · %2 detections").arg(r.episodes).arg(r.detections)
                                                   : r.status === "cancelled" ? qsTr("cancelled — incomplete")
                                                   : qsTr("failed"))
                                            color: r.status === "completed" ? Theme.ink3
                                                 : r.status === "cancelled" ? Theme.warn : Theme.bad
                                            font.family: Theme.fontMono; font.pixelSize: 10
                                        }
                                    }
                                    Text {
                                        id: delText
                                        anchors.right: parent.right; anchors.rightMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "×"
                                        color: delMa.containsMouse ? Theme.bad : Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 14; font.weight: Font.DemiBold
                                        MouseArea { id: delMa; anchors.fill: parent; hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: runner.deleteRun(r.run_id) }
                                        QC.ToolTip.visible: delMa.containsMouse
                                        QC.ToolTip.text: qsTr("Delete this run's local record")
                                        QC.ToolTip.delay: 300
                                    }
                                }
                            }
                            Text {
                                visible: runner.runs.length === 0
                                text: qsTr("No runs yet on this computer")
                                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12
                            }
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.line }

                        // --- verification -------------------------------------
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.margins: 14; spacing: 8
                            Label10 { text: qsTr("Verification — self-checks, not camera findings") }
                            Text {
                                Layout.fillWidth: true
                                text: qsTr("These run the tracking engine's own checks live, on this computer. Synthetic inputs stay labelled; results here are not a benchmark grade.")
                                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                                wrapMode: Text.WordWrap
                            }
                            Flow {
                                Layout.fillWidth: true; spacing: 8
                                Btn {
                                    label: qsTr("Contract checks")
                                    enabledLook: runner.helperAvailable && runner.state !== "verifying"
                                    onClicked: runner.verify("contract", failureSwitch.checked)
                                }
                                Btn {
                                    label: qsTr("Labs regressions")
                                    enabledLook: runner.helperAvailable && runner.state !== "verifying"
                                    onClicked: runner.verify("regressions", failureSwitch.checked)
                                }
                                Btn {
                                    label: qsTr("Streaming workload")
                                    enabledLook: runner.helperAvailable && runner.state !== "verifying"
                                    onClicked: runner.verify("workload", failureSwitch.checked)
                                }
                                Btn {
                                    label: qsTr("Integration checks")
                                    enabledLook: runner.helperAvailable && runner.state !== "verifying"
                                    onClicked: runner.verify("integration", failureSwitch.checked)
                                }
                            }
                            RowLayout {
                                spacing: 8
                                QC.CheckBox {
                                    id: failureSwitch
                                    text: qsTr("Include deliberate failure control")
                                    font.family: Theme.fontSans; font.pixelSize: 11
                                    palette.windowText: Theme.ink2
                                }
                                Item { Layout.fillWidth: true }
                                Btn {
                                    label: qsTr("Stop")
                                    danger: true
                                    enabledLook: runner.state === "verifying"
                                    onClicked: runner.cancelVerify()
                                }
                            }
                            Text {
                                visible: runner.state === "verifying"
                                text: qsTr("Running %1…").arg(runner.verifySuite)
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                            }
                            Text {
                                visible: runner.verifySummary.failed !== undefined || runner.verifySummary.cancelled === true
                                text: runner.verifySummary.cancelled === true
                                      ? qsTr("cancelled")
                                      : qsTr("%1: %2 passed, %3 failed, %4 skipped · %5 s")
                                        .arg(runner.verifySuite)
                                        .arg(runner.verifySummary.passed || 0)
                                        .arg(runner.verifySummary.failed || 0)
                                        .arg(runner.verifySummary.skipped || 0)
                                        .arg(runner.verifySummary.seconds || 0)
                                color: (runner.verifySummary.failed || 0) > 0 ? Theme.bad : Theme.good
                                font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold
                            }
                        }
                    }
                }
            }

            // ---- right: review of the selected run --------------------------
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                LabsTrackReview {
                    anchors.fill: parent
                    visible: runner.selectedRun.run_id !== undefined
                    run: runner.selectedRun
                }
                // The verification results list shares the right pane until a run
                // is opened; a run selection replaces it.
                ColumnLayout {
                    anchors.fill: parent
                    visible: runner.selectedRun.run_id === undefined
                    spacing: 0
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 30; color: Theme.bg
                        Label10 {
                            anchors.left: parent.left; anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: runner.checks.length ? qsTr("Verification results") : qsTr("Tracks")
                        }
                    }
                    ListView {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true
                        model: runner.checks
                        QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }
                        delegate: Rectangle {
                            required property var modelData
                            width: ListView.view.width
                            height: 30
                            color: "transparent"
                            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                                Rectangle {
                                    width: 7; height: 7; radius: 4
                                    color: modelData.status === "pass" ? Theme.good
                                         : modelData.status === "fail" ? Theme.bad
                                         : modelData.status === "skip" ? Theme.ink3 : Theme.accent
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.name
                                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                                Text {
                                    visible: modelData.detail !== undefined && modelData.detail !== ""
                                    text: modelData.detail
                                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                                    Layout.maximumWidth: 300; elide: Text.ElideRight
                                }
                                Text {
                                    text: modelData.status === "pass" ? qsTr("pass")
                                        : modelData.status === "fail" ? qsTr("FAIL")
                                        : modelData.status === "skip" ? qsTr("skip") : "info"
                                    color: modelData.status === "pass" ? Theme.good
                                         : modelData.status === "fail" ? Theme.bad : Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        // Screenshot/dev hook: open a given evidence record (WT_LABS_TRACKS_OPEN).
        if (typeof wtLabsTracksOpen !== "undefined" && wtLabsTracksOpen !== "")
            runner.openRun(wtLabsTracksOpen);
        // Dev validation hooks (main.cpp): auto-start a run or a check suite.
        if (typeof wtLabsRunFile !== "undefined" && wtLabsRunFile !== "") {
            root.autoRun = true;
            runner.probeFile(wtLabsRunFile);
        }
        if (typeof wtLabsVerify !== "undefined" && wtLabsVerify !== "") {
            var failctl = wtLabsVerify.indexOf("+failure") >= 0;
            runner.verify(wtLabsVerify.replace("+failure", ""), failctl);
        }
    }

    Timer { id: cancelHookTimer; interval: 2000; onTriggered: runner.cancel() }
}
