import QtQuick
import QtQuick.Layouts
import Watchtower

// Save-current-view modal (O03 / design §4). Centered modal that names the
// current Live Monitor state and visibility, restating what's captured. Opened
// from the Live Monitor's "Save current view" and the Saved Views screen.
// Emits saved(name, shared); the parent (Main) reads the live state and calls
// SavedViewModel.saveCurrent(...).
Item {
    id: root
    anchors.fill: parent
    visible: false

    // captured state (set by the parent before open(), used in the summary)
    property string layout: "16"
    property string statusFilter: ""
    property string groupLabel: qsTr("All cameras")

    property string viewName: ""
    property bool shared: false

    signal saved(string name, bool shared)
    signal closed()

    function open() {
        viewName = ""; shared = false;
        visible = true;
        nameInput.forceActiveFocus();
    }
    function close() { visible = false; closed(); }

    function filterLabel(f) {
        switch (f) {
        case "": return qsTr("None");
        case "online": return qsTr("Online");
        case "offline": return qsTr("Offline");
        case "degraded": return qsTr("Degraded");
        case "recording": return qsTr("Recording");
        case "notrec": return qsTr("Not recording");
        case "gap": return qsTr("Recent gaps");
        case "favorites": return qsTr("Favorites");
        case "issues": return qsTr("Contains issues");
        case "recent": return qsTr("Recent events");
        default: return f;
        }
    }
    readonly property bool canSave: viewName.trim() !== ""

    // scrim
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.65)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    // modal
    Rectangle {
        anchors.centerIn: parent
        width: 500
        implicitHeight: mHead.height + mBody.implicitHeight + mFoot.height
        color: Theme.panel
        border.width: 1; border.color: Theme.accent
        MouseArea { anchors.fill: parent }   // eat clicks inside

        Rectangle {
            id: mHead
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: 56; color: Theme.panel
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            Text { anchors.left: parent.left; anchors.leftMargin: 22; anchors.verticalCenter: parent.verticalCenter; text: qsTr("Save current view"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
            IconButton { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; name: "x"; iconColor: Theme.ink2; hoverIcon: Theme.ink; hoverBg: Theme.panel2; hoverBorder: Theme.line2; tip: qsTr("Cancel"); onClicked: root.close() }
        }

        ColumnLayout {
            id: mBody
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: mHead.bottom
            anchors.leftMargin: 22; anchors.rightMargin: 22; anchors.topMargin: 18
            spacing: 14

            // name
            ColumnLayout {
                Layout.fillWidth: true; spacing: 6
                RowLayout {
                    spacing: 4
                    Text { text: qsTr("View name"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.capitalization: Font.AllUppercase; font.letterSpacing: 1.2; font.weight: Font.DemiBold }
                    Text { text: "*"; color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 10 }
                }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 36
                    color: Theme.bg; border.width: 1; border.color: nameInput.activeFocus ? Theme.accent : Theme.line2
                    TextInput {
                        id: nameInput
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13
                        selectByMouse: true
                        text: root.viewName
                        onTextChanged: root.viewName = text
                        Keys.onReturnPressed: if (root.canSave) { root.saved(root.viewName.trim(), root.shared); root.close() }
                    }
                    Text { visible: nameInput.text === ""; anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter; text: qsTr("e.g. First Floor — afternoon shift"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13 }
                }
            }

            // visibility
            ColumnLayout {
                Layout.fillWidth: true; spacing: 6
                Text { text: qsTr("Visibility"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.capitalization: Font.AllUppercase; font.letterSpacing: 1.2; font.weight: Font.DemiBold }
                Rectangle {
                    implicitHeight: 34; implicitWidth: visRow.implicitWidth
                    color: Theme.bg; border.width: 1; border.color: Theme.line2
                    Row {
                        id: visRow
                        component Seg: Rectangle {
                            property string label: ""
                            property bool on: false
                            signal clicked()
                            width: 140; height: 32; y: 1; x: 1
                            color: on ? Theme.accent : "transparent"
                            Text { anchors.centerIn: parent; text: parent.label; color: parent.on ? Theme.bg : Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
                        }
                        Seg { label: qsTr("Mine"); on: !root.shared; onClicked: root.shared = false }
                        Seg { label: qsTr("Shared (team)"); on: root.shared; onClicked: root.shared = true }
                    }
                }
            }

            // captured-state summary
            Rectangle {
                Layout.fillWidth: true
                color: Theme.bg
                implicitHeight: sumCol.implicitHeight + 20
                Column {
                    id: sumCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10
                    spacing: 5
                    component Line: Text {
                        textFormat: Text.StyledText
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12
                    }
                    Line { text: qsTr("<b>Layout:</b> ") + LayoutSpec.label(root.layout) + " tiles" }
                    Line { text: qsTr("<b>Group context:</b> ") + root.groupLabel }
                    Line { text: qsTr("<b>Active filter:</b> ") + root.filterLabel(root.statusFilter) }
                }
            }
        }

        Rectangle {
            id: mFoot
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: mBody.bottom
            anchors.topMargin: 18
            height: 60; color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }
            Row {
                anchors.right: parent.right; anchors.rightMargin: 22; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                Rectangle {
                    implicitWidth: cancT.implicitWidth + 28; implicitHeight: 34
                    color: cancMa.containsMouse ? Theme.panel2 : "transparent"
                    Text { id: cancT; anchors.centerIn: parent; text: qsTr("Cancel"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                    MouseArea { id: cancMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.close() }
                }
                Rectangle {
                    implicitWidth: saveT.implicitWidth + 28; implicitHeight: 34
                    opacity: root.canSave ? 1 : 0.55
                    color: !root.canSave ? Theme.line2 : (saveMa.containsMouse ? "#f0b04e" : Theme.accent)
                    Text { id: saveT; anchors.centerIn: parent; text: qsTr("Save view"); color: Theme.bg; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                    MouseArea { id: saveMa; anchors.fill: parent; enabled: root.canSave; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.saved(root.viewName.trim(), root.shared); root.close() } }
                }
            }
        }
    }

    Keys.onEscapePressed: (e) => { root.close(); e.accepted = true }
    focus: visible
}
