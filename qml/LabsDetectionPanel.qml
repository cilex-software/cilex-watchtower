import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import QtQuick.Dialogs
import QtMultimedia
import Watchtower

// Labs — Detection (Stage 3 semantic analysers). Panel id LabsDetectionPanel; the
// model is LabsDetection (src/models), which runs tools/labs/stage3_detect.py in
// its own process and asks tools/labs/stage3_evaluate.py for the target checklist.
//
// WHAT THE OPERATOR SEES, and what is deliberately NOT shown:
//   * object boxes on the recording, each carrying its class, detector confidence
//     and — separately — the colour of a NAMED region of that object. A colour is
//     never drawn for an object that has none, and `unknown` is shown as unknown
//     rather than as a colour.
//   * the boxes come from the observation whose decoded PTS is at or before the
//     playhead, within one sampling interval; the legend names that frame's own
//     time, so a stale box cannot masquerade as the current frame.
//   * a target is a CANDIDATE until a named reviewer decides. The panel never
//     auto-accepts, and a green row means a reviewer accepted, nothing else.
Item {
    id: root

    property var detection: null
    readonly property var dt: detection
    readonly property var modelState: detection ? detection.modelState : ({})
    readonly property var probeInfo: detection ? detection.probe : ({})
    readonly property real srcAspect: (probeInfo.width && probeInfo.height)
                                       ? (probeInfo.width / probeInfo.height) : (16 / 9)
    readonly property var sample: observed
    property var observed: ({ found: false })
    property string rightTab: "objects"
    property string reviewerName: (typeof wtStage3Reviewer !== "undefined" && wtStage3Reviewer !== "")
                                  ? wtStage3Reviewer : "operator (in-app reviewer)"
    property string noteDraft: ""
    readonly property var selected: detection ? detection.selectedDetail : ({})

    function timeText(ms) {
        if (ms === undefined || ms === null || isNaN(ms)) return "—"
        var s = Math.max(0, Math.floor(ms / 1000))
        var m = Math.floor(s / 60); s = s % 60
        var f = Math.floor(ms % 1000)
        return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s + "." +
               (f < 100 ? (f < 10 ? "00" : "0") : "") + f
    }

    function refreshObserved() {
        if (!dt || !dt.hasResult) { observed = { found: false }; return }
        observed = dt.observationsAt(player.position, 900)
        overlay.requestPaint()
    }
    onDetectionChanged: { refreshObserved(); autoPick() }

    // A finished run opens its most useful observation: the first person, else the
    // first object. The operator can then step through the crop and colour evidence
    // without hunting through a 400-row list.
    function autoPick() {
        if (!root.dt || !root.dt.hasResult || root.dt.selectedObservation !== "") return
        var rows = root.dt.observations
        if (!rows || rows.length === 0) return
        var pick = rows[0]
        for (var i = 0; i < rows.length; i++)
            if (rows[i]["class"] === "person") { pick = rows[i]; break }
        root.seekToObservation(pick.id)
    }
    onSampleChanged: overlay.requestPaint()

    Timer {
        interval: 250; running: player.playbackState === MediaPlayer.PlayingState
        repeat: true
        onTriggered: root.refreshObserved()
    }
    Timer {
        id: selectTimer
        interval: 100; repeat: false
        onTriggered: root.refreshObserved()
    }

    Component.onCompleted: {
        if (dt) { dt.refreshRecordings(); dt.refreshRuns(); dt.probeModel() }
        refreshObserved()
    }

    Connections {
        target: root.dt
        function onObservationsChanged() { root.refreshObserved(); root.autoPick() }
        function onTargetsChanged() { root.rightTab = (root.rightTab === "objects" &&
                                                       root.dt && root.dt.targets.length > 0)
                                                      ? root.rightTab : root.rightTab }
    }

    // WT_LABS_STAGE3_* (main.cpp): review hooks so a screenshot can show a real run
    // without a terminal.
    onDtChanged: {
        if (!dt) return
        if (typeof wtStage3Recording !== "undefined" && wtStage3Recording !== "" &&
                dt.recording !== wtStage3Recording)
            dt.recording = wtStage3Recording
        if (typeof wtStage3Run !== "undefined" && wtStage3Run === true)
            runTimer.start()
        if (typeof wtStage3Checks !== "undefined" && wtStage3Checks !== "") {
            rightTab = "verify"
            checksTimer.start()
        }
    }
    Timer { id: runTimer; interval: 900; repeat: false
            onTriggered: if (root.dt && !root.dt.running) root.dt.start() }
    Timer { id: checksTimer; interval: 1100; repeat: false
            onTriggered: if (root.dt && !root.dt.checking) root.dt.runChecks(wtStage3Checks) }

    FileDialog {
        id: pickRecording
        title: qsTr("Choose a recording")
        nameFilters: [qsTr("Recordings (*.mp4 *.mkv *.mov *.ts)"), qsTr("All files (*)")]
        onAccepted: if (root.dt) root.dt.recording = selectedFile
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ============================ source + analyser =======================
        Rectangle {
            Layout.preferredWidth: 330
            Layout.fillHeight: true
            color: Theme.panel
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }

            Flickable {
                id: leftFlick
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: leftCol.implicitHeight + 28
                QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }

                ColumnLayout {
                    id: leftCol
                    x: 14; y: 14
                    width: leftFlick.width - 28
                    spacing: 9

                    Text { text: qsTr("SEMANTIC ANALYSERS · STAGE 3")
                           color: Theme.ink3; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel; font.weight: Font.DemiBold
                           font.letterSpacing: 0.8 }

                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: 34
                        color: Theme.panel2; border.width: 1
                        border.color: root.dt && root.dt.status === "failed" ? Theme.badDim
                                    : root.dt && root.dt.status === "completed" ? Theme.goodDim
                                    : root.dt && root.dt.status === "cancelled" ? Theme.warnDim
                                    : Theme.line2
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 8
                            Rectangle {
                                width: 7; height: 7
                                color: !root.dt ? Theme.ink3
                                     : root.dt.status === "running" ? Theme.info
                                     : root.dt.status === "completed" ? Theme.good
                                     : root.dt.status === "cancelled" ? Theme.warn
                                     : root.dt.status === "failed" ? Theme.bad : Theme.ink3
                            }
                            Text {
                                Layout.fillWidth: true
                                text: !root.dt ? qsTr("No analyser")
                                    : root.dt.status === "idle" ? qsTr("IDLE — nothing run yet")
                                    : root.dt.status === "running" ? qsTr("RUNNING")
                                    : root.dt.status === "completed" ? qsTr("COMPLETED")
                                    : root.dt.status === "cancelled" ? qsTr("CANCELLED · PARTIAL")
                                    : root.dt.status === "failed" ? qsTr("FAILED")
                                    : root.dt.status
                                color: Theme.ink; font.family: Theme.fontMono
                                font.pixelSize: Theme.fsMono; font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.dt ? root.dt.statusText : ""
                        color: Theme.ink2; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsSmall; wrapMode: Text.WordWrap
                        visible: text !== ""
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.dt && root.dt.errorText !== ""
                        text: root.dt ? (root.dt.errorCode + ": " + root.dt.errorText) : ""
                        color: Theme.bad; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsMono; wrapMode: Text.WordWrap
                    }
                    QC.ProgressBar {
                        Layout.fillWidth: true
                        visible: root.dt && (root.dt.running || root.dt.progress > 0)
                        from: 0; to: 1; value: root.dt ? root.dt.progress : 0
                    }

                    // ---- model state: a prerequisite, shown as one -------------
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.dt !== null
                        implicitHeight: modelCol.implicitHeight + 14
                        color: Theme.panel2
                        border.width: 1
                        border.color: root.modelState.weights_present ? Theme.goodDim : Theme.warnDim
                        ColumnLayout {
                            id: modelCol
                            anchors.fill: parent; anchors.margins: 7
                            spacing: 2
                            Text {
                                text: root.modelState.weights_present
                                      ? qsTr("MODEL READY")
                                      : qsTr("MODEL NOT AVAILABLE")
                                color: root.modelState.weights_present ? Theme.good : Theme.warn
                                font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                                font.weight: Font.DemiBold
                            }
                            Text {
                                Layout.fillWidth: true
                                text: (root.modelState.name || "?")
                                color: Theme.ink2; font.family: Theme.fontMono
                                font.pixelSize: Theme.fsLabel; elide: Text.ElideMiddle
                            }
                            Text {
                                Layout.fillWidth: true
                                text: (root.modelState.licence || "?") + " · " +
                                      (root.modelState.device || "cpu")
                                color: Theme.ink3; font.family: Theme.fontMono
                                font.pixelSize: Theme.fsLabel
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: !root.modelState.weights_present
                                text: qsTr("weights expected at ") +
                                      (root.modelState.weights_path || "?") +
                                      qsTr("\nnot a no-detection result")
                                color: Theme.warn; font.family: Theme.fontMono
                                font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                            }
                        }
                    }

                    // ---- recording ---------------------------------------------
                    Text { text: qsTr("RECORDING"); color: Theme.ink3
                           font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                           font.weight: Font.DemiBold }
                    Text {
                        Layout.fillWidth: true
                        text: root.dt && root.dt.recording !== "" ? root.dt.recordingName
                                                                 : qsTr("none selected")
                        color: root.dt && root.dt.recording !== "" ? Theme.ink : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        elide: Text.ElideMiddle
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.dt && root.dt.recording !== ""
                        text: {
                            var p = root.probeInfo
                            if (!p || !p.ok) return qsTr("container facts unknown")
                            return (p.width || "?") + "×" + (p.height || "?") + " · " +
                                   (p.codec || "?") + " · " +
                                   (p.duration_ms ? Math.round(p.duration_ms / 100) / 10 + " s" : "?")
                        }
                        color: Theme.ink3; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsLabel
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 6
                        EvButton {
                            label: qsTr("Stage 3 clips"); small: true; Layout.fillWidth: true
                            onClicked: recPopup.open()
                        }
                        EvButton { label: qsTr("Browse…"); small: true; Layout.fillWidth: true
                                   onClicked: pickRecording.open() }
                    }

                    QC.Popup {
                        id: recPopup
                        width: 430; height: 330
                        anchors.centerIn: parent
                        modal: true; focus: true
                        background: Rectangle { color: Theme.panel3; border.width: 1
                                                border.color: Theme.line2 }
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 8
                            Text { text: qsTr("Supplied clips and exports")
                                   color: Theme.ink3; font.family: Theme.fontMono
                                   font.pixelSize: Theme.fsLabel }
                            ListView {
                                Layout.fillWidth: true; Layout.fillHeight: true
                                clip: true
                                model: root.dt ? root.dt.recordings : []
                                delegate: Rectangle {
                                    width: ListView.view.width; height: 44
                                    color: rma.containsMouse ? Theme.panel2 : "transparent"
                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.left: parent.left; anchors.right: parent.right
                                        anchors.margins: 8
                                        Text { text: (modelData.stage3 ? "★ " : "  ") + modelData.name
                                               color: Theme.ink; font.family: Theme.fontMono
                                               font.pixelSize: Theme.fsMono
                                               elide: Text.ElideMiddle; width: parent.width }
                                        Text { text: modelData.modified + " · " +
                                                     Math.round(modelData.bytes / 1048576) + " MB"
                                               color: Theme.ink3; font.family: Theme.fontMono
                                               font.pixelSize: Theme.fsLabel }
                                    }
                                    MouseArea {
                                        id: rma; anchors.fill: parent; hoverEnabled: true
                                        onClicked: { root.dt.recording = modelData.path; recPopup.close() }
                                    }
                                }
                            }
                        }
                    }

                    // ---- analyser settings --------------------------------------
                    Text { text: qsTr("ANALYSER"); color: Theme.ink3; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel; font.weight: Font.DemiBold }
                    QC.ComboBox {
                        Layout.fillWidth: true
                        model: root.dt ? root.dt.backends : []
                        textRole: "label"
                        valueRole: "key"
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                        Component.onCompleted: currentIndex = 0
                        onActivated: if (root.dt) root.dt.backend = currentValue
                    }
                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2; columnSpacing: 8; rowSpacing: 6
                        Text { text: qsTr("clip id"); color: Theme.ink2
                               font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel }
                        QC.TextField {
                            Layout.fillWidth: true
                            text: root.dt ? root.dt.clipId : ""
                            font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                            onEditingFinished: if (root.dt) root.dt.clipId = text
                        }
                        Text { text: qsTr("sample"); color: Theme.ink2
                               font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel }
                        QC.TextField {
                            Layout.fillWidth: true
                            text: root.dt ? String(root.dt.sampleFps) : "2.5"
                            font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                            validator: DoubleValidator { bottom: 0.2; top: 15.0; decimals: 2 }
                            onEditingFinished: if (root.dt && acceptableInput)
                                                    root.dt.sampleFps = parseFloat(text)
                        }
                        Text { text: qsTr("min conf"); color: Theme.ink2
                               font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel }
                        QC.TextField {
                            Layout.fillWidth: true
                            text: root.dt ? String(root.dt.scoreThreshold) : "0.55"
                            font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                            validator: DoubleValidator { bottom: 0.05; top: 0.95; decimals: 2 }
                            onEditingFinished: if (root.dt && acceptableInput)
                                                    root.dt.scoreThreshold = parseFloat(text)
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Objects and object-linked colours run as one versioned "
                                   + "pipeline; decoding uses each frame's own PTS.")
                        color: Theme.ink3; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                    }
                    EvButton {
                        Layout.fillWidth: true
                        label: root.dt && root.dt.running ? qsTr("Cancel") : qsTr("Run analysers")
                        variant: root.dt && root.dt.running ? "danger" : "pri"
                        enabledBtn: root.dt && (root.dt.running || root.dt.recording !== "")
                        onClicked: if (root.dt) { root.dt.running ? root.dt.cancel() : root.dt.start() }
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.line }

                    // ---- saved runs ----------------------------------------------
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: qsTr("SAVED RUNS"); color: Theme.ink3
                               font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                               font.weight: Font.DemiBold; Layout.fillWidth: true }
                        Text { text: qsTr("refresh")
                               color: rrma.containsMouse ? Theme.accent : Theme.ink3
                               font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                               MouseArea { id: rrma; anchors.fill: parent; hoverEnabled: true
                                           onClicked: if (root.dt) root.dt.refreshRuns() } }
                    }
                    ListView {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(200, Math.max(56,
                            (root.dt ? root.dt.runs.length : 0) * 40))
                        clip: true
                        model: root.dt ? root.dt.runs : []
                        delegate: Rectangle {
                            width: ListView.view.width; height: 40
                            color: rrma2.containsMouse ? Theme.panel2 : "transparent"
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left; anchors.right: parent.right
                                Text {
                                    text: modelData.clip_id + "  ·  " + modelData.status +
                                          (modelData.reviewed ? qsTr("  ·  reviewed") : "")
                                    color: modelData.status === "completed" ? Theme.ink
                                         : modelData.status === "cancelled" ? Theme.warn : Theme.bad
                                    font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                                    width: parent.width; elide: Text.ElideRight
                                }
                                Text {
                                    text: modelData.id + " · " + modelData.observations +
                                          qsTr(" observations")
                                    color: Theme.ink3; font.family: Theme.fontMono
                                    font.pixelSize: Theme.fsLabel; elide: Text.ElideRight
                                    width: parent.width
                                }
                            }
                            MouseArea {
                                id: rrma2; anchors.fill: parent; hoverEnabled: true
                                onClicked: if (root.dt) root.dt.openRun(modelData.dir)
                            }
                        }
                    }
                }
            }
        }

        // ============================== reviewer ==============================
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 220
                Layout.preferredHeight: 460

                Rectangle { anchors.fill: parent; color: Theme.tileBg }

                Item {
                    id: videoArea
                    anchors.centerIn: parent
                    width: Math.min(parent.width, parent.height * root.srcAspect)
                    height: width / root.srcAspect

                    MediaPlayer {
                        id: player
                        source: (root.dt && root.dt.recording !== "")
                                ? "file://" + root.dt.recording : ""
                        videoOutput: videoOut
                        audioOutput: null
                        onPositionChanged: root.refreshObserved()
                    }
                    VideoOutput { id: videoOut; anchors.fill: parent
                                  fillMode: VideoOutput.PreserveAspectFit }

                    Text {
                        anchors.centerIn: parent
                        visible: !root.dt || root.dt.recording === ""
                        text: qsTr("Choose a recording to analyse")
                        color: Theme.ink3; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsBody
                    }

                    Canvas {
                        id: overlay
                        anchors.fill: parent
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            var s = root.observed
                            if (!s || !s.found || !s.observations) return
                            var W = width, H = height
                            for (var i = 0; i < s.observations.length; i++) {
                                var o = s.observations[i]
                                var b = o.bbox_xywh
                                if (!b) continue
                                var x = b[0] * W, y = b[1] * H, w = b[2] * W, h = b[3] * H
                                var cls = o["class"]
                                ctx.strokeStyle = cls === "person" ? Theme.good
                                                : cls === "car" ? Theme.info
                                                : cls === "bag" || cls === "dog" ? Theme.violet
                                                : Theme.ink3
                                ctx.lineWidth = o.selected ? 2.4 : 1.3
                                ctx.strokeRect(x, y, w, h)
                                ctx.fillStyle = ctx.strokeStyle
                                ctx.font = "10px " + Theme.fontMono
                                var label = cls + " " + (Math.round(o.confidence * 100) / 100)
                                for (var c = 0; c < (o.colors ? o.colors.length : 0); c++) {
                                    var col = o.colors[c]
                                    if (col.region === "upper_clothing" || col.region === "vehicle_body")
                                        label += "  " + col.region.replace("_clothing", "") + ":" + col.label
                                }
                                ctx.fillText(label, x, Math.max(11, y - 3))
                            }
                        }
                    }
                }

                Rectangle {
                    anchors.left: parent.left; anchors.bottom: parent.bottom
                    anchors.margins: 10
                    width: legendText.implicitWidth + 16
                    height: legendText.implicitHeight + 12
                    color: Qt.rgba(0, 0, 0, 0.55); border.width: 1; border.color: Theme.line2
                    Text {
                        id: legendText
                        anchors.centerIn: parent
                        color: Theme.ink2; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsMono
                        text: {
                            if (!root.dt || !root.dt.hasResult) return qsTr("no analysis loaded")
                            var s = root.observed
                            if (!s || !s.found)
                                return s && s.first_pts_ms !== undefined
                                    ? qsTr("before the first analysed frame (starts at ") +
                                      root.timeText(s.first_pts_ms) + ")"
                                    : qsTr("no observation within one sampling interval")
                            var n = s.observations ? s.observations.length : 0
                            return qsTr("decoded frame at ") + root.timeText(s.pts_ms) +
                                   "  ·  " + n + qsTr(" object") + (n === 1 ? "" : "s") +
                                   qsTr("  ·  ") + Math.round(s.age_ms) + qsTr(" ms before playhead")
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true; implicitHeight: 38; color: Theme.panel
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    spacing: 8
                    EvButton {
                        label: player.playbackState === MediaPlayer.PlayingState
                               ? qsTr("Pause") : qsTr("Play"); small: true
                        enabledBtn: root.dt && root.dt.recording !== ""
                        onClicked: player.playbackState === MediaPlayer.PlayingState
                                   ? player.pause() : player.play()
                    }
                    Text { text: root.timeText(player.position); color: Theme.ink
                           font.family: Theme.fontMono; font.pixelSize: Theme.fsMono }
                    QC.Slider {
                        Layout.fillWidth: true
                        from: 0; to: Math.max(1, player.duration); value: player.position
                        enabled: player.duration > 0
                        onMoved: { player.position = value; root.refreshObserved() }
                    }
                    Text { text: root.timeText(player.duration); color: Theme.ink3
                           font.family: Theme.fontMono; font.pixelSize: Theme.fsMono }
                }
            }

            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 46; color: Theme.bg
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                    spacing: 12
                    LabsSeg {
                        choices: [ { k: qsTr("Objects"), v: "objects" },
                                   { k: qsTr("Targets"), v: "targets" },
                                   { k: qsTr("Verification"), v: "verify" } ]
                        value: root.rightTab
                        onPicked: (v) => root.rightTab = v
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        visible: root.rightTab === "objects" && root.dt
                        text: root.dt ? (root.dt.observations.length + qsTr(" observations · ") +
                              (root.dt.summary && root.dt.summary.measurements
                               ? (root.dt.summary.measurements.inference_frame_count || 0) +
                                 qsTr(" frames analysed of ") +
                                 (root.dt.summary.measurements.decoded_frame_count || 0)
                               : "")) : ""
                        color: Theme.ink3; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsLabel
                    }
                    Text {
                        visible: root.rightTab === "targets" && root.dt && root.dt.evaluation
                                 && root.dt.evaluation.valid !== undefined
                        text: root.dt && root.dt.evaluation.valid === false
                              ? qsTr("INVALID EVIDENCE")
                              : (root.dt && root.dt.evaluation.summary
                                 ? qsTr("status ") + root.dt.evaluation.status
                                 : "")
                        color: root.dt && root.dt.evaluation.valid === false ? Theme.bad : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                    }
                }
            }

            // ---- objects -------------------------------------------------------
            RowLayout {
                visible: root.rightTab === "objects"
                Layout.fillWidth: true; Layout.fillHeight: true
                Layout.minimumHeight: 250; Layout.preferredHeight: 340
                spacing: 0

                ListView {
                    Layout.preferredWidth: 380
                    Layout.fillHeight: true
                    clip: true
                    model: root.dt ? root.dt.observations : []
                    delegate: Rectangle {
                        width: ListView.view.width; height: 46
                        color: root.dt && root.dt.selectedObservation === modelData.id
                               ? Theme.accentSoft
                               : oma.containsMouse ? Theme.panel2 : "transparent"
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width
                                    height: 1; color: Theme.line }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.margins: 10
                            spacing: 1
                            RowLayout {
                                width: parent.width - 20; spacing: 8
                                Text { text: modelData["class"]; color: Theme.ink
                                       font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                                       font.weight: Font.DemiBold }
                                Text { text: root.timeText(modelData.frame_pts_ms)
                                       color: Theme.ink2; font.family: Theme.fontMono
                                       font.pixelSize: Theme.fsLabel }
                                Text { text: (Math.round(modelData.confidence * 1000) / 1000)
                                       color: Theme.ink2; font.family: Theme.fontMono
                                       font.pixelSize: Theme.fsLabel }
                                Item { Layout.fillWidth: true }
                                Text { text: modelData.track_id || ""
                                       color: Theme.ink3; font.family: Theme.fontMono
                                       font.pixelSize: Theme.fsLabel }
                            }
                            Text {
                                text: {
                                    var parts = []
                                    for (var i = 0; i < (modelData.colors || []).length; i++) {
                                        var c = modelData.colors[i]
                                        parts.push(c.region + "=" + c.label)
                                    }
                                    return parts.length ? parts.join("  ") : qsTr("no colour regions")
                                }
                                color: Theme.ink3; font.family: Theme.fontMono
                                font.pixelSize: Theme.fsLabel; elide: Text.ElideRight
                                width: parent.width
                            }
                        }
                        MouseArea {
                            id: oma; anchors.fill: parent; hoverEnabled: true
                            onClicked: {
                                if (!root.dt) return
                                root.dt.selectObservation(modelData.id)
                                if (modelData.frame_pts_ms !== undefined &&
                                        player.duration > 0)
                                    player.position = Math.max(0, Math.min(
                                        modelData.frame_pts_ms, player.duration))
                                selectTimer.start()
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !root.dt || root.dt.observations.length === 0
                        text: root.dt && root.dt.running ? qsTr("analysing…")
                             : root.dt && root.dt.hasResult ? qsTr("no objects in this run")
                             : qsTr("no analysis yet")
                        color: Theme.ink3; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsBody
                    }
                }

                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.line }

                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Layout.margins: 12
                    spacing: 7
                    Text {
                        text: root.dt && root.dt.selectedObservation !== ""
                              ? root.dt.selectedObservation : qsTr("SELECT AN OBSERVATION")
                        color: root.dt && root.dt.selectedObservation !== ""
                               ? Theme.ink : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        font.weight: Font.DemiBold
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.selected && root.selected.id !== undefined
                        color: Theme.ink2; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsSmall; wrapMode: Text.WordWrap
                        text: root.selected && root.selected.id !== undefined
                              ? (qsTr("class ") + root.selected["class"] +
                                 qsTr(" · confidence ") + root.selected.confidence +
                                 qsTr(" · native ") + (root.selected.native_class || root.selected["class"]) +
                                 qsTr("\nobserved frame ") + root.selected.frame_index +
                                 qsTr(" at PTS ") + root.timeText(root.selected.frame_pts_ms) +
                                 qsTr(" · track ") + (root.selected.track_id || "—") +
                                 qsTr("\nbox ") + (root.selected.bbox_text || ""))
                              : ""
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.selected && root.selected.crop_path !== undefined
                                 && root.selected.crop_path !== ""
                        text: qsTr("object crop (the pixels the detector saw):")
                        color: Theme.ink3; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsLabel
                    }
                    Image {
                        Layout.preferredHeight: 130
                        Layout.fillWidth: true
                        fillMode: Image.PreserveAspectFit
                        source: (root.selected && root.selected.crop_path)
                                ? "file://" + root.selected.crop_path : ""
                        visible: source !== ""
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.selected && root.selected.regions !== undefined
                                 && root.selected.regions.length > 0
                        text: qsTr("colour regions (each from its own pixels):")
                        color: Theme.ink3; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsLabel
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Repeater {
                            model: (root.selected && root.selected.regions)
                                   ? root.selected.regions : []
                            delegate: ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Image {
                                    Layout.preferredHeight: 74
                                    Layout.fillWidth: true
                                    fillMode: Image.PreserveAspectFit
                                    source: modelData.crop_path ? "file://" + modelData.crop_path : ""
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.region + " = " + modelData.label +
                                          "  (" + (Math.round(modelData.confidence * 100) / 100) + ")"
                                    color: modelData.label === "unknown" ? Theme.ink3 : Theme.ink2
                                    font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }

            // ---- targets -------------------------------------------------------
            ColumnLayout {
                visible: root.rightTab === "targets"
                Layout.fillWidth: true; Layout.fillHeight: true
                Layout.minimumHeight: 250; Layout.preferredHeight: 340
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    Layout.margins: 10
                    text: qsTr("A candidate is NOT a pass. Accept only after comparing the "
                               + "crop and the recording with the target description; unknown "
                               + "colours stay visible and never qualify.")
                    color: Theme.ink3; font.family: Theme.fontSans
                    font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                }
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 10; Layout.rightMargin: 10
                    visible: root.dt && root.dt.evaluation && root.dt.evaluation.valid === false
                    text: root.dt ? qsTr("Evaluator errors: ") +
                          JSON.stringify(root.dt.evaluation.errors) : ""
                    color: Theme.bad; font.family: Theme.fontMono
                    font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                }
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    model: root.dt ? root.dt.targets : []
                    delegate: Rectangle {
                        width: ListView.view.width
                        height: tcol.implicitHeight + 18
                        color: "transparent"
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width
                                    height: 1; color: Theme.line }
                        ColumnLayout {
                            id: tcol
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.top: parent.top; anchors.margins: 10
                            spacing: 4
                            RowLayout {
                                width: parent.width; spacing: 8
                                Rectangle {
                                    width: 96; height: 16
                                    color: modelData.status === "accepted" ? Theme.goodDim
                                         : modelData.status === "rejected" ? Theme.badDim
                                         : modelData.status === "not_detected" ? Theme.panel2
                                         : modelData.status === "not_verified" ? Theme.badDim
                                         : Theme.warnDim
                                    border.width: 1
                                    border.color: modelData.status === "accepted" ? Theme.good
                                                : modelData.status === "rejected" ? Theme.bad
                                                : modelData.status === "not_verified" ? Theme.bad
                                                : Theme.warn
                                    Text {
                                        anchors.centerIn: parent
                                        text: String(modelData.status).toUpperCase()
                                        color: modelData.status === "accepted" ? Theme.good
                                             : modelData.status === "rejected" ? Theme.bad
                                             : modelData.status === "not_detected" ? Theme.ink3
                                             : modelData.status === "not_verified" ? Theme.bad
                                             : Theme.warn
                                        font.family: Theme.fontMono; font.pixelSize: 8
                                        font.weight: Font.DemiBold
                                    }
                                }
                                Text { text: modelData.target_id + "  " + root.targetClass(modelData.target_id)
                                       color: Theme.ink; font.family: Theme.fontMono
                                       font.pixelSize: Theme.fsMono; font.weight: Font.DemiBold }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: qsTr("candidates ") +
                                          (modelData.class_observation_ids
                                           ? modelData.class_observation_ids.length : 0) +
                                          qsTr(" · qualifying ") +
                                          (modelData.qualifying_observation_ids
                                           ? modelData.qualifying_observation_ids.length : 0)
                                    color: Theme.ink3; font.family: Theme.fontMono
                                    font.pixelSize: Theme.fsLabel
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: (root.dt ? root.targetDescription(modelData.target_id) : "")
                                color: Theme.ink2; font.family: Theme.fontSans
                                font.pixelSize: Theme.fsSmall; wrapMode: Text.WordWrap
                                visible: text !== ""
                            }
                            Text {
                                Layout.fillWidth: true
                                text: qsTr("required colour: ") + root.requiredColour(modelData.target_id)
                                      + qsTr("   ·   reviewer: ") + root.reviewerName
                                      + (modelData.review_note ? qsTr("   ·   note: ") + modelData.review_note : "")
                                color: Theme.ink3; font.family: Theme.fontMono
                                font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                            }
                            RowLayout {
                                width: parent.width; spacing: 6
                                EvButton {
                                    label: qsTr("Accept"); small: true; variant: "good"
                                    enabledBtn: modelData.qualifying_observation_ids
                                                && modelData.qualifying_observation_ids.length > 0
                                    onClicked: if (root.dt)
                                        root.dt.decide(modelData.target_id, "accepted",
                                                       modelData.qualifying_observation_ids, noteField.text)
                                }
                                EvButton {
                                    label: qsTr("Reject"); small: true; variant: "danger"
                                    onClicked: if (root.dt)
                                        root.dt.decide(modelData.target_id, "rejected",
                                                       modelData.class_observation_ids,
                                                       noteField.text !== "" ? noteField.text
                                                                             : "reviewed: wrong object or colour")
                                }
                                EvButton {
                                    label: qsTr("Unreviewable"); small: true
                                    onClicked: if (root.dt)
                                        root.dt.decide(modelData.target_id, "unreviewable",
                                                       [], noteField.text !== ""
                                                       ? noteField.text : "cannot judge from this evidence")
                                }
                                QC.TextField {
                                    id: noteField
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("review note (goes into the saved review)")
                                    font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                                }
                            }
                            RowLayout {
                                width: parent.width; spacing: 6
                                visible: modelData.class_observation_ids
                                         && modelData.class_observation_ids.length > 0
                                Repeater {
                                    model: (modelData.class_observation_ids || []).slice(0, 8)
                                    delegate: Rectangle {
                                        width: 74; height: 18
                                        color: Theme.panel2; border.width: 1
                                        border.color: Theme.line2
                                        Text { anchors.centerIn: parent; text: modelData
                                               color: Theme.ink2; font.family: Theme.fontMono
                                               font.pixelSize: 9 }
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: root.seekToObservation(modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !root.dt || root.dt.targets.length === 0
                        text: root.dt && root.dt.hasResult
                              ? qsTr("no target annotations for this clip (analysis still ran)")
                              : qsTr("no run to evaluate yet")
                        color: Theme.ink3; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsBody
                    }
                }
            }

            // ---- verification --------------------------------------------------
            ColumnLayout {
                visible: root.rightTab === "verify"
                Layout.fillWidth: true; Layout.fillHeight: true
                Layout.minimumHeight: 250; Layout.preferredHeight: 340
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true; Layout.margins: 10; spacing: 8
                    EvButton { label: qsTr("All"); small: true
                               enabledBtn: root.dt && !root.dt.checking
                               onClicked: if (root.dt) root.dt.runChecks("all") }
                    EvButton { label: qsTr("Supplied clips"); small: true
                               enabledBtn: root.dt && !root.dt.checking
                               onClicked: if (root.dt) root.dt.runChecks("supplied") }
                    EvButton { label: qsTr("Controls"); small: true
                               enabledBtn: root.dt && !root.dt.checking
                               onClicked: if (root.dt) root.dt.runChecks("controls") }
                    EvButton { label: qsTr("Suites"); small: true
                               enabledBtn: root.dt && !root.dt.checking
                               onClicked: if (root.dt) root.dt.runChecks("checks") }
                    EvButton { label: qsTr("Regressions"); small: true
                               enabledBtn: root.dt && !root.dt.checking
                               onClicked: if (root.dt) root.dt.runChecks("regressions") }
                    EvButton { label: qsTr("Stop"); small: true; variant: "danger"
                               enabledBtn: root.dt && root.dt.checking
                               onClicked: if (root.dt) root.dt.stopChecks() }
                    Item { Layout.fillWidth: true }
                    Text { text: root.dt ? root.dt.checkSummary : ""; color: Theme.ink2
                           font.family: Theme.fontMono; font.pixelSize: Theme.fsMono }
                }
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 10; Layout.rightMargin: 10; Layout.bottomMargin: 4
                    text: qsTr("These run the real analyser, evaluator, helper suite and "
                               + "existing regressions. The deliberate control is a check that "
                               + "MUST fail; the panel would be lying if it showed it green.")
                    color: Theme.ink3; font.family: Theme.fontSans
                    font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                }
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    model: root.dt ? root.dt.checks : []
                    delegate: Rectangle {
                        width: ListView.view.width
                        height: cdetail.implicitHeight + 24
                        color: "transparent"
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width
                                    height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 9
                            Rectangle {
                                width: 46; height: 16
                                color: modelData.status === "pass" ? Theme.goodDim
                                     : modelData.status === "fail" ? Theme.badDim : Theme.panel2
                                border.width: 1
                                border.color: modelData.status === "pass" ? Theme.good
                                            : modelData.status === "fail" ? Theme.bad : Theme.line2
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.status === "pass" ? qsTr("PASS")
                                        : modelData.status === "fail"
                                          ? (modelData.control ? qsTr("FAIL*") : qsTr("FAIL"))
                                        : qsTr("SKIP")
                                    color: modelData.status === "pass" ? Theme.good
                                         : modelData.status === "fail" ? Theme.bad : Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 8
                                    font.weight: Font.DemiBold
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.group + qsTr(" · ") + modelData.name
                                          + (modelData.control ? qsTr("   (deliberate control)") : "")
                                    color: Theme.ink; font.family: Theme.fontSans
                                    font.pixelSize: Theme.fsSmall; elide: Text.ElideRight
                                }
                                Text {
                                    id: cdetail
                                    Layout.fillWidth: true
                                    visible: modelData.detail !== ""
                                    text: modelData.detail
                                    color: Theme.ink3; font.family: Theme.fontMono
                                    font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                                }
                            }
                            Text { text: modelData.ms > 0 ? Math.round(modelData.ms) + qsTr(" ms") : ""
                                   color: Theme.ink3; font.family: Theme.fontMono
                                   font.pixelSize: Theme.fsLabel }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !root.dt || root.dt.checks.length === 0
                        text: root.dt && root.dt.checking ? qsTr("running the real suites…")
                                                          : qsTr("no checks run yet")
                        color: Theme.ink3; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsBody
                    }
                }
            }
        }
    }

    function targetDescription(targetId) {
        var info = root.dt ? root.dt.targetInfo : null
        var t = info ? info[targetId] : null
        return t ? (t.description || "") : ""
    }
    // The target's class lives in the annotation view (targetInfo), not in the
    // evaluator's result row: reading it from the row printed "undefined".
    function targetClass(targetId) {
        var info = root.dt ? root.dt.targetInfo : null
        var t = info ? info[targetId] : null
        return t ? (t["class"] || "?") : "?"
    }
    function requiredColour(targetId) {
        var info = root.dt ? root.dt.targetInfo : null
        var t = info ? info[targetId] : null
        if (!t || !t.required_colors || t.required_colors.length === 0) return qsTr("none")
        var out = []
        for (var i = 0; i < t.required_colors.length; i++)
            out.push(t.required_colors[i].region + " in {" +
                     t.required_colors[i].accepted_labels.join("/") + "}")
        return out.join(", ")
    }
    function seekToObservation(id) {
        if (!root.dt) return
        root.dt.selectObservation(id)
        for (var i = 0; i < root.dt.observations.length; i++) {
            var o = root.dt.observations[i]
            if (o.id === id && player.duration > 0) {
                player.position = Math.max(0, Math.min(o.frame_pts_ms, player.duration))
                selectTimer.start()
                break
            }
        }
    }
}
