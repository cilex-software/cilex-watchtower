import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import QtQuick.Dialogs
import QtMultimedia
import Watchtower

// Labs — Tracking workspace (LabsTrackingPanel; the MODEL is LabsTracking, src/models).
//
// Run the temporal tracking engine over a recording the operator
// picked inside Watchtower, review its tracks beside that recording, and run the
// verification checks. The analysis runs in its own process (LabsTracking), so
// decoding never blocks the UI and a cancelled run leaves nothing behind.
//
// WHAT IS DRAWN, AND WHAT IS NOT. The boxes come from the run's own per-frame
// evidence ledger: the most recent OBSERVED frame at or before the playhead, with
// its real timestamp and its age shown beside the picture. Nothing is interpolated
// to fit the player, and there is no box between observations. Dashed amber boxes
// are the engine's explicit abstentions (a cost tie or a possible merge) — not
// failures and not detections either. A track's polyline is the contract's bounded
// sample of REAL observed centres, each at its own timestamp.
Item {
    id: root

    property var tracking: null
    property var cameraModel: null

    readonly property var tr: tracking
    readonly property bool haveRun: tracking ? tracking.hasResult : false
    readonly property var probe: tracking ? tracking.probe : ({})
    readonly property var probeInfo: (probe && probe.probe) ? probe.probe : ({})
    readonly property real srcAspect: (probeInfo.width && probeInfo.height)
                                       ? (probeInfo.width / probeInfo.height) : (16 / 9)
    readonly property var sample: sampleCache
    property var sampleCache: ({ found: false })
    property string selectedTrack: ""
    property string rightTab: "tracks"
    property real pendingSeekMs: -1
    readonly property int playheadMs: player.position

    function timeText(ms) {
        if (ms === undefined || ms === null || isNaN(ms)) return "—"
        var s = Math.max(0, Math.floor(ms / 1000))
        var m = Math.floor(s / 60); s = s % 60
        var f = Math.floor(ms % 1000)
        return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s + "." +
               (f < 100 ? (f < 10 ? "00" : "0") : "") + f
    }

    function refreshSample() {
        if (!tr || !tr.hasResult) { sampleCache = { found: false }; return }
        sampleCache = tr.samplesAt(playheadMs)
        overlay.requestPaint()
    }

    function selectTrack(id, startMs) {
        selectedTrack = id
        rightTab = "tracks"
        if (startMs !== undefined && startMs !== null && startMs >= 0) {
            if (player.duration > 0) {
                player.position = Math.max(0, Math.min(startMs, player.duration))
            } else {
                pendingSeekMs = startMs          // applied when the media is ready
            }
        }
        refreshSample()
        overlay.requestPaint()
    }

    onTrackingChanged: {
        refreshSample()
        autoPick()
    }

    // A finished run opens its first track: the panel shows real observed boxes
    // instead of an empty picture, and the operator can step through the rest.
    function autoPick() {
        if (!tr || !tr.hasResult || root.selectedTrack !== "") return
        if (!tr.tracks || tr.tracks.length === 0) return
        var t = tr.tracks[0]
        selectTrack(t.track_id, t.start_ms)
    }
    onPlayheadMsChanged: sampleTimer.restart()

    // 10 Hz repaint: the ledger lookup happens at most ten times a second, not
    // once per decoded frame, so a wall of boxes cannot cost the UI its smoothness.
    Timer {
        id: sampleTimer
        interval: 100; repeat: false
        onTriggered: root.refreshSample()
    }
    Timer {
        interval: 250; running: player.playbackState === MediaPlayer.PlayingState
        repeat: true
        onTriggered: root.refreshSample()
    }

    Component.onCompleted: {
        if (tr) { tr.refreshRecordings(); tr.refreshRuns() }
        refreshSample()
    }

    // WT_LABS_TRACK_RECORDING / WT_LABS_TRACK_RUN (main.cpp): review hooks so a
    // screenshot can show a real run without a terminal.
    onTrChanged: {
        if (!tr) return
        tr.tracksChanged.connect(autoPick)
        if (typeof wtTrackRecording !== "undefined" && wtTrackRecording !== "" &&
                tr.recording !== wtTrackRecording)
            tr.recording = wtTrackRecording
        if (typeof wtTrackRun !== "undefined" && wtTrackRun === true)
            runTimer.start()
        if (typeof wtTrackChecks !== "undefined" && wtTrackChecks !== "") {
            rightTab = "checks"
            checksTimer.start()
        }
    }
    Timer {
        id: checksTimer
        interval: 900; repeat: false
        onTriggered: if (root.tr && !root.tr.checking) root.tr.startChecks(wtTrackChecks)
    }
    Timer {
        id: runTimer
        interval: 700; repeat: false
        onTriggered: if (root.tr && !root.tr.running) root.tr.start()
    }

    FileDialog {
        id: pickRecording
        title: qsTr("Choose a recording")
        nameFilters: [qsTr("Recordings (*.mp4 *.mkv *.mov *.ts *.m4v)"), qsTr("All files (*)")]
        onAccepted: if (root.tr) root.tr.recording = selectedFile
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ============================ source + run ============================
        Rectangle {
            Layout.preferredWidth: 322
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
                spacing: 10

                Text {
                    text: qsTr("TEMPORAL TRACKING")
                    color: Theme.ink3; font.family: Theme.fontMono
                    font.pixelSize: Theme.fsLabel; font.weight: Font.DemiBold
                    font.letterSpacing: 0.8
                }

                // --- status chip -------------------------------------------------
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 34
                    color: Theme.panel2; border.width: 1
                    border.color: root.tr && root.tr.status === "failed" ? Theme.badDim
                                : root.tr && root.tr.status === "completed" ? Theme.goodDim
                                : root.tr && root.tr.status === "cancelled" ? Theme.warnDim
                                : Theme.line2
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        spacing: 8
                        Rectangle {
                            width: 7; height: 7; radius: 0
                            color: !root.tr ? Theme.ink3
                                 : root.tr.status === "running" ? Theme.info
                                 : root.tr.status === "completed" ? Theme.good
                                 : root.tr.status === "cancelled" ? Theme.warn
                                 : root.tr.status === "failed" ? Theme.bad : Theme.ink3
                        }
                        Text {
                            Layout.fillWidth: true
                            text: !root.tr ? qsTr("No engine")
                                : root.tr.status === "idle" ? qsTr("IDLE — nothing run yet")
                                : root.tr.status === "running" ? qsTr("RUNNING")
                                : root.tr.status === "completed"
                                  ? (root.tr.summary && root.tr.summary.empty
                                     ? qsTr("COMPLETED · NO DETECTIONS")
                                     : qsTr("COMPLETED"))
                                : root.tr.status === "cancelled" ? qsTr("CANCELLED · PARTIAL")
                                : root.tr.status === "failed" ? qsTr("FAILED") : root.tr.status
                            color: Theme.ink; font.family: Theme.fontMono
                            font.pixelSize: Theme.fsMono; font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: root.tr ? root.tr.statusText : ""
                    color: Theme.ink2; font.family: Theme.fontSans
                    font.pixelSize: Theme.fsSmall; wrapMode: Text.WordWrap
                    visible: text !== ""
                }
                Text {
                    Layout.fillWidth: true
                    visible: root.tr && root.tr.errorText !== ""
                    text: root.tr ? (root.tr.errorCode + ": " + root.tr.errorText) : ""
                    color: Theme.bad; font.family: Theme.fontMono
                    font.pixelSize: Theme.fsMono; wrapMode: Text.WordWrap
                }

                QC.ProgressBar {
                    Layout.fillWidth: true
                    visible: root.tr && (root.tr.running || root.tr.progress > 0)
                    from: 0; to: 1; value: root.tr ? root.tr.progress : 0
                }

                // --- recording ---------------------------------------------------
                Text {
                    text: qsTr("RECORDING")
                    color: Theme.ink3; font.family: Theme.fontMono
                    font.pixelSize: Theme.fsLabel; font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    text: root.tr && root.tr.recording !== ""
                          ? root.tr.recordingName : qsTr("none selected")
                    color: root.tr && root.tr.recording !== "" ? Theme.ink : Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                    elide: Text.ElideMiddle
                    QC.ToolTip.visible: recMa.containsMouse
                    QC.ToolTip.text: root.tr ? root.tr.recording : ""
                    MouseArea { id: recMa; anchors.fill: parent; hoverEnabled: true }
                }
                Text {
                    Layout.fillWidth: true
                    visible: root.tr && root.tr.recording !== ""
                    text: {
                        if (!root.tr) return ""
                        var p = root.probeInfo
                        if (!p || !p.ok) return qsTr("container facts unknown")
                        var fps = (p.fps !== undefined) ? (Math.round(p.fps * 100) / 100) : "?"
                        return (p.width || "?") + "×" + (p.height || "?") + " · " +
                               fps + qsTr(" fps · ") + (p.codec || "?")
                    }
                    color: Theme.ink3; font.family: Theme.fontMono
                    font.pixelSize: Theme.fsLabel
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    EvButton {
                        label: qsTr("Exports…"); small: true; Layout.fillWidth: true
                        enabledBtn: root.tr && root.tr.recordings.length > 0
                        onClicked: recPopup.open()
                    }
                    EvButton {
                        label: qsTr("Browse…"); small: true; Layout.fillWidth: true
                        onClicked: pickRecording.open()
                    }
                }

                // The export list is the product's own folder, never a guess.
                QC.Popup {
                    id: recPopup
                    width: 420; height: 300
                    anchors.centerIn: parent
                    modal: true; focus: true
                    background: Rectangle { color: Theme.panel3; border.width: 1; border.color: Theme.line2 }
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 8
                        Text {
                            text: qsTr("Exports in ") + (root.tr ? root.tr.exportDir : "")
                            color: Theme.ink3; font.family: Theme.fontMono
                            font.pixelSize: Theme.fsLabel; elide: Text.ElideMiddle
                            Layout.fillWidth: true
                        }
                        ListView {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            clip: true
                            model: root.tr ? root.tr.recordings : []
                            delegate: Rectangle {
                                width: ListView.view.width; height: 46
                                color: ma2.containsMouse ? Theme.panel2 : "transparent"
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.right: parent.right
                                    anchors.margins: 8
                                    Text { text: modelData.name; color: Theme.ink
                                           font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                                           elide: Text.ElideMiddle; width: parent.width }
                                    Text { text: modelData.modified + " · " +
                                                 Math.round(modelData.bytes / 1048576) + " MB"
                                           color: Theme.ink3; font.family: Theme.fontMono
                                           font.pixelSize: Theme.fsLabel }
                                }
                                MouseArea {
                                    id: ma2; anchors.fill: parent; hoverEnabled: true
                                    onClicked: { root.tr.recording = modelData.path; recPopup.close() }
                                }
                            }
                        }
                    }
                }

                // --- scope + mapping ---------------------------------------------
                Text { text: qsTr("SCOPE AND TIME MAPPING"); color: Theme.ink3
                       font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                       font.weight: Font.DemiBold }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2; columnSpacing: 8; rowSpacing: 6
                    Text { text: qsTr("camera"); color: Theme.ink2; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel }
                    QC.TextField {
                        Layout.fillWidth: true
                        text: root.tr ? root.tr.cameraId : ""
                        placeholderText: qsTr("camera id")
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        onEditingFinished: if (root.tr) root.tr.cameraId = text
                    }
                    Text { text: qsTr("unit"); color: Theme.ink2; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel }
                    QC.TextField {
                        Layout.fillWidth: true
                        text: root.tr ? root.tr.unitId : ""
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        onEditingFinished: if (root.tr) root.tr.unitId = text
                    }
                    Text { text: qsTr("start"); color: Theme.ink2; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel }
                    QC.TextField {
                        Layout.fillWidth: true
                        text: root.tr ? root.tr.startUtc : ""
                        placeholderText: qsTr("recording start (UTC)")
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        onEditingFinished: if (root.tr) root.tr.startUtc = text
                    }
                    Text { text: qsTr("frames"); color: Theme.ink2; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel }
                    QC.SpinBox {
                        Layout.fillWidth: true
                        from: 10; to: 20000; stepSize: 150
                        value: root.tr ? root.tr.maxFrames : 900
                        editable: true
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        onValueModified: if (root.tr) root.tr.maxFrames = value
                    }
                    Text { text: qsTr("offset"); color: Theme.ink2; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel }
                    QC.SpinBox {
                        Layout.fillWidth: true
                        from: 0; to: 36000; stepSize: 10
                        value: root.tr ? root.tr.startOffsetS : 0
                        editable: true
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        onValueModified: if (root.tr) root.tr.startOffsetS = value
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: root.tr && root.tr.recording !== ""
                          ? qsTr("start source: ") + root.tr.startSource
                          : ""
                    color: Theme.ink3; font.family: Theme.fontMono
                    font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                    visible: text !== ""
                }
                Text {
                    Layout.fillWidth: true
                    visible: root.tr && root.tr.summary && root.tr.summary.recording_sha256 !== undefined
                    text: qsTr("input sha256 ") + (root.tr && root.tr.summary
                          ? String(root.tr.summary.recording_sha256).substring(0, 16) : "")
                    color: Theme.ink3; font.family: Theme.fontMono
                    font.pixelSize: Theme.fsLabel
                }

                // --- engine knobs ------------------------------------------------
                Text { text: qsTr("ENGINE"); color: Theme.ink3; font.family: Theme.fontMono
                       font.pixelSize: Theme.fsLabel; font.weight: Font.DemiBold }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2; columnSpacing: 8; rowSpacing: 6
                    Text { text: qsTr("path pts"); color: Theme.ink2; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel }
                    QC.SpinBox {
                        Layout.fillWidth: true; from: 2; to: 128; value: pathSpin
                        editable: true
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        onValueModified: root.applyConfig("path_points", value)
                    }
                    Text { text: qsTr("gap ms"); color: Theme.ink2; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel }
                    QC.SpinBox {
                        Layout.fillWidth: true; from: 1; to: 10000; stepSize: 100; value: gapSpin
                        editable: true
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        onValueModified: root.applyConfig("max_gap_ms", value)
                    }
                    Text { text: qsTr("margin"); color: Theme.ink2; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel }
                    QC.SpinBox {
                        Layout.fillWidth: true; from: 0; to: 1000000; stepSize: 500; value: marginSpin
                        editable: true
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        onValueModified: root.applyConfig("ambiguity_margin", value)
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Only these three are exposed here; anything else uses the contract's default.")
                    color: Theme.ink3; font.family: Theme.fontSans
                    font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    EvButton {
                        label: root.tr && root.tr.running ? qsTr("Cancel") : qsTr("Run analysis")
                        variant: root.tr && root.tr.running ? "danger" : "pri"
                        Layout.fillWidth: true
                        enabledBtn: root.tr && (root.tr.running || root.tr.recording !== "")
                        onClicked: if (root.tr) { root.tr.running ? root.tr.cancel() : root.tr.start() }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.line }

                // --- saved runs --------------------------------------------------
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: qsTr("SAVED RUNS"); color: Theme.ink3; font.family: Theme.fontMono
                           font.pixelSize: Theme.fsLabel; font.weight: Font.DemiBold
                           Layout.fillWidth: true }
                    Text {
                        text: qsTr("refresh"); color: rma.containsMouse ? Theme.accent : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                        MouseArea { id: rma; anchors.fill: parent; hoverEnabled: true
                                    onClicked: if (root.tr) root.tr.refreshRuns() }
                    }
                }
                ListView {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(220, Math.max(60,
                        (root.tr ? root.tr.runs.length : 0) * 40))
                    clip: true
                    model: root.tr ? root.tr.runs : []
                    delegate: Rectangle {
                        width: ListView.view.width; height: 40
                        color: rma2.containsMouse ? Theme.panel2 : "transparent"
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left; anchors.right: parent.right
                            Text {
                                text: modelData.id + "  ·  " + modelData.status
                                color: modelData.status === "completed" ? Theme.ink
                                     : modelData.status === "cancelled" ? Theme.warn : Theme.bad
                                font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                                elide: Text.ElideRight; width: parent.width
                            }
                            Text {
                                text: (modelData.recording || "?") + " · " + modelData.frames +
                                      qsTr(" frames · ") + modelData.tracks + qsTr(" tracks")
                                color: Theme.ink3; font.family: Theme.fontMono
                                font.pixelSize: Theme.fsLabel; elide: Text.ElideRight
                                width: parent.width
                            }
                        }
                        MouseArea {
                            id: rma2; anchors.fill: parent; hoverEnabled: true
                            onClicked: if (root.tr) root.tr.openRun(modelData.dir)
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

            // --- player + overlay ---------------------------------------------
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
                        source: (root.tr && root.tr.recording !== "")
                                ? "file://" + root.tr.recording : ""
                        videoOutput: videoOut
                        audioOutput: null
                        onPositionChanged: root.refreshSample()
                        onDurationChanged: (dur) => {
                            if (dur > 0 && root.pendingSeekMs >= 0) {
                                player.position = Math.min(root.pendingSeekMs, dur)
                                root.pendingSeekMs = -1
                                root.refreshSample()
                            }
                        }
                    }
                    VideoOutput {
                        id: videoOut
                        anchors.fill: parent
                        fillMode: VideoOutput.PreserveAspectFit
                    }

                    // No recording yet: an honest empty state, never a black frame
                    // pretending to be footage.
                    Text {
                        anchors.centerIn: parent
                        visible: !root.tr || root.tr.recording === ""
                        text: qsTr("Choose a recording to review tracks against")
                        color: Theme.ink3; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsBody
                    }

                    Canvas {
                        id: overlay
                        anchors.fill: parent
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            if (!root.tr || !root.tr.hasResult) return
                            var W = width, H = height

                            // the selected track's bounded OBSERVED samples
                            if (root.selectedTrack !== "") {
                                var pts = root.tr.trackSamples(root.selectedTrack)
                                ctx.strokeStyle = Theme.accent
                                ctx.lineWidth = 1.5
                                ctx.beginPath()
                                for (var i = 0; i < pts.length; i++) {
                                    var px = pts[i][1] * W, py = pts[i][2] * H
                                    if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
                                }
                                ctx.stroke()
                                ctx.fillStyle = Theme.accent
                                for (var j = 0; j < pts.length; j++) {
                                    ctx.beginPath()
                                    ctx.arc(pts[j][1] * W, pts[j][2] * H, 2.0, 0, 2 * Math.PI)
                                    ctx.fill()
                                }
                            }

                            // the current OBSERVED sample's boxes
                            var s = root.sampleCache
                            if (!s || !s.found || !s.detections) return
                            for (var k = 0; k < s.detections.length; k++) {
                                var d = s.detections[k]
                                var b = d.bbox
                                var x = b[0] * W, y = b[1] * H, w = b[2] * W, h = b[3] * H
                                var ambiguous = d.status === "ambiguous"
                                ctx.strokeStyle = ambiguous ? Theme.warn
                                                : d.track_id === root.selectedTrack ? Theme.accent
                                                : d.status === "born" ? Theme.info : Theme.good
                                ctx.lineWidth = d.track_id === root.selectedTrack ? 2.0 : 1.2
                                ctx.setLineDash(ambiguous ? [4, 3] : [])
                                ctx.strokeRect(x, y, w, h)
                                ctx.setLineDash([])
                                ctx.fillStyle = ctx.strokeStyle
                                ctx.font = "10px " + Theme.fontMono
                                var label = ambiguous ? (d.reason || "ambiguous")
                                                      : (d.track_id || d.status)
                                ctx.fillText(label, x, Math.max(10, y - 2))
                            }
                        }
                    }
                }

                // overlay legend — says exactly which instant is on screen
                Rectangle {
                    anchors.left: parent.left; anchors.bottom: parent.bottom
                    anchors.margins: 10
                    width: legend.implicitWidth + 16; height: legend.implicitHeight + 12
                    color: Qt.rgba(0, 0, 0, 0.55); border.width: 1; border.color: Theme.line2
                    Text {
                        id: legend
                        anchors.centerIn: parent
                        color: Theme.ink2; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsMono
                        text: {
                            if (!root.tr || !root.tr.hasResult)
                                return qsTr("no analysis loaded")
                            var s = root.sampleCache
                            if (!s || !s.found)
                                return s && s.firstMs !== undefined
                                    ? qsTr("before the first analysed frame (starts at ")
                                      + root.timeText(s.firstMs) + ")"
                                    : qsTr("no frames in this run")
                            var n = s.detections ? s.detections.length : 0
                            return qsTr("observed sample ") + root.timeText(s.t_ms) +
                                   qsTr("  ·  ") + n + qsTr(" detection") + (n === 1 ? "" : "s") +
                                   qsTr("  ·  ") + Math.round(s.age_ms) + qsTr(" ms before playhead")
                        }
                    }
                }
            }

            // --- transport -----------------------------------------------------
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 38
                color: Theme.panel
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    spacing: 8
                    EvButton {
                        label: player.playbackState === MediaPlayer.PlayingState
                               ? qsTr("Pause") : qsTr("Play"); small: true
                        enabledBtn: root.tr && root.tr.recording !== ""
                        onClicked: player.playbackState === MediaPlayer.PlayingState
                                   ? player.pause() : player.play()
                    }
                    Text { text: root.timeText(player.position); color: Theme.ink
                           font.family: Theme.fontMono; font.pixelSize: Theme.fsMono }
                    QC.Slider {
                        id: seek
                        Layout.fillWidth: true
                        from: 0; to: Math.max(1, player.duration); value: player.position
                        enabled: player.duration > 0
                        onMoved: player.position = value
                    }
                    Text { text: root.timeText(player.duration); color: Theme.ink3
                           font.family: Theme.fontMono; font.pixelSize: Theme.fsMono }
                }
            }

            // --- tracks | verification -----------------------------------------
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                color: Theme.bg
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                    spacing: 12
                    LabsSeg {
                        choices: [ { k: qsTr("Tracks"), v: "tracks" },
                                   { k: qsTr("Verification"), v: "checks" } ]
                        value: root.rightTab
                        onPicked: (v) => root.rightTab = v
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        visible: root.rightTab === "tracks"
                        text: root.tr ? (root.tr.tracks.length + qsTr(" tracks · ") +
                              (root.tr.summary && root.tr.summary.frames !== undefined
                               ? root.tr.summary.frames + qsTr(" frames · ") : "") +
                              (root.tr.summary && root.tr.summary.detections !== undefined
                               ? root.tr.summary.detections + qsTr(" detections") : "")) : ""
                        color: Theme.ink3; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsLabel
                    }
                    Text {
                        visible: root.rightTab === "tracks" && root.tr && root.tr.summary &&
                                 root.tr.summary.model_runs > 1
                        text: qsTr("model rebuilt ") + (root.tr && root.tr.summary
                              ? root.tr.summary.model_runs - 1 : 0) + qsTr("× — each rebuild resets tracks")
                        color: Theme.ink3; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsLabel
                    }
                }
            }

            // ---- tracks ----
            RowLayout {
                visible: root.rightTab === "tracks"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 260
                Layout.preferredHeight: 340
                spacing: 0

                ListView {
                    Layout.preferredWidth: 430
                    Layout.fillHeight: true
                    clip: true
                    model: root.tr ? root.tr.tracks : []
                    delegate: Rectangle {
                        width: ListView.view.width
                        height: 54
                        color: root.selectedTrack === modelData.track_id ? Theme.accentSoft
                             : tma.containsMouse ? Theme.panel2 : "transparent"
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width
                                    height: 1; color: Theme.line }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.margins: 12
                            spacing: 2
                            RowLayout {
                                width: parent.width - 24; spacing: 8
                                Text { text: modelData.track_id; color: Theme.ink
                                       font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                                       font.weight: Font.DemiBold }
                                Rectangle {
                                    visible: modelData.uncertain
                                    width: uncert.implicitWidth + 10; height: 15
                                    color: Theme.warnDim; border.width: 1; border.color: Theme.warn
                                    Text { id: uncert; anchors.centerIn: parent
                                           text: qsTr("UNCERTAIN"); color: Theme.warn
                                           font.family: Theme.fontMono; font.pixelSize: 8
                                           font.weight: Font.DemiBold }
                                }
                                Item { Layout.fillWidth: true }
                                Text { text: modelData.reason; color: Theme.ink3
                                       font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel }
                            }
                            Text { text: modelData.timing; color: Theme.ink2
                                   font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel }
                            Text { text: modelData.counts; color: Theme.ink3
                                   font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel }
                        }
                        MouseArea {
                            id: tma; anchors.fill: parent; hoverEnabled: true
                            onClicked: root.selectTrack(modelData.track_id, modelData.start_ms)
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !root.tr || root.tr.tracks.length === 0
                        text: root.tr && root.tr.running ? qsTr("analysing…")
                             : root.tr && root.tr.hasResult ? qsTr("no tracks in this run")
                             : qsTr("no analysis yet")
                        color: Theme.ink3; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsBody
                    }
                }

                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.line }

                // detail of the selected track
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 14
                    spacing: 8
                    Text {
                        text: root.selectedTrack === "" ? qsTr("SELECT A TRACK")
                                                        : root.selectedTrack
                        color: root.selectedTrack === "" ? Theme.ink3 : Theme.ink
                        font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                        font.weight: Font.DemiBold
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.selectedTrack !== ""
                        color: Theme.ink2; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsSmall; wrapMode: Text.WordWrap
                        text: {
                            var t = root.selectedTrackDetail
                            if (!t) return ""
                            return qsTr("observed ") + t.observations + qsTr(" times at real frame instants · ") +
                                   t.ambiguous_batches + qsTr(" batch(es) abstained as ambiguous · end: ") +
                                   t.reason + qsTr("\nlargest box at ") +
                                   root.timeText(t.bbox_at_ms) + qsTr(", observed path length ") +
                                   (Math.round(t.path_length * 1000) / 1000) + qsTr(", net displacement ") +
                                   (Math.round(t.net_displacement * 1000) / 1000) +
                                   (t.mean_speed === null ? qsTr(", mean speed n/a (single instant)")
                                                          : qsTr(", mean speed ") + (Math.round(t.mean_speed * 1000) / 1000)) +
                                   qsTr("\nworst observation gap ") + t.max_observation_gap_ms +
                                   qsTr(" ms · click the row to seek the recording to ") +
                                   root.timeText(t.start_ms)
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.selectedTrack !== ""
                        color: Theme.ink3; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                        text: qsTr("The polyline is the contract's bounded sample of observed centres — ") +
                              (root.selectedTrackDetail && root.selectedTrackDetail.path
                               ? root.selectedTrackDetail.path.length : 0) +
                              qsTr(" of the ") +
                              (root.selectedTrackDetail ? root.selectedTrackDetail.observations : 0) +
                              qsTr(" observations. No interpolated point is drawn anywhere.")
                    }
                }
            }

            // ---- verification ----
            ColumnLayout {
                visible: root.rightTab === "checks"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 260
                Layout.preferredHeight: 340
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 12
                    spacing: 8
                    EvButton { label: qsTr("All checks"); small: true
                               enabledBtn: root.tr && !root.tr.checking
                               onClicked: if (root.tr) root.tr.startChecks("all") }
                    EvButton { label: qsTr("Contract"); small: true
                               enabledBtn: root.tr && !root.tr.checking
                               onClicked: if (root.tr) root.tr.startChecks("contract") }
                    EvButton { label: qsTr("Regressions"); small: true
                               enabledBtn: root.tr && !root.tr.checking
                               onClicked: if (root.tr) root.tr.startChecks("regression") }
                    EvButton { label: qsTr("Workload"); small: true
                               enabledBtn: root.tr && !root.tr.checking
                               onClicked: if (root.tr) root.tr.startChecks("workload") }
                    EvButton { label: qsTr("Integration"); small: true
                               enabledBtn: root.tr && !root.tr.checking
                               onClicked: if (root.tr) root.tr.startChecks("integration") }
                    EvButton { label: qsTr("Stop"); small: true; variant: "danger"
                               enabledBtn: root.tr && root.tr.checking
                               onClicked: if (root.tr) root.tr.stopChecks() }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.tr ? root.tr.checkSummary : ""
                        color: Theme.ink2; font.family: Theme.fontMono
                        font.pixelSize: Theme.fsMono
                    }
                }
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 6
                    text: qsTr("These execute the real suites and the real engine in this checkout; "
                               + "the deliberate control is a check that MUST fail, and the panel "
                               + "would be lying if it showed it green.")
                    color: Theme.ink3; font.family: Theme.fontSans
                    font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.tr ? root.tr.checks : []
                    delegate: Rectangle {
                        width: ListView.view.width
                        height: detailText.implicitHeight + 26
                        color: "transparent"
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width
                                    height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                            spacing: 10
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
                                    id: detailText
                                    Layout.fillWidth: true
                                    visible: modelData.detail !== ""
                                    text: modelData.detail
                                    color: Theme.ink3; font.family: Theme.fontMono
                                    font.pixelSize: Theme.fsLabel; wrapMode: Text.WordWrap
                                }
                            }
                            Text {
                                text: modelData.ms > 0 ? Math.round(modelData.ms) + qsTr(" ms") : ""
                                color: Theme.ink3; font.family: Theme.fontMono
                                font.pixelSize: Theme.fsLabel
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !root.tr || root.tr.checks.length === 0
                        text: root.tr && root.tr.checking ? qsTr("running the real suites…")
                                                          : qsTr("no checks run yet")
                        color: Theme.ink3; font.family: Theme.fontSans
                        font.pixelSize: Theme.fsBody
                    }
                }
            }
        }
    }

    // --- helpers -------------------------------------------------------------
    readonly property var selectedTrackDetail: {
        if (!root.tr || root.selectedTrack === "") return null
        for (var i = 0; i < root.tr.tracks.length; i++)
            if (root.tr.tracks[i].track_id === root.selectedTrack) return root.tr.tracks[i]
        return null
    }
    readonly property int pathSpin: engineValue("path_points", 32)
    readonly property int gapSpin: engineValue("max_gap_ms", 2000)
    readonly property int marginSpin: engineValue("ambiguity_margin", 1000)

    function engineValue(key, fallback) {
        if (!root.tr) return fallback
        var cfg = root.tr.engineConfig
        return (cfg && cfg[key] !== undefined) ? cfg[key] : fallback
    }
    function applyConfig(key, value) {
        if (!root.tr) return
        var cfg = {}
        for (var k in root.tr.engineConfig) cfg[k] = root.tr.engineConfig[k]
        cfg[key] = value
        root.tr.engineConfig = cfg
    }
}
