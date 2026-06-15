import QtQuick
import QtQuick.Layouts
import Watchtower

// Right-docked operations sidebar (320px), Live Monitor only (design §10). Site
// status 2×2 + a scrolling Live Events feed. Hidden in full-screen mode.
Item {
    id: root

    property var cameraModel: null
    property var eventModel: null

    signal eventActivated(int row)
    signal viewAllEvents()

    implicitWidth: Theme.opsSidebarWidth

    function eventIcon(type) { return EventStyle.icon(type); }
    function eventColor(type) { return EventStyle.color(type); }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        Rectangle {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 1
            color: Theme.line
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 1   // clear the left hairline
            spacing: 0

            // ---- Site Status header ----
            Text {
                Layout.fillWidth: true
                Layout.topMargin: 14
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 8
                text: "Site Status"
                color: Theme.ink3
                font.family: Theme.fontMono
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.6
                font.capitalization: Font.AllUppercase
            }

            // ---- 2×2 stats ----
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: stats.implicitHeight + 2
                color: Theme.line
                GridLayout {
                    id: stats
                    anchors.fill: parent
                    anchors.margins: 1
                    columns: 2
                    rowSpacing: 1
                    columnSpacing: 1

                    component StatCell: Rectangle {
                        id: cell
                        property string lbl: ""
                        property int value: 0
                        property color valueColor: Theme.ink
                        Layout.fillWidth: true
                        Layout.preferredHeight: 64
                        color: Theme.bg
                        Column {
                            anchors { left: parent.left; top: parent.top; leftMargin: 14; topMargin: 12 }
                            spacing: 4
                            Text {
                                text: cell.lbl
                                color: Theme.ink3
                                font.family: Theme.fontMono
                                font.pixelSize: 10
                                font.letterSpacing: 1.0
                                font.capitalization: Font.AllUppercase
                            }
                            Text {
                                text: cell.value
                                color: cell.valueColor
                                font.family: Theme.fontSans
                                font.pixelSize: 22
                                font.weight: Font.Bold
                                font.letterSpacing: -0.44
                            }
                        }
                    }

                    StatCell { lbl: "Online";   value: root.cameraModel ? root.cameraModel.onlineCount : 0;       valueColor: Theme.good }
                    StatCell { lbl: "Offline";  value: root.cameraModel ? root.cameraModel.offlineCount : 0;      valueColor: Theme.bad }
                    StatCell { lbl: "Degraded"; value: root.cameraModel ? root.cameraModel.degradedCount : 0;     valueColor: Theme.warn }
                    StatCell { lbl: "Not rec";  value: root.cameraModel ? root.cameraModel.notRecordingCount : 0; valueColor: Theme.warn }
                }
            }

            // ---- Live Events header ----
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 16
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 8
                Text {
                    Layout.fillWidth: true
                    text: "Live Events"
                    color: Theme.ink3
                    font.family: Theme.fontMono
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.6
                    font.capitalization: Font.AllUppercase
                }
                Text {
                    text: "View all →"
                    color: Theme.accent
                    font.family: Theme.fontSans
                    font.pixelSize: 11
                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.viewAllEvents() }
                }
            }

            // ---- event feed ----
            ListView {
                id: feed
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 12
                clip: true
                model: root.eventModel

                delegate: Item {
                    id: row
                    required property int index
                    required property string type
                    required property string desc
                    required property string camName
                    required property string time
                    required property bool ack

                    width: ListView.view.width
                    height: 56

                    Rectangle {
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1
                        color: Theme.line
                        visible: row.index > 0
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.topMargin: 10
                        anchors.bottomMargin: 10
                        spacing: 10

                        Item {
                            Layout.preferredWidth: 22
                            Layout.preferredHeight: 22
                            Layout.alignment: Qt.AlignTop
                            Icon {
                                anchors.centerIn: parent
                                name: root.eventIcon(row.type)
                                size: 14
                                color: root.eventColor(row.type)
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3
                            Text {
                                Layout.fillWidth: true
                                text: row.desc
                                color: row.ack ? Theme.ink2 : Theme.ink
                                font.family: Theme.fontSans
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                            Text {
                                text: row.camName + " · " + row.time
                                color: Theme.ink3
                                font.family: Theme.fontMono
                                font.pixelSize: 10
                            }
                        }
                        Rectangle {
                            visible: !row.ack
                            Layout.preferredWidth: 6
                            Layout.preferredHeight: 6
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 2
                            color: Theme.bad
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.eventActivated(row.index)
                    }
                }
            }
        }
    }
}
