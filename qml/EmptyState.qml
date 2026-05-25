import QtQuick
import Watchtower

// Reusable empty / error pattern (design §32): a single component with a
// variable icon, message, and optional action — not many one-off screens.
Item {
    id: root

    property string icon: "alert"
    property color iconColor: Theme.ink3
    property string title: ""
    property string subtitle: ""
    property string actionLabel: ""

    signal action()

    Column {
        anchors.centerIn: parent
        spacing: Theme.s14
        width: Math.min(parent.width - Theme.s48, 420)

        Icon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: root.icon
            size: 32
            color: root.iconColor
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.title
            color: Theme.ink
            font.family: Theme.fontSans
            font.pixelSize: Theme.fsTitle
            font.weight: Font.DemiBold
        }
        Text {
            visible: root.subtitle !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.subtitle
            color: Theme.ink3
            font.family: Theme.fontSans
            font.pixelSize: Theme.fsBody
            lineHeight: 1.35
        }

        // optional action (ghost .btn)
        Rectangle {
            visible: root.actionLabel !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            implicitWidth: actionText.implicitWidth + 28
            height: 34
            radius: 0
            color: abtn.containsMouse ? Theme.panel : "transparent"
            border.width: 1
            border.color: abtn.containsMouse ? Theme.accent : Theme.line2

            Text {
                id: actionText
                anchors.centerIn: parent
                text: root.actionLabel
                color: Theme.ink
                font.family: Theme.fontSans
                font.pixelSize: Theme.fsSmall
                font.weight: Font.Medium
            }
            MouseArea {
                id: abtn
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.action()
            }
        }
    }
}
