import QtQuick
import Watchtower

// events-v2 .statetag — lifecycle state: round 6px dot + uppercase mono label.
// new=bad · ack=accent · progress=info · resolved=good · dismissed=ink-3.
Row {
    id: r
    property string state: "new"
    property bool dotOnly: false                  // row usage: just the 7px dot, no label
    property string label: ""                     // override label (e.g. "resolved · False alarm")
    property int dotSize: 6
    readonly property color _c: r.state === "new" ? Theme.bad
        : r.state === "ack" ? Theme.accent
        : r.state === "progress" ? Theme.info
        : r.state === "resolved" ? Theme.good : Theme.ink3
    spacing: 6
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: r.dotSize; height: r.dotSize; radius: width / 2; color: r._c
    }
    Text {
        visible: !r.dotOnly
        anchors.verticalCenter: parent.verticalCenter
        text: r.label !== "" ? r.label : r.state.toUpperCase(); color: r._c
        font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 0.8
    }
}
