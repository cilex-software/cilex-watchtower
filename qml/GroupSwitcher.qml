import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// The camera-group quick filter: a button naming the current scope, and a popup listing
// "All cameras" and every group with its camera count, plus "Sync from server".
//
// ONE component for both walls — the live wall's header (LiveMonitor.qml, where it was
// born) and the synchronized playback wall's sub-bar (WallPlayback.qml) — because the
// operator asked for "exactly the same one from the live wall screen" (2026-09-26), and a
// copy would drift. Change it here and both screens change.
Rectangle {
    id: ctl

    // [{ id, name, count }] — "All cameras" (id "") first, then each group. The counts are
    // the CLIENT roster's (groupList().total), never the backend's /groups camera_count,
    // which counts cameras this client cannot see (2026-08-10: Inside 26 vs 22 visible).
    property var options: []
    // The highlighted row. Pass a value no row carries (e.g. "__custom__") for "none of these".
    property var currentId: ""
    property string label: ""           // button text: the current scope
    property var cameraModel: null      // "Sync from server" calls refresh() on it
    // The live wall scopes to an empty group and says "no cameras in X", so an empty row
    // stays clickable there. The playback wall cannot composite zero cameras: there an
    // empty row is dimmed AND inert, with a tooltip saying why (operator 2026-08-10: a
    // click that did "nothing" is worse than a row that visibly can't be picked).
    property bool emptySelectable: true
    signal picked(string id, string name)

    function open() { groupPopup.open() }     // for verification hooks
    function close() { groupPopup.close() }

    Layout.preferredHeight: 38
    implicitHeight: 38
    implicitWidth: groupRow.implicitWidth + 24
    color: Theme.panel
    border.width: 1
    border.color: grpMa.containsMouse ? Theme.accent : Theme.line2
    Row {
        id: groupRow; anchors.centerIn: parent; spacing: 8
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: ctl.label
            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
            elide: Text.ElideRight; width: Math.min(implicitWidth, 180)
        }
        Icon { anchors.verticalCenter: parent.verticalCenter; name: "chev"; size: 12; color: Theme.ink3 }
    }
    MouseArea { id: grpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: groupPopup.open() }
    C.Popup {
        id: groupPopup
        y: ctl.height + 4
        x: 0
        width: 220
        padding: 0
        background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
        contentItem: Column {
            Repeater {
                model: ctl.options
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool isEmpty: modelData.count === 0
                    readonly property bool inert: isEmpty && !ctl.emptySelectable
                    width: 220; height: 34
                    color: (grpOptMa.containsMouse && !inert) ? Theme.panel2 : "transparent"
                    Text {
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        width: parent.width - 24 - cntTxt.implicitWidth - 8
                        text: modelData.name
                        // an empty group is dimmed so it stops looking like a group with
                        // cameras in it; whether it is clickable is emptySelectable's call
                        color: ctl.currentId === modelData.id ? Theme.accent
                             : (parent.isEmpty ? Theme.ink3 : Theme.ink)
                        font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
                    }
                    Text {
                        id: cntTxt
                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: modelData.count
                        color: parent.isEmpty ? Theme.ink3
                             : (ctl.currentId === modelData.id ? Theme.accent : Theme.ink2)
                        font.family: Theme.fontMono; font.pixelSize: 11
                    }
                    MouseArea {
                        id: grpOptMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: parent.inert ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: {
                            if (parent.inert) return;
                            ctl.picked(modelData.id, modelData.name);
                            groupPopup.close();
                        }
                    }
                    C.ToolTip.visible: grpOptMa.containsMouse && inert
                    C.ToolTip.delay: 300
                    C.ToolTip.text: qsTr("No cameras in this group")
                }
            }

            // Manual resync — pull fresh groups + membership from the server now
            // (the 15 s poll also auto-syncs groups).
            Rectangle { width: 220; height: 1; color: Theme.line2 }
            Rectangle {
                width: 220; height: 34
                color: grpSyncMa.containsMouse ? Theme.panel2 : "transparent"
                Text {
                    anchors { left: parent.left; leftMargin: 12; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    text: qsTr("↻  Sync from server")
                    color: grpSyncMa.containsMouse ? Theme.accent : Theme.ink2
                    font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
                }
                MouseArea {
                    id: grpSyncMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { if (ctl.cameraModel) ctl.cameraModel.refresh(); groupPopup.close(); }
                }
            }
        }
    }
}
