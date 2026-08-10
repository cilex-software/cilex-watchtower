import QtQuick
import Watchtower

// An honest state, centred on the picture (spec §4). Every banner has three
// parts — a TAG, a FACT and a CONSEQUENCE — and, where one exists, an action.
// None of them says "something went wrong".
//
// It centres on the STAGE, and the stage is the video's own box because the
// right rail is a column rather than an overlay: no per-element offset is
// needed for the banner to land on the picture it is about.
Rectangle {
    id: banner

    property string tag: ""
    property color tagInk: Theme.ink3
    property color tagBg: Theme.panel2
    property color tagRing: Theme.line2
    property string fact: ""
    property string consequence: ""
    property string action: ""
    signal actionClicked()

    color: Qt.rgba(11 / 255, 10 / 255, 10 / 255, 0.82)

    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 460)
        spacing: 13

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: banner.tag !== ""
            width: tagT.implicitWidth + 16; height: 16
            color: banner.tagBg
            border.width: 1; border.color: banner.tagRing
            Text { id: tagT; anchors.centerIn: parent; text: banner.tag; color: banner.tagInk
                   font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.6 }
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            text: banner.fact; color: Theme.ink
            font.family: Theme.fontSans; font.pixelSize: 15; lineHeight: 1.5
        }
        Text {
            visible: banner.consequence !== ""
            width: Math.min(parent.width, 420)
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            text: banner.consequence; color: Theme.ink3
            font.family: Theme.fontSans; font.pixelSize: 12; lineHeight: 1.5
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: banner.action !== ""
            width: actT.implicitWidth + 24; height: 26
            color: actMa.containsMouse ? Theme.accentSoft : "transparent"
            border.width: 1; border.color: Theme.accent
            Text { id: actT; anchors.centerIn: parent; text: banner.action; color: Theme.accent
                   font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.8 }
            MouseArea { id: actMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: banner.actionClicked() }
        }
    }
}
