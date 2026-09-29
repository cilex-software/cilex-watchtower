import QtQuick
import Watchtower

// Preferences' segmented control, with any number of choices -- the Labs screen's view and
// period switches and the Findings view's period switch are the same control.
Rectangle {
    id: seg
    property var choices: []             // [{k: label, v: value}]
    property string value: ""
    signal picked(string v)
    implicitWidth: segRow.implicitWidth + 2
    implicitHeight: 28
    color: Theme.bg
    border.width: 1
    border.color: Theme.line2
    Row {
        id: segRow
        x: 1; y: 1
        Repeater {
            model: seg.choices
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: seg.value === modelData.v
                width: segText.implicitWidth + 28; height: 26
                color: on ? Theme.accent : (segMa.containsMouse ? Theme.panel : "transparent")
                Text { id: segText; anchors.centerIn: parent; text: modelData.k
                       color: parent.on ? Theme.bg : Theme.ink2
                       font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold
                       font.capitalization: Font.AllUppercase; font.letterSpacing: 0.8 }
                MouseArea { id: segMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: if (!parent.on) seg.picked(modelData.v) }
            }
        }
    }
}
