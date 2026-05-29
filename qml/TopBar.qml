import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// Top bar (64px): operator card · global search · site status strip · clock ·
// alerts bell · avatar (design §10, §13).
Item {
    id: root

    property var cameraModel: null
    property var eventModel: null       // drives the alerts dropdown
    property string operatorName: ""    // signed-in operator (from AuthController)
    property string initials: ""        // monogram (from AuthController)
    property double now: Date.now()
    property bool hasAlerts: true
    property string statusFilter: ""   // "online" | "offline" | "notrec" | ""

    signal searchActivated()
    signal statusChipClicked(string which)
    signal alertsViewAllRequested()
    signal preferencesRequested()

    implicitHeight: Theme.topBarHeight

    // Live, format-aware clock (replaces the old static "17:42" placeholder).
    Timer { interval: 10000; running: true; repeat: true; onTriggered: root.now = Date.now() }
    function tzLabel() {
        var off = -(new Date(root.now).getTimezoneOffset());
        var sign = off >= 0 ? "+" : "−"; off = Math.abs(off);
        var h = Math.floor(off / 60), m = off % 60;
        return "UTC" + sign + h + (m ? (":" + (m < 10 ? "0" : "") + m) : "");
    }

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
                    RowLayout {
                        spacing: 8
                        Text {
                            text: "Watchtower"
                            color: Theme.ink
                            font.family: Theme.fontSans
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                            font.letterSpacing: -0.16
                        }
                        // Build identifier (short git SHA) — visible at a glance
                        // so a relaunch confirms which binary is running.
                        Text {
                            text: (typeof wtBuild !== "undefined") ? wtBuild : "dev"
                            color: Theme.ink3
                            font.family: Theme.fontMono
                            font.pixelSize: 10
                            font.letterSpacing: 0.8
                            Layout.alignment: Qt.AlignBottom
                            bottomPadding: 3
                        }
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
                    text: Settings.clock(root.now, false) + " · "
                    color: Theme.ink2
                    font.family: Theme.fontMono
                    font.pixelSize: 12
                }
                Text {
                    text: root.tzLabel()
                    color: Theme.ink
                    font.family: Theme.fontMono
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }
            }

            // alerts bell
            Item {
                id: bellBox
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
                MouseArea { id: bellMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: alertsPopup.open() }

                AlertsDropdown {
                    id: alertsPopup
                    eventModel: root.eventModel
                    y: bellBox.height + 6
                    x: bellBox.width - width    // right-aligned to the bell
                    onViewAllRequested: root.alertsViewAllRequested()
                }
            }

            // account / avatar — operator initials monogram; opens the user menu
            // (account, preferences, sign out). Design §10, §13.
            Item {
                id: avatarBox
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
                Rectangle {
                    anchors.fill: parent
                    color: Theme.accent
                }
                Text {
                    anchors.centerIn: parent
                    text: root.initials
                    color: Theme.bg
                    font.family: Theme.fontMono
                    font.pixelSize: 12
                    font.weight: Font.Bold
                }
                MouseArea { id: avMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: userMenu.open() }

                C.Popup {
                    id: userMenu
                    y: avatarBox.height + 6
                    x: avatarBox.width - width      // right-aligned to the avatar
                    width: 220
                    padding: 0
                    background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                    contentItem: Column {
                        // signed-in identity
                        Item {
                            width: parent.width; height: 52
                            Column {
                                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                                spacing: 2
                                Text {
                                    text: AuthController.username
                                    color: Theme.ink; font.family: Theme.fontSans
                                    font.pixelSize: 13; font.weight: Font.DemiBold
                                }
                                Text {
                                    text: AuthController.role
                                    color: Theme.ink3; font.family: Theme.fontMono
                                    font.pixelSize: 10; font.capitalization: Font.AllUppercase
                                    font.letterSpacing: 1.0
                                }
                            }
                        }
                        Rectangle { width: parent.width; height: 1; color: Theme.line }
                        Rectangle {
                            width: parent.width; height: 40
                            color: prefMa.containsMouse ? Theme.panel2 : "transparent"
                            Text {
                                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                                text: "Preferences"; color: Theme.ink
                                font.family: Theme.fontSans; font.pixelSize: 13
                            }
                            MouseArea {
                                id: prefMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { userMenu.close(); root.preferencesRequested() }
                            }
                        }
                        Rectangle {
                            width: parent.width; height: 40
                            color: outMa.containsMouse ? Theme.panel2 : "transparent"
                            Text {
                                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                                text: "Sign out"; color: Theme.bad
                                font.family: Theme.fontSans; font.pixelSize: 13
                            }
                            MouseArea {
                                id: outMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { userMenu.close(); AuthController.logout() }
                            }
                        }
                    }
                }
            }
        }
    }
}
