import QtQuick
import QtQuick.Layouts
import Watchtower

// Top bar (64px): operator card · global search · site status strip · clock ·
// alerts bell · avatar (design §10, §13).
Item {
    id: root

    property var cameraModel: null
    property string operatorName: "m.osei"
    property string initials: "MO"
    property string clockTime: "17:42"
    property string tz: "UTC+1"
    property bool hasAlerts: true
    property string statusFilter: ""   // "online" | "offline" | "notrec" | ""

    signal searchActivated()
    signal statusChipClicked(string which)
    signal bellClicked()
    signal avatarClicked()

    implicitHeight: Theme.topBarHeight

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: Theme.line
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 16

            // operator card
            RowLayout {
                spacing: 0
                ColumnLayout {
                    spacing: 2
                    Text {
                        text: "Cilex Vision"
                        color: Theme.ink3
                        font.family: Theme.fontMono
                        font.pixelSize: 10
                        font.letterSpacing: 1.6
                        font.capitalization: Font.AllUppercase
                    }
                    Text {
                        text: "Watchtower"
                        color: Theme.ink
                        font.family: Theme.fontSans
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                        font.letterSpacing: -0.16
                    }
                }
                Rectangle { Layout.leftMargin: 18; width: 1; Layout.preferredHeight: 36; color: Theme.line }
            }

            // global search
            Rectangle {
                Layout.fillWidth: true
                Layout.maximumWidth: 420
                Layout.preferredHeight: 38
                color: Theme.panel
                border.width: 1
                border.color: searchMa.containsMouse ? Theme.ink3 : Theme.line2

                Icon {
                    id: searchIcon
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    name: "search"; size: 14; color: Theme.ink3
                }
                Text {
                    anchors { left: searchIcon.right; leftMargin: 12; right: kbdBox.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    text: "Search cameras, groups, views, clips, events…"
                    color: Theme.ink3
                    font.family: Theme.fontSans
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
                Rectangle {
                    id: kbdBox
                    anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    width: kbd.implicitWidth + 12; height: 20
                    color: "transparent"
                    border.width: 1; border.color: Theme.line2
                    Text {
                        id: kbd
                        anchors.centerIn: parent
                        text: "CTRL K"
                        color: Theme.ink3
                        font.family: Theme.fontMono
                        font.pixelSize: 10
                    }
                }
                MouseArea {
                    id: searchMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.IBeamCursor
                    onClicked: root.searchActivated()
                }
            }

            // site status strip
            Rectangle {
                Layout.preferredHeight: 38
                implicitWidth: strip.implicitWidth
                color: Theme.panel
                border.width: 1
                border.color: Theme.line2
                Row {
                    id: strip
                    height: 38
                    StatusSummaryChip {
                        label: "Online"; dotColor: Theme.good
                        count: root.cameraModel ? root.cameraModel.onlineCount : 0
                        active: root.statusFilter === "online"
                        onClicked: root.statusChipClicked("online")
                    }
                    Rectangle { width: 1; height: 38; color: Theme.line }
                    StatusSummaryChip {
                        label: "Offline"; dotColor: Theme.bad
                        count: root.cameraModel ? root.cameraModel.offlineCount : 0
                        active: root.statusFilter === "offline"
                        onClicked: root.statusChipClicked("offline")
                    }
                    Rectangle { width: 1; height: 38; color: Theme.line }
                    StatusSummaryChip {
                        label: "Not Rec"; dotColor: Theme.accent
                        count: root.cameraModel ? root.cameraModel.notRecordingCount : 0
                        active: root.statusFilter === "notrec"
                        onClicked: root.statusChipClicked("notrec")
                    }
                }
            }

            Item { Layout.fillWidth: true }   // spacer pushes the right cluster out

            // clock
            RowLayout {
                spacing: 0
                Rectangle { width: 1; Layout.preferredHeight: 24; color: Theme.line; Layout.rightMargin: 16 }
                Text {
                    text: root.clockTime + " · "
                    color: Theme.ink2
                    font.family: Theme.fontMono
                    font.pixelSize: 12
                }
                Text {
                    text: root.tz
                    color: Theme.ink
                    font.family: Theme.fontMono
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }
            }

            // alerts bell
            Item {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                Rectangle {
                    anchors.fill: parent
                    color: bellMa.containsMouse ? Theme.panel : "transparent"
                    border.width: bellMa.containsMouse ? 1 : 0
                    border.color: Theme.line2
                }
                Icon { anchors.centerIn: parent; name: "bell"; size: 16; color: bellMa.containsMouse ? Theme.ink : Theme.ink2 }
                Rectangle {
                    visible: root.hasAlerts
                    anchors { top: parent.top; topMargin: 6; right: parent.right; rightMargin: 6 }
                    width: 8; height: 8
                    color: Theme.bad
                    border.width: 2; border.color: Theme.bg
                }
                MouseArea { id: bellMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.bellClicked() }
            }

            // settings / account access (Preferences live here, design §11)
            Item {
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
                Rectangle {
                    anchors.fill: parent
                    color: avMa.containsMouse ? Theme.panel : "transparent"
                    border.width: avMa.containsMouse ? 1 : 0
                    border.color: Theme.line2
                }
                Icon { anchors.centerIn: parent; name: "gear"; size: 18; color: avMa.containsMouse ? Theme.ink : Theme.ink2 }
                MouseArea { id: avMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.avatarClicked() }
            }
        }
    }
}
