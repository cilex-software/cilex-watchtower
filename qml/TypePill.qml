import QtQuick
import Watchtower

// events-v2 .tpill — type pill: 22px tall, type icon + uppercase mono label,
// colored per type (person=accent, vehicle=info, tamper/line_cross=bad, else ink).
Rectangle {
    id: r
    property string type: "motion"
    property string text: ""                      // override; default = type label
    readonly property var _def: EventsStore.types[r.type] ? EventsStore.types[r.type] : ({ label:"", icon:"motion" })
    readonly property color _fg: r.type === "person" ? Theme.accent
        : r.type === "vehicle" ? Theme.info
        : (r.type === "tamper" || r.type === "line_cross") ? Theme.bad
        : r.type === "offline" ? Theme.ink3 : Theme.ink2
    readonly property color _bd: r.type === "person" ? Theme.accentDim
        : r.type === "vehicle" ? Theme.infoDim
        : (r.type === "tamper" || r.type === "line_cross") ? Theme.badDim : Theme.line2

    implicitHeight: 22
    implicitWidth: row.implicitWidth + 16
    color: Theme.panel
    border.width: 1; border.color: _bd

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left; anchors.leftMargin: 8
        spacing: 6
        EvIcon { anchors.verticalCenter: parent.verticalCenter; name: r._def.icon; size: 12; color: r._fg }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: (r.text !== "" ? r.text : r._def.label).toUpperCase(); color: r._fg
            font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.6
        }
    }
}
