import QtQuick
import Watchtower

// A single alert/feedback toast (design §25). 380px, panel bg, a colored left
// edge (bad for single alerts, accent for grouped/info), header + secondary line,
// an optional action, and a close affordance.
Rectangle {
    id: root

    property string title: ""
    property string subtitle: ""
    property color edgeColor: Theme.bad
    property string actionLabel: ""

    signal actionClicked()
    signal closed()

    width: 380
    implicitHeight: col.implicitHeight + 24
    color: Theme.panel
    border.width: 1
    border.color: Theme.line2

    // colored left edge
    Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Theme.edgeToast
        color: root.edgeColor
    }

    Column {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 14 }
        anchors.rightMargin: 12
        spacing: 8

        Item {
            width: parent.width
            implicitHeight: Math.max(titleText.implicitHeight, closeBtn.height)
            Text {
                id: titleText
                anchors { left: parent.left; right: closeBtn.left; rightMargin: 8; top: parent.top }
                text: root.title
                color: Theme.ink
                font.family: Theme.fontSans
                font.pixelSize: Theme.fsBody
                font.weight: Font.DemiBold
                // Titles carry VERBATIM backend sentences (autofocus results,
                // ingest errors) — they must WRAP, not vanish behind an ellipsis
                // (operator report 2026-08-04: both AF toasts clipped mid-word).
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
            }
            IconButton {
                id: closeBtn
                anchors { right: parent.right; top: parent.top }
                implicitWidth: 22; implicitHeight: 22
                name: "x"; iconSize: 14; iconColor: Theme.ink3; hoverIcon: Theme.ink
                tip: "Dismiss"
                onClicked: root.closed()
            }
        }

        Text {
            visible: root.subtitle !== ""
            width: parent.width
            text: root.subtitle
            color: Theme.ink3
            font.family: Theme.fontMono
            font.pixelSize: Theme.fsMono
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        // action (mono uppercase pill)
        Rectangle {
            visible: root.actionLabel !== ""
            implicitWidth: actTxt.implicitWidth + 20
            height: 28
            color: "transparent"
            border.width: 1
            border.color: actMa.containsMouse ? Theme.accent : Theme.line2
            Text {
                id: actTxt
                anchors.centerIn: parent
                text: root.actionLabel
                color: actMa.containsMouse ? Theme.ink : Theme.ink2
                font.family: Theme.fontMono
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
                font.capitalization: Font.AllUppercase
            }
            MouseArea {
                id: actMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.actionClicked()
            }
        }
    }
}
