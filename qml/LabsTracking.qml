import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import QtMultimedia
import Watchtower

Item {
    id: trackingRoot

    property var screen: null
    property var cameraModel: null

    LabsTrackingController {
        id: ctrl
    }

    property string subView: "verification" // "verification" | "recording" | "evidence"

    Component.onCompleted: {
        if (typeof wtTrackingSubView !== "undefined" && wtTrackingSubView !== "") {
            subView = wtTrackingSubView;
        }
        if (typeof wtTrackingFailControl !== "undefined" && wtTrackingFailControl) {
            ctrl.deliberateFailure = true;
        }
        if (typeof wtTrackingAutoRun !== "undefined" && wtTrackingAutoRun) {
            ctrl.startVerification();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Sub-navigation bar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 18
                anchors.rightMargin: 18
                spacing: 12

                Text {
                    text: qsTr("Temporal Tracking")
                    color: Theme.ink
                    font.family: Theme.fontSans
                    font.pixelSize: 15
                    font.weight: Font.Bold
                }

                Rectangle {
                    visible: trackingRoot.subView === "verification"
                    width: demoBadge.implicitWidth + 12
                    height: 20
                    radius: 3
                    color: Theme.accentSoft
                    border.color: Theme.accent
                    border.width: 1
                    Text {
                        id: demoBadge
                        anchors.centerIn: parent
                        text: qsTr("WT_DEMO / VERIFICATION")
                        color: Theme.accent
                        font.family: Theme.fontMono
                        font.pixelSize: 9
                        font.weight: Font.Bold
                    }
                }

                Item { Layout.fillWidth: true }

                LabsSeg {
                    choices: [
                        { k: qsTr("In-App Verification"), v: "verification" },
                        { k: qsTr("Recording Analysis"), v: "recording" },
                        { k: qsTr("Evidence Archive"), v: "evidence" }
                    ]
                    value: trackingRoot.subView
                    onPicked: (v) => trackingRoot.subView = v
                }
            }
        }

        // =====================================================================
        // VIEW 1: IN-APP VERIFICATION
        // =====================================================================
        ColumnLayout {
            visible: trackingRoot.subView === "verification"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Control and summary strip
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 52
                color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 18
                    spacing: 14

                    Rectangle {
                        id: runBtn
                        implicitWidth: runTxt.implicitWidth + 28
                        implicitHeight: 32
                        radius: 3
                        color: ctrl.state === "running" ? Theme.panel2 : (runMa.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent)
                        Text {
                            id: runTxt
                            anchors.centerIn: parent
                            text: ctrl.state === "running" ? qsTr("Running…") : qsTr("Run Verification")
                            color: ctrl.state === "running" ? Theme.ink3 : Theme.bg
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                        }
                        MouseArea {
                            id: runMa
                            anchors.fill: parent
                            cursorShape: ctrl.state === "running" ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: if (ctrl.state !== "running") ctrl.startVerification()
                        }
                    }

                    Rectangle {
                        visible: ctrl.state === "running"
                        implicitWidth: cancelTxt.implicitWidth + 24
                        implicitHeight: 32
                        radius: 3
                        color: Theme.bg
                        border.color: Theme.bad
                        border.width: 1
                        Text {
                            id: cancelTxt
                            anchors.centerIn: parent
                            text: qsTr("Cancel")
                            color: Theme.bad
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ctrl.cancel()
                        }
                    }

                    // Checkbox: Deliberate failure control
                    Row {
                        spacing: 6
                        Rectangle {
                            width: 16; height: 16; radius: 3; color: Theme.bg; border.color: Theme.line2; border.width: 1
                            anchors.verticalCenter: parent.verticalCenter
                            Rectangle {
                                anchors.centerIn: parent
                                width: 10; height: 10; radius: 2; color: Theme.bad
                                visible: ctrl.deliberateFailure
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: ctrl.deliberateFailure = !ctrl.deliberateFailure
                            }
                        }
                        Text {
                            text: qsTr("Deliberate Failure Control")
                            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    // Checkbox: Section 13 workload
                    Row {
                        spacing: 6
                        Rectangle {
                            width: 16; height: 16; radius: 3; color: Theme.bg; border.color: Theme.line2; border.width: 1
                            anchors.verticalCenter: parent.verticalCenter
                            Rectangle {
                                anchors.centerIn: parent
                                width: 10; height: 10; radius: 2; color: Theme.accent
                                visible: ctrl.runWorkload
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: ctrl.runWorkload = !ctrl.runWorkload
                            }
                        }
                        Text {
                            text: qsTr("Section 13 Workload (100k batches)")
                            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        visible: ctrl.state === "completed"
                        implicitWidth: saveTxt.implicitWidth + 24
                        implicitHeight: 32
                        radius: 3
                        color: Theme.bg
                        border.color: Theme.line2
                        border.width: 1
                        Text {
                            id: saveTxt
                            anchors.centerIn: parent
                            text: qsTr("Save Evidence")
                            color: Theme.ink
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ctrl.saveEvidence("verification_run")
                        }
                    }
                }
            }

            // Metrics summary strip
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                color: Theme.bg
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 18
                    spacing: 24

                    Column {
                        spacing: 4
                        Text {
                            text: ctrl.summary.total ? (ctrl.summary.passed + " / " + ctrl.summary.total) : "—"
                            color: ctrl.summary.failed > 0 ? Theme.bad : Theme.good
                            font.family: Theme.fontSans; font.pixelSize: 22; font.weight: Font.Bold
                        }
                        Text { text: qsTr("PASS RATE"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    }

                    Rectangle { width: 1; height: 40; color: Theme.line }

                    Column {
                        spacing: 4
                        Text {
                            text: ctrl.summary.elapsed_seconds !== undefined ? (ctrl.summary.elapsed_seconds + " s") : "—"
                            color: Theme.ink
                            font.family: Theme.fontSans; font.pixelSize: 22; font.weight: Font.Bold
                        }
                        Text { text: qsTr("ELAPSED TIME"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    }

                    Rectangle { width: 1; height: 40; color: Theme.line }

                    Column {
                        spacing: 4
                        Text {
                            text: ctrl.summary.max_snapshot_bytes !== undefined ? (Math.round(ctrl.summary.max_snapshot_bytes / 1024) + " KB") : "—"
                            color: Theme.ink
                            font.family: Theme.fontSans; font.pixelSize: 22; font.weight: Font.Bold
                        }
                        Text { text: qsTr("MAX CHECKPOINT"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    }

                    Rectangle { width: 1; height: 40; color: Theme.line }

                    Column {
                        spacing: 4
                        Text {
                            text: ctrl.summary.failure_control_active ? (ctrl.summary.failure_control_passed ? qsTr("VERIFIED") : qsTr("FAILED")) : qsTr("OFF")
                            color: ctrl.summary.failure_control_passed ? Theme.good : Theme.ink3
                            font.family: Theme.fontSans; font.pixelSize: 22; font.weight: Font.Bold
                        }
                        Text { text: qsTr("FAILURE CONTROL"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: ctrl.statusMessage
                        color: Theme.ink2
                        font.family: Theme.fontMono
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }
            }

            // Tests Table
            ListView {
                id: testList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: ctrl.testCases

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: testList.width
                    height: 40
                    color: index % 2 === 0 ? Theme.bg : Theme.panel

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: Theme.line
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 18
                        anchors.rightMargin: 18
                        spacing: 12

                        Rectangle {
                            width: 60; height: 22; radius: 3
                            color: modelData.status === "pass" ? Theme.goodSoft
                                 : modelData.status === "fail" ? Theme.badSoft
                                 : modelData.status === "running" ? Theme.accentSoft : Theme.panel2
                            border.color: modelData.status === "pass" ? Theme.good
                                        : modelData.status === "fail" ? Theme.bad
                                        : modelData.status === "running" ? Theme.accent : Theme.line2
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: modelData.status ? modelData.status.toUpperCase() : "PENDING"
                                color: modelData.status === "pass" ? Theme.good
                                     : modelData.status === "fail" ? Theme.bad
                                     : modelData.status === "running" ? Theme.accent : Theme.ink3
                                font.family: Theme.fontMono
                                font.pixelSize: 10
                                font.weight: Font.Bold
                            }
                        }

                        Text {
                            text: modelData.name || ""
                            color: Theme.ink
                            font.family: Theme.fontMono
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            Layout.preferredWidth: 320
                            elide: Text.ElideRight
                        }

                        Text {
                            text: modelData.family || ""
                            color: Theme.ink3
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                            Layout.preferredWidth: 200
                        }

                        Text {
                            text: modelData.durationMs !== undefined ? (modelData.durationMs + " ms") : ""
                            color: Theme.ink3
                            font.family: Theme.fontMono
                            font.pixelSize: 11
                            Layout.preferredWidth: 80
                        }

                        Text {
                            Layout.fillWidth: true
                            text: modelData.error ? modelData.error : (modelData.details || "")
                            color: modelData.error ? Theme.bad : Theme.ink2
                            font.family: Theme.fontSans
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }

        // =====================================================================
        // VIEW 2: REAL RECORDING ANALYSIS & REPLAY
        // =====================================================================
        RowLayout {
            visible: trackingRoot.subView === "recording"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Left Column: Parameters, status, and track findings
            Rectangle {
                Layout.preferredWidth: 380
                Layout.fillHeight: true
                color: Theme.panel
                Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.right: parent.right; width: 1; color: Theme.line }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 12

                    Text {
                        text: qsTr("Recording Input")
                        color: Theme.ink
                        font.family: Theme.fontSans
                        font.pixelSize: 13
                        font.weight: Font.Bold
                    }

                    QC.TextField {
                        id: pathField
                        Layout.fillWidth: true
                        placeholderText: qsTr("Path to recording / export file (.mp4, .ts, .mkv)")
                        text: ctrl.recordingPath
                        onTextChanged: ctrl.recordingPath = text
                        font.family: Theme.fontMono
                        font.pixelSize: 11
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Rectangle {
                            Layout.fillWidth: true
                            height: 32
                            radius: 3
                            color: Theme.accent
                            Text {
                                anchors.centerIn: parent
                                text: qsTr("Start Analysis")
                                color: Theme.bg
                                font.family: Theme.fontSans
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: ctrl.startRecordingAnalysis(pathField.text)
                            }
                        }
                    }

                    // Recording Status Badge
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 70
                        radius: 4
                        color: ctrl.recordingStatus === "completed" ? Theme.goodSoft : (ctrl.recordingStatus === "not_verified" ? Theme.warnSoft : Theme.panel2)
                        border.color: ctrl.recordingStatus === "completed" ? Theme.good : (ctrl.recordingStatus === "not_verified" ? Theme.warn : Theme.line2)
                        border.width: 1

                        Column {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4
                            Row {
                                spacing: 6
                                Text {
                                    text: qsTr("Status:")
                                    font.family: Theme.fontMono
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                    color: Theme.ink
                                }
                                Text {
                                    text: ctrl.recordingStatus === "completed" ? qsTr("COMPLETED")
                                        : ctrl.recordingStatus === "not_verified" ? qsTr("NOT VERIFIED")
                                        : ctrl.recordingStatus.toUpperCase()
                                    font.family: Theme.fontMono
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                    color: ctrl.recordingStatus === "completed" ? Theme.good : Theme.warn
                                }
                            }
                            Text {
                                width: parent.width
                                text: ctrl.recordingStatusNote
                                font.family: Theme.fontSans
                                font.pixelSize: 11
                                color: Theme.ink2
                                wrapMode: Text.Wrap
                            }
                        }
                    }

                    Text {
                        text: qsTr("Detected Tracks (%1)").arg(ctrl.tracks.length)
                        color: Theme.ink
                        font.family: Theme.fontSans
                        font.pixelSize: 13
                        font.weight: Font.Bold
                    }

                    // Track List
                    ListView {
                        id: trackListView
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: ctrl.tracks

                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            width: trackListView.width
                            height: 56
                            color: ctrl.selectedTrackIndex === index ? Theme.accentSoft : (tMa.containsMouse ? Theme.panel2 : Theme.bg)
                            border.color: ctrl.selectedTrackIndex === index ? Theme.accent : Theme.line
                            border.width: 1

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 8

                                Column {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text {
                                        text: modelData.track_id || ""
                                        color: Theme.ink
                                        font.family: Theme.fontMono
                                        font.pixelSize: 12
                                        font.weight: Font.Bold
                                    }
                                    Text {
                                        text: qsTr("%1 observations · %2 s · %3 ms gap").arg(modelData.observations || 0).arg(Math.round(((modelData.end_ms - modelData.start_ms)/1000)*10)/10).arg(modelData.max_observation_gap_ms || 0)
                                        color: Theme.ink3
                                        font.family: Theme.fontSans
                                        font.pixelSize: 11
                                    }
                                }

                                Text {
                                    text: modelData.reason ? modelData.reason.toUpperCase() : ""
                                    color: Theme.accent
                                    font.family: Theme.fontMono
                                    font.pixelSize: 10
                                    font.weight: Font.DemiBold
                                }
                            }

                            MouseArea {
                                id: tMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    ctrl.selectTrack(index);
                                    if (mediaPlayer.seekable && modelData.start_ms !== undefined) {
                                        mediaPlayer.position = modelData.start_ms;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Right Column: Video Playback & Trajectory Canvas
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Stage Area
                Rectangle {
                    id: stageArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "#0a0c10"

                    MediaPlayer {
                        id: mediaPlayer
                        source: ctrl.recordingPath ? ("file://" + ctrl.recordingPath) : ""
                        videoOutput: videoOutput
                    }

                    VideoOutput {
                        id: videoOutput
                        anchors.fill: parent
                        visible: ctrl.recordingPath !== "" && mediaPlayer.hasVideo
                    }

                    // Trajectory & Bounding Box Overlay Canvas
                    Canvas {
                        id: overlayCanvas
                        anchors.fill: parent
                        visible: Boolean(ctrl.selectedTrack && ctrl.selectedTrack.path)

                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            if (!ctrl.selectedTrack || !ctrl.selectedTrack.path) return;

                            var path = ctrl.selectedTrack.path;
                            if (path.length === 0) return;

                            // Draw Trajectory line
                            ctx.beginPath();
                            ctx.strokeStyle = "#38bdf8"; // cyan path
                            ctx.lineWidth = 2.5;

                            for (var i = 0; i < path.length; i++) {
                                var pt = path[i];
                                var px = pt[1] * width;
                                var py = pt[2] * height;
                                if (i === 0) ctx.moveTo(px, py);
                                else ctx.lineTo(px, py);
                            }
                            ctx.stroke();

                            // Draw observation sample points
                            for (var j = 0; j < path.length; j++) {
                                var opt = path[j];
                                var ox = opt[1] * width;
                                var oy = opt[2] * height;
                                ctx.beginPath();
                                ctx.arc(ox, oy, 4, 0, 2 * Math.PI);
                                ctx.fillStyle = "#38bdf8";
                                ctx.fill();
                            }

                            // Draw largest bounding box
                            var bbox = ctrl.selectedTrack.bbox;
                            if (bbox && bbox.length === 4) {
                                ctx.beginPath();
                                ctx.strokeStyle = "#22c55e"; // green box for observed bounding box
                                ctx.lineWidth = 2;
                                ctx.strokeRect(bbox[0] * width, bbox[1] * height, bbox[2] * width, bbox[3] * height);

                                ctx.fillStyle = "rgba(34, 197, 94, 0.15)";
                                ctx.fillRect(bbox[0] * width, bbox[1] * height, bbox[2] * width, bbox[3] * height);
                            }
                        }
                    }

                    Connections {
                        target: ctrl
                        function onSelectedTrackChanged() {
                            overlayCanvas.requestPaint();
                        }
                    }

                    // If no video or synthetic mode: coordinate grid display
                    Text {
                        anchors.centerIn: parent
                        visible: !mediaPlayer.hasVideo
                        text: ctrl.selectedTrack && ctrl.selectedTrack.track_id
                            ? qsTr("Track %1 trajectory (%2 path points)\n[Normalized coordinate space 0..1]").arg(ctrl.selectedTrack.track_id).arg(ctrl.selectedTrack.path ? ctrl.selectedTrack.path.length : 0)
                            : qsTr("Select a track to inspect its trajectory and bounding box overlay.")
                        color: Theme.ink3
                        font.family: Theme.fontMono
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                // Transport scrubber
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    color: Theme.panel
                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        spacing: 10

                        Rectangle {
                            width: 28; height: 24; radius: 3; color: Theme.bg; border.color: Theme.line2; border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: mediaPlayer.playbackState === MediaPlayer.PlayingState ? "⏸" : "▶"
                                color: Theme.ink
                                font.pixelSize: 11
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (mediaPlayer.playbackState === MediaPlayer.PlayingState) mediaPlayer.pause();
                                    else mediaPlayer.play();
                                }
                            }
                        }

                        QC.Slider {
                            id: timeSlider
                            Layout.fillWidth: true
                            from: 0
                            to: Math.max(1, mediaPlayer.duration)
                            value: mediaPlayer.position
                            onMoved: mediaPlayer.position = value
                        }

                        Text {
                            text: qsTr("%1 / %2 s").arg(Math.round(mediaPlayer.position / 1000)).arg(Math.round(mediaPlayer.duration / 1000))
                            color: Theme.ink2
                            font.family: Theme.fontMono
                            font.pixelSize: 11
                        }
                    }
                }

                // Track Engineering Details Panel
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 110
                    color: Theme.bg
                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }

                    GridLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        columns: 4
                        rowSpacing: 4
                        columnSpacing: 16

                        Text { text: qsTr("Track ID: %1").arg(ctrl.selectedTrack.track_id || "—"); color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Scope: %1 / %2").arg(ctrl.selectedTrack.camera_id || "—").arg(ctrl.selectedTrack.unit_id || "—"); color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Duration: %1 ms → %2 ms").arg(ctrl.selectedTrack.start_ms || 0).arg(ctrl.selectedTrack.end_ms || 0); color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Reason: %1").arg(ctrl.selectedTrack.reason || "—"); color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }

                        Text { text: qsTr("Observations: %1").arg(ctrl.selectedTrack.observations || 0); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Ambiguous Batches: %1").arg(ctrl.selectedTrack.ambiguous_batches || 0); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Path Length: %1").arg(ctrl.selectedTrack.path_length ? Math.round(ctrl.selectedTrack.path_length * 1000)/1000 : 0); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Displacement: %1").arg(ctrl.selectedTrack.net_displacement ? Math.round(ctrl.selectedTrack.net_displacement * 1000)/1000 : 0); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }

                        Text { text: qsTr("Mean Speed: %1").arg(ctrl.selectedTrack.mean_speed ? Math.round(ctrl.selectedTrack.mean_speed * 1000)/1000 : "null"); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Max Gap: %1 ms").arg(ctrl.selectedTrack.max_observation_gap_ms || 0); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Largest Box @ %1 ms").arg(ctrl.selectedTrack.bbox_at_ms || 0); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text { text: qsTr("Path Points: %1").arg(ctrl.selectedTrack.path ? ctrl.selectedTrack.path.length : 0); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                    }
                }
            }
        }

        // =====================================================================
        // VIEW 3: EVIDENCE ARCHIVE
        // =====================================================================
        ColumnLayout {
            visible: trackingRoot.subView === "evidence"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 46
                color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 18
                    spacing: 12
                    Text {
                        text: qsTr("Saved Run Evidence (%1)").arg(ctrl.savedRuns.length)
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.Bold
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        implicitWidth: refTxt.implicitWidth + 20
                        implicitHeight: 28
                        radius: 3
                        color: Theme.bg
                        border.color: Theme.line2
                        border.width: 1
                        Text {
                            id: refTxt
                            anchors.centerIn: parent
                            text: qsTr("Refresh")
                            color: Theme.ink
                            font.family: Theme.fontSans
                            font.pixelSize: 11
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ctrl.refreshSavedRuns()
                        }
                    }
                }
            }

            ListView {
                id: evList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: ctrl.savedRuns

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: evList.width
                    height: 48
                    color: index % 2 === 0 ? Theme.bg : Theme.panel
                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 18
                        anchors.rightMargin: 18
                        spacing: 14

                        Text {
                            text: modelData.fileName || ""
                            color: Theme.ink
                            font.family: Theme.fontMono
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        Text {
                            text: qsTr("%1 KB").arg(Math.round(modelData.sizeBytes / 1024))
                            color: Theme.ink3
                            font.family: Theme.fontMono
                            font.pixelSize: 11
                        }

                        Rectangle {
                            implicitWidth: loadTxt.implicitWidth + 18
                            implicitHeight: 26
                            radius: 3
                            color: Theme.accent
                            Text {
                                id: loadTxt
                                anchors.centerIn: parent
                                text: qsTr("Load")
                                color: Theme.bg
                                font.family: Theme.fontSans
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    ctrl.loadEvidence(modelData.filePath);
                                    trackingRoot.subView = "verification";
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
