import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import QtQuick.Dialogs
import QtMultimedia
import Watchtower

// Labs → Temporal tracks: run THIS build's tracking engine over one local
// recording and review what it found beside the picture.
//
// The recording comes from the product's own export directory (Artifacts.exportDir)
// or from a file the operator picks here; nothing is fetched, uploaded or written
// outside this application's data directory. The analysis itself runs in
// tools/labs/temporal_tracks_clip.py as a child process (LabsTrackJob): the same
// decode pass, the same foreground analyser and the same engine the offline suite
// tests. This view only selects, launches, watches, cancels and renders.
//
// HONESTY RULES the view enforces on itself:
//  * a box is drawn only for an instant an observation actually covers; between
//    observations there is nothing, unless the operator switches on the dashed
//    "interpolated (not evidence)" outline;
//  * times are clip-relative unless the operator typed the footage's wall-clock
//    origin, and the banner says which basis is in force;
//  * completed / empty / cancelled / failed / missing are five different banners;
//    none of them reads as a pass;
//  * the results pane shows ONE run id at a time, so a previous run can never be
//    mistaken for the current one.
Item {
    id: root
    property var screen: null

    property var inputs: []
    property int inputIndex: -1
    property string customPath: ""
    readonly property string chosenPath: customPath !== "" ? customPath
        : (inputIndex >= 0 && inputIndex < inputs.length ? inputs[inputIndex].path : "")

    property string cameraId: ""
    property string originText: ""          // operator-typed ISO wall clock, "" = unknown
    property double windowS: 60
    property bool showInterp: false
    property bool showAllTracks: true

    property var doc: ({})                  // the CURRENT run's document only
    property string runId: ""
    property int trackIndex: -1
    property var saved: []
    property string pane: "run"             // "run" | "saved"

    function refreshInputs() { inputs = LabsTrackRuns.listInputs(Artifacts.exportDir) ; if (inputIndex >= inputs.length) inputIndex = -1 }
    function refreshSaved() { saved = LabsTrackRuns.listRuns() }
    Component.onCompleted: {
        refreshInputs(); refreshSaved()
        if (typeof wtLabsTrackTest === "undefined" || wtLabsTrackTest === "") return
        if (wtLabsTrackTest === "first") { if (inputs.length > 0) inputIndex = 0 }
        else customPath = wtLabsTrackTest
        if (chosenPath !== "") startRun()
        if (typeof wtLabsSaved !== "undefined" && wtLabsSaved !== "") pane = "saved"
    }
    // Reuse: prior runs of the EXACT recording currently selected, matched by
    // path. The evidence store is the cache -- reopening one of these costs no
    // decode, and its document still names the bytes it was computed from.
    function priorRunsForCurrent() {
        var n = 0
        for (var i = 0; i < saved.length; i++)
            if (saved[i].inputPath === chosenPath && saved[i].kind !== "verification") n++
        return n
    }

    // ---- the current run ---------------------------------------------------------
    function originEpochMs() {
        if (originText.trim() === "") return -1
        var d = new Date(originText.trim())
        return isNaN(d.getTime()) ? -1 : d.getTime()
    }
    function startRun() {
        if (chosenPath === "") return
        doc = ({})
        runId = ""
        trackIndex = -1
        LabsTrack.startRun(chosenPath, cameraId, "", labelFromName(chosenPath),
                           originEpochMs(), "", windowS, 0)
    }
    function labelFromName(p) {
        // The export name carries a camera label and the SAVE time (Artifacts::
        // newExportPath stamps currentDateTime), never the footage's own clock.
        // Show it as a label only; the time basis stays explicit.
        var n = p.split("/").pop()
        return n.replace(/\.[A-Za-z0-9]+$/, "")
    }
    Connections {
        target: LabsTrack
        function onResultChanged() {
            doc = LabsTrack.result
            runId = LabsTrack.runId
            if (doc && doc.status === "completed") LabsTrackRuns.saveRun(doc)
            refreshSaved()
            // A verification run selects the first track so a screenshot shows the
            // review pane against real results, positioned at that track's start.
            if (typeof wtLabsTrackTest !== "undefined" && wtLabsTrackTest !== ""
                && doc && doc.tracks && doc.tracks.length > 0) {
                trackIndex = 0
                // play-then-pause so a real frame is rendered at the track's start:
                // a paused-before-ever-playing MediaPlayer shows black.
                player.play()
                player.pause()
                player.position = doc.tracks[0].start_ms
            }
        }
    }

    // ---- playback alignment ------------------------------------------------------
    readonly property real frameMs: (doc.probe && doc.probe.fps > 0) ? 1000.0 / doc.probe.fps : 50
    readonly property real srcAspect: (doc.probe && doc.probe.width > 0 && doc.probe.height > 0)
                                      ? doc.probe.width / doc.probe.height : 16.0 / 9.0
    function fitRect(w, h) {
        var aw = w, ah = w / srcAspect
        if (ah > h) { ah = h; aw = h * srcAspect }
        return Qt.rect((w - aw) / 2, (h - ah) / 2, aw, ah)
    }
    function obsAt(obs, tMs) {
        // An observation covers exactly the frame it was decoded from.
        return obs && obs.t_ms !== undefined && tMs >= obs.t_ms && tMs < obs.t_ms + frameMs
    }
    function interpBox(obs, tMs) {
        if (!obs || obs.length < 2) return undefined
        var prev = undefined, next = undefined
        for (var i = 0; i < obs.length; i++) {
            if (obs[i].t_ms <= tMs) prev = obs[i]
            if (obs[i].t_ms > tMs && next === undefined) next = obs[i]
        }
        if (!prev || !next || next.t_ms === prev.t_ms) return undefined
        var f = (tMs - prev.t_ms) / (next.t_ms - prev.t_ms)
        return [prev.bbox[0] + (next.bbox[0] - prev.bbox[0]) * f,
                prev.bbox[1] + (next.bbox[1] - prev.bbox[1]) * f,
                prev.bbox[2] + (next.bbox[2] - prev.bbox[2]) * f,
                prev.bbox[3] + (next.bbox[3] - prev.bbox[3]) * f]
    }
    function obsForTrack(tid) {
        if (!doc.observations) return []
        var out = []
        for (var i = 0; i < doc.observations.length; i++)
            if (doc.observations[i].track === tid) out.push(doc.observations[i])
        return out
    }
    readonly property var currentTrack: (trackIndex >= 0 && doc.tracks && trackIndex < doc.tracks.length)
                                        ? doc.tracks[trackIndex] : undefined

    function stateBanner() {
        switch (LabsTrack.state) {
        case "running":   return qsTr("Running — decoding and tracking off the UI thread")
        case "completed": return qsTr("Completed: %1 tracks from %2 detections over %3 s of a %4 s clip")
                               .arg(doc.counts ? doc.counts.tracks : 0)
                               .arg(doc.counts ? doc.counts.detections : 0)
                               .arg(doc.decode ? Math.round(doc.decode.window_s) : 0)
                               .arg(doc.decode ? Math.round(doc.decode.duration_s) : 0)
        case "empty":     return qsTr("Completed with no detections: the analyser saw no foreground in this window")
        case "cancelled": return qsTr("Cancelled by the operator — partial evidence, not a result")
        case "failed":    return qsTr("Failed: %1").arg(LabsTrack.errorText)
        case "missing":   return qsTr("Missing prerequisite: %1").arg(LabsTrack.errorText)
        default:          return qsTr("No run yet — choose a recording and start")
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== controls =====
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 46; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 10
                Label10 { text: qsTr("Recording") }
                QC.ComboBox {
                    id: inputBox
                    Layout.preferredWidth: 300
                    model: root.inputs.map(function (i) { return i.name })
                    currentIndex: root.inputIndex
                    onActivated: (i) => { root.inputIndex = i; root.customPath = "" }
                    enabled: !LabsTrack.busy
                }
                Btn { label: qsTr("Choose file…"); enabledLook: !LabsTrack.busy
                      onClicked: pick.open() }
                Label10 { text: qsTr("Camera") }
                QC.TextField {
                    Layout.preferredWidth: 130; text: root.cameraId; placeholderText: qsTr("unknown")
                    onTextChanged: root.cameraId = text
                    enabled: !LabsTrack.busy
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                    background: Rectangle { color: Theme.bg; border.color: Theme.line2 }
                }
                Label10 { text: qsTr("Footage starts") }
                QC.TextField {
                    Layout.preferredWidth: 150; text: root.originText
                    placeholderText: qsTr("unknown — clip-relative")
                    onTextChanged: root.originText = text
                    enabled: !LabsTrack.busy
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                    background: Rectangle { color: Theme.bg; border.color: Theme.line2 }
                }
                Label10 { text: qsTr("Window s") }
                QC.SpinBox {
                    from: 5; to: 600; stepSize: 5; value: root.windowS
                    onValueChanged: root.windowS = value
                    enabled: !LabsTrack.busy
                    editable: true
                }
            }
        }

        // ===== status =====
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 40; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 12
                Rectangle { width: 8; height: 8; radius: 4
                            color: LabsTrack.state === "failed" || LabsTrack.state === "missing" ? Theme.bad
                                 : LabsTrack.state === "completed" ? Theme.good
                                 : LabsTrack.state === "cancelled" || LabsTrack.state === "empty" ? Theme.ink3
                                 : Theme.accent }
                Text {
                    Layout.fillWidth: true
                    text: root.stateBanner()
                    color: LabsTrack.state === "failed" || LabsTrack.state === "missing" ? Theme.bad : Theme.ink
                    font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    visible: LabsTrack.busy
                    text: LabsTrack.statusLine
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                }
                Text {
                    visible: root.runId !== ""
                    text: qsTr("run %1").arg(root.runId)
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                }
                Btn { label: LabsTrack.busy ? qsTr("Cancel") : qsTr("Run tracking")
                      enabledLook: LabsTrack.busy || root.chosenPath !== ""
                      onClicked: LabsTrack.busy ? LabsTrack.cancel() : root.startRun() }
                Btn { label: root.pane === "saved" ? qsTr("Hide saved") : qsTr("Saved runs")
                      onClicked: root.pane = root.pane === "saved" ? "run" : "saved" }
            }
            Rectangle {
                visible: LabsTrack.busy
                anchors.left: parent.left; anchors.bottom: parent.bottom; height: 2
                width: parent.width * LabsTrack.percent / 100.0
                color: Theme.accent
            }
        }

        // ===== body =====
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0

            // ---- tracks ----
            Rectangle {
                Layout.preferredWidth: 300; Layout.fillHeight: true; color: Theme.bg
                Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.right: parent.right; width: 1; color: Theme.line }
                ColumnLayout {
                    anchors.fill: parent; spacing: 0
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 30; color: Theme.bg
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                            Label10 { text: qsTr("Tracks"); Layout.fillWidth: true }
                            Label10 { text: root.doc.tracks ? root.doc.tracks.length + "" : "0" }
                        }
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                    }
                    QC.ScrollView {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        ListView {
                            id: trackList
                            model: root.doc.tracks ? root.doc.tracks.length : 0
                            currentIndex: root.trackIndex
                            delegate: Rectangle {
                                required property int index
                                width: trackList.width; height: 44
                                color: index === root.trackIndex ? Theme.panel : "transparent"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 6
                                    Column {
                                        Layout.fillWidth: true
                                        Text { text: root.doc.tracks[index].track_id
                                               color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                                        Text { text: qsTr("%1 obs · %2–%3 ms · %4")
                                                   .arg(root.doc.tracks[index].observations)
                                                   .arg(root.doc.tracks[index].start_ms)
                                                   .arg(root.doc.tracks[index].end_ms)
                                                   .arg(root.doc.tracks[index].reason)
                                               color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                    }
                                    Rectangle {
                                        visible: root.doc.tracks[index].uncertain
                                        width: uncT.implicitWidth + 10; height: 16; radius: 2
                                        color: Theme.panel2; border.color: Theme.line2
                                        Text { id: uncT; anchors.centerIn: parent; text: qsTr("UNCERTAIN")
                                               color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 9; font.weight: Font.DemiBold }
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.trackIndex = index
                                        var t = root.doc.tracks[index]
                                        if (player.playbackState === MediaPlayer.StoppedState) player.play()
                                        player.position = t.start_ms
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- picture ----
            Item {
                Layout.fillWidth: true; Layout.fillHeight: true
                Rectangle { anchors.fill: parent; color: "#000000" }
                VideoOutput {
                    id: vo
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectFit
                    visible: root.chosenPath !== ""
                }
                MediaPlayer {
                    id: player
                    // A local recording only: this player never touches the network.
                    // Wired the way EvHeroPlayer/PlaybackScreen wire it: the player
                    // owns the VideoOutput through `videoOutput`.
                    videoOutput: vo
                    source: root.chosenPath !== "" ? ("file://" + root.chosenPath) : ""
                    loops: 1
                }
                // observed boxes, and (opt-in, dashed) interpolated positions
                Item {
                    anchors.fill: parent
                    visible: root.doc.observations !== undefined
                    Repeater {
                        model: root.doc.observations ? root.doc.observations.length : 0
                        delegate: Item {
                            required property int index
                            readonly property var ob: root.doc.observations[index]
                            readonly property bool mine: root.showAllTracks || (root.currentTrack && ob.track === root.currentTrack.track_id)
                            readonly property bool now: root.obsAt(ob, player.position)
                            readonly property var ib: (!now && root.showInterp && mine)
                                                      ? root.interpBox(root.obsForTrack(ob.track), player.position)
                                                      : undefined
                            visible: mine && (now || ib !== undefined)
                            x: 0; y: 0; width: parent.width; height: parent.height
                            Rectangle {
                                readonly property var fr: root.fitRect(parent.width, parent.height)
                                readonly property var b: (root.obsAt(ob, player.position)) ? ob.bbox : ib
                                readonly property bool has: b !== undefined && b.length === 4
                                visible: has
                                // The bindings must stay defined even when there is
                                // nothing to draw: an observation covers only the frame
                                // it was decoded from, so most instants have no box.
                                x: has ? fr.x + b[0] * fr.width : 0
                                y: has ? fr.y + b[1] * fr.height : 0
                                width: has ? b[2] * fr.width : 0
                                height: has ? b[3] * fr.height : 0
                                color: "transparent"
                                border.width: root.obsAt(ob, player.position) ? 2 : 1
                                border.color: root.obsAt(ob, player.position) ? Theme.accent : Theme.ink3
                                opacity: root.obsAt(ob, player.position) ? 0.95 : 0.6
                                Text {
                                    x: 2; y: -14
                                    text: ob.track
                                    color: parent.border.color
                                    font.family: Theme.fontMono; font.pixelSize: 10
                                }
                            }
                        }
                    }
                }
                Text {
                    anchors.left: parent.left; anchors.leftMargin: 10; anchors.top: parent.top; anchors.topMargin: 8
                    text: qsTr("clip-relative %1 ms").arg(player.position)
                          + (root.originEpochMs() >= 0 ? qsTr(" · wall %1")
                                .arg(new Date(root.originEpochMs() + player.position).toISOString()) : "")
                    color: "#cccccc"; font.family: Theme.fontMono; font.pixelSize: 10
                    visible: root.chosenPath !== ""
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: 10; anchors.top: parent.top; anchors.topMargin: 8
                    text: root.showInterp ? qsTr("dashed outlines are INTERPOLATED, not evidence") : ""
                    color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 10
                }
                // transport
                RowLayout {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    anchors.margins: 10; spacing: 10
                    Btn { label: player.playbackState === MediaPlayer.PlayingState ? qsTr("Pause") : qsTr("Play")
                          enabledLook: root.chosenPath !== ""
                          onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play() }
                    QC.Slider {
                        Layout.fillWidth: true
                        from: 0; to: player.duration > 0 ? player.duration : 1
                        value: player.position
                        onMoved: player.position = value
                    }
                    QC.CheckBox {
                        text: qsTr("show every track")
                        checked: root.showAllTracks
                        onToggled: root.showAllTracks = checked
                        contentItem: Text { text: parent.text; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10
                                            leftPadding: parent.indicator.width + 4; verticalAlignment: Text.AlignVCenter }
                    }
                    QC.CheckBox {
                        text: qsTr("interpolate")
                        checked: root.showInterp
                        onToggled: root.showInterp = checked
                        contentItem: Text { text: parent.text; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10
                                            leftPadding: parent.indicator.width + 4; verticalAlignment: Text.AlignVCenter }
                    }
                }
                Text {
                    anchors.centerIn: parent
                    visible: root.chosenPath === ""
                    text: qsTr("No recording selected")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
                }
            }

            // ---- detail ----
            Rectangle {
                Layout.preferredWidth: 320; Layout.fillHeight: true; color: Theme.bg
                Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left; width: 1; color: Theme.line }
                QC.ScrollView {
                    anchors.fill: parent
                    Column {
                        width: parent.width; spacing: 6
                        anchors.margins: 12
                        Label10 { text: qsTr("Selected track"); visible: root.currentTrack !== undefined }
                        Text {
                            width: parent.width - 24; wrapMode: Text.WordWrap
                            visible: root.currentTrack !== undefined
                            text: root.currentTrack === undefined ? "" :
                                  (root.currentTrack.track_id || "") + "\n" +
                                  qsTr("observations %1 · ambiguous batches %2\ntime %3–%4 ms (%5)\npath length %6 · net %7 · mean speed %8\nlargest box at %9 ms\nreason %10")
                                  .arg(root.currentTrack.observations).arg(root.currentTrack.ambiguous_batches)
                                  .arg(root.currentTrack.start_ms).arg(root.currentTrack.end_ms)
                                  .arg(root.doc.scope && root.doc.scope.time_basis === "wall-clock"
                                       ? qsTr("wall clock") : qsTr("clip-relative"))
                                  .arg(Number(root.currentTrack.path_length).toFixed(3))
                                  .arg(Number(root.currentTrack.net_displacement).toFixed(3))
                                  .arg(root.currentTrack.mean_speed === null ? "—" : Number(root.currentTrack.mean_speed).toFixed(3))
                                  .arg(root.currentTrack.bbox_at_ms).arg(root.currentTrack.reason)
                            color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11
                        }
                        Label10 { text: qsTr("Path samples (actual observation times)") ; visible: root.currentTrack !== undefined }
                        Repeater {
                            model: root.currentTrack && root.currentTrack.path ? root.currentTrack.path.length : 0
                            delegate: Text {
                                required property int index
                                text: "%1 ms  (%2, %3)".arg(root.currentTrack.path[index][0])
                                      .arg(Number(root.currentTrack.path[index][1]).toFixed(3))
                                      .arg(Number(root.currentTrack.path[index][2]).toFixed(3))
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                            }
                        }
                        Label10 { text: qsTr("Run notes"); visible: !!(root.doc.problems && root.doc.problems.length) }
                        Repeater {
                            model: root.doc.problems ? root.doc.problems.length : 0
                            delegate: Text {
                                required property int index
                                width: parent.width - 24; wrapMode: Text.WordWrap
                                text: "• " + root.doc.problems[index]
                                color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 10
                            }
                        }
                        Label10 { text: qsTr("Run identity"); visible: root.doc.input !== undefined }
                        Text {
                            width: parent.width - 24; wrapMode: Text.WordWrap
                            visible: root.doc.input !== undefined
                            text: root.doc.input === undefined ? "" :
                                  qsTr("sha256 %1\nsize %2 B · saved mtime %3\nengine %4 · python %5\ncoverage %6")
                                  .arg(String(root.doc.input.sha256).slice(0, 16))
                                  .arg(root.doc.input.size)
                                  .arg(root.doc.input.mtime_ms)
                                  .arg(root.doc.engine ? root.doc.engine.revision : "?")
                                  .arg(root.doc.engine ? root.doc.engine.python : "?")
                                  .arg(root.doc.decode && root.doc.decode.coverage !== null
                                       ? (Number(root.doc.decode.coverage * 100).toFixed(1) + " %") : "—")
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        }
                    }
                }
            }
        }

        // ===== saved runs =====
        Rectangle {
            visible: root.pane === "saved"
            Layout.fillWidth: true; Layout.preferredHeight: 150; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }
            ColumnLayout {
                anchors.fill: parent; spacing: 0
                RowLayout {
                    Layout.fillWidth: true; Layout.preferredHeight: 28
                    Label10 { text: qsTr("Saved run evidence (this application only)"); Layout.leftMargin: 18 }
                    Label10 {
                        Layout.fillWidth: true
                        text: root.chosenPath === "" ? "" :
                              qsTr("%1 saved run(s) of the currently selected recording")
                              .arg(root.priorRunsForCurrent())
                        color: Theme.ink2
                    }
                    Btn { label: qsTr("Refresh"); onClicked: root.refreshSaved() }
                    Btn { label: qsTr("Close"); onClicked: root.pane = "run" }
                }
                QC.ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        id: savedList
                        model: root.saved
                        delegate: Rectangle {
                            required property int index
                            width: savedList.width; height: 30
                            color: savedMa.containsMouse ? Theme.panel : "transparent"
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 12; spacing: 10
                                Text { Layout.preferredWidth: 150; text: root.saved[index].runId; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                                Text { Layout.preferredWidth: 80; text: root.saved[index].status; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                                Text { Layout.fillWidth: true; elide: Text.ElideRight; text: (root.saved[index].inputName || ""); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                Text { Layout.preferredWidth: 130; text: qsTr("%1 tracks · %2 det").arg(root.saved[index].tracks || 0).arg(root.saved[index].detections || 0); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                Text { Layout.preferredWidth: 170; text: (root.saved[index].startedAt || ""); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                            }
                            MouseArea {
                                id: savedMa; anchors.fill: parent; hoverEnabled: true
                                onClicked: {
                                    var d = LabsTrackRuns.loadRun(root.saved[index].runId)
                                    if (d && d.run_id) {
                                        root.doc = d
                                        root.runId = d.run_id + qsTr(" (saved)")
                                        root.trackIndex = -1
                                        root.customPath = d.input && d.input.path ? d.input.path : ""
                                        root.pane = "run"
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
        id: pick
        title: qsTr("Choose a local recording")
        nameFilters: [qsTr("Video") + " (*.mp4 *.mkv *.mov *.m4v *.webm *.ts)"]
        onAccepted: {
            var p = decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, ""))
            root.customPath = p
            root.inputIndex = -1
        }
    }

    // shared with LabsScreen's idiom
    component Btn: Rectangle {
        id: b
        property string label: ""
        property bool enabledLook: true
        signal clicked()
        implicitHeight: 28
        implicitWidth: bt.implicitWidth + 24
        color: bma.containsMouse && b.enabledLook ? Theme.panel : Theme.bg
        border.width: 1
        border.color: bma.containsMouse && b.enabledLook ? Theme.accent : Theme.line2
        opacity: b.enabledLook ? 1.0 : 0.45
        Text { id: bt; anchors.centerIn: parent; text: b.label; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; cursorShape: b.enabledLook ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: b.clicked() }
    }
    component Label10: Text {
        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
    }
}
