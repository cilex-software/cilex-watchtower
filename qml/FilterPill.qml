import QtQuick
import Watchtower

// Multi-select filter pill (design §16). Active = accent-soft fill + accent
// border/text. Optional leading "+" (add filter) or trailing "×" (remove).
Rectangle {
    id: root

    property string label: ""
    property bool active: false
    property bool removable: false
    property bool leadingPlus: false

    signal clicked()
    signal removed()

    readonly property color fgColor: active ? Theme.accent
                                            : (ma.containsMouse ? Theme.ink : Theme.ink2)

    implicitHeight: 30
    implicitWidth: row.implicitWidth + 24
    height: 30
    radius: 0
    color: active ? Theme.accentSoft : Theme.panel
    border.width: 1
    border.color: active ? Theme.accent : (ma.containsMouse ? Theme.ink3 : Theme.line2)

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
        spacing: 6

        Text {
            visible: root.leadingPlus
            anchors.verticalCenter: parent.verticalCenter
            text: "+"
            color: root.fgColor
            font.family: Theme.fontSans
            font.pixelSize: 13
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: root.fgColor
            font.family: Theme.fontSans
            font.pixelSize: 12
            font.weight: Font.Medium
        }
        Text {
            visible: root.removable
            anchors.verticalCenter: parent.verticalCenter
            text: "×"
            color: Theme.ink3
            font.family: Theme.fontMono
            font.pixelSize: 14
            MouseArea {
                anchors.fill: parent
                anchors.margins: -4
                cursorShape: Qt.PointingHandCursor
                onClicked: root.removed()
            }
        }
    }
}
