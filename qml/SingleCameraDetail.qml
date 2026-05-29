import QtQuick
import QtQuick.Layouts
import Watchtower

// Single Camera Detail — Live (S05): focused live view of one camera. Large
// player (follows the global SD/HD preference, with a per-view SD/HD toggle),
// identity + status aside, and same-group cameras to switch. Back returns to
// where the user came from.
Item {
    id: root

    property var camera: null      // camera map (name, camId, ip, rtspUrl, rtspSubUrl, live, recording, groupId, groupName, mac, model, vendor, firmware)
    property var cameraModel: null
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
                active: root.visible && root.streamUrl !== "" && (root.camera ? root.camera.live !== CameraStatus.Offline : false)
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
                        Text { text: root.camera ? (root.camera.groupName + "  ·  " + root.camera.ip) : ""; color: Qt.rgba(1, 1, 1, 0.6); font.family: Theme.fontMono; font.pixelSize: 11 }
                    }
                    Item { Layout.fillWidth: true }
                    Row {
                        spacing: 4
                        LiveStatusBadge { state: root.camera ? root.camera.live : CameraStatus.LiveUnknown }
                        RecordingStatusBadge { state: root.camera ? root.camera.recording : CameraStatus.RecUnknown }
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
                KV { k: "Stream"; v: vsurf.playing ? "Live" : (root.camera && root.camera.live === CameraStatus.Offline ? "Offline" : (vsurf.errored ? "Unavailable" : "Connecting…")) }
                KV { k: "Recording"; v: root.camera ? (root.camera.recording === CameraStatus.Recording ? "Recording" : (root.camera.recording === CameraStatus.NotRecording ? "Not recording" : "Unknown")) : "—" }
                KV { k: "Quality"; v: root.useMain ? "HD (main)" : "SD (substream)" }
                Item { Layout.preferredHeight: 8 }

                AsideHeader { text: "Device" }
                KV { k: "IP"; v: root.camera ? root.camera.ip : "—" }
                KV { k: "Model"; v: root.camera ? root.camera.model : "—" }
                KV { k: "Vendor"; v: root.camera ? root.camera.vendor : "—" }
                KV { k: "Firmware"; v: root.camera ? root.camera.firmware : "—" }
                Item { Layout.preferredHeight: 8 }

                AsideHeader { text: "Same group" }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.leftMargin: 8
                    Layout.rightMargin: 8
                    Layout.bottomMargin: 8
                    clip: true
                    model: root.siblings
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        visible: root.camera ? modelData.mac !== root.camera.mac : true
                        height: visible ? 36 : 0
                        color: sibMa.containsMouse ? Theme.panel2 : "transparent"
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                            Rectangle { Layout.preferredWidth: 6; Layout.preferredHeight: 6; radius: 0; color: modelData.live === CameraStatus.Live ? Theme.good : (modelData.live === CameraStatus.Offline ? Theme.bad : Theme.accent) }
                            Text { Layout.fillWidth: true; text: modelData.name; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                            Text { text: modelData.ip; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                        }
                        MouseArea { id: sibMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.switchCamera(modelData) }
                    }
                }
            }
        }
    }
}
