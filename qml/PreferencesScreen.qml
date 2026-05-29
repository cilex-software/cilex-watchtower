import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Controls.Basic as QC
import Watchtower

// Preferences (S10 / design §9): personal UI preferences only (no system admin).
// Sections: Video, Snapshots, Workspace (default landing), Time & language (time
// format), Alerts (sound + desktop notifications). Light/Dark theme switching is
// deferred (Theme is a static singleton — a larger refactor). Left-aligned stack.
Item {
    id: root
    signal closed()

    property var savedViewModel: null
    property var cameraModel: null

    // Default-landing options: Live Monitor + each saved view + each group.
    function landingOptions() {
        var opts = [{ value: "live", label: "Live Monitor" }];
        if (root.savedViewModel) {
            var vs = root.savedViewModel.list();
            for (var i = 0; i < vs.length; i++) opts.push({ value: "view:" + vs[i].viewId, label: "View · " + vs[i].name });
        }
        if (root.cameraModel) {
            var gs = root.cameraModel.groupList();
            for (var j = 0; j < gs.length; j++) opts.push({ value: "group:" + gs[j].id, label: "Group · " + gs[j].name });
        }
        return opts;
    }

    FolderDialog {
        id: dirDialog
        title: "Choose the snapshot folder"
        onAccepted: Artifacts.snapshotDir = dirDialog.selectedFolder
    }

    FolderDialog {
        id: exportDirDialog
        title: "Choose the clip export folder"
        onAccepted: Artifacts.exportDir = exportDirDialog.selectedFolder
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

    // segmented option control (used for Time format + Alerts toggles)
    component Segmented: Rectangle {
        id: seg
        property var opts: []        // [{ k: label, v: value }]
        property var value: undefined
        property int segW: 80
        signal picked(var v)
        Layout.preferredHeight: 32
        implicitWidth: seg.opts.length * seg.segW + 2
        implicitHeight: 32
        color: Theme.bg
        border.width: 1; border.color: Theme.line2
        Row {
            Repeater {
                model: seg.opts
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: seg.segW; height: 30; y: 1; x: 1 + index * seg.segW
                    color: seg.value === modelData.v ? Theme.accent : "transparent"
                    Text { anchors.centerIn: parent; text: modelData.k; color: seg.value === modelData.v ? Theme.bg : Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: seg.picked(modelData.v) }
                }
            }
        }
    }

    // dropdown (used for Default landing)
    component PrefDropdown: Rectangle {
        id: dd
        property var options: []
        property string currentValue: ""
        signal pickedValue(string value)
        function currentLabel() {
            for (var i = 0; i < dd.options.length; i++) if (dd.options[i].value === dd.currentValue) return dd.options[i].label;
            return dd.options.length ? dd.options[0].label : "";
        }
        Layout.preferredHeight: 34
        implicitWidth: 260
        color: Theme.bg
        border.width: 1; border.color: ddPop.visible ? Theme.accent : (ddMa.containsMouse ? Theme.line2 : Theme.line2)
        Text { anchors.left: parent.left; anchors.leftMargin: 12; anchors.right: ddCh.left; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; text: dd.currentLabel(); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13 }
        Icon { id: ddCh; anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; name: "chev"; size: 12; color: Theme.ink3 }
        MouseArea { id: ddMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ddPop.visible ? ddPop.close() : ddPop.open() }
        QC.Popup {
            id: ddPop
            y: parent.height + 2; x: 0; width: parent.width
            padding: 1
            background: Rectangle { color: Theme.panel2; border.width: 1; border.color: Theme.line2 }
            contentItem: Column {
                Repeater {
                    model: dd.options
                    delegate: Rectangle {
                        required property var modelData
                        width: ddPop.width - 2; height: 30
                        color: oMa.containsMouse ? Theme.accentSoft : (modelData.value === dd.currentValue ? Theme.bg : "transparent")
                        Text { anchors.left: parent.left; anchors.leftMargin: 11; anchors.right: parent.right; anchors.rightMargin: 11; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; text: modelData.label; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13 }
                        MouseArea { id: oMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { dd.pickedValue(modelData.value); ddPop.close() } }
                    }
                }
            }
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
                title: "Workspace"
                PrefRow {
                    label: "Default landing screen"
                    desc: "Where Watchtower opens on launch."
                    PrefDropdown {
                        options: root.landingOptions()
                        currentValue: Settings.defaultLanding
                        onPickedValue: (val) => Settings.defaultLanding = val
                    }
                }
                PrefRow {
                    label: "Theme"
                    desc: "Light and System themes are planned for a later phase."
                    Text { text: "Dark"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                }
            }

            PrefSection {
                title: "Video"
                PrefRow {
                    label: "Default stream quality (focused view)"
                    desc: "Default quality when you open a single camera. SD uses the substream (lighter, near real-time); HD uses the main stream. The live monitor wall is always SD for performance; you can still promote any tile to HD from its live tile."
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
                title: "Time & language"
                PrefRow {
                    label: "Time format"
                    desc: "How clocks are shown across the app."
                    Segmented {
                        opts: [{ k: "24-hour", v: true }, { k: "12-hour", v: false }]
                        value: Settings.time24h
                        segW: 80
                        onPicked: (v) => Settings.time24h = v
                    }
                }
            }

            PrefSection {
                title: "Alerts"
                PrefRow {
                    label: "Alert sound"
                    desc: "Play a sound when a camera raises an alert."
                    Segmented {
                        opts: [{ k: "Off", v: false }, { k: "On", v: true }]
                        value: Settings.alertSound
                        segW: 56
                        onPicked: (v) => Settings.alertSound = v
                    }
                }
                PrefRow {
                    label: "Desktop notifications"
                    desc: "Show an OS notification for alerts even when Watchtower isn't focused."
                    Segmented {
                        opts: [{ k: "Off", v: false }, { k: "On", v: true }]
                        value: Settings.desktopNotifications
                        segW: 56
                        onPicked: (v) => Settings.desktopNotifications = v
                    }
                }
                Text {
                    Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 12
                    text: "Alerts are raised from camera events (motion, offline, recording gaps). These preferences take effect when alerts arrive."
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11; wrapMode: Text.WordWrap; lineHeight: 1.3
                }
            }

            PrefSection {
                title: "Snapshots & clips"
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
                PrefRow {
                    label: "Clip export folder"
                    desc: Artifacts.exportDir
                    Rectangle {
                        Layout.preferredHeight: 32
                        implicitWidth: exT.implicitWidth + 24
                        color: exMa.containsMouse ? Theme.panel2 : Theme.bg
                        border.width: 1; border.color: exMa.containsMouse ? Theme.accent : Theme.line2
                        Text { id: exT; anchors.centerIn: parent; text: "Change…"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12 }
                        MouseArea { id: exMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: exportDirDialog.open() }
                    }
                }
            }
        }
    }
}
