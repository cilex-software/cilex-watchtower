import QtQuick
import QtQuick.Controls.Basic
import Watchtower

// Reusable icon button with hover styling and a tooltip. Every icon-only action
// in the app needs a tooltip (design §15). Styling is fully prop-driven so it
// covers tile-action buttons, page-bar buttons, top-bar buttons, etc.
Item {
    id: root

    property string name: ""
    property int iconSize: 14
    property color iconColor: Theme.ink2
    property color bgColor: "transparent"
    property color borderColor: "transparent"
    property color hoverIcon: Theme.accent
    property color hoverBg: "transparent"
    property color hoverBorder: "transparent"
    property string tip: ""

    signal clicked()

    implicitWidth: 30
    implicitHeight: 30
    opacity: enabled ? 1.0 : 0.4

    Rectangle {
        anchors.fill: parent
        radius: 0
        color: ma.containsMouse ? root.hoverBg : root.bgColor
        border.width: (root.borderColor.a > 0 || root.hoverBorder.a > 0) ? 1 : 0
        border.color: ma.containsMouse ? root.hoverBorder : root.borderColor

        Icon {
            anchors.centerIn: parent
            name: root.name
            size: root.iconSize
            color: ma.containsMouse ? root.hoverIcon : root.iconColor
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.enabled) root.clicked()
    }

    ToolTip.text: root.tip
    ToolTip.visible: root.tip !== "" && ma.containsMouse
    ToolTip.delay: 400
}
