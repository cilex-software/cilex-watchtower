import QtQuick
import Watchtower

// events-v2 .btn (+ variants .pri / .danger / .good / .sm / .ghost). 34px tall
// (28 small), icon + label, with the spec's hover treatments.
Rectangle {
    id: r
    property string label: ""
    property string icon: ""                 // EvIcon name (optional)
    property string variant: ""              // "" | "pri" | "danger" | "good" | "ghost"
    property bool small: false
    property bool enabledBtn: true
    property bool on: false                   // .is-on — amber active treatment (e.g. bookmarked)
    property string kbd: ""                   // optional trailing keyboard hint (e.g. "E")
    signal clicked()

    readonly property bool _hover: ma.containsMouse && enabledBtn
    implicitHeight: small ? 28 : 34
    implicitWidth: row.implicitWidth + (small ? 20 : 28)
    opacity: enabledBtn ? 1 : 0.45

    color: variant === "pri"    ? (_hover ? "#f0ad48" : Theme.accent)
         : variant === "danger" ? (_hover ? Qt.rgba(217/255,102/255,73/255,0.18) : Theme.badSoft)
         : variant === "good"   ? (_hover ? Qt.rgba(142/255,185/255,107/255,0.18) : Theme.goodSoft)
         : variant === "ghost"  ? (_hover ? Theme.panel : "transparent")
         : (_hover ? Theme.panel2 : Theme.panel)
    border.width: 1
    border.color: variant === "pri"    ? Theme.accent
                : variant === "danger" ? Theme.badDim
                : variant === "good"   ? Theme.goodDim
                : variant === "ghost"  ? "transparent"
                : (_hover ? Theme.ink3 : Theme.line2)

    readonly property color _fg: variant === "pri"    ? Theme.bg
                               : variant === "danger" ? Theme.bad
                               : variant === "good"   ? Theme.good
                               : on                   ? Theme.accent
                               : variant === "ghost"  ? (_hover ? Theme.ink : Theme.ink2)
                               : Theme.ink

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        EvIcon {
            visible: r.icon !== ""
            anchors.verticalCenter: parent.verticalCenter
            name: r.icon; size: r.small ? 13 : 15; color: r._fg
        }
        Text {
            visible: r.label !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: r.label; color: r._fg
            font.family: Theme.fontSans; font.pixelSize: r.small ? 11 : 12; font.weight: Font.DemiBold
        }
        Rectangle {                              // trailing kbd hint (e.g. "E")
            visible: r.kbd !== ""
            anchors.verticalCenter: parent.verticalCenter
            radius: 3; height: 16; width: kbdT.implicitWidth + 10
            color: Qt.rgba(0, 0, 0, 0.2); border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.3)
            Text { id: kbdT; anchors.centerIn: parent; text: r.kbd; color: r._fg
                font.family: Theme.fontMono; font.pixelSize: 10 }
        }
    }
    MouseArea {
        id: ma; anchors.fill: parent; hoverEnabled: true
        cursorShape: r.enabledBtn ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (r.enabledBtn) r.clicked()
    }
}
