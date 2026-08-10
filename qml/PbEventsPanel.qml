import QtQuick
import QtQuick.Controls.Basic as C
import Watchtower

// Playback right rail — a COLUMN the stage shrinks around, never an overlay
// (spec §2.6). This reverses the Groups rule on purpose: a covered tile is still
// where the operator left it, but a single continuous video frame overlaid is
// larger and a third hidden, with the visible remainder off-centre — and every
// centred element (the honest-state banners above all) then centres on a stage
// the operator can only partly see.
//
// The list and the motion lane are ONE selection model: one hover id, one
// selected id, one set of type filters. There is no state in which they
// disagree, because there is only one state.
Rectangle {
    id: panel
    color: Theme.panel

    property var items: []            // [{id, ms, len, type, color}] newest-first
    property int unfilteredCount: 0   // events in the window BEFORE the type chips
    property var types: []            // [{key, label, color, on}]
    property string hoverId: ""
    property string selId: ""

    signal hovered(string id)
    signal picked(string id, double ms)
    signal typeToggled(string key)
    signal closeRequested()
    signal resizeDragged(real dx)
    signal resizeReset()

    Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 1; color: Theme.line2 }

    // ---- width grip -------------------------------------------------------
    Item {
        id: grip
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; leftMargin: -3 }
        width: 6
        z: 9
        Rectangle { anchors.fill: parent; color: Theme.accentSoft; visible: gripMa.containsMouse || gripMa.drag.active }
        Rectangle {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 2 }
            width: gripMa.containsMouse || gripMa.drag.active ? 2 : 1
            height: 34
            color: gripMa.containsMouse || gripMa.drag.active ? Theme.accent : Theme.line2
        }
        MouseArea {
            id: gripMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SizeHorCursor
            property real _x0: 0
            onPressed: (m) => { _x0 = mapToItem(null, m.x, m.y).x }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var nx = mapToItem(null, m.x, m.y).x;
                panel.resizeDragged(_x0 - nx);
                _x0 = nx;
            }
            onDoubleClicked: panel.resizeReset()
        }
        C.ToolTip.visible: gripMa.containsMouse
        C.ToolTip.delay: 600
        C.ToolTip.text: qsTr("Drag to resize · double-click to reset")
    }

    Column {
        anchors.fill: parent
        anchors.leftMargin: 1
        spacing: 0

        Item {   // header
            width: parent.width; height: 28
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: Theme.line }
            Text {
                anchors { left: parent.left; leftMargin: 11; verticalCenter: parent.verticalCenter }
                text: qsTr("EVENTS", "playback right rail header")
                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.4
            }
            Text {
                anchors { right: closeBtn.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                text: panel.items.length
                color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10
            }
            Rectangle {
                id: closeBtn
                anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                width: 24; height: 24
                color: closeMa.containsMouse ? Theme.panel2 : "transparent"
                Text { anchors.centerIn: parent; text: "✕"; color: closeMa.containsMouse ? Theme.ink : Theme.ink3
                       font.family: Theme.fontMono; font.pixelSize: 11 }
                MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: panel.closeRequested() }
            }
        }

        Flow {   // type chips — they filter the list AND the lane, simultaneously
            width: parent.width
            visible: panel.types.length > 0
            leftPadding: 10; rightPadding: 10; topPadding: 7; bottomPadding: 7
            spacing: 5
            Repeater {
                model: panel.types
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    width: chipRow.implicitWidth + 12; height: 18
                    color: modelData.on ? Theme.panel2 : "transparent"
                    border.width: 1
                    border.color: modelData.on ? Theme.ink3 : Theme.line2
                    Row {
                        id: chipRow
                        anchors.centerIn: parent; spacing: 6
                        Rectangle { width: 5; height: 5; color: chip.modelData.color
                                    anchors.verticalCenter: parent.verticalCenter }
                        Text { text: chip.modelData.label
                               color: chip.modelData.on ? Theme.ink : Theme.ink3
                               font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.6
                               anchors.verticalCenter: parent.verticalCenter }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: panel.typeToggled(chip.modelData.key) }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Theme.line; visible: panel.types.length > 0 }

        Item {
            width: parent.width
            height: panel.height - y
            clip: true

            Text {
                anchors { left: parent.left; right: parent.right; top: parent.top
                          leftMargin: 11; rightMargin: 11; topMargin: 12 }
                visible: panel.items.length === 0
                wrapMode: Text.WordWrap
                // The empty state names its filter: "none at all" and "none of the
                // types you chose" are different facts.
                text: panel.unfilteredCount > 0 ? qsTr("No events of the selected types in this window.")
                                                : qsTr("No events in this window.")
                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
            }

            ListView {
                id: list
                anchors.fill: parent
                model: panel.items
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                C.ScrollBar.vertical: C.ScrollBar { policy: C.ScrollBar.AsNeeded }
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool isHov: panel.hoverId === modelData.id
                    readonly property bool isSel: panel.selId === modelData.id
                    width: list.width; height: 28
                    color: isSel ? Theme.accentSoft : (isHov || rowMa.containsMouse ? Theme.panel2 : "transparent")
                    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                height: 1; color: Theme.line }
                    Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                width: 2; color: Theme.accent; visible: row.isSel }
                    Rectangle {
                        anchors { left: parent.left; leftMargin: 11; verticalCenter: parent.verticalCenter }
                        width: 6; height: 6; color: row.modelData.color
                    }
                    Text {
                        anchors { left: parent.left; leftMargin: 25; right: tm.left; rightMargin: 8
                                  verticalCenter: parent.verticalCenter }
                        text: row.modelData.label
                        elide: Text.ElideRight
                        color: row.isSel ? Theme.ink : Theme.ink2
                        font.family: Theme.fontSans; font.pixelSize: 11
                    }
                    Text {
                        id: tm
                        anchors { right: parent.right; rightMargin: 11; verticalCenter: parent.verticalCenter }
                        text: PbFmt.hms(row.modelData.ms)
                        color: row.isSel ? Theme.accent : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 10
                    }
                    MouseArea {
                        id: rowMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onEntered: panel.hovered(row.modelData.id)
                        onExited: if (panel.hoverId === row.modelData.id) panel.hovered("")
                        onClicked: panel.picked(row.modelData.id, row.modelData.ms)
                    }
                }
            }
        }
    }
}
