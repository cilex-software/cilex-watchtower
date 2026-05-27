import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Watchtower

// Playback (S06): recorded playback of one camera from cilex-vision. Main player
// + 340px info aside + full-width bottom timeline. The HLS stream is served
// through the app's local auth proxy (PlaybackClient/HlsProxy). The timeline,
// footage/gap shading, and playhead↔wall-clock mapping all come from the real
// session manifest fragments — no fabricated coverage.
Item {
    id: root

    property var camera: null          // camera map (name, ip, mac, groupName, …)
    property var client: null          // PlaybackClient
    property var cameraModel: null

    signal closed()                    // back — returns to the previous (detail) view
    signal returnToLive()              // red control — back to Live Monitor

    // session state
    property string sessionId: ""
    property var frags: []             // ready fragments (compact_start/end + wall_start/end ms)
    property double compactDuration: 0
    property double winStartMs: 0      // visible wall-clock window
    property double winEndMs: 0
    property int zoomMin: 60           // 15 / 60 / 1440
    property bool loading: false
    property string errorText: ""

    // clip selection (wall ms), -1 = none
    property double selStartMs: -1
    property double selEndMs: -1
    readonly property bool hasSelection: selStartMs >= 0 && selEndMs > selStartMs

    readonly property string camId: (client && camera)
        ? (client.cameraIdForIp(camera.ip) || client.cameraIdForMac(camera.mac || "")) : ""

    // ---- helpers ---------------------------------------------------------
    function pad(n) { return (n < 10 ? "0" : "") + n }
    function fmtClock(ms) {
        if (!ms || isNaN(ms)) return "—";
        var d = new Date(ms);
        return pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
    }
    function fmtDur(sec) {
        sec = Math.max(0, Math.round(sec));
        var m = Math.floor(sec / 60), s = sec % 60;
        return m + ":" + pad(s);
    }
    // compact player-seconds -> wall ms (via ready fragments)
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
    // wall ms -> compact player-seconds (nearest covered fragment)
    function wallToPos(ms) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (ms >= f.ws && ms <= f.we) {
                var frac = (f.we > f.ws) ? (ms - f.ws) / (f.we - f.ws) : 0;
                return f.cs + frac * (f.ce - f.cs);
            }
        }
        // not inside footage — snap to the next fragment that starts after ms
        for (var j = 0; j < frags.length; j++)
            if (frags[j].ws >= ms) return frags[j].cs;
        return compactDuration;
    }
    function seekToWall(ms) {
        if (!player.seekable && player.duration <= 0) return;
        player.position = Math.round(wallToPos(ms) * 1000);
    }

    // current playhead wall ms
    readonly property double playheadMs: posToWall(player.position / 1000)

    // ---- session open ----------------------------------------------------
    property bool _pendingOpen: false
    function openFor(cam, spanMin) {
        camera = cam;
        zoomMin = spanMin || zoomMin;
        errorText = ""; selStartMs = -1; selEndMs = -1;
        if (!client) return;
        client.ensureReady();
        _pendingOpen = true;
        tryOpen();
    }
    function tryOpen() {
        if (!_pendingOpen || !client || !camera) return;
        var id = client.cameraIdForIp(camera.ip) || client.cameraIdForMac(camera.mac || "");
        if (!id) {
            if (!client.loggedIn) return;          // /streams not resolved yet — wait
            _pendingOpen = false;
            errorText = "This camera is not in the recording backend.";
            return;
        }
        _pendingOpen = false;
        loading = true;
        player.stop();
        var end = Date.now();
        var start = end - zoomMin * 60000;
        client.openSession(id, new Date(start).toISOString(),
                           new Date(end).toISOString(), true);
    }
    function setZoom(spanMin) { selStartMs = -1; selEndMs = -1; openFor(camera, spanMin); }

    Connections {
        target: root.client
        enabled: root.client !== null
        function onSessionReady(sid, dur, fragments, meta) {
            root.loading = false;
            root.sessionId = sid;
            root.compactDuration = dur;
            root.winStartMs = Date.parse(meta.wall_start);
            root.winEndMs = Date.parse(meta.wall_end);
            var out = [];
            for (var i = 0; i < fragments.length; i++) {
                var f = fragments[i];
                if (f.availability !== "ready") continue;
                out.push({ cs: f.compact_start, ce: f.compact_end,
                           ws: Date.parse(f.wall_start), we: Date.parse(f.wall_end),
                           codec: f.codec, tier: f.tier });
            }
            root.frags = out;
            if (out.length === 0) { root.errorText = "No footage recorded in this range."; return; }
            root.errorText = "";
            player.source = root.client.playlistUrl(sid);
            player.play();
        }
        function onSessionFailed(err) { root.loading = false; root.errorText = err; }
        function onCamerasResolved() { root.tryOpen(); }
    }

    // pause streams when hidden; tidy player on hide
    onVisibleChanged: if (!visible) player.stop()

    // ======================================================================
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- player + aside ---------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                id: playerArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1d2120"
                clip: true

                VideoOutput { id: vout; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectFit }
                MediaPlayer {
                    id: player
                    videoOutput: vout
                    audioOutput: null
                }

                LoadingState {
                    anchors.centerIn: parent
                    visible: root.loading || (player.mediaStatus === MediaPlayer.LoadingMedia && root.errorText === "")
                    label: "Loading recording…"
                }
                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    visible: root.errorText !== ""
                    Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 30; color: Theme.ink3 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.errorText
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13 }
                }

                // top overlay
                Rectangle {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    height: 60
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(0,0,0,0.75) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    RowLayout {
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.leftMargin: 14; anchors.rightMargin: 16; anchors.topMargin: 12
                        spacing: 10
                        IconButton { name: "back"; iconColor: "#fff"; hoverIcon: Theme.accent; tip: "Back"; onClicked: root.closed() }
                        Rectangle {
                            implicitWidth: pbTag.implicitWidth + 14; implicitHeight: 18; color: Theme.accent
                            Text { id: pbTag; anchors.centerIn: parent; text: "PLAYBACK"; color: Theme.bg
                                font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1 }
                        }
                        Text { text: root.camera ? root.camera.name : ""; color: "#fff"
                            font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold }
                        Text { text: root.camera ? root.camera.ip : ""; color: Qt.rgba(1,1,1,0.55)
                            font.family: Theme.fontMono; font.pixelSize: 11 }
                        Item { Layout.fillWidth: true }
                        Text { text: Qt.formatDate(new Date(root.playheadMs), "ddd") + " · " + root.fmtClock(root.playheadMs)
                            color: Qt.rgba(1,1,1,0.8); font.family: Theme.fontMono; font.pixelSize: 12; visible: root.frags.length > 0 }
                    }
                }

                // selection chip
                Rectangle {
                    anchors.top: parent.top; anchors.topMargin: 64; anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.hasSelection
                    implicitWidth: selRow.implicitWidth + 20; implicitHeight: 32
                    color: Qt.rgba(0,0,0,0.6); border.width: 1; border.color: Theme.accent
                    Row {
                        id: selRow; anchors.centerIn: parent; spacing: 10
                        Text { anchors.verticalCenter: parent.verticalCenter
                            text: "CLIP  " + root.fmtClock(root.selStartMs) + " → " + root.fmtClock(root.selEndMs)
                                  + "  ·  " + root.fmtDur((root.selEndMs - root.selStartMs)/1000)
                            color: "#fff"; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: expTxt.implicitWidth + 16; implicitHeight: 22; color: Theme.accent
                            Text { id: expTxt; anchors.centerIn: parent; text: "Export Clip"; color: Theme.bg
                                font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.Medium }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openExportDrawer() }
                        }
                    }
                }

                // bottom controls
                Rectangle {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    height: 56
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.rgba(0,0,0,0.75) }
                    }
                    component Ctl: IconButton {
                        bgColor: Qt.rgba(0,0,0,0.5); borderColor: Theme.line2
                        iconColor: "#fff"; hoverBg: Theme.accent; hoverBorder: Theme.accent; hoverIcon: Theme.bg
                    }
                    // left cluster
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: 16
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 12
                        spacing: 6
                        Ctl { name: "jumpBack"; tip: "Back 10s"; onClicked: player.position = Math.max(0, player.position - 10000) }
                        Ctl { name: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play"
                            tip: "Play / pause"
                            onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play() }
                        Ctl { name: "jumpFwd"; tip: "Forward 10s"; onClicked: player.position = Math.min(player.duration, player.position + 10000) }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: 40; implicitHeight: 30; color: spdMa.containsMouse ? Theme.accent : Qt.rgba(0,0,0,0.5)
                            border.width: 1; border.color: spdMa.containsMouse ? Theme.accent : Theme.line2
                            Text { anchors.centerIn: parent; text: player.playbackRate + "×"; color: spdMa.containsMouse ? Theme.bg : "#fff"
                                font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.Bold }
                            MouseArea { id: spdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: player.playbackRate = player.playbackRate >= 4 ? 1 : player.playbackRate * 2 }
                        }
                    }
                    // right cluster
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: 16
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 12
                        spacing: 6
                        Ctl { name: "shot"; tip: "Snapshot"; onClicked: root.snapshot() }
                        Ctl { name: "full"; tip: "Fullscreen"; onClicked: root.fullscreenRequested() }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: rtlRow.implicitWidth + 18; implicitHeight: 30
                            color: rtlMa.containsMouse ? Theme.bad : Qt.rgba(0,0,0,0.5)
                            border.width: 1; border.color: Theme.bad
                            Row { id: rtlRow; anchors.centerIn: parent; spacing: 6
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; radius: 4; color: rtlMa.containsMouse ? "#fff" : Theme.bad }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Return to Live"; color: "#fff"
                                    font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                            }
                            MouseArea { id: rtlMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.returnToLive() }
                        }
                    }
                }
            }

            // ---- info aside ----
            Rectangle {
                Layout.preferredWidth: 340
                Layout.fillHeight: true
                color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                ColumnLayout {
                    anchors.fill: parent; anchors.leftMargin: 1; spacing: 0
                    component Hdr: Text {
                        Layout.fillWidth: true; Layout.topMargin: 14; Layout.leftMargin: 16; Layout.bottomMargin: 8
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                    }
                    component KV: RowLayout {
                        property string k: ""; property string v: ""
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                        Text { text: parent.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.preferredWidth: 120 }
                        Text { text: parent.v; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.topMargin: 16; Layout.leftMargin: 16; Layout.rightMargin: 16; spacing: 2
                        Text { text: root.camera ? root.camera.name : ""; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
                        Text { text: root.camera ? (root.camera.groupName + "  ·  " + root.camera.ip) : ""; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Row { spacing: 4; topPadding: 4
                            LiveStatusBadge { state: root.camera ? root.camera.live : CameraStatus.LiveUnknown }
                            RecordingStatusBadge { state: root.camera ? root.camera.recording : CameraStatus.RecUnknown }
                        }
                    }
                    Hdr { text: "Status" }
                    KV { k: "Playhead"; v: root.frags.length ? root.fmtClock(root.playheadMs) : "—" }
                    KV { k: "Quality"; v: { var f = root.fragAt(player.position/1000); return f ? (f.codec === "hevc" ? "HD 1440p (HEVC)" : "SD 720p (H.264)") : "—" } }
                    KV { k: "Coverage"; v: root.frags.length + " segments" }
                    KV { k: "Window"; v: root.zoomMin === 1440 ? "24 hours" : (root.zoomMin === 60 ? "1 hour" : root.zoomMin + " min") }
                    Hdr { text: "Recent events" }
                    Text { Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                        text: "No events in this range."; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
                    Item { Layout.fillHeight: true }
                }
            }
        }

        // ---- timeline ----------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 124
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }

            // controls row
            RowLayout {
                id: tlControls
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.leftMargin: 16; anchors.rightMargin: 16; anchors.topMargin: 12
                height: 22; spacing: 8
                component Chip: Rectangle {
                    property string label: ""
                    property bool active: false
                    signal clicked()
                    implicitWidth: ct.implicitWidth + 18; implicitHeight: 22
                    color: active ? Theme.accent : "transparent"
                    border.width: 1; border.color: active ? Theme.accent : Theme.line2
                    Text { id: ct; anchors.centerIn: parent; text: parent.label; color: parent.active ? Theme.bg : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.8; font.capitalization: Font.AllUppercase }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
                }
                Chip { label: "Last hour"; onClicked: root.setZoom(60) }
                Chip { label: "Last 15 min"; onClicked: root.setZoom(15) }
                Text { text: root.frags.length ? ("PLAYHEAD · " + Qt.formatDate(new Date(root.playheadMs), "ddd") + " " + root.fmtClock(root.playheadMs)) : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; Layout.leftMargin: 8 }
                Item { Layout.fillWidth: true }
                Chip { label: "15m"; active: root.zoomMin === 15; onClicked: root.setZoom(15) }
                Chip { label: "1h"; active: root.zoomMin === 60; onClicked: root.setZoom(60) }
                Chip { label: "24h"; active: root.zoomMin === 1440; onClicked: root.setZoom(1440) }
            }

            // bar
            Rectangle {
                id: bar
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: tlControls.bottom; anchors.topMargin: 10
                anchors.leftMargin: 16; anchors.rightMargin: 16
                height: 64
                color: "#16140f"; border.width: 1; border.color: Theme.line

                readonly property double span: Math.max(1, root.winEndMs - root.winStartMs)
                function xOf(ms) { return (ms - root.winStartMs) / span * width }
                function msOf(x) { return root.winStartMs + (x / width) * span }

                // gap backdrop (whole bar = red stripe), footage drawn on top
                Rectangle {
                    anchors.fill: parent; anchors.margins: 1
                    visible: root.frags.length > 0
                    color: "transparent"
                    Rectangle { anchors.fill: parent; color: Theme.bad; opacity: 0.12 }
                }

                // footage segments (olive)
                Repeater {
                    model: root.frags
                    Rectangle {
                        readonly property double x0: bar.xOf(modelData.ws)
                        readonly property double x1: bar.xOf(modelData.we)
                        x: Math.max(1, x0); y: 8
                        width: Math.max(1, x1 - x0); height: 18
                        color: modelData.codec === "hevc" ? Theme.good : Qt.lighter(Theme.good, 1.15)
                        opacity: 0.75
                    }
                }
                // footage label
                Text { anchors.left: parent.left; anchors.leftMargin: 6; anchors.top: parent.top; anchors.topMargin: 30
                    text: "FOOTAGE"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1 }

                // selection overlay
                Rectangle {
                    visible: root.hasSelection
                    x: bar.xOf(root.selStartMs); width: Math.max(2, bar.xOf(root.selEndMs) - bar.xOf(root.selStartMs))
                    y: 0; height: parent.height
                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                    Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 2; color: Theme.accent }
                    Rectangle { anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 2; color: Theme.accent }
                }

                // playhead
                Rectangle {
                    visible: root.frags.length > 0
                    x: Math.max(0, bar.xOf(root.playheadMs)) - 1; y: 0; width: 2; height: parent.height
                    color: "#ffffff"
                    Rectangle { anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; width: 7; height: 7; rotation: 45; color: "#fff" }
                }

                // click to seek, drag to select
                MouseArea {
                    anchors.fill: parent
                    property double pressMs: -1
                    cursorShape: Qt.PointingHandCursor
                    onPressed: (m) => { pressMs = bar.msOf(m.x); root.selStartMs = -1; root.selEndMs = -1 }
                    onPositionChanged: (m) => {
                        if (pressMs < 0) return;
                        var cur = bar.msOf(m.x);
                        root.selStartMs = Math.min(pressMs, cur);
                        root.selEndMs = Math.max(pressMs, cur);
                    }
                    onReleased: (m) => {
                        var cur = bar.msOf(m.x);
                        if (Math.abs(cur - pressMs) < bar.span / bar.width * 4) {  // a click, not a drag
                            root.selStartMs = -1; root.selEndMs = -1;
                            root.seekToWall(cur);
                        }
                        pressMs = -1;
                    }
                }
            }
        }
    }

    // returns the ready fragment covering compact-seconds s (or null)
    function fragAt(s) {
        for (var i = 0; i < frags.length; i++)
            if (s >= frags[i].cs && s <= frags[i].ce) return frags[i];
        return null;
    }

    signal fullscreenRequested()
    signal snapshotSaved(string path, string camName)

    function snapshot() {
        vout.grabToImage(function(res) {
            var p = Artifacts.newSnapshotPath((root.camera ? root.camera.camId : "playback") + "_pb");
            if (res.saveToFile(p)) root.snapshotSaved(p, root.camera ? root.camera.name : "");
        });
    }
    // Open the export drawer for the current selection, seeding it with a grabbed
    // preview frame. The drawer collects the full export form and emits confirmed()
    // with the fields cilex-vision's API supports today (range + mode).
    function openExportDrawer() {
        if (!hasSelection || !client) return;
        exportDrawer.openWith(camera, camId, selStartMs, selEndMs, frags, playheadMs);
        vout.grabToImage(function(res) { if (res) exportDrawer.previewSource = res.url; });
    }

    ExportDrawer {
        id: exportDrawer
        z: 50
        onConfirmed: (s, e, mode) => {
            if (root.client)
                root.client.createExport(root.camId, new Date(s).toISOString(),
                                         new Date(e).toISOString(), mode);
        }
    }
}
