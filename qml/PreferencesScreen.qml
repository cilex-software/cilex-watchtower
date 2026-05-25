import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import Watchtower

// Preferences (S10): personal UI preferences only (no system admin). Phase 2:
// default stream quality + snapshot folder; more (theme, time format, alerts)
// land later. Left-aligned stack of panel sections (design §28).
Item {
    id: root
    signal closed()

    FolderDialog {
        id: dirDialog
        title: "Choose the snapshot folder"
        onAccepted: Artifacts.snapshotDir = dirDialog.selectedFolder
    }

    // reusable section + row
    component PrefSection: Rectangle {
        default property alias content: inner.data
        property string title: ""
        Layout.fillWidth: true
        Layout.preferredHeight: inner.implicitHeight + header.implicitHeight + 24
        color: Theme.panel
        border.width: 1
        border.color: Theme.line
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 0
            spacing: 0
            Text {
                id: header
                Layout.fillWidth: true
                Layout.margins: 14
                Layout.bottomMargin: 6
                text: parent.parent.title
                color: Theme.ink3
                font.family: Theme.fontMono; font.pixelSize: 10
                font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
            }
            ColumnLayout { id: inner; Layout.fillWidth: true; spacing: 0 }
        }
    }

    component PrefRow: RowLayout {
        property string label: ""
        property string desc: ""
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
        Layout.topMargin: 12
        Layout.bottomMargin: 12
        spacing: 16
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Text { text: parent.parent.label; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.Medium }
            Text { visible: parent.parent.desc !== ""; text: parent.parent.desc; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: page.implicitHeight + 48
        clip: true

        ColumnLayout {
            id: page
            x: 24
            y: 24
            width: Math.min(root.width - 48, 680)
            spacing: 16

            RowLayout {
                Layout.fillWidth: true
                Text { text: "Preferences"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 24; font.weight: Font.DemiBold; Layout.fillWidth: true }
                Rectangle {
                    implicitWidth: backT.implicitWidth + 24; implicitHeight: 32
                    color: backMa.containsMouse ? Theme.panel : "transparent"
                    border.width: 1; border.color: backMa.containsMouse ? Theme.accent : Theme.line2
                    Text { id: backT; anchors.centerIn: parent; text: "Back to monitoring"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                    MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closed() }
                }
            }

            PrefSection {
                title: "Video"
                PrefRow {
                    label: "Default stream quality"
                    desc: "SD uses the camera substream (lighter, more responsive). HD uses the main stream. You can also toggle SD/HD per camera from the live tile."
                    // SD / HD segmented toggle
                    Rectangle {
                        Layout.preferredHeight: 32
                        implicitWidth: 120
                        color: Theme.bg
                        border.width: 1; border.color: Theme.line2
                        Row {
                            anchors.fill: parent
                            Repeater {
                                model: [{ k: "SD", hd: false }, { k: "HD", hd: true }]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: 60; height: 30
                                    y: 1; x: modelData.hd ? 60 : 0
                                    color: Settings.defaultStreamHd === modelData.hd ? Theme.accent : "transparent"
                                    Text { anchors.centerIn: parent; text: modelData.k; color: Settings.defaultStreamHd === modelData.hd ? Theme.bg : Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Settings.defaultStreamHd = modelData.hd }
                                }
                            }
                        }
                    }
                }
            }

            PrefSection {
                title: "Snapshots"
                PrefRow {
                    label: "Snapshot folder"
                    desc: Artifacts.snapshotDir
                    Rectangle {
                        Layout.preferredHeight: 32
                        implicitWidth: chT.implicitWidth + 24
                        color: chMa.containsMouse ? Theme.panel2 : Theme.bg
                        border.width: 1; border.color: chMa.containsMouse ? Theme.accent : Theme.line2
                        Text { id: chT; anchors.centerIn: parent; text: "Change…"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12 }
                        MouseArea { id: chMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dirDialog.open() }
                    }
                }
            }
        }
    }
}
