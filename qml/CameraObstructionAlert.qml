import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Watchtower

// Global attention card: graphite shell, restrained pulsing status edge, amber action.
Item {
    id: root
    required property var controller
    signal openCamera(string cameraId, string incidentId)
    readonly property var incident: controller.pendingIncident
    visible: !!incident.incident_id
    z: 1500
    onVisibleChanged: if (visible) Qt.callLater(function() { if (root.visible) openLiveButton.forceActiveFocus(Qt.PopupFocusReason); })

    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.65) }
    MouseArea { anchors.fill: parent; onWheel: (wheel) => { wheel.accepted = true } }
    Rectangle {
        id: card
        objectName: "cameraObstructionAlertCard"
        anchors.centerIn: parent
        width: Math.min(560, parent.width - Theme.s32)
        height: header.height + content.implicitHeight + Theme.s48 + footer.height
        color: Theme.panel
        border.color: Theme.line2
        border.width: Theme.borderThin
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: Theme.edgeAccent
            color: Theme.bad
            SequentialAnimation on opacity {
                running: root.visible
                loops: Animation.Infinite
                NumberAnimation { from: 0.4; to: 1.0; duration: 1100 }
                NumberAnimation { from: 1.0; to: 0.4; duration: 1100 }
            }
        }
        RowLayout {
            id: header
            x: Theme.s24
            width: parent.width - Theme.s48
            height: Theme.s56
            spacing: Theme.s10
            Icon { name: "alert"; size: Theme.s18; color: Theme.bad }
            Text {
                Layout.fillWidth: true
                text: qsTr("Potential camera obstruction")
                color: Theme.ink
                font.family: Theme.fontSans
                font.pixelSize: Theme.fsTitle
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
            }
        }
        Rectangle { y: header.height; width: parent.width; height: Theme.borderThin; color: Theme.line }
        ColumnLayout {
            id: content
            anchors { left: parent.left; right: parent.right; top: header.bottom; margins: Theme.s24 }
            spacing: Theme.s12
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s12
                Rectangle {
                    implicitWidth: Theme.s48
                    implicitHeight: Theme.s48
                    color: Theme.bg
                    border.width: Theme.borderThin
                    border.color: Theme.line
                    Icon { anchors.centerIn: parent; name: "monitor"; size: Theme.s22; color: Theme.ink2 }
                }
                Text {
                    Layout.fillWidth: true
                    text: root.incident.camera_name || root.incident.camera_id || ""
                    color: Theme.ink
                    font.family: Theme.fontSans
                    font.pixelSize: Theme.fsH1
                    font.weight: Font.DemiBold
                    wrapMode: Text.WordWrap
                }
            }
            Text {
                Layout.fillWidth: true
                text: qsTr("The camera view has substantially deteriorated. Open the live stream to confirm the incident or report a false alarm.")
                color: Theme.ink2
                font.family: Theme.fontSans
                font.pixelSize: Theme.fsBody
                wrapMode: Text.WordWrap
                lineHeight: 1.3
            }
            Text {
                Layout.fillWidth: true
                visible: root.controller.errorString !== ""
                text: root.controller.errorString
                color: Theme.warn
                font.family: Theme.fontSans
                font.pixelSize: Theme.fsSmall
                wrapMode: Text.WordWrap
            }
        }
        Rectangle {
            id: footer
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 1 }
            height: openLiveButton.implicitHeight + Theme.s32
            color: Theme.bg
            Rectangle { width: parent.width; height: Theme.borderThin; color: Theme.line }
            CameraObstructionButton {
                id: openLiveButton
                objectName: "cameraObstructionOpenLive"
                anchors { right: parent.right; rightMargin: Theme.s24; verticalCenter: parent.verticalCenter }
                width: Math.min(implicitWidth, parent.width - Theme.s48)
                text: qsTr("Open camera live stream")
                leadingIcon: "play"
                variant: "primary"
                onClicked: root.openCamera(String(root.incident.camera_id), String(root.incident.incident_id))
            }
        }
    }
}
