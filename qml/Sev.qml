import QtQuick
import Watchtower

// events-v2 .sev — severity tag: a 3×12 colored bar + uppercase mono label.
// critical=bad · high=accent · medium=ink-2 · low=ink-3.
Row {
    id: r
    property string level: "low"
    spacing: 6
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 3; height: 12; color: Theme.sevColor(r.level)
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: r.level.toUpperCase(); color: Theme.sevColor(r.level)
        font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 0.8
    }
}
