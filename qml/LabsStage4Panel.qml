import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import QtMultimedia
import Watchtower

// Labs — the Stage 4 workspace. Two frozen approaches (A: from scratch, B: a
// non-YOLO pretrained trunk with a newly trained head) over the same V1 filters,
// the same evidence and the same resource readout. The panel never invents a
// state: no result renders as "no analysis loaded", a failed run keeps its errors,
// and an unknown colour is shown as unknown rather than as a match.
Item {
    id: root

    property var stage4: null
    property string exportDir: ""

    // filters (the V1 controls; the model evaluates them, this only edits them)
    property var typeOptions: ["human", "car", "animal"]
    property var sizeOptions: ["small", "medium", "big"]
    property var colourOptions: [
        { label: "red", hex: "#c81e1e" }, { label: "orange", hex: "#eb821e" },
        { label: "yellow", hex: "#e6d228" }, { label: "green", hex: "#28963c" },
        { label: "cyan", hex: "#28bec8" }, { label: "blue", hex: "#2846be" },
        { label: "purple", hex: "#783caa" }, { label: "pink", hex: "#e68cb9" },
        { label: "brown", hex: "#6e4628" }, { label: "black", hex: "#000000" },
        { label: "dark grey", hex: "#464646" }, { label: "light grey", hex: "#aaaaaa" },
        { label: "white", hex: "#ffffff" }
    ]
    property string rightTab: "objects"
    property var rows: []
    // playback: the video of the loaded run, with the observed boxes drawn at the
    // playhead's own presentation timestamp
    property var shown: ({})
    property bool playing: false
    property string seekPending: ""
    property bool bootstrapped: false

    function seekToObservation(id) {
        if (!stage4) return
        stage4.selectedObservation = id
        var o = root.observationById(id)
        if (!o) return
        if (player.duration > 0)
            player.position = Math.max(0, Math.min(o.frame_pts_ms, player.duration))
        else
            seekPending = id          // the player is not ready yet: seek on duration change
    }

    function refreshShown() {
        if (!stage4 || !stage4.hasResult || stage4.videoPath === "") { shown = {}; return }
        shown = stage4.observationsAt(player.position)
    }

    function refreshRows() {
        rows = (stage4 && stage4.hasResult) ? stage4.filtered : []
    }

    // Ordinary result selection seeks the player to the supporting observation's own
    // PTS and lets the overlay redraw there. In R1 this function only set the
    // selection while a separate seek function existed unused by the list
    // (R2 finding 2), so clicking a row highlighted it and left the playhead behind.
    function select(id) {
        root.seekToObservation(id)
    }

    // Identity-based lookup: after filtering or reopening, the row index is not the
    // observation, so the PTS is taken from the observation with this id.
    function observationById(id) {
        if (!stage4) return null
        var list = stage4.observations
        for (var i = 0; i < list.length; i++)
            if (list[i].observation_id === id) return list[i]
        return null
    }

    function fmt(v, digits) {
        return (v === null || v === undefined || v === "") ? "—"
                                                           : Number(v).toFixed(digits === undefined ? 2 : digits)
    }

    function sizeColour(label) {
        if (label === "small") return "#7fc4ff"
        if (label === "medium") return "#ffd166"
        if (label === "big") return "#ff9f6e"
        return "#8a8f98"
    }

    function stateColour(state) {
        if (state === "match") return "#9ade7b"
        if (state === "uncertain") return "#ffd166"
        return "#6b7078"
    }

    Connections {
        target: root.stage4
        // NOTE: the startup hook must NOT re-arm here. Re-arming made it reload the
        // run 900 ms after any state change, which silently undid an input or model
        // switch and made the switch look like it had not cleared anything.
        function onResultChanged() { root.refreshRows(); root.refreshShown() }
        function onFiltersChanged() { root.refreshRows() }
        function onSelectionChanged() { root.refreshShown() }
    }

    // In-app acceptance hook (WT_LABS_STAGE4_RUN / _OBS, main.cpp): open a run and
    // select an observation at startup.
    Timer {
        id: startTimer
        interval: 900
        repeat: false
        onTriggered: {
            if (root.bootstrapped) return
            if (typeof wtStage4Run === "undefined" || wtStage4Run === "" || !root.stage4) return
            root.bootstrapped = true
            root.stage4.loadRun(wtStage4Run)
            if (typeof wtStage4Obs !== "undefined" && wtStage4Obs !== "") {
                var list = root.stage4.observations
                var pick = wtStage4Obs
                if (pick === "first" && list.length > 0) pick = list[0].observation_id
                if (list.length > 0) root.seekToObservation(pick)
            }
            player.play()
            player.pause()
            root.refreshShown()
            if (typeof wtStage4SwitchTo !== "undefined" && wtStage4SwitchTo !== "")
                root.stage4.approach = wtStage4SwitchTo
            // Product-path hook: switch the INPUT after a run is loaded, which must
            // clear every derived result exactly as an operator's own switch does.
            if (typeof wtStage4SwitchInput !== "undefined" && wtStage4SwitchInput !== "") {
                root.stage4.recording = wtStage4SwitchInput
                root.refreshShown()
            }
            // Product-path hook: verify the loaded run's artifact hashes in-app.
            // limit 0 = verify every listed file. A bounded sample is right for the
            // UI, but an altered file outside the sample looked "verified" (caught by
            // S4-C10), so the test hook checks all of them.
            if (typeof wtStage4VerifyArtifacts !== "undefined" && wtStage4VerifyArtifacts === "1")
                root.stage4.verifyRunArtifacts(wtStage4Run, 0)
        }
    }

    // Self-test hook: after the startup sequence has settled, write the controller's
    // own state so an application-path check can assert on the real product.
    Timer {
        id: dumpTimer
        interval: 4500
        repeat: false
        onTriggered: {
            if (typeof wtStage4StateDump === "undefined" || wtStage4StateDump === ""
                || !root.stage4) return
            root.stage4.writeStateDump(wtStage4StateDump)
        }
    }

    Component.onCompleted: {
        if (stage4) { stage4.refreshRecordings(); stage4.refreshRuns(); stage4.probeRecording() }
        refreshRows()
        startTimer.start()
        dumpTimer.start()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // ---- header ---------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            ColumnLayout {
                spacing: 2
                Text {
                    text: "STAGE 4 · OBJECT · SIZE · COLOUR"
                    color: "#e8e8e8"; font.pixelSize: 13; font.bold: true
                    font.letterSpacing: 1.1
                }
                Text {
                    text: "Two frozen approaches trained on the released public data, "
                          + "the V1 filters, and the evidence each claim rests on."
                    color: "#8a8f98"; font.pixelSize: 11
                }
            }
            Item { Layout.fillWidth: true }
            RowLayout {
                spacing: 6
                Repeater {
                    model: root.stage4 ? root.stage4.approaches : []
                    delegate: Button {
                        required property var modelData
                        text: modelData.id
                        checkable: true
                        checked: root.stage4 && root.stage4.approach === modelData.id
                        ToolTip.visible: hovered
                        ToolTip.text: modelData.label + " — " + modelData.detail
                        onClicked: if (root.stage4) root.stage4.approach = modelData.id
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12

            // ---- left: source, model, filters ------------------------------
            ColumnLayout {
                Layout.preferredWidth: 330
                Layout.fillHeight: true
                spacing: 10

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: sourceCol.implicitHeight + 20
                    color: "#161a1f"; radius: 6; border.color: "#252a31"
                    ColumnLayout {
                        id: sourceCol
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 6
                        Text {
                            text: (root.stage4 ? root.stage4.status : "idle").toUpperCase()
                            color: root.stage4 && root.stage4.running ? "#ffd166"
                                 : (root.stage4 && root.stage4.status === "completed" ? "#9ade7b"
                                    : (root.stage4 && root.stage4.status === "failed" ? "#ff6b6b" : "#8a8f98"))
                            font.pixelSize: 12; font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.stage4 ? root.stage4.statusText : ""
                            color: "#c8ccd2"; font.pixelSize: 11; wrapMode: Text.WordWrap
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.stage4 && root.stage4.errorText !== ""
                            text: root.stage4 ? root.stage4.errorText : ""
                            color: "#ff8f8f"; font.pixelSize: 11; wrapMode: Text.WordWrap
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: modelCol.implicitHeight + 20
                    color: "#161a1f"; radius: 6; border.color: "#252a31"
                    ColumnLayout {
                        id: modelCol
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 5
                        Text {
                            text: "MODEL · APPROACH " + (root.stage4 ? root.stage4.approach : "A")
                            color: "#8a8f98"; font.pixelSize: 10; font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: {
                                var m = root.stage4 ? root.stage4.modelState : null
                                if (!m || !m.ready) return m && m.message ? m.message
                                                                          : "no checkpoint"
                                return (root.stage4.approach === "A"
                                        ? "scratch CNN · GroupNorm · random init"
                                        : "ResNet-18 trunk (frozen, ImageNet) · trained head")
                            }
                            color: "#e8e8e8"; font.pixelSize: 11; wrapMode: Text.WordWrap
                        }
                        Text {
                            Layout.fillWidth: true
                            text: {
                                var m = root.stage4 ? root.stage4.modelState : null
                                if (!m) return ""
                                var rev = m.revision ? ("revision " + m.revision) : "no revision"
                                var label = m.label ? (" · " + m.label) : ""
                                if (!m.ready) return rev + label + " · NOT USABLE — Run disabled"
                                return rev + label + " · checkpoint verified "
                                       + (m.verified ? "✓" : "✗") + " · runtime "
                                       + (m.onnx ? "ONNX" : "torch")
                            }
                            color: (root.stage4 && root.stage4.modelState
                                    && root.stage4.modelState.ready === true)
                                   ? "#9ade7b" : "#ff8f8f"
                            font.pixelSize: 10; wrapMode: Text.WordWrap
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.stage4 && root.stage4.modelState
                                     && root.stage4.modelState.checkpoint_sha256
                            text: root.stage4 && root.stage4.modelState
                                  ? ("sha256 " + String(root.stage4.modelState.checkpoint_sha256).slice(0, 24)
                                     + " · " + Math.round((root.stage4.modelState.bytes || 0) / 1048576 * 10) / 10 + " MiB")
                                  : ""
                            color: "#6f7681"; font.pixelSize: 10; wrapMode: Text.WordWrap
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.stage4 && root.stage4.modelState && root.stage4.modelState.ready
                            text: root.stage4 && root.stage4.modelState
                                  ? ("sha256 " + String(root.stage4.modelState.path).split("/").pop()
                                     + " · " + Math.round(root.stage4.modelState.bytes / 1048576 * 10) / 10 + " MiB")
                                  : ""
                            color: "#6f7681"; font.pixelSize: 10; wrapMode: Text.WordWrap
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: !!(root.stage4 && root.stage4.summary
                                        && root.stage4.summary.checkpoint_sha256)
                            text: root.stage4 && root.stage4.summary && root.stage4.summary.checkpoint_sha256
                                  ? ("run checkpoint " + root.stage4.summary.checkpoint_sha256.slice(0, 12))
                                  : ""
                            color: "#6f7681"; font.pixelSize: 10
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: recCol.implicitHeight + 20
                    color: "#161a1f"; radius: 6; border.color: "#252a31"
                    ColumnLayout {
                        id: recCol
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 6
                        Text {
                            text: "RECORDING"
                            color: "#8a8f98"; font.pixelSize: 10; font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.stage4 && root.stage4.recordingName !== ""
                                  ? root.stage4.recordingName : "none selected"
                            color: "#e8e8e8"; font.pixelSize: 12; elide: Text.ElideMiddle
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.stage4 && root.stage4.probe && root.stage4.probe.width
                            text: root.stage4 && root.stage4.probe && root.stage4.probe.width
                                  ? (root.stage4.probe.width + "×" + root.stage4.probe.height
                                     + " · " + root.stage4.probe.codec
                                     + " · " + Math.round(root.stage4.probe.duration_s) + " s")
                                  : ""
                            color: "#8a8f98"; font.pixelSize: 10
                        }
                        ComboBox {
                            Layout.fillWidth: true
                            model: root.stage4 ? root.stage4.recordings : []
                            textRole: "name"
                            onActivated: function (i) {
                                root.stage4.recording = root.stage4.recordings[i].path
                            }
                        }
                        RowLayout {
                            spacing: 6
                            Button {
                                text: "Stage 4 clips"
                                onClicked: root.stage4.refreshRecordings()
                            }
                            Button {
                                text: "Browse…"
                                onClicked: fileDialog.open()
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "#161a1f"; radius: 6; border.color: "#252a31"
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 6
                        Text {
                            text: "V1 FILTERS"
                            color: "#8a8f98"; font.pixelSize: 10; font.bold: true
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 4
                            Repeater {
                                model: root.typeOptions
                                delegate: Button {
                                    required property string modelData
                                    text: modelData
                                    checkable: true
                                    checked: root.stage4 && root.stage4.filterTypes.indexOf(modelData) >= 0
                                    onClicked: {
                                        var list = root.stage4.filterTypes.slice()
                                        var i = list.indexOf(modelData)
                                        if (i >= 0) list.splice(i, 1); else list.push(modelData)
                                        root.stage4.filterTypes = list
                                    }
                                }
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 4
                            Repeater {
                                model: root.sizeOptions
                                delegate: Button {
                                    required property string modelData
                                    text: modelData
                                    checkable: true
                                    checked: root.stage4 && root.stage4.filterSizes.indexOf(modelData) >= 0
                                    onClicked: {
                                        var list = root.stage4.filterSizes.slice()
                                        var i = list.indexOf(modelData)
                                        if (i >= 0) list.splice(i, 1); else list.push(modelData)
                                        root.stage4.filterSizes = list
                                    }
                                }
                            }
                        }
                        RowLayout {
                            spacing: 4
                            Text { text: "colour location"; color: "#8a8f98"; font.pixelSize: 10 }
                            ComboBox {
                                Layout.fillWidth: true
                                model: ["", "upper", "lower", "either", "body", "coat"]
                                currentIndex: {
                                    var v = root.stage4 ? root.stage4.filterLocation : ""
                                    var i = model.indexOf(v)
                                    return i < 0 ? 0 : i
                                }
                                onActivated: function (i) {
                                    root.stage4.filterLocation = (i === 0 ? "" : model[i])
                                }
                            }
                        }
                        RowLayout {
                            spacing: 4
                            CheckBox {
                                text: "colour"
                                checked: root.stage4 ? root.stage4.filterColourActive : false
                                onToggled: root.stage4.filterColourActive = checked
                            }
                            Repeater {
                                model: root.colourOptions
                                delegate: Rectangle {
                                    required property var modelData
                                    width: 18; height: 18; radius: 3
                                    color: modelData.hex
                                    border.color: root.stage4
                                                  && root.stage4.filterColourHex === modelData.hex
                                                  ? "#ffd166" : "#3a4048"
                                    border.width: 2
                                    ToolTip.visible: swatchMa.containsMouse
                                    ToolTip.text: modelData.label
                                    MouseArea {
                                        id: swatchMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: {
                                            root.stage4.filterColourHex = modelData.hex
                                            root.stage4.filterColourActive = true
                                        }
                                    }
                                }
                            }
                        }
                        RowLayout {
                            spacing: 6
                            Text {
                                text: "ΔE00 tolerance " + (root.stage4
                                                           ? root.stage4.filterTolerance.toFixed(0) : "20")
                                color: "#8a8f98"; font.pixelSize: 10
                            }
                            Slider {
                                Layout.fillWidth: true
                                from: 0; to: 40; stepSize: 1
                                value: root.stage4 ? root.stage4.filterTolerance : 20
                                onMoved: root.stage4.filterTolerance = value
                            }
                        }
                        CheckBox {
                            text: "include uncertain colours (separate bucket)"
                            checked: root.stage4 ? root.stage4.includeUncertain : false
                            onToggled: root.stage4.includeUncertain = checked
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Button {
                                text: "Clear filters"
                                onClicked: root.stage4.clearFilters()
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: {
                                    var c = root.stage4 ? root.stage4.filterCounts : null
                                    return c ? (c.matched + " of " + c.observations
                                                + (c.uncertain > 0 ? " · " + c.uncertain + " uncertain" : ""))
                                             : ""
                                }
                                color: "#e8e8e8"; font.pixelSize: 11
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Button {
                                Layout.fillWidth: true
                                text: "Run analysers"
                                enabled: !!(root.stage4 && !root.stage4.running
                                            && root.stage4.modelState
                                            && root.stage4.modelState.ready)
                                onClicked: root.stage4.start()
                            }
                            Button {
                                text: "Cancel"
                                enabled: root.stage4 && root.stage4.running
                                onClicked: root.stage4.cancel()
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: {
                                var m = root.stage4 ? root.stage4.metrics : null
                                if (!m || !m.frames_scheduled) return "resource metrics appear here after a run"
                                return m.frames_scheduled + " scheduled · " + m.frames_analysed
                                       + " analysed · " + fmt(m.inference_ms_per_frame_mean, 0)
                                       + " ms/frame · peak RSS "
                                       + Math.round((m.peak_rss_bytes || 0) / 1048576) + " MiB (this process)"
                            }
                            color: "#6f7681"; font.pixelSize: 10; wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            // ---- right: results -------------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 8

                // ---- playback with the observed boxes at the playhead --------
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 300
                    color: "#0b0e11"; radius: 6; border.color: "#252a31"

                    MediaPlayer {
                        id: player
                        source: (root.stage4 && root.stage4.videoPath !== "")
                                ? "file://" + root.stage4.videoPath : ""
                        videoOutput: videoOut
                        audioOutput: null
                        onPositionChanged: root.refreshShown()
                        onDurationChanged: {
                            if (root.seekPending !== "") {
                                var o = root.observationById(root.seekPending)
                                if (o) player.position = Math.max(0, Math.min(o.frame_pts_ms,
                                                                            player.duration))
                                root.seekPending = ""
                            }
                        }
                    }
                    VideoOutput {
                        id: videoOut
                        anchors.fill: parent
                        anchors.bottomMargin: 34
                        fillMode: VideoOutput.PreserveAspectFit
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !root.stage4 || root.stage4.videoPath === ""
                        text: qsTr("no run loaded — the video appears here with its "
                                   + "observed boxes at the playhead")
                        color: "#6f7681"; font.pixelSize: 11
                    }
                    Canvas {
                        id: boxOverlay
                        anchors.fill: videoOut
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            var rows = root.shown && root.shown.observations
                                            ? root.shown.observations : []
                            if (!rows.length) return
                            // the video is letterboxed into this item; map the
                            // normalized source box through the same fit
                            var vw = videoOut.contentRect ? videoOut.contentRect.width
                                                          : videoOut.width
                            var vh = videoOut.contentRect ? videoOut.contentRect.height
                                                          : videoOut.height
                            var ox = videoOut.contentRect ? videoOut.contentRect.x : 0
                            var oy = videoOut.contentRect ? videoOut.contentRect.y : 0
                            for (var i = 0; i < rows.length; i++) {
                                var o = rows[i]
                                var b = o.bbox_xywh
                                var x = ox + b[0] * vw, y = oy + b[1] * vh
                                var w = b[2] * vw, h = b[3] * vh
                                ctx.lineWidth = 2
                                ctx.strokeStyle = (o.observation_id
                                                   === root.stage4.selectedObservation)
                                                  ? "#ffd166" : "#9ade7b"
                                ctx.strokeRect(x, y, w, h)
                                ctx.fillStyle = ctx.strokeStyle
                                ctx.font = "12px sans-serif"
                                ctx.fillText(o["class"] + " " + Number(o.confidence).toFixed(2)
                                             + (o.apparent_size ? " · " + o.apparent_size.label : ""),
                                             x, Math.max(12, y - 4))
                            }
                        }
                        Connections {
                            target: root
                            function onShownChanged() { boxOverlay.requestPaint() }
                        }
                    }
                    RowLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 8
                        height: 24
                        spacing: 8
                        Button {
                            text: root.playing ? "Pause" : "Play"
                            onClicked: {
                                if (root.playing) player.pause(); else player.play()
                                root.playing = !root.playing
                            }
                        }
                        Text {
                            text: {
                                var ms = player.position
                                var s = Math.floor(ms / 1000)
                                return (s < 10 ? "0" : "") + s + "."
                                       + String(Math.floor(ms % 1000)).padStart(3, "0")
                                       + " / " + Number(player.duration / 1000).toFixed(1) + " s"
                            }
                            color: "#c8ccd2"; font.pixelSize: 11
                        }
                        Text {
                            Layout.fillWidth: true
                            text: {
                                if (!root.shown || !root.shown.found)
                                    return "no observation within one sampling interval "
                                           + "of the playhead"
                                return "decoded frame at "
                                       + Number(root.shown.pts_ms / 1000).toFixed(3) + " s · "
                                       + root.shown.count + " object(s) · "
                                       + Math.round(root.shown.age_ms) + " ms before playhead"
                            }
                            color: "#8a8f98"; font.pixelSize: 11; elide: Text.ElideRight
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: ["objects", "evidence", "runs", "verification"]
                        delegate: Button {
                            required property string modelData
                            text: modelData
                            checkable: true
                            checked: root.rightTab === modelData
                            onClicked: root.rightTab = modelData
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.stage4 && root.stage4.hasResult
                              ? (root.rows.length + " shown of " + root.stage4.observations.length
                                 + " observations · approach " + root.stage4.approach)
                              : "no analysis loaded"
                        color: "#8a8f98"; font.pixelSize: 11
                    }
                }

                // objects + filters
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 8
                    visible: root.rightTab === "objects"

                    ListView {
                        Layout.preferredWidth: 380
                        Layout.fillHeight: true
                        clip: true
                        model: root.rows
                        delegate: Rectangle {
                            required property var modelData
                            width: ListView.view.width
                            height: 46
                            color: root.stage4 && root.stage4.selectedObservation
                                   === modelData.observation_id ? "#20262e" : "transparent"
                            border.color: "#1d2229"
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 8
                                Rectangle {
                                    width: 6; height: 30; radius: 2
                                    color: root.sizeColour(modelData.apparent_size
                                                           ? modelData.apparent_size.label : "")
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text {
                                        text: modelData["class"] + "  "
                                              + fmt(modelData.confidence, 3) + "  "
                                              + (modelData.apparent_size
                                                 ? modelData.apparent_size.label : "—")
                                        color: "#e8e8e8"; font.pixelSize: 11
                                    }
                                    Text {
                                        text: "@" + fmt(modelData.frame_pts_ms / 1000, 2) + " s · frame "
                                              + modelData.frame_index + " · "
                                              + (modelData.colors && modelData.colors.length
                                                 ? modelData.colors.map(function (c) {
                                                       return c.region.replace("_clothing", "")
                                                              + ":" + c.label }).join(" ")
                                                 : "no colour region")
                                        color: "#8a8f98"; font.pixelSize: 10
                                    }
                                }
                                Text {
                                    visible: modelData.filter_state === "match"
                                             || modelData.filter_state === "uncertain"
                                    text: modelData.filter_state === "match" ? "MATCH" : "UNCERTAIN"
                                    color: root.stateColour(modelData.filter_state)
                                    font.pixelSize: 9; font.bold: true
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.select(modelData.observation_id)
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: "#12161a"; radius: 6; border.color: "#252a31"
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 8
                            Text {
                                text: "SELECT AN OBSERVATION"
                                color: "#8a8f98"; font.pixelSize: 10; font.bold: true
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: root.stage4 && root.stage4.selectedDetail
                                         && root.stage4.selectedDetail.observation_id
                                         !== undefined
                                text: {
                                    var d = root.stage4 ? root.stage4.selectedDetail : null
                                    if (!d || !d.observation_id) return ""
                                    return d["class"] + " · confidence " + fmt(d.confidence, 3)
                                           + " · apparent size " + (d.apparent_size
                                              ? (d.apparent_size.label + " (area "
                                                 + fmt(d.apparent_size.area_fraction, 5) + ")") : "—")
                                           + " · observed frame " + d.frame_index + " at PTS "
                                           + fmt(d.frame_pts_ms, 1) + " ms"
                                           + " · box [" + d.bbox_xywh.map(function (v) {
                                                 return fmt(v, 3) }).join(", ") + "]"
                                           + (d.truncated ? " · truncated at the frame edge" : "")
                                           + (d.filter_state ? "  →  filter: " + d.filter_state
                                               + (d.filter_region ? " on " + d.filter_region : "")
                                               + (d.filter_delta_e !== null && d.filter_delta_e !== undefined
                                                  ? " (ΔE00 " + fmt(d.filter_delta_e, 1) + ")" : "")
                                               : "")
                                }
                                color: "#e8e8e8"; font.pixelSize: 11; wrapMode: Text.WordWrap
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: root.stage4 && root.stage4.selectedDetail
                                         && root.stage4.selectedDetail.observation_id
                                         !== undefined
                                         && root.stage4.selectedDetail.filter_reason
                                         !== undefined
                                         && root.stage4.selectedDetail.filter_reason !== ""
                                text: (root.stage4 && root.stage4.selectedDetail)
                                      ? ("reason: " + (root.stage4.selectedDetail.filter_reason
                                                       || "")) : ""
                                color: "#ffd166"; font.pixelSize: 10; wrapMode: Text.WordWrap
                            }
                            Text {
                                text: "colour evidence (each region from its own pixels)"
                                color: "#8a8f98"; font.pixelSize: 10
                            }
                            ListView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                model: root.stage4 && root.stage4.selectedDetail
                                       ? root.stage4.selectedDetail.colors : []
                                delegate: Rectangle {
                                    required property var modelData
                                    width: ListView.view.width
                                    height: 74
                                    color: "#161a1f"; radius: 4; border.color: "#252a31"
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.margins: 8
                                        spacing: 10
                                        Image {
                                            width: 58; height: 58
                                            fillMode: Image.PreserveAspectFit
                                            source: modelData.crop && root.stage4.runDir
                                                    ? "file://" + root.stage4.runDir + "/" + modelData.crop : ""
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
                                            Text {
                                                text: modelData.region + "  ·  " + modelData.label
                                                      + (modelData.confidence !== undefined
                                                         ? "  (" + fmt(modelData.confidence, 2) + ")" : "")
                                                color: "#e8e8e8"; font.pixelSize: 11
                                            }
                                            Text {
                                                text: modelData.srgb
                                                      ? ("sRGB " + modelData.srgb.join(", ")
                                                         + "   Lab " + modelData.lab_d65.map(function (v) {
                                                               return fmt(v, 1) }).join(", "))
                                                      : ("no numeric colour" + (modelData.reason
                                                         ? " — " + modelData.reason : ""))
                                                color: "#8a8f98"; font.pixelSize: 10
                                                wrapMode: Text.WordWrap
                                                Layout.fillWidth: true
                                            }
                                            Text {
                                                text: modelData.support_pixel_count !== undefined
                                                      ? (modelData.support_pixel_count + " supporting pixels · "
                                                         + fmt(modelData.support_fraction * 100, 0)
                                                         + "% of the region"
                                                         + (modelData.support_mask ? " · mask saved" : ""))
                                                      : ""
                                                color: "#6f7681"; font.pixelSize: 10
                                            }
                                        }
                                        Rectangle {
                                            width: 34; height: 34; radius: 4
                                            visible: modelData.srgb !== null
                                                     && modelData.srgb !== undefined
                                            color: modelData.srgb
                                                     ? Qt.rgba(modelData.srgb[0] / 255,
                                                               modelData.srgb[1] / 255,
                                                               modelData.srgb[2] / 255, 1)
                                                     : "transparent"
                                            border.color: "#3a4048"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // evidence (crop + region crops side by side)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.rightTab === "evidence"
                    color: "#12161a"; radius: 6; border.color: "#252a31"
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: "The object crop and the region crops the analyser saved, "
                                  + "for the selected observation. A colour claim without "
                                  + "pixels behind it would not be usable evidence."
                            color: "#8a8f98"; font.pixelSize: 11; wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 12
                            ColumnLayout {
                                spacing: 4
                                Text { text: "object crop"; color: "#8a8f98"; font.pixelSize: 10 }
                                Image {
                                    Layout.preferredWidth: 260
                                    Layout.preferredHeight: 260
                                    fillMode: Image.PreserveAspectFit
                                    source: root.stage4 && root.stage4.selectedDetail
                                            && root.stage4.selectedDetail.crop && root.stage4.runDir
                                            ? "file://" + root.stage4.runDir + "/"
                                              + root.stage4.selectedDetail.crop : ""
                                }
                            }
                            Repeater {
                                model: root.stage4 && root.stage4.selectedDetail
                                       ? root.stage4.selectedDetail.colors : []
                                delegate: ColumnLayout {
                                    required property var modelData
                                    spacing: 4
                                    Text {
                                        text: modelData.region + " → " + modelData.label
                                        color: "#8a8f98"; font.pixelSize: 10
                                    }
                                    Image {
                                        Layout.preferredWidth: 200
                                        Layout.preferredHeight: 200
                                        fillMode: Image.PreserveAspectFit
                                        source: modelData.crop && root.stage4.runDir
                                                ? "file://" + root.stage4.runDir + "/" + modelData.crop : ""
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                    }
                }

                // runs
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.rightTab === "runs"
                    color: "#12161a"; radius: 6; border.color: "#252a31"
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "SAVED RUNS"
                                color: "#8a8f98"; font.pixelSize: 10; font.bold: true
                            }
                            Item { Layout.fillWidth: true }
                            Button { text: "refresh"; onClicked: root.stage4.refreshRuns() }
                        }
                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: root.stage4 ? root.stage4.runs : []
                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width
                                height: 40
                                color: "#161a1f"; radius: 4; border.color: "#252a31"
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name
                                        color: "#e8e8e8"; font.pixelSize: 11
                                        elide: Text.ElideMiddle
                                    }
                                    Text {
                                        text: "approach " + modelData.approach + " · " + modelData.status
                                              + " · " + modelData.observations + " obs"
                                        color: modelData.status === "completed" ? "#9ade7b" : "#ffd166"
                                        font.pixelSize: 10
                                    }
                                    Button {
                                        text: "open"
                                        onClicked: root.stage4.loadRun(modelData.dir)
                                    }
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "Reopening a run restores its inference envelope, input and model "
                                  + "identity, coverage, observations and evidence paths. A run whose "
                                  + "video or crops are missing stays visibly incomplete."
                            color: "#6f7681"; font.pixelSize: 10; wrapMode: Text.WordWrap
                        }
                    }
                }

                // verification
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.rightTab === "verification"
                    color: "#12161a"; radius: 6; border.color: "#252a31"
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Repeater {
                                model: ["all", "training", "inference", "colour", "product",
                                        "resources", "regressions"]
                                delegate: Button {
                                    required property string modelData
                                    text: modelData
                                    enabled: root.stage4 && !root.stage4.checking
                                    onClicked: root.stage4.runChecks(modelData)
                                }
                            }
                            Button {
                                text: "Stop"
                                enabled: root.stage4 && root.stage4.checking
                                onClicked: root.stage4.stopChecks()
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.stage4 ? root.stage4.checkSummary : ""
                                color: "#e8e8e8"; font.pixelSize: 11
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "S4-C01…S4-C16. A deliberate failing control is part of the "
                                  + "list: if every control passes, that check is broken and says so."
                            color: "#8a8f98"; font.pixelSize: 10; wrapMode: Text.WordWrap
                        }
                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: root.stage4 ? root.stage4.checks : []
                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width
                                height: modelData.event === "check" ? 38 : 26
                                color: "transparent"
                                RowLayout {
                                    anchors.fill: parent
                                    spacing: 8
                                    Text {
                                        text: modelData.event === "check"
                                              ? String(modelData.status).toUpperCase()
                                              : String(modelData.event).toUpperCase()
                                        color: modelData.status === "pass" ? "#9ade7b"
                                               : (modelData.status === "fail" ? "#ff6b6b"
                                                  : (modelData.status === "skip" ? "#ffd166" : "#8a8f98"))
                                        font.pixelSize: 10; font.bold: true
                                        Layout.preferredWidth: 56
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.event === "check"
                                              ? (modelData.name + "  —  " + (modelData.detail || ""))
                                              : JSON.stringify(modelData)
                                        color: "#c8ccd2"; font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    FileDialog {
        id: fileDialog
        title: "Choose a recording"
        nameFilters: ["Video files (*.mp4 *.mkv *.mov)", "All files (*)"]
        onAccepted: root.stage4.recording = String(selectedFile).replace("file://", "")
    }
}
