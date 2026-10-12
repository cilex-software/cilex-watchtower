import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Watchtower

// App-wide alert, outside all page/loaders. Pulse only the border, slowly;
// text and controls remain stationary and fully opaque for readability.
Item {
    id: root
    required property var controller
    signal openCamera(string cameraId, string incidentId)
    readonly property var incident: controller.pendingIncident
    visible: !!incident.incident_id
    z: 1500

    Rectangle { anchors.fill: parent; color: "#99000000" }
    MouseArea { anchors.fill: parent; onWheel: (wheel) => { wheel.accepted = true } }
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(560, parent.width - 40)
        height: content.implicitHeight + 48
        color: Theme.panel
        border.color: Theme.bad
        border.width: 2
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            border.color: "#ff7d66"
            border.width: 4
            SequentialAnimation on opacity {
                running: root.visible
                loops: Animation.Infinite
                NumberAnimation { from: 0.25; to: 1.0; duration: 1100 }
                NumberAnimation { from: 1.0; to: 0.25; duration: 1100 }
            }
        }
        ColumnLayout {
            id: content
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 24 }
            spacing: 14
            Text {
                Layout.fillWidth: true
                text: qsTr("Potential camera obstruction")
                color: Theme.bad
                font.family: Theme.fontSans
                font.pixelSize: 23
                font.bold: true
                wrapMode: Text.WordWrap
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
            }
            Text {
                Layout.fillWidth: true
                text: root.incident.camera_name || root.incident.camera_id || ""
                color: Theme.ink
                font.family: Theme.fontSans
                font.pixelSize: 21
                wrapMode: Text.WordWrap
            }
            Text {
                Layout.fillWidth: true
                text: qsTr("The camera view has substantially deteriorated. Open the live stream to confirm the incident or report a false alarm.")
                color: Theme.ink2
                font.family: Theme.fontSans
                font.pixelSize: 14
                wrapMode: Text.WordWrap
            }
            Text {
                Layout.fillWidth: true
                visible: root.controller.errorString !== ""
                text: root.controller.errorString
                color: Theme.warn
                wrapMode: Text.WordWrap
            }
            Button {
                id: openLiveButton
                objectName: "cameraObstructionOpenLive"
                Layout.fillWidth: true
                text: qsTr("Open camera live stream")
                font.pixelSize: 16
                font.bold: true
                onClicked: root.openCamera(String(root.incident.camera_id), String(root.incident.incident_id))
                background: Rectangle { color: openLiveButton.down ? Theme.warnDim : Theme.accent }
                contentItem: Text { text: openLiveButton.text; font: openLiveButton.font; color: Theme.bg; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                padding: 14
            }
        }
    }
}
