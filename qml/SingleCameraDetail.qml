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

    function captureSnapshot() {
        var t = (vsurf.playing) ? vsurf : playerArea;
        t.grabToImage(function(result) {
            var path = Artifacts.newSnapshotPath(root.camera ? root.camera.camId : "cam");
            if (result.saveToFile(path))
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
                        RecordingStatusBadge { state: root.recOff ? CameraStatus.Disabled : (root.camera ? root.camera.recording : CameraStatus.RecUnknown) }
                    }
                }
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
                    CtlButton { name: "shot"; tip: "Capture snapshot"; onClicked: root.captureSnapshot() }
                    CtlButton { name: "bookmark"; tip: "Add bookmark" }
                    CtlButton { name: "newtab"; tip: "Open in new tab" }

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

                // status section
                component AsideHeader: Text {
                    Layout.fillWidth: true
                    Layout.topMargin: 14; Layout.leftMargin: 16; Layout.bottomMargin: 8
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                }
                component KV: RowLayout {
                    property string k: ""
                    property string v: ""
                    Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                    Text { text: parent.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.preferredWidth: 110 }
                    Text { text: parent.v; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                }

                AsideHeader { text: "Status" }
                KV { k: "Stream"; v: root.liveOff ? "Live View off" : (vsurf.playing ? "Live" : (root.camera && root.camera.live === CameraStatus.Offline ? "Offline" : (vsurf.errored ? "Unavailable" : "Connecting…"))) }
                KV { k: "Recording"; v: root.recOff ? "Switched off"
                        : !root.camera ? "—"
                        : root.camera.recording === CameraStatus.Recording ? "Recording"
                        : root.camera.recording === CameraStatus.Stalled ? "Stalled"
                        : root.camera.recording === CameraStatus.Armed ? "Motion armed"
                        : root.camera.recording === CameraStatus.Disabled ? "Disabled"
                        : root.camera.recording === CameraStatus.NotRecording ? "Not recording"
                        : root.camera.recording === CameraStatus.RecordingGap ? "Recording gap" : "Unknown" }
                KV { k: "Last recording"; v: (root.camera && root.camera.lastSegmentAt)
                        ? Qt.formatDateTime(new Date(root.camera.lastSegmentAt), "ddd d MMM, HH:mm:ss") : "—" }
                KV { k: "Quality"; v: root.useMain ? "HD (main)" : "SD (substream)" }
                Item { Layout.preferredHeight: 8 }

                AsideHeader { text: "Device" }
                KV { k: "IP"; v: root.camera ? root.camera.ip : "—" }
                KV { k: "Model"; v: root.camera ? root.camera.model : "—" }
                KV { k: "Vendor"; v: root.camera ? root.camera.vendor : "—" }
                KV { k: "Firmware"; v: root.camera ? root.camera.firmware : "—" }
                Item { Layout.preferredHeight: 8 }

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
                    Layout.fillHeight: true
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
                        Rectangle {
                            anchors.fill: parent; anchors.margins: 3
                            color: "#0b0d10"; clip: true
                            border.width: thumbMa.containsMouse ? 1.5 : 1
                            border.color: thumbMa.containsMouse ? Theme.accent : Theme.line2
                            // live frame, double-buffered: the periodic refresh loads the
                            // HIDDEN image and crossfades to it once ready, so the tile never
                            // blanks during a reload (Qt 6.4 clears an Image while its source
                            // reloads). cache:false → no shared-cache poisoning across tiles.
                            Item {
                                id: thumb
                                anchors.fill: parent; anchors.margins: 1
                                property int _tick: 0
                                property bool _showA: true       // which buffer is on screen
                                property bool _everLoaded: false
                                readonly property string _base: modelData.snapshotUrl ? modelData.snapshotUrl : ""
                                function _refresh() {
                                    if (_base === "") return;
                                    _tick++;
                                    var url = _base + "&_r=" + _tick;
                                    if (_showA) imgB.source = url; else imgA.source = url;   // load the off-screen buffer
                                }
                                Component.onCompleted: if (_base !== "") imgA.source = _base + "&_r=0"
                                Image {
                                    id: imgA
                                    anchors.fill: parent; fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false
                                    opacity: thumb._showA ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 220 } }
                                    onStatusChanged: if (status === Image.Ready) { thumb._everLoaded = true; thumb._showA = true; }
                                }
                                Image {
                                    id: imgB
                                    anchors.fill: parent; fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false
                                    opacity: thumb._showA ? 0 : 1
                                    Behavior on opacity { NumberAnimation { duration: 220 } }
                                    onStatusChanged: if (status === Image.Ready) { thumb._everLoaded = true; thumb._showA = false; }
                                }
                                // periodic live refresh — fresh frame every few seconds while the
                                // detail view is on screen (off-screen cells are virtualised away).
                                Timer { interval: 4000; repeat: true; running: root.visible; onTriggered: thumb._refresh() }
                            }
                            Icon {   // placeholder until the first frame loads (offline / loading)
                                anchors.centerIn: parent; visible: !thumb._everLoaded
                                name: modelData.live === CameraStatus.Offline ? "off" : "monitor"
                                size: 16; color: Theme.ink3
                            }
                            Rectangle {   // live-status dot (top-right)
                                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 3
                                width: 7; height: 7; radius: 3.5
                                color: modelData.live === CameraStatus.Live ? Theme.good : (modelData.live === CameraStatus.Offline ? Theme.bad : Theme.accent)
                                border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.4)
                            }
                            Rectangle {   // faint octet badge (e.g. ".101")
                                anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 2
                                visible: octT.text !== ""
                                width: octT.implicitWidth + 8; height: octT.implicitHeight + 3; radius: 2
                                color: Qt.rgba(0, 0, 0, 0.42)
                                Text {
                                    id: octT; anchors.centerIn: parent
                                    text: { var p = ("" + (modelData.ip || "")).split("."); return p.length ? ("." + p[p.length - 1]) : ""; }
                                    color: Qt.rgba(1, 1, 1, 0.82); font.family: Theme.fontMono; font.pixelSize: 10
                                }
                            }
                            MouseArea { id: thumbMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; onClicked: root.switchCamera(modelData) }
                        }
                    }
                }
                Text {
                    visible: root.groupSiblings.length === 0
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 4
                    text: (root.camera && root.camera.groupName) ? "No other cameras in this group." : "This camera isn't in a group."
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.WordWrap
                    verticalAlignment: Text.AlignTop
                }
            }
        }
    }
}
