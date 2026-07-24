import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// View tabs. `tabs[0]` is the MAIN tab — whatever the nav rail points at (the
// Live wall, Events, Health…), which may itself hold a camera opened in place;
// `tabs[1..]` are cameras opened from a tile's "Open in new tab". Those persist
// while the operator works elsewhere, which is the entire point of that control:
// before 2026-07-25 it opened the same full-screen view as "Open" and left
// nothing behind, so the two actions were indistinguishable (operator report).
//
// The strip only exists while camera tabs do, so the default shell is unchanged
// — that is what keeps it non-obstructive.
//
// The handoff has no tab spec, so the strip is built from the system's own
// idiom: orthogonal geometry, --panel as the active surface, the 3px accent edge
// the nav rail uses for "you are here" (rotated to the top), hairline dividers.
Item {
    id: root

    property var tabs: []
    property int activeIndex: 0
    property var cameraModel: null
    property string homeLabel: ""        // tabs[0]: the section, or the camera opened in it
    property bool homeIsCamera: false

    signal activated(int index)
    signal closeRequested(int index)

    implicitHeight: Theme.tabStripHeight

    // A tab's status dot and label come from the MODEL, not from the snapshot the
    // tab was opened with, so a camera that goes offline (or is renamed) shows it
    // on its tab. stateRev ticks on every observed live/recording transition.
    readonly property int rev: root.cameraModel ? root.cameraModel.stateRev : 0
    function camFor(t) {
        if (!t || !t.camId || !root.cameraModel) return null;
        var c = root.cameraModel.cameraByBackendId(t.camId);
        return (c && c.camId !== undefined && c.camId !== "") ? c : (t.cam ? t.cam : null);
    }
    function labelFor(t) {
        var c = camFor(t);
        return (c && c.name) ? c.name : (t && t.camId ? t.camId : "");
    }
    function dotFor(t) {
        var c = camFor(t);
        var s = c ? c.live : CameraStatus.LiveUnknown;
        return s === CameraStatus.Live ? Theme.good
             : s === CameraStatus.Offline ? Theme.bad
             : s === CameraStatus.Degraded ? Theme.warn : Theme.ink3;
    }

    onActiveIndexChanged: if (activeIndex > 0) list.positionViewAtIndex(activeIndex - 1, ListView.Contain)

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: Theme.line
        }
    }

    component TabItem: Item {
        id: tab
        property string label: ""
        property string iconName: ""
        property bool showDot: false
        property color dotColor: Theme.ink3
        property bool active: false
        property bool closable: false
        property string tip: ""
        // Camera names on this fleet end in the thing that tells them apart —
        // "HiWatch DS-I456Z(B) (192.168.1.106)". Eliding right made every tab on a
        // model read identically ("HiWatch DS-I456Z(B) (192…"), so camera tabs elide
        // in the MIDDLE and keep the tail.
        property int elide: Text.ElideRight
        signal chosen()
        signal closeChosen()

        Accessible.role: Accessible.PageTab
        Accessible.name: tab.label
        Accessible.selected: tab.active
        Accessible.onPressAction: tab.chosen()

        Rectangle {
            anchors.fill: parent
            color: tab.active ? Theme.panel : (tabMa.containsMouse ? Theme.panel2 : "transparent")
            Rectangle {                       // "you are here" — the rail's accent edge
                visible: tab.active
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: Theme.edgeAccent
                color: Theme.accent
            }
            Rectangle {                       // divider
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: 1
                color: Theme.line
            }
        }

        // Below the content row so the close button keeps its own clicks.
        MouseArea {
            id: tabMa
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (m) => {
                if (m.button === Qt.MiddleButton) { if (tab.closable) tab.closeChosen() }
                else tab.chosen();
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 8
            anchors.topMargin: Theme.edgeAccent
            spacing: 8

            Icon {
                visible: tab.iconName !== ""
                Layout.alignment: Qt.AlignVCenter
                name: tab.iconName; size: 13
                color: tab.active ? Theme.accent : Theme.ink3
            }
            Rectangle {
                visible: tab.showDot
                Layout.alignment: Qt.AlignVCenter
                width: 6; height: 6; radius: 3
                color: tab.dotColor
            }
            Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: tab.label
                color: tab.active ? Theme.ink : Theme.ink2
                font.family: Theme.fontSans
                font.pixelSize: 12
                font.weight: tab.active ? Font.DemiBold : Font.Normal
                elide: tab.elide
            }
            Item {
                visible: tab.closable
                Layout.preferredWidth: 16; Layout.preferredHeight: 16
                Layout.alignment: Qt.AlignVCenter
                Rectangle { anchors.fill: parent; color: xMa.containsMouse ? Theme.line2 : "transparent" }
                Icon {
                    anchors.centerIn: parent
                    name: "x"; size: 12
                    color: xMa.containsMouse ? Theme.ink : Theme.ink3
                }
                MouseArea {
                    id: xMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: tab.closeChosen()
                }
                C.ToolTip.visible: xMa.containsMouse
                C.ToolTip.text: qsTr("Close tab")
                C.ToolTip.delay: 500
            }
        }

        C.ToolTip.visible: tabMa.containsMouse && tab.tip !== ""
        C.ToolTip.text: tab.tip
        C.ToolTip.delay: 700
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---- main tab: pinned, never closes ----
        TabItem {
            Layout.preferredWidth: 172
            Layout.fillHeight: true
            label: root.homeLabel
            iconName: root.homeIsCamera ? "monitor" : "grid"
            elide: root.homeIsCamera ? Text.ElideMiddle : Text.ElideRight
            active: root.activeIndex === 0
            tip: qsTr("Main view")
            onChosen: root.activated(0)
        }

        // ---- camera tabs ----
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: ListView.Horizontal
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            model: Math.max(0, root.tabs.length - 1)
            // Tabs share the free width, down to a floor; past that the strip scrolls
            // rather than shrinking labels into uselessness.
            readonly property real tabW: count > 0 ? Math.max(140, Math.min(260, width / count)) : 0

            delegate: TabItem {
                required property int index
                readonly property var t: root.tabs.length > index + 1 ? root.tabs[index + 1] : null
                width: list.tabW
                height: list.height
                label: t ? root.labelFor(t) : ""
                elide: Text.ElideMiddle
                showDot: true
                dotColor: { root.rev; return t ? root.dotFor(t) : Theme.ink3 }
                active: root.activeIndex === index + 1
                closable: true
                tip: {
                    root.rev;
                    var c = t ? root.camFor(t) : null;
                    return c ? (c.name + (c.ip ? ("  ·  " + c.ip) : "")) : "";
                }
                onChosen: root.activated(index + 1)
                onCloseChosen: root.closeRequested(index + 1)
            }
        }
    }
}
