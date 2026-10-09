import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import QtMultimedia
import Watchtower

// LabsTrackReview — one completed (or failed/cancelled) tracking run beside its
// recording. The video plays the same local file the helper decoded; overlay boxes
// come ONLY from observed detections joined to receipts (evidence.assignments),
// never interpolated; a selected track's path trail is drawn from its episode's
// bounded samples at their ACTUAL timestamps (not equally spaced). Selecting a
// track seeks the recording to its first observation.
Item {
    id: rev
    property var run: ({})
    property string selectedTrack: ""
    property bool detailsOpen: false

    readonly property var episodes: (run && run.episodes) ? run.episodes : []
    readonly property var assignments: (run && run.assignments) ? run.assignments : []
    readonly property var scope: (run && run.scope) ? run.scope : ({})
    readonly property var wall: (run && run.wall) ? run.wall : ({})
    readonly property var input: (run && run.input) ? run.input : ({})
    readonly property string status: (run && run.status) ? run.status : ""
    readonly property int containerStartMs: Math.round(1000 * (input.container_start_s || 0))
    readonly property bool playable: input.path !== undefined && status !== "cancelled"

    // t_ms -> batch assignments, plus sorted batch times for nearest lookup.
    readonly property var byTms: _indexByTime(assignments)
    readonly property var batchTimes: byTms.times
    readonly property real medianStepMs: byTms.stepMs

    function _indexByTime(list) {
        var map = {}, times = [];
        for (var i = 0; i < list.length; i++) {
            var a = list[i];
            if (map[a.t_ms] === undefined) { map[a.t_ms] = []; times.push(a.t_ms); }
            map[a.t_ms].push(a);
        }
        times.sort(function (x, y) { return x - y; });
        var step = 200;
        if (times.length > 1) {
            var diffs = [];
            for (var k = 1; k < times.length; k++) diffs.push(times[k] - times[k - 1]);
            diffs.sort(function (x, y) { return x - y; });
            step = diffs[Math.floor(diffs.length / 2)];
        }
        return { map: map, times: times, stepMs: step };
    }

    function nearestBoxes(posMs) {
        // Nearest observed batch within half a sampling step; nothing otherwise —
        // an overlay may only draw observed evidence.
        var times = batchTimes;
        if (!times.length) return [];
        var lo = 0, hi = times.length - 1;
        while (lo < hi) { var mid = (lo + hi) >> 1; if (times[mid] < posMs) lo = mid + 1; else hi = mid; }
        var best = times[lo], bd = Math.abs(best - posMs);
        if (lo > 0 && Math.abs(times[lo - 1] - posMs) < bd) { best = times[lo - 1]; bd = Math.abs(times[lo - 1] - posMs); }
        if (bd > Math.max(120, medianStepMs * 0.75)) return [];
        return byTms.map[best] || [];
    }

    function trackColor(tid) {
        var h = 0;
        for (var i = 0; i < tid.length; i++) h = (h * 31 + tid.charCodeAt(i)) >>> 0;
        return Qt.hsla((h % 360) / 360.0, 0.65, 0.55, 1.0);
    }

    function wallText(tms) {
        if (!wall.start_time) return "";
        var d = new Date(Date.parse(wall.start_time) + tms);
        return d.toLocaleTimeString(Qt.locale(), "HH:mm:ss");
    }
    function clipText(ms) {
        var s = Math.round(ms / 1000);
        var m = Math.floor(s / 60);
        return (m < 10 ? "0" : "") + m + ":" + (s % 60 < 10 ? "0" : "") + (s % 60);
    }

    // Opening a run selects its first track and seeks to its first observation —
    // the review starts on evidence, not on an arbitrary frame. NOTE: read `run`
    // directly here — dependent bindings (episodes/playable) may still be stale
    // inside the change handler.
    onRunChanged: {
        selectedTrack = "";
        var eps = (run && run.episodes) ? run.episodes : [];
        if (eps.length > 0) {
            var first = eps[0];
            for (var i = 1; i < eps.length; i++)
                if (eps[i].start_ms < first.start_ms) first = eps[i];
            selectedTrack = first.track_id;
            var inp = (run && run.input) ? run.input : ({});
            var st = (run && run.status) ? run.status : "";
            if (inp.path !== undefined && st !== "cancelled") seekTimer.start();
        }
    }
    // A position set before preroll is silently dropped (the Playback rule); the
    // timer retries until the player is seekable. A frame only reaches the sink
    // while playing, so the review plays from the first observation and lets the
    // operator pause.
    Timer { id: seekTimer; interval: 250; repeat: true
            onTriggered: if (player.seekable) { rev.seekToFirst(); stop() } }
    function seekToFirst() {
        var eps = (run && run.episodes) ? run.episodes : [];
        if (eps.length === 0) return;
        var first = eps[0];
        for (var i = 1; i < eps.length; i++)
            if (eps[i].start_ms < first.start_ms) first = eps[i];
        player.position = containerStartMs + first.start_ms;
        player.play();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- run header ---------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                Rectangle {
                    width: 7; height: 7; radius: 4
                    color: rev.status === "completed" ? Theme.good
                         : rev.status === "cancelled" ? Theme.warn : Theme.bad
                }
                Text {
                    text: (rev.scope.camera_id || "—") + "  ·  "
                          + (rev.wall.start_time ? rev.wall.start_time.replace("T", " ").slice(0, 19) : "—")
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold
                }
                Text {
                    visible: rev.run.synthetic === true
                    text: qsTr("synthetic input")
                    color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                }
                Text {
                    text: rev.status === "completed"
                          ? (rev.episodes.length === 0
                             ? qsTr("completed — no detections")
                             : qsTr("completed — %1 track(s)").arg(rev.episodes.length))
                        : rev.status === "cancelled" ? qsTr("cancelled — results incomplete")
                        : qsTr("failed")
                    color: rev.status === "completed" ? Theme.ink2
                         : rev.status === "cancelled" ? Theme.warn : Theme.bad
                    font.family: Theme.fontMono; font.pixelSize: 11
                }
                Item { Layout.fillWidth: true }
                Text {
                    visible: rev.status === "failed"
                    text: rev.run.error || ""
                    color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 10
                    elide: Text.ElideRight; Layout.maximumWidth: 420
                }
                Text {
                    text: rev.detailsOpen ? qsTr("hide details") : qsTr("details")
                    color: detMa.containsMouse ? Theme.accent : Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                    MouseArea { id: detMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: rev.detailsOpen = !rev.detailsOpen }
                }
            }
        }

        // ---- engineering metadata (details view) ----------------------------
        // Input identity, engine revision and resolved configuration — the facts
        // needed to reproduce this run, kept out of the way until asked for.
        Rectangle {
            visible: rev.detailsOpen
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 120 : 0
            color: Theme.panel
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            Flickable {
                anchors.fill: parent; anchors.margins: 12
                contentWidth: width; contentHeight: detText.implicitHeight
                clip: true
                Text {
                    id: detText
                    width: parent.width
                    wrapMode: Text.WrapAnywhere
                    color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10
                    text: {
                        var e = rev.run.engine || {}, cfg = rev.run.config || {},
                            st = rev.run.stats || {}, inp = rev.input;
                        var eng = e.files_sha256 || {};
                        return qsTr("run %1 · created %2 · input %3 bytes · sha256 %4\n"
                                    + "engine %5 · temporal_tracks %6 · config %7\n"
                                    + "batches %8 · frames %9 decoded · wall %10 s · timing %11 · every %12th frame")
                               .arg(rev.run.run_id || "—").arg(rev.run.created_local || "—")
                               .arg(inp.bytes || 0).arg(inp.sha256 || "—")
                               .arg(e.source_revision || "—")
                               .arg((eng["temporal_tracks.py"] || "—").slice(0, 12))
                               .arg(JSON.stringify(cfg))
                               .arg(st.batches || 0).arg(st.frames_decoded || 0)
                               .arg(st.wall_seconds || 0)
                               .arg(inp.timing_mode || "—").arg(inp.every_nth || 0);
                    }
                }
            }
        }

        // ---- player + overlay ---------------------------------------------
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: rev.width * 0.30
            Layout.minimumHeight: 220
            Rectangle { anchors.fill: parent; color: "#0b0a0a" }

            VideoOutput {
                id: vout
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectFit
            }
            MediaPlayer {
                id: player
                videoOutput: vout
                audioOutput: null
                source: rev.playable ? Qt.url("file://" + rev.input.path) : ""
            }
            // Overlay: exactly over the video's letterboxed rectangle, and only
            // while it holds a frame (the EvHeroPlayer rule for the bars).
            Item {
                id: overlay
                x: vout.contentRect.x; y: vout.contentRect.y
                width: vout.contentRect.width; height: vout.contentRect.height
                visible: width > 0 && vout.sourceRect.width > 0
                clip: true

                Repeater {
                    model: rev.nearestBoxes(player.position - rev.containerStartMs)
                    delegate: Rectangle {
                        required property var modelData
                        readonly property var bb: modelData.bbox
                        x: bb[0] * overlay.width; y: bb[1] * overlay.height
                        width: bb[2] * overlay.width; height: bb[3] * overlay.height
                        color: "transparent"
                        border.width: modelData.status === "ambiguous" ? 2 : 2
                        border.color: modelData.status === "ambiguous" ? Theme.warn
                                    : rev.trackColor(modelData.track_id || "")
                        Rectangle {
                            anchors.left: parent.left; anchors.bottom: parent.top
                            visible: modelData.status === "ambiguous"
                            color: Theme.warn
                            implicitWidth: ambText.implicitWidth + 8; implicitHeight: 14
                            Text { id: ambText; anchors.centerIn: parent
                                   text: qsTr("uncertain"); color: Theme.bg
                                   font.family: Theme.fontMono; font.pixelSize: 9; font.weight: Font.DemiBold }
                        }
                        Text {
                            anchors.left: parent.left; anchors.top: parent.bottom
                            visible: modelData.status !== "ambiguous"
                            text: modelData.track_id || ""
                            color: parent.border.color
                            font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                        }
                    }
                }
                Canvas {
                    id: trailCanvas
                    anchors.fill: parent
                    property int posMs: player.position - rev.containerStartMs
                    property string trackId: rev.selectedTrack
                    onPosMsChanged: requestPaint()
                    onTrackIdChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        if (!trackId) return;
                        for (var i = 0; i < rev.episodes.length; i++) {
                            var ep = rev.episodes[i];
                            if (ep.track_id !== trackId) continue;
                            var pts = [];
                            for (var j = 0; j < ep.path.length; j++)
                                if (ep.path[j][0] <= posMs) pts.push(ep.path[j]);
                            if (!pts.length) return;
                            ctx.strokeStyle = rev.trackColor(trackId);
                            ctx.lineWidth = 2;
                            ctx.beginPath();
                            ctx.moveTo(pts[0][1] * width, pts[0][2] * height);
                            for (var p = 1; p < pts.length; p++)
                                ctx.lineTo(pts[p][1] * width, pts[p][2] * height);
                            ctx.stroke();
                            for (var q = 0; q < pts.length; q++) {
                                ctx.beginPath();
                                ctx.arc(pts[q][1] * width, pts[q][2] * height, 3, 0, 2 * Math.PI);
                                ctx.fillStyle = rev.trackColor(trackId);
                                ctx.fill();
                            }
                            return;
                        }
                    }
                }
            }

            // No-evidence veil for runs without a playable overlay.
            Rectangle {
                anchors.fill: parent
                color: "#0b0a0a"
                visible: !rev.playable
                Text {
                    anchors.centerIn: parent; width: parent.width - 40
                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                    text: rev.status === "cancelled"
                          ? qsTr("Cancelled before completion — no recording review")
                          : qsTr("The recording is not available on this computer")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12
                }
            }
        }

        // ---- transport + timeline ------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            ColumnLayout {
                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                anchors.topMargin: 6; anchors.bottomMargin: 6
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Text {
                        text: player.playbackState === MediaPlayer.PlayingState ? qsTr("Pause") : qsTr("Play")
                        color: playMa.containsMouse ? Theme.accent : Theme.ink
                        font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold
                        MouseArea { id: playMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    enabled: rev.playable
                                    onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play() }
                    }
                    Text {
                        text: rev.clipText(player.position) + " / " + rev.clipText(player.duration)
                              + (rev.wall.start_time ? "   ·   " + rev.wallText(Math.max(0, player.position - rev.containerStartMs)) : "")
                        color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        visible: rev.assignments.length > 0
                        text: qsTr("boxes: observed detections only (every ~%1 ms)").arg(Math.round(rev.medianStepMs))
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                }
                // Episode spans on the clip timeline; click seeks. Gaps between
                // spans are real: nothing is smoothed over them.
                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Canvas {
                        id: tl
                        anchors.fill: parent
                        property int posMs: player.position
                        onPosMsChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            var dur = Math.max(1, player.duration - rev.containerStartMs);
                            ctx.fillStyle = "#1c1b1e";
                            ctx.fillRect(0, 6, width, height - 12);
                            for (var i = 0; i < rev.episodes.length; i++) {
                                var ep = rev.episodes[i];
                                var x0 = width * ep.start_ms / dur;
                                var x1 = width * Math.max(ep.end_ms, ep.start_ms + dur * 0.004) / dur;
                                ctx.fillStyle = rev.trackColor(ep.track_id);
                                ctx.globalAlpha = ep.track_id === rev.selectedTrack ? 1.0 : 0.65;
                                ctx.fillRect(x0, 6, Math.max(2, x1 - x0), height - 12);
                                ctx.globalAlpha = 1.0;
                            }
                            ctx.fillStyle = "#e8e6ea";
                            ctx.fillRect(width * Math.max(0, (posMs - rev.containerStartMs)) / dur, 0, 1.5, height);
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: rev.playable
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                var dur = Math.max(1, player.duration - rev.containerStartMs);
                                player.position = rev.containerStartMs + dur * mouseX / width;
                            }
                        }
                    }
                }
            }
        }

        // ---- tracks list ---------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            color: Theme.bg
            Text {
                anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Tracks — %1").arg(rev.episodes.length)
                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
            }
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: rev.episodes
            QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }
            delegate: Rectangle {
                id: epRow
                required property var modelData
                readonly property var ep: modelData
                readonly property bool sel: ep.track_id === rev.selectedTrack
                width: ListView.view.width
                height: epColumn.implicitHeight + 16
                color: sel ? Theme.panel : (epMa.containsMouse ? Theme.panel : "transparent")
                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                            width: 3; color: rev.trackColor(ep.track_id); visible: true }
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                MouseArea {
                    id: epMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        rev.selectedTrack = ep.track_id;
                        if (rev.playable)
                            player.position = rev.containerStartMs + ep.start_ms;
                    }
                }
                Column {
                    id: epColumn
                    anchors.left: parent.left; anchors.leftMargin: 20; anchors.right: parent.right; anchors.rightMargin: 14
                    anchors.top: parent.top; anchors.topMargin: 8
                    spacing: 2
                    Row {
                        spacing: 10
                        Text { text: ep.track_id; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                        Text {
                            visible: ep.ambiguous_batches > 0
                            text: qsTr("%n uncertain batch(es)", "", ep.ambiguous_batches)
                            color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                        }
                        Text { text: qsTr("ended: %1").arg(ep.reason); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    }
                    Text {
                        color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11
                        text: qsTr("%1 → %2 · %3 ms · %n observation(s)", "", ep.observations)
                              .arg(rev.wallText(ep.start_ms)).arg(rev.wallText(ep.end_ms))
                              .arg(ep.end_ms - ep.start_ms)
                    }
                    Text {
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        text: qsTr("path %1 · net %2 · mean speed %3 · max gap %4 ms")
                              .arg(Number(ep.path_length).toFixed(3))
                              .arg(Number(ep.net_displacement).toFixed(3))
                              .arg(ep.mean_speed === null ? "—" : Number(ep.mean_speed).toFixed(3))
                              .arg(ep.max_observation_gap_ms)
                    }
                }
            }
        }
    }
}
