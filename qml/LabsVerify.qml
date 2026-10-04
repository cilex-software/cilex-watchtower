import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Labs → Verification: runs THIS repository's real checks as child processes and
// shows every line they print, plus integration self-checks that drive the same
// LabsTrackJob the operator's analysis uses. Nothing here reads a prewritten
// report: a row is green only because a process that just ran exited zero.
//
// Groups:
//   contract        tools/tests/labs-temporal-tracks.py (public cases + checks + workload)
//   contract-fast   the same suite without the 100k-batch workload
//   regress-worker  tools/tests/labs-worker.py (the protected worker suite)
//   regress-shape   tools/labs/selftest_shape_observations.py
//   regress-prof    tools/labs/selftest_object_profile.py
//   workload        the declared streaming/resource workload, measured here and now
//   integration     synthetic-clip run, identity, alignment, repeat, cancel, evidence
//   failure         a deliberate failure the interface must show as a failure
//
// A group that has not been run says NOT RUN; a cancelled or timed-out group says
// so. Neither is a pass and neither is a zero. The synthetic clip is generated
// locally and labelled SYNTHETIC everywhere it appears: it is a verification
// input, never footage and never a recognition claim.
Item {
    id: root
    property var screen: null

    readonly property string tools: LabsTrack.toolsDir          // <repo>/tools/labs
    readonly property string repoTools: tools === "" ? "" : tools + "/.."
    readonly property bool available: tools !== ""
    readonly property string synClip: LabsTrackRuns.runsDir + "/synthetic-verify-clip.mp4"

    Component.onCompleted: {
        if (typeof wtLabsVerifyTest === "undefined" || wtLabsVerifyTest === "") return
        if (wtLabsVerifyTest === "failure") failureControl()
        else if (wtLabsVerifyTest === "integration") beginIntegration()
        else if (wtLabsVerifyTest === "workload") runGroup("workload")
        else if (wtLabsVerifyTest === "all") runAll()
    }

    ListModel { id: log }
    readonly property int capLines: 4000
    function push(check, kind, text) {
        while (log.count >= capLines) log.remove(0)
        log.append({ check: check, kind: kind, line: text })
    }

    property var groups: [
        { id: "contract",       title: qsTr("Contract cases & checks (full suite)"),   state: "notrun", summary: "" },
        { id: "contract-fast",  title: qsTr("Contract cases & checks (no workload)"),  state: "notrun", summary: "" },
        { id: "regress-worker", title: qsTr("Labs worker regression suite"),           state: "notrun", summary: "" },
        { id: "regress-shape",  title: qsTr("Shape-observations self-test"),           state: "notrun", summary: "" },
        { id: "regress-prof",   title: qsTr("Object-profile self-test"),               state: "notrun", summary: "" },
        { id: "workload",       title: qsTr("Streaming resource workload (measured)"), state: "notrun", summary: "" },
        { id: "integration",    title: qsTr("Integration self-checks (this app)"),      state: "notrun", summary: "" },
        { id: "failure",        title: qsTr("Failure control (must show a failure)"),   state: "notrun", summary: "" }
    ]
    function setGroup(id, state, summary) {
        for (var i = 0; i < groups.length; i++)
            if (groups[i].id === id) { groups[i].state = state; groups[i].summary = summary; break }
        groups = groups.slice()
    }
    function mark(id, ok, summary) {
        // A group is only as green as its worst step: later passes must not
        // paint over an earlier failure.
        var was = "pass"
        for (var i = 0; i < groups.length; i++)
            if (groups[i].id === id) was = groups[i].state
        setGroup(id, (ok && was !== "fail") ? "pass" : "fail", summary)
        push(id, ok ? "pass" : "fail", "— " + id + ": " + summary)
    }

    Connections {
        target: Verify
        function onLineReceived(checkId, kind, text) { root.push(checkId, kind, text) }
        function onCheckFinished(checkId, ok, exitCode, summary) {
            push(checkId, ok ? "pass" : "fail",
                 "— " + checkId + ": " + summary + (ok ? "" : "  [exit " + exitCode + "]"))
            if (checkId !== "integration-gen")
                setGroup(checkId, ok ? "pass" : "fail", summary)
        }
        function onQueueFinished() {
            if (root.pendingIntegration) root.beginIntegration()
        }
    }

    function runGroup(id) {
        if (!available) { push(id, "fail", qsTr("the tools tree is not beside this binary; nothing can run")); return }
        if (id === "integration") { beginIntegration(); return }
        if (id === "failure") { failureControl(); return }
        Verify.clearQueue()
        enqueueOne(id)
        setGroup(id, "running", "")
        Verify.startQueue()
    }
    function enqueueOne(id) {
        if (id === "contract")
            Verify.enqueue(id, "Contract cases & checks (full suite)",
                               ["python3", repoTools + "/tests/labs-temporal-tracks.py"], 900)
        else if (id === "contract-fast")
            Verify.enqueueEnv(id, "Contract cases & checks (no workload)",
                                  ["python3", repoTools + "/tests/labs-temporal-tracks.py"], 300,
                                  { "WT_SHORT": "1" })
        else if (id === "regress-worker")
            Verify.enqueue(id, "Labs worker regression suite",
                               ["python3", repoTools + "/tests/labs-worker.py"], 600)
        else if (id === "regress-shape")
            Verify.enqueue(id, "Shape-observations self-test",
                               ["python3", tools + "/selftest_shape_observations.py"], 300)
        else if (id === "regress-prof")
            Verify.enqueue(id, "Object-profile self-test",
                               ["python3", tools + "/selftest_object_profile.py"], 300)
        else if (id === "workload")
            Verify.enqueue(id, "Streaming resource workload (measured)",
                               ["python3", repoTools + "/tests/fixtures/temporal_tracks/workload.py"], 900)
    }
    function runAll() {
        if (!available || Verify.busy) return
        Verify.clearQueue()
        enqueueOne("contract-fast")
        enqueueOne("regress-worker")
        enqueueOne("regress-shape")
        enqueueOne("regress-prof")
        setGroup("contract-fast", "running", "")
        setGroup("regress-worker", "running", "")
        setGroup("regress-shape", "running", "")
        setGroup("regress-prof", "running", "")
        root.pendingIntegration = true      // integration follows once the queue drains
        Verify.startQueue()
    }

    // ---- integration self-checks: the same job the operator runs ---------------
    property bool pendingIntegration: false
    property string iwait: ""
    property var idoc: ({})
    property string irun1: ""
    property var icounts1: ({})
    property string isha1: ""
    property bool cancelSent: false

    function beginIntegration() {
        pendingIntegration = false
        if (!available) { mark("integration", false, qsTr("tools tree missing")); return }
        setGroup("integration", "running", "")
        push("integration", "section", qsTr("integration: generating a SYNTHETIC clip (labelled, not footage)"))
        Verify.clearQueue()
        // overlay's x/y are evaluated per frame (drawbox's are not, on ffmpeg 6.1:
        // measured identical frames), so this is what actually moves.
        Verify.enqueue("integration-gen", "synthetic clip",
                       ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                        "-f", "lavfi", "-i", "color=c=black:s=320x240:d=6:r=20",
                        "-f", "lavfi", "-i", "color=c=white:s=48x72:d=6:r=20",
                        "-filter_complex", "[0:v][1:v]overlay=x='mod(t*48,272)':y=90",
                        "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "veryfast",
                        synClip], 120)
        Verify.startQueue()
        iwait = "gen"
    }

    Timer {
        id: ipoll
        interval: 250; running: root.iwait !== ""; repeat: true
        onTriggered: root.integrationTick()
    }

    function integrationTick() {
        if (iwait === "gen") {
            if (Verify.busy) return
            iwait = "run1"
            push("integration", "section", qsTr("integration: real run on the synthetic clip"))
            LabsTrack.startRun(synClip, "verify-synthetic", "verify-unit", "SYNTHETIC-verify", -1, "", 10, 0)
            return
        }
        if (iwait === "run1") {
            if (LabsTrack.busy) return
            iwait = ""
            var st = LabsTrack.state
            idoc = LabsTrack.result
            irun1 = LabsTrack.runId
            icounts1 = idoc.counts ? idoc.counts : ({})
            isha1 = idoc.input ? String(idoc.input.sha256) : ""
            mark("integration", st === "completed" && isha1.length === 64
                 && (icounts1.tracks || 0) > 0,
                 qsTr("run 1: state %1, %2 tracks from %3 detections, input sha256 %4…")
                     .arg(st).arg(icounts1.tracks !== undefined ? icounts1.tracks : 0)
                     .arg(icounts1.detections !== undefined ? icounts1.detections : 0)
                     .arg(isha1.slice(0, 12)))
            if (st !== "completed") return
            var obs = idoc.observations || []
            var mono = true, inRange = true
            var lastByTrack = ({})
            for (var i = 0; i < obs.length; i++) {
                var o = obs[i]
                if (o.truncated) continue
                if (lastByTrack[o.track] !== undefined && o.t_ms <= lastByTrack[o.track]) mono = false
                lastByTrack[o.track] = o.t_ms
                if (o.t_ms < 0 || (idoc.decode && o.t_ms > idoc.decode.duration_s * 1000 + 1000)) inRange = false
            }
            mark("integration", mono && inRange && obs.length > 0,
                 qsTr("alignment: %1 observations, times monotonic per track and inside the clip")
                     .arg(obs.length))
            iwait = "run2"
            push("integration", "section", qsTr("integration: a repeat run must agree and must not be stale"))
            LabsTrack.startRun(synClip, "verify-synthetic", "verify-unit", "SYNTHETIC-verify", -1, "", 10, 0)
            return
        }
        if (iwait === "run2") {
            if (LabsTrack.busy) return
            iwait = ""
            var d2 = LabsTrack.result
            var same = d2.input && d2.input.sha256 === isha1
                && d2.counts && icounts1
                && d2.counts.tracks === icounts1.tracks
                && d2.counts.detections === icounts1.detections
            mark("integration", same && LabsTrack.runId !== irun1,
                 qsTr("repeat: same input identity and counts under a distinct run id (%1 → %2)")
                     .arg(irun1).arg(LabsTrack.runId))
            iwait = "cancel"
            push("integration", "section", qsTr("integration: cancellation must report cancelled, not success"))
            // Cancel in the same tick the child is spawned: a 6 s synthetic clip
            // decodes in well under a second, so a timed cancel would race the
            // finish and "prove" nothing. Whatever the signal's timing, the run
            // must come back cancelled, never completed.
            LabsTrack.startRun(synClip, "verify-synthetic", "verify-unit", "SYNTHETIC-verify", -1, "", 60, 0)
            LabsTrack.cancel()
            return
        }
        if (iwait === "cancel") {
            if (LabsTrack.busy) return
            var cst = LabsTrack.state
            mark("integration", cst === "cancelled",
                 qsTr("cancel at spawn: the stopped run reported state '%1'").arg(cst))
            var inputs = LabsTrackRuns.listInputs(Artifacts.exportDir)
            if (inputs.length === 0) {
                mark("integration", false, qsTr("cancel mid-run: SKIPPED, no local recording in %1")
                     .arg(Artifacts.exportDir))
                iwait = ""
                integrationEvidence()
                return
            }
            iwait = "cancel2"
            push("integration", "section", qsTr("integration: cancelling a live run mid-decode"))
            LabsTrack.startRun(inputs[0].path, "verify-cancel", "verify-unit", "", -1, "", 600, 0)
            return
        }
        if (iwait === "cancel2") {
            if (LabsTrack.busy) return
            var c2 = LabsTrack.state
            iwait = ""
            mark("integration", c2 === "cancelled",
                 qsTr("cancel mid-decode of a real recording: state '%1'").arg(c2))
            integrationEvidence()
            return
        }
    }
    function integrationEvidence() {
        push("integration", "section", qsTr("integration: run evidence saved, listed and reopened"))
        var saved = LabsTrackRuns.saveRun(idoc)
        var back = LabsTrackRuns.loadRun(idoc.run_id)
        var listed = false
        var runs = LabsTrackRuns.listRuns()
        for (var k = 0; k < runs.length; k++) if (runs[k].runId === idoc.run_id) listed = true
        mark("integration", saved !== "" && back && back.run_id === idoc.run_id && listed,
             qsTr("evidence: saved to %1 and reopened with the same run id").arg(saved))
    }

    function failureControl() {
        setGroup("failure", "running", "")
        push("failure", "section", qsTr("failure control: a run on a path that does not exist must be shown as a failure"))
        // iwait BEFORE startRun: a missing input is refused synchronously inside
        // startRun, so the state change lands before this function returns and
        // the handler would otherwise see an unarmed step and stay "running".
        iwait = "fail"
        LabsTrack.startRun(LabsTrackRuns.runsDir + "/does-not-exist.mp4", "verify", "verify-unit",
                           "", -1, "", 10, 0)
    }
    // The failure step rides the same poll timer; it is terminal for iwait.
    Connections {
        target: LabsTrack
        function onStateChanged() {
            // Cancel once the child is provably alive (its meta line arrived):
            // progress lines only start after the analyser's priming pass, which
            // on a 1440p recording is longer than the cancel grace window.
            if (root.iwait === "cancel2" && LabsTrack.busy && LabsTrack.started && !cancelSent) {
                cancelSent = true
                LabsTrack.cancel()
            }
            if (root.iwait !== "fail" || LabsTrack.busy) return
            var st = LabsTrack.state
            root.iwait = ""
            root.mark("failure", st === "failed" && LabsTrack.errorText !== "",
                      qsTr("deliberate failure surfaced as state '%1' with the message '%2'")
                          .arg(st).arg(LabsTrack.errorText))
        }
    }

    function saveEvidence() {
        var doc = {
            run_id: "verify-" + Date.now().toString(36),
            kind: "verification",
            started_at: new Date().toISOString(),
            build: (typeof wtBuild !== "undefined" ? wtBuild : "?") + " "
                   + (typeof wtVersion !== "undefined" ? wtVersion : "?"),
            groups: groups.map(function (g) { return { id: g.id, title: g.title, state: g.state, summary: g.summary } }),
            log_tail: logTail()
        }
        var p = LabsTrackRuns.saveRun(doc)
        push("evidence", p !== "" ? "pass" : "fail", qsTr("verification evidence saved: %1").arg(p))
    }
    function logTail() {
        var out = []
        for (var i = Math.max(0, log.count - 400); i < log.count; i++) out.push(log.get(i))
        return out
    }

    ColumnLayout {
        anchors.fill: parent; spacing: 0
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 46; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 10
                Label10 { text: qsTr("Verification") }
                Text {
                    Layout.fillWidth: true
                    text: available ? qsTr("Runs this repository's real checks as child processes and shows what they print now.")
                                    : qsTr("The Labs tools tree is not beside this binary: verification cannot run here.")
                    color: available ? Theme.ink2 : Theme.bad
                    font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
                }
                Btn { label: qsTr("Run all (no workload)"); enabledLook: available && !Verify.busy && !LabsTrack.busy
                      onClicked: root.runAll() }
                Btn { label: qsTr("Cancel"); visible: Verify.busy; onClicked: Verify.cancel() }
                Btn { label: qsTr("Save evidence"); enabledLook: available; onClicked: root.saveEvidence() }
            }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
            Rectangle {
                Layout.preferredWidth: 440; Layout.fillHeight: true; color: Theme.bg
                Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.right: parent.right; width: 1; color: Theme.line }
                ListView {
                    id: groupList
                    anchors.fill: parent
                    model: root.groups
                    delegate: Rectangle {
                        required property var modelData
                        width: groupList.width; height: 52
                        color: gma.containsMouse ? Theme.panel : "transparent"
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12; spacing: 8
                            Rectangle {
                                width: 9; height: 9; radius: 5
                                color: modelData.state === "pass" ? Theme.good
                                     : modelData.state === "fail" ? Theme.bad
                                     : modelData.state === "running" ? Theme.accent : Theme.line2
                            }
                            Column {
                                Layout.fillWidth: true
                                Text { text: modelData.title; color: Theme.ink
                                       font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium
                                       elide: Text.ElideRight; width: 260 }
                                Text { text: modelData.state === "notrun" ? qsTr("NOT RUN")
                                             : modelData.state === "running" ? qsTr("running…")
                                             : modelData.summary
                                       color: modelData.state === "fail" ? Theme.bad : Theme.ink3
                                       font.family: Theme.fontMono; font.pixelSize: 10
                                       elide: Text.ElideRight; width: 260 }
                            }
                            Btn { label: qsTr("Run"); enabledLook: modelData.state !== "running" && !Verify.busy
                                  onClicked: root.runGroup(modelData.id) }
                        }
                        MouseArea { id: gma; anchors.fill: parent; hoverEnabled: true; z: -1 }
                    }
                }
            }
            QC.ScrollView {
                Layout.fillWidth: true; Layout.fillHeight: true
                ListView {
                    id: logView
                    model: log
                    onCountChanged: positionViewAtEnd()
                    delegate: Text {
                        required property string line
                        required property string kind
                        width: logView.width - 24
                        text: line
                        elide: Text.ElideRight
                        color: kind === "fail" || kind === "error" ? Theme.bad
                             : kind === "pass" ? Theme.ink2
                             : kind === "section" ? Theme.accent : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 10
                        leftPadding: 12; topPadding: 1
                    }
                }
            }
        }
    }

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
