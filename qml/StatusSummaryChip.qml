import QtQuick
import Watchtower

// One cell of the operational status strip (design §13): dot + uppercase mono
// label + large count. Clickable to filter. Used in the top-bar strip.
Rectangle {
    id: root

    property string label: ""
    property bool compact: false
    property int count: 0
    property color dotColor: Theme.ink3
    property bool active: false
    property bool pulse: false

    signal clicked()

    implicitHeight: 38
    implicitWidth: row.implicitWidth + (compact ? 14 : 28)
    height: 38
    radius: 0
    color: active ? Theme.accentSoft
                  : (ma.containsMouse ? Theme.panel2 : "transparent")

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: root.compact ? 5 : 8

        Rectangle {
            id: dot
            width: 7
            height: 7
            radius: 0
            anchors.verticalCenter: countText.verticalCenter
            color: root.dotColor
            SequentialAnimation on opacity {
                running: root.pulse
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 800; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
            }
        }

        Text {
            anchors.baseline: countText.baseline
            text: root.label
            color: root.active ? Theme.accent : Theme.ink3
            font.family: Theme.fontMono
            font.pixelSize: root.compact ? 10 : 11
            font.weight: Font.DemiBold
            font.letterSpacing: root.compact ? 0.5 : 0.88
            font.capitalization: Font.AllUppercase
        }

        Text {
            id: countText
            anchors.verticalCenter: parent.verticalCenter
            text: root.count
            color: root.active ? Theme.accent : Theme.ink
            font.family: Theme.fontSans
            font.pixelSize: root.compact ? 16 : 18
            font.weight: Font.Bold
            font.letterSpacing: -0.36
        }
    }
}
