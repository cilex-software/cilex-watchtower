import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// Camera Groups (S03): organize cameras into user-defined groups and rename
// them (names/groups are the operator's, persisted). Two-pane: group list left,
// the selected group's cameras right with inline rename + group assignment.
Item {
    id: root
    property var cameraModel: null

    property string selectedGroup: ""             // "" = all cameras
    property string selectedGroupName: "All cameras"
    property int rev: 0                            // bump to refresh derived lists
    // Group create/rename/delete/assign is admin/operator only (backend RBAC);
    // viewers/engineers see groups read-only.
    readonly property bool canEdit: AuthController.role === "admin" || AuthController.role === "operator"

    signal openInLive(string groupId, string label)
    signal openCamera(var cam)

    Connections {
        target: root.cameraModel
        function onCountsChanged() { root.rev++; }
        function onGroupsChanged() { root.rev++; }
        // createGroup is async — select the new group once the backend confirms it.
        function onGroupCreated(groupId) {
            root.selectedGroup = groupId;
            root.selectedGroupName = "New group";
        }
    }

    readonly property var groupsData: (root.rev, root.cameraModel ? root.cameraModel.groupList() : [])
    readonly property var cams: (root.rev, root.cameraModel
        ? root.cameraModel.page(root.selectedGroup, "", "alpha", 1, 100000) : [])
    readonly property int allCount: (root.rev, root.cameraModel ? root.cameraModel.total : 0)

    // small ghost text button
    component GhostButton: Rectangle {
        property string label: ""
        property bool danger: false
        signal clicked()
        implicitWidth: gbT.implicitWidth + 24
        implicitHeight: 32
        color: gbMa.containsMouse ? Theme.panel : "transparent"
        border.width: 1
        border.color: gbMa.containsMouse ? (danger ? Theme.bad : Theme.accent) : Theme.line2
        Text {
            id: gbT; anchors.centerIn: parent; text: parent.label
            color: danger ? Theme.bad : Theme.ink2
            font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium
        }
        MouseArea { id: gbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ----------------------------------------------------- left: groups
        Rectangle {
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            color: Theme.bg
            Rectangle { anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: 16; Layout.leftMargin: 16; Layout.bottomMargin: 8
                    text: "Camera Groups"
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    font.weight: Font.DemiBold; font.letterSpacing: 1.6; font.capitalization: Font.AllUppercase
                }

                component GroupRow: Rectangle {
                    property string gid: ""
                    property string gname: ""
                    property int gcount: 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    color: root.selectedGroup === gid ? Theme.accentSoft : (gma.containsMouse ? Theme.panel2 : "transparent")
                    Rectangle { visible: root.selectedGroup === gid; anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 3; color: Theme.accent }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 14; spacing: 8
                        Icon { name: gid === "" ? "monitor" : "layers"; size: 14; color: root.selectedGroup === gid ? Theme.accent : Theme.ink3 }
                        Text { Layout.fillWidth: true; text: gname; color: root.selectedGroup === gid ? Theme.accent : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: root.selectedGroup === gid ? Font.DemiBold : Font.Normal; elide: Text.ElideRight }
                        Text { text: gcount; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                    }
                    MouseArea { id: gma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.selectedGroup = gid; root.selectedGroupName = gname; } }
                }

                GroupRow { gid: ""; gname: "All cameras"; gcount: root.allCount }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.line }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.groupsData
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        height: 40
                        color: root.selectedGroup === modelData.id ? Theme.accentSoft : (grpRowMa.containsMouse ? Theme.panel2 : "transparent")
                        Rectangle { visible: root.selectedGroup === modelData.id; anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 3; color: Theme.accent }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 14; spacing: 8
                            Icon { name: "layers"; size: 14; color: root.selectedGroup === modelData.id ? Theme.accent : Theme.ink3 }
                            Text { Layout.fillWidth: true; text: modelData.name; color: root.selectedGroup === modelData.id ? Theme.accent : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: root.selectedGroup === modelData.id ? Font.DemiBold : Font.Normal; elide: Text.ElideRight }
                            Text { text: modelData.total; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                        }
                        MouseArea { id: grpRowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.selectedGroup = modelData.id; root.selectedGroupName = modelData.name; } }
                    }
                }

                Rectangle {
                    visible: root.canEdit
                    Layout.fillWidth: true; Layout.preferredHeight: 44
                    color: ngMa.containsMouse ? Theme.panel : "transparent"
                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 16; spacing: 8
                        Text { text: "+"; color: Theme.accent; font.pixelSize: 16 }
                        Text { text: "New group"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13 }
                        Item { Layout.fillWidth: true }
                    }
                    MouseArea {
                        id: ngMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.cameraModel.createGroup("New group")  // selected via onGroupCreated
                    }
                }
            }
        }

        // ----------------------------------------------- right: group detail
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // header
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.subBarHeight
                color: Theme.bg
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 12

                    // editable group name (for real groups)
                    C.TextField {
                        id: groupNameField
                        visible: root.selectedGroup !== ""
                        readOnly: !root.canEdit
                        Layout.preferredWidth: Math.min(implicitWidth + 20, 320)
                        text: root.selectedGroupName
                        color: Theme.ink
                        font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold
                        background: Rectangle { color: groupNameField.activeFocus ? Theme.panel : "transparent"; border.width: groupNameField.activeFocus ? 1 : 0; border.color: Theme.accent }
                        onEditingFinished: {
                            if (text !== "" && text !== root.selectedGroupName) {
                                root.cameraModel.renameGroup(root.selectedGroup, text);
                                root.selectedGroupName = text;
                            }
                        }
                    }
                    Text {
                        visible: root.selectedGroup === ""
                        text: root.selectedGroupName
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold
                    }

                    Text { text: root.cams.length + " cameras"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                    Item { Layout.fillWidth: true }
                    GhostButton { label: "Open in Live Monitor"; onClicked: root.openInLive(root.selectedGroup, root.selectedGroupName) }
                    GhostButton {
                        visible: root.selectedGroup !== "" && root.canEdit
                        label: "Delete group"; danger: true
                        onClicked: { root.cameraModel.removeGroup(root.selectedGroup); root.selectedGroup = ""; root.selectedGroupName = "All cameras"; }
                    }
                }
            }

            // how-to hint
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                color: Theme.bg
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                Text {
                    anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
                    text: "Click a thumbnail to open it live  ·  click the name to rename  ·  use the group chip to move it into a group"
                    color: Theme.ink3
                    font.family: Theme.fontSans
                    font.pixelSize: 11
                }
            }

            // camera thumbnails — each tile is the camera's live frame (refreshing every
            // few seconds); click to open it live, rename inline, or reassign its group.
            GridView {
                id: camGrid
                visible: root.cams.length > 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: 8
                clip: true
                model: root.cams
                boundsBehavior: Flickable.StopAtBounds
                C.ScrollBar.vertical: C.ScrollBar { }
                readonly property int cols: Math.max(1, Math.floor(width / 250))
                cellWidth: width > 0 ? Math.floor(width / cols) : 250
                cellHeight: Math.round((cellWidth - 10) * 9 / 16) + 64   // thumbnail (16:9) + footer

                delegate: Item {
                    id: card
                    required property var modelData
                    width: camGrid.cellWidth; height: camGrid.cellHeight
                    property bool editing: false

                    Rectangle {
                        anchors.fill: parent; anchors.margins: 5
                        color: Theme.panel2; border.width: 1; border.color: Theme.line2
                        ColumnLayout {
                            anchors.fill: parent; spacing: 0

                            LiveThumb {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.round(width * 9 / 16)
                                cam: card.modelData
                                active: root.visible
                                onClicked: root.openCamera(card.modelData)
                            }

                            // footer — name (rename) + ip + group chip
                            ColumnLayout {
                                Layout.fillWidth: true; Layout.fillHeight: true
                                Layout.leftMargin: 8; Layout.rightMargin: 8; Layout.topMargin: 5; Layout.bottomMargin: 5
                                spacing: 3
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 6
                                    RecordingStatusBadge { state: card.modelData.recording }
                                    Item {
                                        Layout.fillWidth: true; Layout.preferredHeight: 18
                                        Text {
                                            visible: !card.editing; anchors.fill: parent; verticalAlignment: Text.AlignVCenter
                                            text: card.modelData.name; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium; elide: Text.ElideRight
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onClicked: { card.editing = true; nameF.forceActiveFocus(); nameF.selectAll(); } }
                                        }
                                        C.TextField {
                                            id: nameF; visible: card.editing; anchors.fill: parent
                                            text: card.modelData.name; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                                            background: Rectangle { color: Theme.bg; border.width: 1; border.color: Theme.accent }
                                            onEditingFinished: { if (text !== "") root.cameraModel.setCameraName(card.modelData.camId, text); card.editing = false; }
                                            Keys.onEscapePressed: card.editing = false
                                        }
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 6
                                    Text { text: card.modelData.ip; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                    Item { Layout.fillWidth: true }
                                    Rectangle {
                                        Layout.preferredHeight: 20; implicitWidth: gchRow.implicitWidth + 14
                                        color: gchMa.containsMouse ? Theme.panel3 : "transparent"; border.width: 1; border.color: Theme.line2
                                        RowLayout {
                                            id: gchRow; anchors.centerIn: parent; spacing: 4
                                            Text { text: card.modelData.groupName !== "" ? card.modelData.groupName : "Ungrouped"
                                                color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 10; elide: Text.ElideRight; Layout.maximumWidth: 96 }
                                            Icon { visible: root.canEdit; name: "chev"; size: 9; color: Theme.ink3 }
                                        }
                                        MouseArea { id: gchMa; anchors.fill: parent; hoverEnabled: true
                                            cursorShape: root.canEdit ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: if (root.canEdit) gPop.open() }
                                        C.Popup {
                                            id: gPop; y: parent.height + 2; x: parent.width - 200; width: 200; padding: 0
                                            background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                                            contentItem: Column {
                                                Repeater {
                                                    model: [{ id: "", name: "Ungrouped" }].concat(root.groupsData)
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: 200; height: 32; color: gOptMa.containsMouse ? Theme.panel2 : "transparent"
                                                        Text {
                                                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                                            text: modelData.name
                                                            color: card.modelData.groupId === modelData.id ? Theme.accent : Theme.ink
                                                            font.family: Theme.fontSans; font.pixelSize: 12
                                                        }
                                                        MouseArea { id: gOptMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                            onClicked: { root.cameraModel.setCameraGroup(card.modelData.camId, modelData.id); gPop.close(); } }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // empty group
            EmptyState {
                Layout.fillWidth: true; Layout.fillHeight: true
                visible: root.cams.length === 0
                icon: "layers"
                title: root.selectedGroup === "" ? "No cameras" : "No cameras in this group"
                subtitle: root.selectedGroup === "" ? "Import cameras to get started." : "Assign cameras to this group from another group's list."
            }
        }
    }
}
