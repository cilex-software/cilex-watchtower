import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import QtQuick.Dialogs
import QtMultimedia
import Watchtower

// Labs → Objects & colours: the Stage-3 local semantic analysers
// (semantic_object s3-1 + object_colour s3-1) inside the existing Labs screen.
//
// The analysis itself runs in tools/labs/semantic_objects.py as a child
// process (LabsSemanticJob): real decoded frames, real decoded PTS, a local
// pretrained detector and an unweighted region colour sampler. This view only
// selects, launches, watches, cancels, displays and reviews.
//
// HONESTY RULES this view enforces on itself:
//  * a candidate observation is REVIEW REQUIRED until a named reviewer decides;
//    a schema-valid label is never shown as a pass, and a completed run is never
//    coloured green by itself;
//  * boxes are drawn only for the frame window an observation was decoded from
//    (the run carries every decoded frame's PTS); between windows there is
//    nothing, unless the operator switches on the dashed "interpolated" outline;
//  * findings belong to ONE run id and ONE input sha; selecting another input
//    clears them, and a reopened saved run is labelled with its own run id;
//  * missing weights, undecodable input, cancellation and failure are five
//    different banners; none of them reads as success;
//  * the deliberate-invalid control and the renamed-input equivalence control
//    are labelled VERIFICATION and their documents are stored apart from runs.
Item {
    id: root
    property var screen: null
    property string pane: "findings"

    // ---- inputs -------------------------------------------------------------
    property var inputs: []
    property int inputIndex: -1
    property string customPath: ""
    readonly property string chosenPath: customPath !== "" ? customPath
        : (inputIndex >= 0 && inputIndex < inputs.length ? inputs[inputIndex].path : "")

    function refreshInputs() {
        var list = []
        var s3 = LabsTrackRuns.listInputs(Semantic.stage3Dir)
        for (var i = 0; i < s3.length; i++) { s3[i].source = "stage3"; list.push(s3[i]) }
        var ex = LabsTrackRuns.listInputs(Artifacts.exportDir)
        for (var j = 0; j < ex.length; j++) { ex[j].source = "exports"; list.push(ex[j]) }
        inputs = list
        if (inputIndex >= list.length) inputIndex = -1
    }
    function clipIdFor(path) {
        // clip-00N.mp4 in the neutral directory is WT3-00N by the public manifest;
        // anything else gets a local id. The detector never branches on this: it is
        // provenance for the checklist, which is the only label reader.
        var m = /clip-0*(\d+)\.mp4$/.exec(path)
        if (m && path.indexOf(Semantic.stage3Dir) === 0)
            return "WT3-" + ("00" + m[1]).slice(-3)
        var n = path.split("/").pop().replace(/\.[A-Za-z0-9]+$/, "")
        return "local-" + n.slice(0, 40)
    }
    Component.onCompleted: {
        refreshInputs(); refreshSaved()
        if (typeof wtLabsSemanticPane !== "undefined" && wtLabsSemanticPane !== "")
            pane = wtLabsSemanticPane
        if (typeof wtLabsSemanticTest !== "undefined" && wtLabsSemanticTest !== "") {
            customPath = wtLabsSemanticTest
            inputIndex = -1
            startRun()          // drives the REAL controller, like an operator click
            if (typeof wtLabsSemanticCancelMs !== "undefined" && wtLabsSemanticCancelMs !== "") {
                cancelTimer.interval = parseInt(wtLabsSemanticCancelMs, 10) || 1500
                cancelTimer.start()      // cancel DURING the run, like an operator click
            }
        }
    }

    // ---- settings -------------------------------------------------------------
    property string schedule: "adaptive"     // adaptive | whole-second (CASES.md schedule)
    property real sampleFps: 2.0
    property real conf: 0.35
    property int imgsz: 640
    property bool wantCrops: true
    property bool wantTracks: true
    property bool showInterp: false

    // ---- current run ------------------------------------------------------------
    property var doc: ({})
    property string runId: ""
    property string runPath: ""
    property string runInputSha: ""
    property var checklist: ({})
    property var reviewDoc: ({})
    property string reviewer: ""
    property var decisions: ({})
    property int selObs: -1
    property string verifyLog: ""
    property string equivalencePending: ""
    property bool equivalenceDone: false

    function clearRun() {
        doc = ({}) ; runId = "" ; runPath = "" ; runInputSha = ""
        checklist = ({}) ; reviewDoc = ({}) ; decisions = ({}) ; selObs = -1
    }
    function startRun() {
        if (chosenPath === "") return
        clearRun()
        Semantic.startRun(chosenPath, {
            clipId: clipIdFor(chosenPath), schedule: root.schedule, sampleFps: root.sampleFps,
            conf: root.conf, imgsz: root.imgsz, crops: root.wantCrops, tracks: root.wantTracks,
            cameraId: "", unitId: "labs-semantic" })
    }
    Connections {
        target: Semantic
        function onResultChanged() {
            root.doc = Semantic.runDoc
            root.runId = Semantic.runId
            root.runPath = Semantic.runPath
            root.runInputSha = root.doc && root.doc.input_sha256 ? root.doc.input_sha256 : ""
            // an equivalence run is verification evidence, not a clip finding: never save it
            if (root.doc && root.doc.status === "completed" && root.equivalencePending === "")
                LabsTrackRuns.saveRun(root.doc)
            root.refreshSaved()
            if (root.equivalencePending !== "") { root.finishEquivalence(); return }
            root.evaluateChecklist()
            if (typeof wtLabsSemanticVerify !== "undefined" && wtLabsSemanticVerify === "invalid")
                root.runInvalidControl()
            if (typeof wtLabsSemanticVerify !== "undefined" && wtLabsSemanticVerify === "rename"
                    && !root.equivalenceDone && root.doc && root.doc.status === "completed") {
                root.equivalenceDone = true
                eqTimer.start()     // the finished run's child is torn down just after this signal
            }
        }
    }
    Timer {
        id: cancelTimer
        interval: 0; repeat: false
        onTriggered: if (Semantic.busy) Semantic.cancel()
    }
    Timer {
        id: eqTimer
        interval: 150; repeat: true
        onTriggered: {
            if (Semantic.busy) return
            stop()
            root.startEquivalence()
        }
    }
    function evaluateChecklist() {
        if (!runPath || !doc || !doc.clip_id) { checklist = ({}); return }
        checklist = Semantic.evaluate(runPath, doc.clip_id)
    }

    // ---- playback alignment -------------------------------------------------------
    readonly property var frameTimes: (doc.details && doc.details.frame_times_ms)
                                      ? doc.details.frame_times_ms : []
    function frameEndMs(idx) {
        if (idx + 1 < frameTimes.length) return frameTimes[idx + 1]
        if (idx > 0 && idx < frameTimes.length) return frameTimes[idx] + (frameTimes[idx] - frameTimes[idx - 1])
        return (doc.observations && doc.observations[idx]) ? doc.observations[idx].frame_pts_ms + 50 : 0
    }
    function obsVisible(ob) {
        if (!ob) return false
        var p = player.position
        return p >= ob.frame_pts_ms && p < frameEndMs(ob.frame_index)
    }
    function interpBox(ob) {
        if (!ob || !doc.observations) return undefined
        var prev = undefined, next = undefined
        for (var i = 0; i < doc.observations.length; i++) {
            var o = doc.observations[i]
            if (o.class !== ob.class || o.track_id !== ob.track_id) continue
            if (o.frame_pts_ms <= player.position) prev = o
            if (o.frame_pts_ms > player.position && next === undefined) next = o
        }
        if (!prev || !next || next.frame_pts_ms === prev.frame_pts_ms) return undefined
        var f = (player.position - prev.frame_pts_ms) / (next.frame_pts_ms - prev.frame_pts_ms)
        return [prev.bbox_xywh[0] + (next.bbox_xywh[0] - prev.bbox_xywh[0]) * f,
                prev.bbox_xywh[1] + (next.bbox_xywh[1] - prev.bbox_xywh[1]) * f,
                prev.bbox_xywh[2] + (next.bbox_xywh[2] - prev.bbox_xywh[2]) * f,
                prev.bbox_xywh[3] + (next.bbox_xywh[3] - prev.bbox_xywh[3]) * f]
    }
    readonly property real srcAspect: (doc.details && doc.details.media && doc.details.media.width)
        ? doc.details.media.width / doc.details.media.height : 16.0 / 9.0
    function fitRect(w, h) {
        var aw = w, ah = w / srcAspect
        if (ah > h) { ah = h; aw = h * srcAspect }
        return Qt.rect((w - aw) / 2, (h - ah) / 2, aw, ah)
    }
    readonly property var sel: (selObs >= 0 && doc.observations && selObs < doc.observations.length)
                               ? doc.observations[selObs] : undefined

    // ---- saved runs ---------------------------------------------------------------
    property var saved: []
    function refreshSaved() { saved = LabsTrackRuns.listRuns("semantic_object+object_colour") }

    // ---- verification controls ------------------------------------------------------
    function runInvalidControl() {
        if (!runPath || !doc.clip_id) { verifyLog = qsTr("run a real analysis first"); return }
        var r = Semantic.controlInvalid(runPath, doc.clip_id)
        verifyLog = qsTr("VERIFICATION control-invalid: helper status %1, %2 structural error(s): %3")
                    .arg(r.assessment_status || "?").arg((r.validation_errors || []).length)
                    .arg((r.validation_errors || []).slice(0, 4).join(" | "))
    }
    function startEquivalence() {
        if (!chosenPath || Semantic.busy) return
        var copy = Semantic.copyForVerification(chosenPath)
        if (!copy) { verifyLog = qsTr("VERIFICATION renamed-input: could not copy the bytes"); return }
        equivalencePending = runPath
        verifyLog = qsTr("VERIFICATION renamed-input: analysing the same bytes as %1")
                    .arg(copy.split("/").pop())
        Semantic.startRun(copy, {
            clipId: doc.clip_id || clipIdFor(chosenPath), schedule: root.schedule,
            sampleFps: root.sampleFps, conf: root.conf, imgsz: root.imgsz,
            crops: false, tracks: root.wantTracks, cameraId: "", unitId: "labs-semantic" })
    }
    function finishEquivalence() {
        var origPath = equivalencePending
        equivalencePending = ""
        var orig = LabsTrackRuns.loadRun(runIdOfPath(origPath))
        var a = orig && orig.observations ? orig.observations : []
        var b = doc && doc.observations ? doc.observations : []
        var same = a.length === b.length
        for (var i = 0; same && i < a.length; i++)
            same = a[i].class === b[i].class && a[i].frame_index === b[i].frame_index
                && a[i].frame_pts_ms === b[i].frame_pts_ms
                && JSON.stringify(a[i].bbox_xywh) === JSON.stringify(b[i].bbox_xywh)
                && JSON.stringify(a[i].colors) === JSON.stringify(b[i].colors)
        verifyLog = qsTr("VERIFICATION renamed-input: %1 vs %2 observations under a different "
                         + "filename -> %3 (run ids differ: %4 / %5)")
                    .arg(a.length).arg(b.length).arg(same ? qsTr("IDENTICAL") : qsTr("DIFFERENT"))
                    .arg(runIdOfPath(origPath)).arg(runId)
        // the equivalence run is verification evidence, not a clip finding: keep it
        // out of the saved-run list's normal flow by leaving it unsaved here.
        clearRun()
        evaluateChecklist()
    }
    function runIdOfPath(p) {
        for (var i = 0; i < saved.length; i++) if (saved[i].savedPath === p) return saved[i].runId
        return p ? p.split("/").pop().replace(".json", "") : ""
    }

    function stateBanner() {
        switch (Semantic.state) {
        case "running":   return qsTr("Running: decoding and inferring off the GUI thread")
        case "completed": return qsTr("Completed: %1 observations (%2 person, %3 car) over %4 analysed frames")
                               .arg((doc.observations || []).length)
                               .arg(countClass("person")).arg(countClass("car"))
                               .arg(doc.measurements ? doc.measurements.inference_frame_count : 0)
        case "empty":     return qsTr("Completed with no observations above the confidence floor")
        case "cancelled": return qsTr("Cancelled by the operator — partial evidence, not a result")
        case "failed":    return qsTr("Failed: %1").arg(Semantic.errorText)
        case "missing":   return qsTr("Missing prerequisite: %1").arg(Semantic.errorText)
        default:          return qsTr("No analysis yet — choose a recording and start")
        }
    }
    function tgt(i) {
        return (checklist && checklist.targets && checklist.targets[i]) ? checklist.targets[i] : ({})
    }
    function countClass(c) {
        var n = 0
        for (var i = 0; i < (doc.observations || []).length; i++)
            if (doc.observations[i].class === c) n++
        return n
    }

    ColumnLayout {
        anchors.fill: parent; spacing: 0

        // ===== controls =====
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 46; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 8
                Label10 { text: qsTr("Recording") }
                QC.ComboBox {
                    id: inputBox; Layout.preferredWidth: 300
                    model: inputs.map(function (i) { return (i.source === "stage3" ? "◦ " : "") + i.name })
                    currentIndex: root.inputIndex
                    onActivated: (i) => { root.inputIndex = i; root.customPath = ""; root.clearRun() }
                    enabled: !Semantic.busy
                }
                Btn { label: qsTr("Choose…"); enabledLook: !Semantic.busy; onClicked: pick.open() }
                Text { visible: root.customPath !== ""
                       text: qsTr("using %1").arg(root.customPath.split("/").pop())
                       color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 10
                       elide: Text.ElideRight; Layout.preferredWidth: 150 }
                Btn { label: qsTr("Neutral dir…"); onClicked: dirPick.open() }
                Label10 { text: qsTr("conf") }
                QC.SpinBox { from: 10; to: 95; value: root.conf * 100; editable: true
                             onValueChanged: root.conf = value / 100.0; enabled: !Semantic.busy }
                Label10 { text: qsTr("sample fps") }
                QC.SpinBox { from: 1; to: 20; value: root.sampleFps; editable: true
                             onValueChanged: root.sampleFps = value; enabled: !Semantic.busy }
                QC.CheckBox {
                    checked: root.schedule === "whole-second"
                    onToggled: root.schedule = checked ? "whole-second" : "adaptive"
                    enabled: !Semantic.busy
                    text: qsTr("whole-second schedule")
                    contentItem: Text { text: parent.text; color: Theme.ink2
                                        font.family: Theme.fontMono; font.pixelSize: 10
                                        leftPadding: parent.indicator.width + 4; verticalAlignment: Text.AlignVCenter }
                }
                QC.CheckBox {
                    checked: root.wantCrops; onToggled: root.wantCrops = checked
                    enabled: !Semantic.busy; text: qsTr("crops")
                    contentItem: Text { text: parent.text; color: Theme.ink2
                                        font.family: Theme.fontMono; font.pixelSize: 10
                                        leftPadding: parent.indicator.width + 4; verticalAlignment: Text.AlignVCenter }
                }
                Item { Layout.fillWidth: true }
                Btn { label: Semantic.busy ? qsTr("Cancel") : qsTr("Analyse")
                      enabledLook: Semantic.busy || root.chosenPath !== ""
                      onClicked: Semantic.busy ? Semantic.cancel() : root.startRun() }
                Btn { label: qsTr("Saved"); onClicked: root.pane = root.pane === "saved" ? "findings" : "saved" }
            }
        }

        // ===== status =====
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 40; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 10
                Rectangle { width: 8; height: 8; radius: 4
                            color: Semantic.state === "failed" || Semantic.state === "missing" ? Theme.bad
                                 : Semantic.state === "completed" ? Theme.good
                                 : Semantic.state === "cancelled" || Semantic.state === "empty" ? Theme.ink3
                                 : Theme.accent }
                Text { Layout.fillWidth: true; text: root.stateBanner(); elide: Text.ElideRight
                       color: Semantic.state === "failed" || Semantic.state === "missing" ? Theme.bad : Theme.ink
                       font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                Text { visible: Semantic.busy; text: Semantic.statusLine
                       color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                Text { visible: root.runId !== ""; text: qsTr("run %1").arg(root.runId)
                       color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
            }
            Rectangle { visible: Semantic.busy
                        anchors.left: parent.left; anchors.bottom: parent.bottom; height: 2
                        width: parent.width * Semantic.percent / 100.0; color: Theme.accent }
        }

        // ===== pane switch =====
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 34; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; spacing: 12
                LabsSeg {
                    choices: [ { k: qsTr("Findings"), v: "findings" },
                               { k: qsTr("Target checklist"), v: "checklist" },
                               { k: qsTr("Saved evidence"), v: "saved" } ]
                    value: root.pane
                    onPicked: (v) => root.pane = v
                }
                Text { visible: !!(root.doc && root.doc.clip_id)
                       text: qsTr("clip %1 · sha %2 · %3").arg(root.doc.clip_id || "")
                             .arg(String(root.runInputSha || "").slice(0, 12))
                             .arg(root.doc.measurements && root.doc.measurements.peak_rss_method
                            ? String(root.doc.measurements.peak_rss_method).split(" ")[0] : "")
                       color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
            }
        }

        // ===== findings pane =====
        RowLayout {
            visible: root.pane === "findings"
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0

            Rectangle {
                Layout.preferredWidth: 330; Layout.fillHeight: true; color: Theme.bg
                Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.right: parent.right; width: 1; color: Theme.line }
                ColumnLayout {
                    anchors.fill: parent; spacing: 0
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 30; color: Theme.bg
                        RowLayout { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                            Label10 { text: qsTr("Observations"); Layout.fillWidth: true }
                            Label10 { text: (doc.observations || []).length + "" } }
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                    }
                    QC.ScrollView {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        ListView {
                            id: obsList
                            model: (doc.observations || []).length
                            currentIndex: root.selObs
                            delegate: Rectangle {
                                required property int index
                                width: obsList.width; height: 46
                                color: index === root.selObs ? Theme.panel : "transparent"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; spacing: 6
                                    Rectangle { width: 3; height: 30; color: doc.observations[index].class === "person" ? Theme.accent : Theme.info }
                                    Column {
                                        Layout.fillWidth: true
                                        Text { text: doc.observations[index].class + "  " +
                                                    Number(doc.observations[index].confidence).toFixed(2) +
                                                    (doc.observations[index].track_id ? "  ·  " + doc.observations[index].track_id : "")
                                               color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold }
                                        Text { text: qsTr("%1 ms · frame %2 · %3")
                                                   .arg(doc.observations[index].frame_pts_ms)
                                                   .arg(doc.observations[index].frame_index)
                                                   .arg((doc.observations[index].colors || [])
                                                        .map(function (c) { return c.region.split("_")[0] + ":" + c.label }).join(" "))
                                               color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; elide: Text.ElideRight; width: 300 }
                                    }
                                }
                                MouseArea { anchors.fill: parent
                                    onClicked: { root.selObs = index
                                                 player.play(); player.pause()
                                                 player.position = doc.observations[index].frame_pts_ms } }
                            }
                        }
                    }
                }
            }

            Item {
                Layout.fillWidth: true; Layout.fillHeight: true
                Rectangle { anchors.fill: parent; color: "#000000" }
                VideoOutput { id: vo; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectFit
                              visible: root.chosenPath !== "" }
                MediaPlayer { id: player; videoOutput: vo; audioOutput: null
                              source: root.chosenPath !== "" ? ("file://" + root.chosenPath) : "" }
                Item {
                    anchors.fill: parent
                    visible: (doc.observations || []).length > 0
                    Repeater {
                        model: (doc.observations || []).length
                        delegate: Item {
                            required property int index
                            readonly property var ob: doc.observations[index]
                            readonly property bool now: root.obsVisible(ob)
                            readonly property var ib: (!now && root.showInterp) ? root.interpBox(ob) : undefined
                            visible: now || ib !== undefined
                            x: 0; y: 0; width: parent.width; height: parent.height
                            Rectangle {
                                readonly property var fr: root.fitRect(parent.width, parent.height)
                                readonly property var b: now ? ob.bbox_xywh : ib
                                readonly property bool has: b !== undefined && b.length === 4
                                visible: has
                                x: has ? fr.x + b[0] * fr.width : 0
                                y: has ? fr.y + b[1] * fr.height : 0
                                width: has ? b[2] * fr.width : 0
                                height: has ? b[3] * fr.height : 0
                                color: "transparent"
                                border.width: now ? 2 : 1
                                border.color: now ? (ob.class === "person" ? Theme.accent : Theme.info) : Theme.ink3
                                opacity: now ? 0.95 : 0.6
                                Text { x: 2; y: -15
                                       text: ob.class + " " + Number(ob.confidence).toFixed(2)
                                       color: parent.border.color
                                       font.family: Theme.fontMono; font.pixelSize: 10 }
                                Text { x: 2; y: parent.height + 2
                                       visible: now && (ob.colors || []).length > 0
                                       text: (ob.colors || []).map(function (c) { return c.label }).join(" · ")
                                       color: parent.border.color
                                       font.family: Theme.fontMono; font.pixelSize: 9 }
                            }
                        }
                    }
                }
                Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.top: parent.top; anchors.topMargin: 8
                       visible: root.chosenPath !== ""
                       text: qsTr("decoded PTS %1 ms").arg(player.position)
                       color: "#cccccc"; font.family: Theme.fontMono; font.pixelSize: 10 }
                Text { anchors.right: parent.right; anchors.rightMargin: 10; anchors.top: parent.top; anchors.topMargin: 8
                       visible: root.showInterp
                       text: qsTr("dashed outlines are INTERPOLATED, not observed")
                       color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 10 }
                RowLayout {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    anchors.margins: 10; spacing: 10
                    Btn { label: player.playbackState === MediaPlayer.PlayingState ? qsTr("Pause") : qsTr("Play")
                          enabledLook: root.chosenPath !== ""
                          onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play() }
                    QC.Slider { Layout.fillWidth: true; from: 0; to: player.duration > 0 ? player.duration : 1
                                value: player.position; onMoved: player.position = value }
                    QC.CheckBox { checked: root.showInterp; onToggled: root.showInterp = checked
                                  text: qsTr("interpolate")
                                  contentItem: Text { text: parent.text; color: Theme.ink2
                                                      font.family: Theme.fontMono; font.pixelSize: 10
                                                      leftPadding: parent.indicator.width + 4; verticalAlignment: Text.AlignVCenter } }
                }
                Text { anchors.centerIn: parent; visible: root.chosenPath === ""
                       text: qsTr("No recording selected"); color: Theme.ink3
                       font.family: Theme.fontSans; font.pixelSize: 13 }
            }

            Rectangle {
                Layout.preferredWidth: 330; Layout.fillHeight: true; color: Theme.bg
                Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left; width: 1; color: Theme.line }
                QC.ScrollView {
                    anchors.fill: parent
                    Column {
                        width: parent.width; spacing: 8; padding: 12
                        Label10 { text: qsTr("Selected observation"); visible: root.sel !== undefined }
                        Text {
                            width: parent.width - 24; wrapMode: Text.WordWrap
                            visible: root.sel !== undefined
                            text: root.sel === undefined ? "" :
                                  root.sel.class + "  conf " + Number(root.sel.confidence).toFixed(3) +
                                  "  (native: " + (root.sel.native_class || "?") + ")\n" +
                                  qsTr("frame %1 at %2 ms (decoded PTS, first frame = 0)\nbox %3\ntrack %4")
                                  .arg(root.sel.frame_index).arg(root.sel.frame_pts_ms)
                                  .arg(root.sel.bbox_xywh.map(function (v) { return Number(v).toFixed(3) }).join(", "))
                                  .arg(root.sel.track_id || qsTr("none (abstained or untracked)"))
                            color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11
                        }
                        Label10 { text: qsTr("Colour evidence by region"); visible: root.sel !== undefined }
                        Repeater {
                            model: root.sel && root.sel.colors ? root.sel.colors.length : 0
                            delegate: Column {
                                required property int index
                                width: parent.width - 24; spacing: 2
                                Text { text: (root.sel.colors[index].region) + ":  " + root.sel.colors[index].label
                                             + "  conf " + Number(root.sel.colors[index].confidence).toFixed(2)
                                       color: root.sel.colors[index].label === "unknown" ? Theme.ink3 : Theme.ink
                                       font.family: Theme.fontMono; font.pixelSize: 11 }
                                Text { text: qsTr("sampled %1 px, H %2 S %3 V %4, agreement %5")
                                             .arg(root.sel.color_evidence[index].pixels)
                                             .arg(root.sel.color_evidence[index].H)
                                             .arg(root.sel.color_evidence[index].S)
                                             .arg(root.sel.color_evidence[index].V)
                                             .arg(root.sel.color_evidence[index].agreement)
                                       color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; wrapMode: Text.WordWrap; width: parent.width }
                            }
                        }
                        Image {
                            visible: root.sel !== undefined && root.sel.crop !== undefined
                            width: 280; height: sourceSize.height > 0 ? 280 * sourceSize.height / sourceSize.width : 0
                            fillMode: Image.PreserveAspectFit
                            source: root.sel && root.sel.crop
                                    ? "file://" + (doc.details.evidence_dir || "") + "/" + root.sel.crop.file : ""
                        }
                        Label10 { text: qsTr("Crop from the stated frame and box"); visible: root.sel !== undefined && root.sel.crop !== undefined }
                        Label10 { text: qsTr("Run identity"); visible: root.doc.input !== undefined }
                        Text {
                            width: parent.width - 24; wrapMode: Text.WordWrap
                            visible: root.doc.input !== undefined
                            text: root.doc.input === undefined ? "" :
                                  qsTr("sha256 %1\n%2 B · %3×%4 %5 @ %6\nmodel %7 (licence %8)\nweights %9\nelapsed %10 ms · load %11 ms\npeak RSS %12 MB (%13)")
                                  .arg(String(root.doc.input_sha256).slice(0, 16))
                                  .arg(root.doc.input.bytes || root.doc.input.size || "?")
                                  .arg(root.doc.details.media.width).arg(root.doc.details.media.height)
                                  .arg(root.doc.details.media.codec).arg(root.doc.details.media.avg_frame_rate)
                                  .arg(root.doc.model.name).arg(root.doc.model.licence)
                                  .arg(String(root.doc.model.weights_sha256).slice(0, 16))
                                  .arg(root.doc.measurements.elapsed_ms).arg(root.doc.measurements.model_load_ms)
                                  .arg(Math.round(root.doc.measurements.peak_rss_bytes / 1048576))
                                  .arg(root.doc.measurements.peak_rss_method)
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        }
                    }
                }
            }
        }

        // ===== checklist pane =====
        ColumnLayout {
            visible: root.pane === "checklist"
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 40; color: Theme.bg
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 10
                    Text { Layout.fillWidth: true
                           text: checklist && checklist.manifest === false
                                 ? qsTr("No manifest entry for this recording: the target checklist does not apply; the run is still valid evidence.")
                                 : checklist && checklist.identity_mismatch
                                 ? qsTr("The selected run's input hash does not match this manifest clip — refusing to score one clip's run against another's targets.")
                                 : checklist && checklist.status
                                 ? qsTr("Checklist status: %1 · %2").arg(checklist.status)
                                       .arg(JSON.stringify(checklist.summary && checklist.summary.status_counts || {}))
                                 : qsTr("Run an analysis to build the checklist.")
                           color: checklist && checklist.identity_mismatch ? Theme.bad : Theme.ink2
                           font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight }
                    Btn { label: qsTr("Re-evaluate"); enabledLook: root.runPath !== "" && !Semantic.busy
                          onClicked: root.evaluateChecklist() }
                }
            }
            QC.ScrollView {
                Layout.fillWidth: true; Layout.fillHeight: true
                Column {
                    width: parent.width; spacing: 0
                    Repeater {
                        model: checklist && checklist.targets ? checklist.targets.length : 0
                        delegate: Rectangle {
                            required property int index
                            width: parent.width; height: tgtCol.implicitHeight + 18
                            color: index % 2 ? Theme.bg : Theme.panel
                            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                            Column {
                                id: tgtCol; anchors.left: parent.left; anchors.right: parent.right
                                anchors.leftMargin: 18; anchors.rightMargin: 18; anchors.top: parent.top; anchors.topMargin: 9
                                spacing: 5
                                RowLayout {
                                    spacing: 10
                                    Text { text: tgt(index).target_id; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                                    Text { text: tgt(index).class; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                                    Rectangle { width: st.implicitWidth + 14; height: 18; radius: 2
                                                color: tgt(index).status === "accepted" ? Theme.goodSoft
                                                     : tgt(index).status === "rejected" || tgt(index).status === "not_detected" || tgt(index).status === "invalid" ? Theme.badSoft
                                                     : tgt(index).status === "unreviewable" ? Theme.panel2 : Theme.accentSoft
                                                border.color: Theme.line2
                                                Text { id: st; anchors.centerIn: parent; text: tgt(index).status.toUpperCase()
                                                       color: tgt(index).status === "accepted" ? Theme.good
                                                            : tgt(index).status === "rejected" || tgt(index).status === "not_detected" || tgt(index).status === "invalid" ? Theme.bad
                                                            : tgt(index).status === "unreviewable" ? Theme.ink2 : Theme.accent
                                                       font.family: Theme.fontMono; font.pixelSize: 9; font.weight: Font.DemiBold } }
                                    Text { text: qsTr("%1 class candidates · %2 with every required colour on ONE observation")
                                               .arg((tgt(index).class_observation_ids || []).length)
                                               .arg((tgt(index).qualifying_observation_ids || []).length)
                                           color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                }
                                Text { text: qsTr("required: %1").arg((tgt(index).color_candidates || []).map(function (c) {
                                           return c.region + " ∈ {" + c.accepted_labels.join("|") + "}"
                                               + (c.observation_ids.length ? " (" + c.observation_ids.length + " obs)" : " (none)") }).join("  ·  "))
                                       color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; wrapMode: Text.WordWrap; width: parent.width }
                                Text { visible: (tgt(index).review_note || "") !== ""
                                       text: qsTr("reviewer note: %1").arg(tgt(index).review_note)
                                       color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10; wrapMode: Text.WordWrap; width: parent.width }
                                RowLayout {
                                    spacing: 8
                                    Label10 { text: qsTr("Review as") }
                                    QC.TextField {
                                        Layout.preferredWidth: 150; text: root.reviewer
                                        placeholderText: qsTr("reviewer id"); onTextChanged: root.reviewer = text
                                        color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                                        background: Rectangle { color: Theme.bg; border.color: Theme.line2 } }
                                    Label10 { text: qsTr("Observation") }
                                    QC.ComboBox {
                                        id: candBox; Layout.preferredWidth: 150
                                        model: (tgt(index).qualifying_observation_ids || []).length
                                               ? (tgt(index).qualifying_observation_ids || [])
                                               : (tgt(index).class_observation_ids || []).slice(0, 12)
                                        enabled: model.length > 0
                                    }
                                    Btn { label: qsTr("Accept")
                                          enabledLook: root.reviewer !== "" && candBox.currentText !== "" && !Semantic.busy
                                          onClicked: root.recordDecision(tgt(index).target_id, "accepted", candBox.currentText, noteField.text) }
                                    Btn { label: qsTr("Reject")
                                          enabledLook: root.reviewer !== "" && noteField.text.trim() !== ""
                                          onClicked: root.recordDecision(tgt(index).target_id, "rejected", candBox.currentText, noteField.text) }
                                    Btn { label: qsTr("Unreviewable")
                                          enabledLook: root.reviewer !== "" && noteField.text.trim() !== ""
                                          onClicked: root.recordDecision(tgt(index).target_id, "unreviewable", candBox.currentText, noteField.text) }
                                    Btn { label: qsTr("Show on video")
                                          enabledLook: candBox.currentText !== ""
                                          onClicked: root.jumpToObservation(candBox.currentText) }
                                }
                                QC.TextField {
                                    id: noteField; Layout.fillWidth: true
                                    placeholderText: qsTr("note / reason (required for reject and unreviewable)")
                                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                                    background: Rectangle { color: Theme.bg; border.color: Theme.line2 } }
                            }
                        }
                    }
                    Rectangle {
                        width: parent.width; height: verCol.implicitHeight + 20; color: Theme.bg
                        Column {
                            id: verCol; anchors.left: parent.left; anchors.right: parent.right
                            anchors.margins: 18; anchors.top: parent.top; anchors.topMargin: 10; spacing: 8
                            Label10 { text: qsTr("Verification controls (CASES.md S3-C02, S3-C09)") }
                            RowLayout {
                                spacing: 8
                                Btn { label: qsTr("Deliberate invalid result"); enabledLook: root.runPath !== ""
                                      onClicked: root.runInvalidControl() }
                                Btn { label: qsTr("Renamed-input equivalence"); enabledLook: root.chosenPath !== "" && !Semantic.busy
                                      onClicked: root.startEquivalence() }
                                Btn { label: qsTr("Common helper self-tests"); enabledLook: !Verify.busy
                                      onClicked: {
                                          Verify.clearQueue()
                                          Verify.enqueue("s3-helper", "Stage-3 common helper self-tests",
                                                         ["python3", Semantic.toolsDir + "/../tests/labs-stage3-evidence.py"], 300)
                                          Verify.startQueue()
                                      } }
                            }
                            Text { visible: root.verifyLog !== ""; text: root.verifyLog
                                   color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 10
                                   wrapMode: Text.WordWrap; width: parent.width }
                            Text { visible: checklist && (checklist.validation_errors || []).length > 0
                                   text: qsTr("structural errors: %1").arg((checklist.validation_errors || []).join(" | "))
                                   color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 10
                                   wrapMode: Text.WordWrap; width: parent.width }
                        }
                    }
                }
            }
        }

        // ===== saved pane =====
        ColumnLayout {
            visible: root.pane === "saved"
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 30; color: Theme.bg
                RowLayout { anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 12
                    Label10 { text: qsTr("Saved semantic runs (this application only)"); Layout.fillWidth: true }
                    Btn { label: qsTr("Refresh"); onClicked: root.refreshSaved() } }
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            }
            QC.ScrollView {
                Layout.fillWidth: true; Layout.fillHeight: true
                ListView {
                    id: savedList; model: root.saved
                    delegate: Rectangle {
                        required property int index
                        width: savedList.width; height: 32
                        color: sma.containsMouse ? Theme.panel : "transparent"
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 12; spacing: 10
                            Text { Layout.preferredWidth: 120; text: root.saved[index].runId; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                            Text { Layout.preferredWidth: 80; text: root.saved[index].status; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                            Text { Layout.preferredWidth: 90; text: root.saved[index].clipId || ""; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                            Text { Layout.fillWidth: true; elide: Text.ElideRight; text: (root.saved[index].inputName || ""); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                            Text { Layout.preferredWidth: 120; text: qsTr("%1 obs").arg(root.saved[index].observations || 0); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                            Text { Layout.preferredWidth: 170; text: (root.saved[index].startedAt || ""); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                        }
                        MouseArea { id: sma; anchors.fill: parent; hoverEnabled: true
                            onClicked: root.openSaved(root.saved[index].runId) }
                    }
                }
            }
        }
    }

    function jumpToObservation(oid) {
        if (!doc.observations) return
        for (var i = 0; i < doc.observations.length; i++)
            if (doc.observations[i].id === oid) {
                root.pane = "findings"
                root.selObs = i
                player.play(); player.pause()
                player.position = doc.observations[i].frame_pts_ms
                return
            }
    }
    function recordDecision(targetId, decision, obsId, note) {
        var d = { target_id: targetId, decision: decision,
                  observation_ids: obsId ? [obsId] : [], note: note || "" }
        var list = []
        for (var k in decisions) if (k !== targetId) list.push(decisions[k])
        list.push(d)
        decisions = list
        var res = Semantic.recordReview(runPath, doc.clip_id, reviewer, list)
        if (res && res.error) { verifyLog = qsTr("review refused: %1").arg(res.error); return }
        reviewDoc = res || ({})
        verifyLog = qsTr("review recorded by %1: checklist status %2")
                    .arg(reviewer).arg(res && res.status ? res.status : "?")
        evaluateChecklistWithReview()
    }
    function evaluateChecklistWithReview() {
        // re-evaluate with the stored review so statuses show the decisions
        var r = Semantic.evaluate(runPath, doc.clip_id)
        if (reviewDoc && reviewDoc.review_path) {
            var st = statusWithReview(runPath, reviewDoc.review_path, doc.clip_id)
            if (st && st.targets) { r.targets = st.targets; r.status = st.status; r.summary = st.summary }
        }
        checklist = r
    }
    function statusWithReview(runPath, reviewPath, clipId) {
        return Semantic.statusOf ? Semantic.statusOf(runPath, reviewPath, clipId) : ({})
    }
    function openSaved(runId) {
        var d = LabsTrackRuns.loadRun(runId)
        if (!d || !d.run_id) return
        clearRun()
        doc = d; runId = d.run_id
        runInputSha = d.input_sha256 || ""
        if (d.details && d.details.input_path) customPath = d.details.input_path
        evaluateChecklist()
        pane = "findings"
    }

    FileDialog {
        id: pick; title: qsTr("Choose a local recording")
        nameFilters: [qsTr("Video") + " (*.mp4 *.mkv *.mov *.m4v *.webm *.ts)"]
        onAccepted: { customPath = decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, ""))
                      inputIndex = -1; clearRun() }
    }
    FolderDialog {
        id: dirPick; title: qsTr("Choose the neutral recording directory")
        onAccepted: { Semantic.stage3Dir = decodeURIComponent(selectedFolder.toString().replace(/^file:\/\//, ""))
                      refreshInputs() }
    }

    component Btn: Rectangle {
        id: b
        property string label: ""
        property bool enabledLook: true
        signal clicked()
        implicitHeight: 28; implicitWidth: bt.implicitWidth + 24
        color: bma.containsMouse && b.enabledLook ? Theme.panel : Theme.bg
        border.width: 1; border.color: bma.containsMouse && b.enabledLook ? Theme.accent : Theme.line2
        opacity: b.enabledLook ? 1.0 : 0.45
        Text { id: bt; anchors.centerIn: parent; text: b.label; color: Theme.ink
               font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true
                    cursorShape: b.enabledLook ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: b.clicked() }
    }
    component Label10: Text {
        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
    }
}
