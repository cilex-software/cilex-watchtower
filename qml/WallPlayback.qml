import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Watchtower

// Synchronized wall playback (E1). The whole visible wall rewinds to one instant
// and plays back in lock-step. Because the backend composites the grid into ONE
// HLS stream (server-side, perfectly synced), the client renders a single video
// surface (which visually *is* the grid) + per-cell label overlays placed from
// the backend's cells[] mapping, plus a master timeline/transport and the
// union-coverage calendar. One decode, one timeline — no client-side sync.
//
// Until the backend ships POST /review/mosaic-sessions this lands on an honest
// "compositing pending" state (never a broken player, never fabricated frames).
Item {
    id: root

    property var cameras: []          // the wall page's camera maps (≤16), in display order
    property var client: null         // PlaybackClient
    property var cameraModel: null

    signal returnToLive()

    // session/composited-timeline state
    property string sessionId: ""
    property var grid: ({})           // {cols,rows,cell_w,cell_h,width,height,fps,codec}
    property var cells: []            // [{index,camera_id,row,col}]
    property var frags: []            // composited fragments {cs,ce,ws,we,avail}
    property double compactDuration: 0
    property double winStartMs: 0
    property double winEndMs: 0
    property int zoomMin: 60          // 15 / 60 / 360 / 720 / 1440
    property string selectedDay: ""
    property bool loading: false
    property string errorText: ""     // honest pending/error message
    property bool pending: false      // true = backend compositing not available yet

    // In/Out clip selection on the master timeline (wall ms; -1 = none)
    property double selStartMs: -1
    property double selEndMs: -1
    readonly property bool hasSelection: selStartMs >= 0 && selEndMs > selStartMs
    // timeline view window (a zoomable subset of [winStartMs, winEndMs])
    property double viewStartMs: 0
    property double viewEndMs: 0
    function resetView() { viewStartMs = winStartMs; viewEndMs = winEndMs; selStartMs = -1; selEndMs = -1; }

    // coverage (union) for the calendar
    property int retentionDays: 35
    property var footageDays: []
    property bool coveragePending: true

    // ---- user-assigned wall cameras (picker) -------------------------------
    // The wall is seeded from the live page on entry, but the operator can
    // assign any ≤16 cameras from the full roster; Apply re-composites the same
    // wall window and restores the playhead.
    property bool pickerOpen: false
    property var pickIds: ({})           // camId -> true (picker working set)
    property string pickSearch: ""
    property double _pendingSeekMs: -1   // restore playhead after re-open (applied when seekable)
    readonly property int pickerCount: { var n = 0; var m = pickIds; for (var k in m) n++; return n }
    readonly property var pickerRows: {
        var out = [];
        var n = cameraModel ? cameraModel.total : 0;
        var q = pickSearch.toLowerCase();
        for (var i = 0; i < n; i++) {
            var c = cameraModel.get(i);
            if (!c || !c.camId) continue;
            if (q !== "" && ("" + c.name).toLowerCase().indexOf(q) < 0
                         && ("" + c.ip).indexOf(q) < 0
                         && ("" + c.groupName).toLowerCase().indexOf(q) < 0) continue;
            out.push(c);
        }
        return out;
    }
    function openPicker() {
        var m = ({});
        for (var i = 0; i < cameras.length; i++)
            if (cameras[i].camId) m[cameras[i].camId] = true;
        pickIds = m; pickSearch = ""; pickerOpen = true;
    }
    function togglePick(id) {
        var m = ({});
        for (var k in pickIds) m[k] = true;
        if (m[id]) delete m[id];
        else { if (pickerCount >= 16) return; m[id] = true; }   // hard cap: 16 cells
        pickIds = m;
    }
    function applyPick() {
        var out = [];
        var n = cameraModel ? cameraModel.total : 0;
        for (var i = 0; i < n && out.length < 16; i++) {
            var c = cameraModel.get(i);
            if (c && c.camId && pickIds[c.camId] === true) out.push(c);
        }
        if (out.length === 0) return;
        pickerOpen = false;
        var keepMs = frags.length ? playheadMs : -1;
        cameras = out;
        if (winEndMs > winStartMs && winStartMs > 0) _open(winStartMs, winEndMs);  // same wall window
        else openFor(zoomMin || 60);
        _pendingSeekMs = keepMs;         // set AFTER _open (which resets it)
    }

    function pad(n) { return (n < 10 ? "0" : "") + n }
    function fmtClock(ms) { return (!ms || isNaN(ms)) ? "—" : Settings.clock(ms, true) }

    function camIds() {
        var out = [];
        for (var i = 0; i < cameras.length && out.length < 16; i++) {
            var id = client ? (client.cameraIdForIp(cameras[i].ip) || client.cameraIdForMac(cameras[i].mac || "")) : "";
            if (id !== "") out.push(id);
        }
        return out;
    }
    function gridDims(n) {
        var cols = Math.ceil(Math.sqrt(Math.max(1, n)));
        var rows = Math.ceil(n / cols);
        return { cols: cols, rows: rows };
    }

    // compact player-seconds → wall ms (via composited fragments)
    function posToWall(sec) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (sec >= f.cs && sec <= f.ce) {
                var frac = (f.ce > f.cs) ? (sec - f.cs) / (f.ce - f.cs) : 0;
                return f.ws + frac * (f.we - f.ws);
            }
        }
        return frags.length ? frags[0].ws : winStartMs;
    }
    function wallToPos(ms) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (ms >= f.ws && ms <= f.we) {
                var frac = (f.we > f.ws) ? (ms - f.ws) / (f.we - f.ws) : 0;
                return f.cs + frac * (f.ce - f.cs);
            }
        }
        return 0;
    }
    readonly property double playheadMs: posToWall(player.position / 1000)
    function seekToWall(ms) {
        if (player.duration <= 0) return;
        player.position = Math.round(wallToPos(ms) * 1000);
    }

    // ---- open / transport --------------------------------------------------
    function _windowFor(spanMin) {
        var end = Date.now();
        var start = end - spanMin * 60000;
        return { s: start, e: end };
    }
    function openFor(spanMin) {
        zoomMin = spanMin || zoomMin;
        selectedDay = "";
        var w = _windowFor(zoomMin);
        _open(w.s, w.e);
    }
    function openForDay(dateStr) {
        selectedDay = dateStr;
        var s = new Date(dateStr + "T00:00:00").getTime();
        _open(s, Math.min(s + 86400000, Date.now()));
        zoomMin = 1440;
    }
    function _open(startMs, endMs) {
        if (!client || cameras.length === 0) return;
        renderGuard.stop();
        errorText = ""; pending = false; loading = true;
        sessionId = ""; frags = []; grid = ({}); cells = []; _pendingSeekMs = -1;
        // Fully unload (not just stop): Qt 6.4's stop() re-prerolls the old media
        // at position 0, re-downloading its first segments through the proxy while
        // the new session is created (see PlaybackScreen's matching note).
        player.stop();
        player.source = "";
        var ids = camIds();
        if (ids.length === 0) { loading = false; errorText = "These cameras aren't in the recording backend."; return; }
        var d = gridDims(ids.length);
        client.ensureReady();
        client.fetchCoverageUnion(ids);
        client.openMosaicSession(ids, new Date(startMs).toISOString(), new Date(endMs).toISOString(), d.cols, d.rows);
    }
    function setZoom(spanMin) { openFor(spanMin); }

    // Export the In→Out moment across the wall (dual-archive): a per-camera clip
    // for each tile (live today) + one combined synchronized-grid clip (E2 —
    // honest failure until the backend ships the mosaic export). Feedback rides
    // the existing playbackClient export toasts in Main.
    function exportSelection() {
        if (!hasSelection || !client) return;
        var s = new Date(selStartMs).toISOString(), e = new Date(selEndMs).toISOString();
        var ids = camIds();
        // One group_id ties the dual-archive set (N per-camera clips + 1 combined
        // grid) together so the exports list (A6) renders them as one wall moment.
        var gid = "wall-" + Date.now();
        var purpose = "Wall review · " + ids.length + " cams · " + fmtClock(selStartMs) + "–" + fmtClock(selEndMs);
        for (var i = 0; i < ids.length; i++)
            client.createExport(ids[i], s, e, "wallclock", Artifacts.newExportPath(ids[i]), gid, purpose);
        if (sessionId !== "")
            client.createMosaicExport(sessionId, s, e, "wallclock", Artifacts.newExportPath("wall"), gid, purpose);
    }

    Connections {
        target: root.client
        enabled: root.client !== null
        function onMosaicSessionReady(sid, g, c, dur, fragments, meta) {
            root.loading = false; root.pending = false; root.errorText = "";
            root.sessionId = sid; root.grid = g; root.cells = c; root.compactDuration = dur;
            root.winStartMs = Date.parse(meta.wall_start);
            root.winEndMs = Date.parse(meta.wall_end);
            root.resetView();
            var out = [];
            for (var i = 0; i < fragments.length; i++) {
                var f = fragments[i];
                if (f.availability === "no_recording") continue;   // whole-grid gap → shown as gap on the bar
                out.push({ cs: f.compact_start, ce: f.compact_end,
                           ws: Date.parse(f.wall_start), we: Date.parse(f.wall_end), avail: f.availability });
            }
            root.frags = out;
            if (out.length === 0) { root.errorText = "No footage recorded in this range."; return; }
            player.source = root.client.mosaicPlaylistUrl(sid);
            player.play();
            renderGuard.restart();   // honest failure if the composite never produces frames
        }
        function onMosaicSessionFailed(err, pending) {
            root.loading = false;
            root.pending = pending;     // 404 ⇒ endpoint not shipped yet
            root.errorText = err;
        }
        function onCoverageUnionReady(available, retDays, unionDays) {
            root.coveragePending = !available;
            if (available && retDays > 0) root.retentionDays = retDays;
            root.footageDays = unionDays;
        }
    }

    // Render watchdog: a cold 16-cell composite now takes the backend ~4-6s for
    // the first segment (3043dbe: render chase + batched bounded resolves +
    // ~3.7× realtime; was ~45-55s before 2026-06-12). Poll while "Compositing…"
    // is up: if frames arrive, stand down; only fail honestly after a budget
    // comfortably above the measured cold start (the file's contract: never a
    // broken player — and never an error banner over video that IS playing).
    Timer {
        id: renderGuard
        interval: 5000; repeat: true
        property int waitedMs: 0
        onRunningChanged: if (running) waitedMs = 0
        onTriggered: {
            if (root.sessionId === "" || root.errorText !== "") { running = false; return; }
            if (player.position > 0) { running = false; return; }   // frames arrived
            waitedMs += interval;
            if (waitedMs >= 25000) {
                running = false;
                root.errorText = "Couldn't composite the synchronized grid for this window — the server didn't return frames in time. Try a different time, or Return to live.";
            }
        }
    }
    focus: true
    onVisibleChanged: { if (visible) forceActiveFocus(); else player.stop(); }
    // keyboard transport: space = play/pause, ←/→ = ∓10s (Shift = ∓60s)
    Keys.onPressed: (e) => {
        if (root.pickerOpen) {           // picker owns the keyboard while open
            if (e.key === Qt.Key_Escape) { root.pickerOpen = false; e.accepted = true; }
            return;
        }
        if (player.duration <= 0) return;
        if (e.key === Qt.Key_Space) {
            player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play();
            e.accepted = true;
        } else if (e.key === Qt.Key_Left) {
            player.position = Math.max(0, player.position - ((e.modifiers & Qt.ShiftModifier) ? 60000 : 10000));
            e.accepted = true;
        } else if (e.key === Qt.Key_Right) {
            player.position = Math.min(player.duration, player.position + ((e.modifiers & Qt.ShiftModifier) ? 60000 : 10000));
            e.accepted = true;
        }
    }

    // ======================================================================
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0

            // ---- grid (single composited stream) + per-cell overlays --------
            Rectangle {
                id: playerArea
                Layout.fillWidth: true; Layout.fillHeight: true
                color: "#121110"; clip: true

                VideoOutput { id: vout; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectFit }
                MediaPlayer {
                    id: player
                    videoOutput: vout
                    audioOutput: null
                    onErrorOccurred: (e, s) => { if (e !== MediaPlayer.NoError) root.errorText = s }
                    onPositionChanged: if (player.position > 0) renderGuard.stop()   // frames flowing → not stalled
                    // Apply the deferred playhead restore (camera re-assign). Must
                    // wait for `seekable` — a position set before the pipeline
                    // prerolls is silently dropped (same fix as PlaybackScreen).
                    function applyPendingSeek() {
                        if (seekable && duration > 0 && root._pendingSeekMs >= 0) {
                            root.seekToWall(root._pendingSeekMs);
                            root._pendingSeekMs = -1;
                        }
                    }
                    onSeekableChanged: applyPendingSeek()
                    onDurationChanged: applyPendingSeek()
                }

                // Fitted video rect (PreserveAspectFit) for placing cell overlays.
                readonly property real gAspect: (root.grid.width && root.grid.height)
                    ? root.grid.width / root.grid.height : (16 / 9)
                readonly property real boxAspect: width / Math.max(1, height)
                readonly property real fitW: gAspect > boxAspect ? width : height * gAspect
                readonly property real fitH: gAspect > boxAspect ? width / gAspect : height
                readonly property real fitX: (width - fitW) / 2
                readonly property real fitY: (height - fitH) / 2

                // per-cell labels (the grid pixels come from the server; we only
                // annotate each cell with its camera name)
                Repeater {
                    model: (root.sessionId !== "" && root.grid.cols && root.errorText === "") ? root.cells : []
                    delegate: Item {
                        readonly property int cols: root.grid.cols
                        readonly property int rows: root.grid.rows
                        x: playerArea.fitX + (modelData.col / cols) * playerArea.fitW
                        y: playerArea.fitY + (modelData.row / rows) * playerArea.fitH
                        width: playerArea.fitW / cols
                        height: playerArea.fitH / rows
                        Rectangle {   // name chip
                            anchors { left: parent.left; top: parent.top; margins: 4 }
                            width: nm.implicitWidth + 10; height: 16
                            color: "#cc16140f"; radius: 2
                            Text {
                                id: nm; anchors.centerIn: parent
                                text: {
                                    var cam = root.cameraModel ? root.cameraModel.cameraByBackendId(modelData.camera_id) : null;
                                    return cam && cam.name ? cam.name : modelData.camera_id;
                                }
                                color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 9
                            }
                        }
                    }
                }

                LoadingState {
                    anchors.centerIn: parent
                    visible: root.loading || (player.mediaStatus === MediaPlayer.LoadingMedia && root.errorText === "" && !root.pending)
                    label: root.loading ? "Opening wall session…" : "Compositing…"
                }
                // honest pending / error / empty state
                Column {
                    anchors.centerIn: parent; spacing: 8; width: parent.width * 0.7
                    visible: root.errorText !== ""
                    Icon { anchors.horizontalCenter: parent.horizontalCenter; name: root.pending ? "pulse" : "off"; size: 30; color: Theme.ink3 }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; horizontalAlignment: Text.AlignHCenter
                        width: parent.width; wrapMode: Text.WordWrap
                        text: root.pending ? "Synchronized wall playback — backend compositing pending"
                                           : root.errorText
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; horizontalAlignment: Text.AlignHCenter
                        width: parent.width; wrapMode: Text.WordWrap
                        visible: root.pending
                        text: "The server-composited grid stream (E1) isn't live yet. Live tiles are unaffected — use Return to live."
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                    }
                }
            }

            // ---- aside: wall info + footage calendar ------------------------
            Rectangle {
                Layout.preferredWidth: 320; Layout.fillHeight: true; color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                ColumnLayout {
                    anchors.fill: parent; anchors.leftMargin: 1; spacing: 0
                    component Hdr: Text {
                        Layout.fillWidth: true; Layout.topMargin: 14; Layout.leftMargin: 16; Layout.bottomMargin: 8
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.topMargin: 16; Layout.leftMargin: 16; Layout.rightMargin: 16; spacing: 2
                        Text { text: "Wall playback"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Text { text: root.cameras.length + " cameras · synchronized"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
                            Rectangle {
                                implicitWidth: ecT.implicitWidth + 16; implicitHeight: 20
                                color: ecMa.containsMouse ? Theme.accent : "transparent"
                                border.width: 1; border.color: ecMa.containsMouse ? Theme.accent : Theme.line2
                                Text { id: ecT; anchors.centerIn: parent; text: "EDIT CAMERAS"; color: ecMa.containsMouse ? Theme.bg : Theme.ink2
                                    font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.8 }
                                MouseArea { id: ecMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openPicker() }
                            }
                        }
                    }
                    Hdr { text: "Status" }
                    RowLayout {
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                        Text { text: "Playhead"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.preferredWidth: 110 }
                        Text { text: root.frags.length ? root.fmtClock(root.playheadMs) : "—"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight }
                    }
                    RowLayout {
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                        Text { text: "Window"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.preferredWidth: 110 }
                        Text {
                            text: root.selectedDay !== "" ? Qt.formatDate(new Date(root.selectedDay + "T00:00:00"), "ddd d MMM")
                                  : (root.zoomMin === 1440 ? "24 hours" : root.zoomMin === 720 ? "12 hours"
                                     : root.zoomMin === 360 ? "6 hours" : root.zoomMin === 60 ? "1 hour" : root.zoomMin + " min")
                            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight
                        }
                    }
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 10 }
                    Rectangle { Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.preferredHeight: 1; color: Theme.line }
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 14 }
                    PlaybackCalendar {
                        Layout.fillWidth: true
                        retentionDays: root.retentionDays
                        footageDays: root.footageDays
                        pending: root.coveragePending
                        selectedDate: root.selectedDay
                        onDaySelected: (d) => root.openForDay(d)
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }

        // ---- master timeline + transport ---------------------------------
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 124; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }

            RowLayout {
                id: tlControls
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 12 }
                height: 24; spacing: 8
                component Chip: Rectangle {
                    property string label: ""; property bool active: false; signal clicked()
                    implicitWidth: ct.implicitWidth + 18; implicitHeight: 24
                    color: active ? Theme.accent : "transparent"; border.width: 1; border.color: active ? Theme.accent : Theme.line2
                    Text { id: ct; anchors.centerIn: parent; text: parent.label; color: parent.active ? Theme.bg : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.8; font.capitalization: Font.AllUppercase }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
                }
                Chip {
                    label: player.playbackState === MediaPlayer.PlayingState ? "❚❚" : "▶"
                    onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
                }
                Chip { label: "−10s"; onClicked: player.position = Math.max(0, player.position - 10000) }
                Chip { label: "+10s"; onClicked: player.position = Math.min(player.duration, player.position + 10000) }
                Text { text: root.frags.length ? (Qt.formatDate(new Date(root.playheadMs), "ddd") + " " + root.fmtClock(root.playheadMs)) : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; Layout.leftMargin: 8 }
                Item { Layout.fillWidth: true }
                Chip { label: "15m"; active: root.zoomMin === 15 && root.selectedDay === ""; onClicked: root.setZoom(15) }
                Chip { label: "1h"; active: root.zoomMin === 60 && root.selectedDay === ""; onClicked: root.setZoom(60) }
                Chip { label: "6h"; active: root.zoomMin === 360 && root.selectedDay === ""; onClicked: root.setZoom(360) }
                Chip { label: "12h"; active: root.zoomMin === 720 && root.selectedDay === ""; onClicked: root.setZoom(720) }
                Chip { label: "24h"; active: root.zoomMin === 1440 && root.selectedDay === ""; onClicked: root.setZoom(1440) }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 18; color: Theme.line2 }
                Chip { visible: root.hasSelection; label: "Export selection"; active: true; onClicked: root.exportSelection() }
                Chip { label: "Return to live"; onClicked: root.returnToLive() }
            }

            // scrub bar — composited footage vs whole-grid gaps + playhead
            Rectangle {
                id: bar
                anchors { left: parent.left; right: parent.right; top: tlControls.bottom; topMargin: 10; leftMargin: 16; rightMargin: 16 }
                height: 60
                color: "#16140f"; border.width: 1; border.color: Theme.line

                // span/x↔ms use the (zoomable) VIEW window, not the full session window
                readonly property double span: Math.max(1, root.viewEndMs - root.viewStartMs)
                function xOf(ms) { return (ms - root.viewStartMs) / span * width }
                function msOf(x) { return root.viewStartMs + (x / width) * span }
                property double pressMs: -1
                property double hoverMs: -1

                // footage segments (olive); gaps are the bare track
                Repeater {
                    model: root.frags
                    delegate: Rectangle {
                        x: bar.xOf(modelData.ws); width: Math.max(1, bar.xOf(modelData.we) - bar.xOf(modelData.ws))
                        y: 0; height: parent.height
                        color: modelData.avail === "ready" ? "#3f5a2a" : "#4a4327"   // ready vs warming
                    }
                }
                // In/Out selection
                Rectangle {
                    visible: root.hasSelection
                    x: bar.xOf(root.selStartMs); width: Math.max(1, bar.xOf(root.selEndMs) - bar.xOf(root.selStartMs))
                    y: 0; height: parent.height
                    color: Theme.accentSoft; border.width: 1; border.color: Theme.accent
                }
                // playhead
                Rectangle {
                    visible: root.frags.length > 0
                    width: 2; height: parent.height; color: "#fff"
                    x: bar.xOf(root.playheadMs)
                }
                // hover scrub guide
                Rectangle {
                    visible: bar.hoverMs >= 0 && root.frags.length > 0
                    width: 1; height: parent.height; color: Theme.ink3
                    x: bar.xOf(bar.hoverMs)
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.frags.length > 0
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onPositionChanged: (m) => {
                        bar.hoverMs = bar.msOf(m.x);
                        if (pressed && bar.pressMs >= 0) {     // dragging → tentative selection
                            var a = Math.min(bar.pressMs, bar.hoverMs), b = Math.max(bar.pressMs, bar.hoverMs);
                            root.selStartMs = a; root.selEndMs = b;
                        }
                    }
                    onExited: bar.hoverMs = -1
                    onPressed: (m) => { bar.pressMs = bar.msOf(m.x); root.selStartMs = -1; root.selEndMs = -1; }
                    onReleased: (m) => {
                        var cur = bar.msOf(m.x);
                        // small movement = a click (seek); a real drag = clip selection
                        if (Math.abs(cur - bar.pressMs) < bar.span / bar.width * 4) {
                            root.selStartMs = -1; root.selEndMs = -1;
                            root.seekToWall(cur);
                        }
                        bar.pressMs = -1;
                    }
                    // mouse-wheel zoom (days→seconds) within the session window, around the cursor
                    onWheel: (w) => {
                        var atMs = bar.msOf(w.x);
                        var factor = w.angleDelta.y > 0 ? 0.8 : 1.25;   // up = zoom in
                        var newSpan = Math.max(5000, Math.min(root.winEndMs - root.winStartMs, bar.span * factor));
                        var leftFrac = (atMs - root.viewStartMs) / bar.span;
                        var ns = atMs - leftFrac * newSpan;
                        var ne = ns + newSpan;
                        if (ns < root.winStartMs) { ns = root.winStartMs; ne = ns + newSpan; }
                        if (ne > root.winEndMs) { ne = root.winEndMs; ns = ne - newSpan; }
                        root.viewStartMs = Math.max(root.winStartMs, ns);
                        root.viewEndMs = Math.min(root.winEndMs, ne);
                    }
                }
                Text {
                    anchors { left: parent.left; bottom: parent.bottom; margins: 6 }
                    text: root.frags.length ? (root.hasSelection
                            ? ("IN " + root.fmtClock(root.selStartMs) + "  →  OUT " + root.fmtClock(root.selEndMs))
                            : "FOOTAGE · scroll to zoom · drag to select")
                          : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1
                }
            }
        }
    }

    // ---- camera picker: assign any ≤16 roster cameras to the wall ----------
    Rectangle {
        visible: root.pickerOpen
        anchors.fill: parent
        z: 60
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: root.pickerOpen = false }
        Rectangle {
            anchors.centerIn: parent
            width: 460; height: Math.min(600, parent.height - 60)
            color: Theme.panel; border.width: 1; border.color: Theme.line2
            MouseArea { anchors.fill: parent; onClicked: {} }    // swallow backdrop clicks
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 14; spacing: 10
                RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                        spacing: 1; Layout.fillWidth: true
                        Text { text: "Assign cameras"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 15; font.weight: Font.DemiBold }
                        Text { text: "The wall re-composites at the current moment"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11 }
                    }
                    Text { text: root.pickerCount + " / 16"; color: root.pickerCount >= 16 ? Theme.accent : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 13; font.weight: Font.DemiBold }
                }
                // search
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 32
                    color: Theme.bg; border.width: 1
                    border.color: pickInput.activeFocus ? Theme.accent : Theme.line2
                    TextInput {
                        id: pickInput
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                        clip: true
                        onTextChanged: root.pickSearch = text
                        Connections { target: root; function onPickerOpenChanged() { if (root.pickerOpen) { pickInput.text = ""; pickInput.forceActiveFocus() } } }
                    }
                    Text {
                        visible: pickInput.text === ""
                        anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 10
                        text: "Search name, IP or group…"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12
                    }
                }
                // roster checklist
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    model: root.pickerRows
                    spacing: 2
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool on: root.pickIds[modelData.camId] === true
                        width: ListView.view ? ListView.view.width : 0
                        height: 42
                        color: prMa.containsMouse ? Theme.panel2 : "transparent"
                        Rectangle {   // checkbox
                            id: prBox
                            anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                            width: 14; height: 14
                            color: parent.on ? Theme.accent : "transparent"
                            border.width: 1; border.color: parent.on ? Theme.accent : Theme.ink3
                            Text { anchors.centerIn: parent; visible: parent.parent.on; text: "✓"; color: Theme.bg; font.pixelSize: 10; font.weight: Font.Bold }
                        }
                        Column {
                            anchors.left: prBox.right; anchors.leftMargin: 10; anchors.right: parent.right; anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text { text: modelData.name; color: parent.parent.on ? Theme.ink : Theme.ink2
                                font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium
                                elide: Text.ElideRight; width: parent.width }
                            Text { text: modelData.ip + (modelData.groupName ? "  ·  " + modelData.groupName : "")
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                                elide: Text.ElideRight; width: parent.width }
                        }
                        MouseArea { id: prMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.togglePick(modelData.camId) }
                    }
                }
                // footer actions
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text {
                        text: root.pickerCount === 0 ? "Pick at least one camera" : ""
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        implicitWidth: pcT.implicitWidth + 22; implicitHeight: 28
                        color: "transparent"; border.width: 1; border.color: pcMa.containsMouse ? Theme.ink3 : Theme.line2
                        Text { id: pcT; anchors.centerIn: parent; text: "Cancel"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        MouseArea { id: pcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickerOpen = false }
                    }
                    Rectangle {
                        readonly property bool enabled: root.pickerCount > 0
                        implicitWidth: paT.implicitWidth + 22; implicitHeight: 28
                        color: enabled ? (paMa.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent) : Theme.panel2
                        Text { id: paT; anchors.centerIn: parent
                            text: "Apply · " + root.pickerCount + (root.pickerCount === 1 ? " camera" : " cameras")
                            color: parent.enabled ? Theme.bg : Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                        MouseArea { id: paMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (parent.enabled) root.applyPick() }
                    }
                }
            }
        }
    }
}
