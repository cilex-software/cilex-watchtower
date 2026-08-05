import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import Watchtower

// Single Camera Detail — Live (S05): focused live view of one camera. Large
// player (follows the global SD/HD preference, with a per-view SD/HD toggle),
// identity + status aside, and same-group cameras to switch. Back returns to
// where the user came from.
Item {
    id: root

    property var camera: null      // camera map (name, camId, ip, rtspUrl, rtspSubUrl, live, recording, groupId, groupName, mac, model, vendor, firmware)
    property var cameraModel: null
    // Business-function state (fail-safe: only an explicit enabled:false counts as
    // off). Lets the detail view show a deliberate "switched off" instead of a fault.
    readonly property bool recOff:  cameraModel ? (cameraModel.recordingEnabled === false) : false
    readonly property bool liveOff: cameraModel ? (cameraModel.liveViewEnabled === false) : false
    property bool useMain: Settings.defaultStreamHd   // focused view follows the global SD/HD preference; the HD toggle overrides
    property bool ptzOpen: typeof wtPtzOpen !== "undefined" && wtPtzOpen   // dev: WT_PTZ_OPEN=1 opens the panel
    // Hardware pre-gate for the PTZ/lens button, derived ONLY from the backend-
    // reported model string (no invented capability): HiWatch/Hikvision motorized-
    // lens models carry a digit+"Z" designator (fleet: DS-I456Z(B) = 2.8–12 mm
    // motorized; DS-I259M = fixed), and PTZ domes advertise "PTZ". The panel then
    // probes the backend for truth (letter 2026-07-16-ptz-lens-control-endpoint.md).
    readonly property bool ptzCapable: {
        var m = camera ? String(camera.model || "") : "";
        return /PTZ/i.test(m) || /\dZ[\s(]/.test(m) || /\dZ$/.test(m);
    }
    // A stale panel must never drive the next camera (the WT_PTZ_OPEN dev pilot
    // keeps it open across switches for deterministic verification).
    onCameraChanged: {
        ptzOpen = (typeof wtPtzOpen !== "undefined" && wtPtzOpen && camera !== null);
        _syncEvents();
    }
    Component.onCompleted: _syncEvents()

    signal closed()
    signal openPlayback(string mac)
    signal snapshotSaved(string path, string camName)
    signal switchCamera(var cam)

    readonly property string camName: camera ? camera.name : ""
    readonly property string streamUrl: !camera ? ""
        : (useMain ? (camera.rtspUrl || camera.rtspSubUrl || "")
                   : (camera.rtspSubUrl || camera.rtspUrl || ""))
    readonly property var siblings: (cameraModel && camera)
        ? cameraModel.page(camera.groupId, "", "alpha", 1, 24) : []
    // Same-group cameras minus the one we're already viewing — drives the thumbnail grid.
    readonly property var groupSiblings: {
        var out = [], s = root.siblings;
        for (var i = 0; i < s.length; i++)
            if (!root.camera || s[i].mac !== root.camera.mac) out.push(s[i]);
        return out;
    }

    // ---- per-camera events (aside rail) ----
    // Private EventModel so the global feed/triage state is untouched; search()
    // is server-scoped to this camera. Rows are ALSO filtered by camId here:
    // the instance's constructor fires one unfiltered fetch on auth, and a late
    // global reply must never leak foreign cameras into this rail.
    property string _evCamId: ""
    property int _evRev: 0
    readonly property var _camRows: {
        _evRev;
        if (!camera) return [];
        var out = [], a = camEvents.all();
        for (var i = 0; i < a.length; i++)
            if (a[i].camId === camera.camId) out.push(a[i]);
        return out;
    }
    function _syncEvents() {
        var cid = (camera && camera.camId) ? camera.camId : "";
        if (cid !== "" && cid !== _evCamId) { _evCamId = cid; camEvents.search(cid, "", ""); }
    }
    function relTime(tsMs) {
        if (!tsMs || tsMs <= 0) return "";
        var s = Math.max(0, (Date.now() - tsMs) / 1000);
        if (s < 60) return qsTr("now");
        if (s < 3600) return Math.floor(s / 60) + qsTr("m");
        if (s < 86400) return Math.floor(s / 3600) + qsTr("h");
        return Math.floor(s / 86400) + qsTr("d");
    }
    function fmtDur(ms) {
        var s = Math.round(ms / 1000);
        if (s < 60) return s + qsTr("s");
        return Math.floor(s / 60) + qsTr("m") + (s % 60 ? " " + (s % 60) + qsTr("s") : "");
    }
    EventModel { id: camEvents }
    Connections { target: camEvents; function onChanged() { root._evRev++ } }
    // Keep the rail current while the view is open — events roll in live.
    Timer {
        interval: 30000; repeat: true
        running: root.visible && root._evCamId !== ""
        onTriggered: camEvents.search(root._evCamId, "", "")
    }

    function captureSnapshot() {
        var t = (vsurf.playing) ? vsurf : playerArea;
        t.grabToImage(function(result) {
            var path = Artifacts.newSnapshotPath(root.camera ? root.camera.camId : "cam");
            if (result.saveToFile(path))
                root.snapshotSaved(path, root.camName);
        });
    }
    // Same grab, with the capture instant (live = now) burned bottom-right.
    function captureSnapshotStamped() {
        var t = (vsurf.playing) ? vsurf : playerArea;
        var stamp = Qt.formatDateTime(new Date(), "yyyy-MM-dd HH:mm:ss") + "  " + root.camName;
        t.grabToImage(function(result) {
            var path = Artifacts.saveImageWithTimestamp(result.image,
                            root.camera ? root.camera.camId : "cam", stamp);
            if (path !== "")
                root.snapshotSaved(path, root.camName);
        });
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ------------------------------------------------- player
        Rectangle {
            id: playerArea
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#000000"
            clip: true

            VideoSurface {
                id: vsurf
                anchors.fill: parent
                url: root.streamUrl
                active: root.visible && !root.liveOff && root.streamUrl !== "" && (root.camera ? root.camera.live !== CameraStatus.Offline : false)
            }

            // Triple-click on the picture → one-touch autofocus (operator ask,
            // 2026-08-03 letter). Lives HERE, not on wall tiles — a wall tile's
            // single click already opens the camera, so a literal triple-click
            // there would navigate on click #1; the wall gets the AF chip twin
            // instead. tapCount===3 cannot fire on an ordinary double-click, and
            // PtzClient.focusAutoRequest adds the hard 5 s per-camera debounce.
            TapHandler {
                enabled: root.ptzCapable
                acceptedButtons: Qt.LeftButton
                onTapped: {
                    if (tapCount === 3 && root.camera && root.camera.camId) {
                        if (Ptz.capsFor(root.camera.camId) === "")
                            Ptz.probe(root.camera.camId);   // warm the gate for next time
                        Ptz.focusAutoRequest(root.camera.camId);
                    }
                }
            }

            // connecting / offline / unavailable
            LoadingState {
                anchors.centerIn: parent
                visible: vsurf.active && !vsurf.playing && !vsurf.errored
                label: "Connecting…"
            }
            Column {
                anchors.centerIn: parent
                spacing: 6
                visible: root.camera && root.camera.live === CameraStatus.Offline
                Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 36; color: Theme.bad }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "NO SIGNAL"; color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 14; font.letterSpacing: 1.4 }
            }
            Column {
                anchors.centerIn: parent
                spacing: 6
                visible: vsurf.errored && root.camera && root.camera.live !== CameraStatus.Offline
                Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "alert"; size: 32; color: Theme.warn }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "STREAM UNAVAILABLE"; color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 13; font.letterSpacing: 1.0 }
            }

            // Live View switched off by an operator (go2rtc stopped) — a deliberate
            // state, not a fault. Calm; covers the stream states beneath it.
            Rectangle {
                anchors.fill: parent
                visible: root.liveOff
                color: "#0a0d11"
                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 36; color: Theme.ink3 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "LIVE VIEW OFF"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 14; font.letterSpacing: 1.4 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "switched off by operator"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11 }
                }
            }

            // top overlay: back · name · live label
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 64
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.75) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                RowLayout {
                    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 14; rightMargin: 16; topMargin: 12 }
                    spacing: 12
                    IconButton { name: "back"; iconColor: "#ffffff"; hoverIcon: Theme.accent; tip: "Back"; onClicked: root.closed() }
                    ColumnLayout {
                        spacing: 0
                        Text { text: root.camName; color: "#ffffff"; font.family: Theme.fontSans; font.pixelSize: 15; font.weight: Font.DemiBold }
                        Text { text: root.camera ? root.camera.groupName : ""; color: Qt.rgba(1, 1, 1, 0.6); font.family: Theme.fontSans; font.pixelSize: 11 }
                    }
                    Item { Layout.fillWidth: true }
                    Row {
                        spacing: 4
                        LiveStatusBadge { state: root.camera ? root.camera.live : CameraStatus.LiveUnknown }
                        RecordingStatusBadge { state: root.recOff ? CameraStatus.Disabled : (root.camera ? root.camera.recording : CameraStatus.RecUnknown)
                            lastSegmentAtMs: (root.camera && root.camera.lastSegmentAt) ? Date.parse(root.camera.lastSegmentAt) : -1 }
                        // Audio-recording state — ear only when the camera CAN record
                        // audio (backend `audio` fields; letter 2026-07-16). Muted ear
                        // = supported but disabled. Nothing = unsupported/unknown.
                        Item {
                            visible: root.camera ? (root.camera.hasAudio === true) : false
                            width: 18; height: 18
                            anchors.verticalCenter: parent.verticalCenter
                            Icon {
                                anchors.centerIn: parent
                                name: (root.camera && root.camera.audioRecording === true) ? "ear" : "earMute"
                                size: 14
                                color: (root.camera && root.camera.audioRecording === true) ? Theme.good : Theme.ink3
                            }
                            MouseArea { id: earMa; anchors.fill: parent; hoverEnabled: true }
                            ToolTip.text: (root.camera && root.camera.audioRecording === true)
                                          ? qsTr("Recording audio") : qsTr("Audio recording disabled")
                            ToolTip.visible: earMa.containsMouse
                            ToolTip.delay: 400
                        }
                    }
                }
            }

            // ---- ticking clock: adaptive placement + size (operator research ask,
            // 2026-08-06). Where the industry puts live time: camera OSD
            // (Hikvision/HiWatch default) = top edge with black&white
            // SELF-ADAPTIVE font; Milestone Smart Client = the view item's
            // CHROME, never the pixels; Nx = corner overlay. Synthesis,
            // operator-confirmed: when the letterboxed fit leaves a bar under
            // the video, the clock lives IN the bar (zero occlusion); bars too
            // thin/absent -> docks top-center ON the video inside the existing
            // header scrim. Contrast is guaranteed by construction (black
            // bar / dark scrim / plate + outlined digits), NOT by
            // luminance-adaptive inversion: Hikvision's own self-adaptive OSD
            // is famously unreadable on busy scenes, and flickering digits are
            // poison during evidence review. Monospace (JetBrains Mono) keeps
            // the digits tabular so the clock doesn't jitter as it ticks.
            Item {
                id: liveClock
                readonly property rect vr: vsurf.playing ? vsurf.contentRect
                                                         : Qt.rect(0, 0, playerArea.width, playerArea.height)
                readonly property real barBelow: playerArea.height - (vr.y + vr.height)
                readonly property bool inBar: vsurf.playing && barBelow >= height + 12
                width: clockRow.implicitWidth + 26
                height: clockRow.implicitHeight + 12
                x: (playerArea.width - width) / 2
                y: inBar ? vr.y + vr.height + (barBelow - height) / 2 : 12

                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, liveClock.inBar ? 0.35 : 0.55)
                    border.width: 1
                    border.color: liveClock.inBar ? Theme.line : Theme.line2
                }
                // No caption: the time-source honesty this plate used to carry as a
                // permanent "station clock" tag (operator: zero value, ate the date's
                // space) moves to an ANOMALY chip — when cilex-vision ships per-camera
                // clock offsets, a visible drift renders beside the time; a normal
                // clock stays clean. Label the exception, not the steady state.
                Row {
                    id: clockRow
                    anchors.centerIn: parent
                    spacing: 12
                    Text {
                        id: clockDate
                        anchors.baseline: clockTime.baseline
                        color: Qt.rgba(1, 1, 1, 0.9)
                        style: Text.Outline; styleColor: "#000000"
                        font.family: Theme.fontMono; font.pixelSize: 15
                        text: Qt.formatDateTime(new Date(), "yyyy-MM-dd")
                    }
                    Text {
                        id: clockTime
                        color: "#ffffff"
                        style: Text.Outline; styleColor: "#000000"
                        font.family: Theme.fontMono; font.pixelSize: 24; font.weight: Font.DemiBold
                        text: Qt.formatDateTime(new Date(), "HH:mm:ss")
                    }
                }
                Timer {
                    interval: 1000; repeat: true; running: root.visible; triggeredOnStart: true
                    onTriggered: {
                        var now = new Date();
                        clockTime.text = Qt.formatDateTime(now, "HH:mm:ss");
                        clockDate.text = Qt.formatDateTime(now, "yyyy-MM-dd");
                    }
                }
            }

            // PTZ / lens panel — sits above the bottom control bar, right-aligned.
            PtzPanel {
                visible: root.ptzOpen && root.ptzCapable
                camera: root.camera
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: 16; bottomMargin: 64 }
                onClosed: root.ptzOpen = false
            }

            // bottom controls
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 56
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.75) }
                }
                RowLayout {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 16; rightMargin: 16; bottomMargin: 12 }
                    spacing: 8

                    // SD/HD toggle
                    Rectangle {
                        visible: root.streamUrl !== ""
                        implicitWidth: 36; implicitHeight: 30
                        color: hdMa.containsMouse ? Theme.accent : Qt.rgba(0, 0, 0, 0.55)
                        border.width: 1; border.color: hdMa.containsMouse ? Theme.accent : Theme.line2
                        Text { anchors.centerIn: parent; text: root.useMain ? "HD" : "SD"; color: hdMa.containsMouse ? Theme.bg : (root.useMain ? Theme.accent : "#ffffff"); font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.Bold }
                        MouseArea { id: hdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.useMain = !root.useMain }
                    }

                    component CtlButton: IconButton {
                        bgColor: Qt.rgba(0, 0, 0, 0.55); borderColor: Theme.line2
                        iconColor: "#ffffff"; hoverBg: Theme.accent; hoverBorder: Theme.accent; hoverIcon: Theme.bg
                    }
                    CtlButton { name: "shot"; tip: qsTr("Capture snapshot"); onClicked: root.captureSnapshot() }
                    CtlButton { name: "shotStamp"; tip: qsTr("Snapshot with timestamp"); onClicked: root.captureSnapshotStamped() }
                    CtlButton { name: "ptz"; visible: root.ptzCapable; tip: qsTr("PTZ / lens control")
                                onClicked: root.ptzOpen = !root.ptzOpen }
                    // bookmark / open-in-new-tab removed: they had no handlers — dead
                    // controls violate the no-silent-no-op rule; restore WITH behavior
                    // if/when those features exist for the maximized view.

                    Item { Layout.fillWidth: true }

                    // open playback
                    Rectangle {
                        implicitWidth: pbRow.implicitWidth + 24; implicitHeight: 34
                        color: pbMa.containsMouse ? Theme.accent : Qt.rgba(0, 0, 0, 0.55)
                        border.width: 1; border.color: Theme.accent
                        Row {
                            id: pbRow; anchors.centerIn: parent; spacing: 8
                            Icon { anchors.verticalCenter: parent.verticalCenter; name: "clip"; size: 14; color: pbMa.containsMouse ? Theme.bg : Theme.accent }
                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Open playback"; color: pbMa.containsMouse ? Theme.bg : Theme.accent; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                        }
                        MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openPlayback(root.camera ? root.camera.mac : "") }
                    }
                }
            }
        }

        // ------------------------------------------------- info aside
        Rectangle {
            Layout.preferredWidth: 340
            Layout.fillHeight: true
            color: Theme.panel
            Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }

            ColumnLayout {
                anchors.fill: parent
                anchors.leftMargin: 1
                spacing: 0

                // ---- Events — what this camera has seen ----
                // Replaces the Status/Device fact sheets (operator feedback,
                // 2026-08-05): every row there was already on screen — the
                // overlay badges carry stream/recording/audio, the SD/HD button
                // carries quality, the header carries name+IP+model — and
                // firmware is admin detail, not guard detail. The reclaimed
                // space shows this camera's own recent events instead.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 14; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 8
                    spacing: 7
                    Text {
                        text: "EVENTS"; color: Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4
                    }
                    Text {
                        Layout.fillWidth: true; elide: Text.ElideRight
                        text: camEvents.loading && root._camRows.length === 0 ? qsTr("loading…") : ""
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                    }
                    Text {
                        visible: camEvents.serverTotal > 0; text: camEvents.serverTotal
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                }
                ListView {
                    id: evList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.leftMargin: 8; Layout.rightMargin: 8
                    clip: true
                    model: root._camRows
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Item {
                        id: evRow
                        required property int index
                        required property var modelData
                        width: ListView.view.width
                        height: 62
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; top: parent.top }
                            height: 1; color: Theme.line; visible: evRow.index > 0
                        }
                        RowLayout {
                            anchors.fill: parent
                            anchors.topMargin: 5; anchors.bottomMargin: 5
                            anchors.leftMargin: 8; anchors.rightMargin: 8
                            spacing: 10
                            // mid-incident still — same recipe as the ops rail
                            Rectangle {
                                Layout.preferredWidth: 92
                                Layout.preferredHeight: 52
                                Layout.alignment: Qt.AlignVCenter
                                color: Theme.panel2
                                border.width: 1; border.color: Theme.line2
                                clip: true
                                Image {
                                    id: evStill
                                    anchors.fill: parent; anchors.margins: 1
                                    asynchronous: true
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize.width: 184
                                    source: (evRow.modelData.clipUrl && evRow.modelData.eventId)
                                            ? "image://cvframe/events/" + evRow.modelData.eventId + "/snapshot?pos=mid" : ""
                                    visible: status === Image.Ready
                                }
                                Rectangle {
                                    anchors.fill: parent; anchors.margins: 1
                                    visible: evStill.status === Image.Loading
                                    color: Theme.panel3
                                    SequentialAnimation on opacity {
                                        running: evStill.status === Image.Loading
                                        loops: Animation.Infinite
                                        NumberAnimation { to: 0.45; duration: 600; easing.type: Easing.InOutSine }
                                        NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                                    }
                                }
                                Icon {
                                    anchors.centerIn: parent
                                    visible: evStill.status !== Image.Ready && evStill.status !== Image.Loading
                                    name: "shot"; size: 14; color: Theme.ink3
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 3
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Rectangle { Layout.preferredWidth: 6; Layout.preferredHeight: 6; color: EventStyle.color(evRow.modelData.type) }
                                    Text {
                                        Layout.fillWidth: true; elide: Text.ElideRight
                                        text: EventStyle.label(evRow.modelData.type)
                                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        text: root.relTime(evRow.modelData.ts)
                                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                    text: Qt.formatDateTime(new Date(evRow.modelData.ts), "ddd d MMM, HH:mm:ss")
                                          + (evRow.modelData.durationMs > 0 ? "  ·  " + root.fmtDur(evRow.modelData.durationMs) : "")
                                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                                }
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 32
                        visible: !camEvents.loading && root._camRows.length === 0
                        text: qsTr("No events recorded for this camera yet.")
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12
                        wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                    }
                }

                // "Same group" header with the actual group name in parentheses so it's
                // clear which group these cameras belong to.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 14; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 8
                    spacing: 7
                    Text {
                        text: "SAME GROUP"; color: Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4
                    }
                    Text {
                        Layout.fillWidth: true; elide: Text.ElideRight
                        text: (root.camera && root.camera.groupName) ? ("(" + root.camera.groupName + ")") : ""
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11
                    }
                    Text {
                        visible: root.groupSiblings.length > 0; text: root.groupSiblings.length
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                }
                // Thumbnail grid: each tile is the camera's live frame (go2rtc snapshot)
                // with a faint octet badge (e.g. ".101") so the whole group reads at a
                // glance; click a tile to switch the focused camera.
                GridView {
                    id: sibGrid
                    visible: root.groupSiblings.length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: cellHeight * 2   // two rows; the rest scrolls
                    Layout.leftMargin: 8; Layout.rightMargin: 8; Layout.bottomMargin: 8
                    clip: true
                    model: root.groupSiblings
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }
                    readonly property int cols: Math.max(2, Math.round(width / 112))
                    cellWidth: width > 0 ? Math.floor(width / cols) : 110
                    cellHeight: Math.round(cellWidth * 9 / 16) + 4
                    delegate: Item {
                        required property var modelData
                        width: sibGrid.cellWidth; height: sibGrid.cellHeight
                        LiveThumb {
                            anchors.fill: parent; anchors.margins: 3
                            cam: modelData
                            active: root.visible
                            onClicked: root.switchCamera(modelData)
                        }
                    }
                }
                Text {
                    visible: root.groupSiblings.length === 0
                    Layout.fillWidth: true
                    Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 4; Layout.bottomMargin: 12
                    text: (root.camera && root.camera.groupName) ? "No other cameras in this group." : "This camera isn't in a group."
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.WordWrap
                    verticalAlignment: Text.AlignTop
                }
            }
        }
    }
}
