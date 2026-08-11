import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// Alerts dropdown opened from the top-bar bell. Lists recent operational events
// from EventModel (unacknowledged marked with a 6×6 bad square), mirroring the
// ops sidebar feed. Honest empty/loading state — the events pipeline may be
// empty (backend-blocked), so "No alerts" is expected. "View all" and any row
// jump to the Events screen.
C.Popup {
    id: root

    property var eventModel: null
    signal viewAllRequested()

    width: 360
    padding: 0
    modal: false

    background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }

    function eventIcon(type) { return EventStyle.icon(type); }
    function eventColor(type) { return EventStyle.color(type); }

    contentItem: ColumnLayout {
        spacing: 0

        // header
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 14
            Text {
                Layout.fillWidth: true
                text: qsTr("Alerts")
                color: Theme.ink
                font.family: Theme.fontSans
                font.pixelSize: Theme.fsTitle
                font.weight: Font.DemiBold
            }
            Text {
                text: qsTr("View all →")
                color: Theme.accent
                font.family: Theme.fontSans
                font.pixelSize: 11
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.close(); root.viewAllRequested() }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.line }

        // empty / loading
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 96
            visible: !root.eventModel || root.eventModel.total === 0
            Column {
                anchors.centerIn: parent
                spacing: 6
                Icon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: (root.eventModel && root.eventModel.loading) ? "pulse" : "check"
                    size: 24
                    color: Theme.ink3
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: (root.eventModel && root.eventModel.loading) ? qsTr("Loading alerts…") : qsTr("No alerts")
                    color: Theme.ink2
                    font.family: Theme.fontSans
                    font.pixelSize: Theme.fsSmall
                }
            }
        }

        // feed
        ListView {
            id: feed
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            Layout.bottomMargin: 8
            visible: root.eventModel && root.eventModel.total > 0
            implicitHeight: Math.min(contentHeight, 320)
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
                    height: 1; color: Theme.line; visible: row.index > 0
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.topMargin: 10
                    anchors.bottomMargin: 10
                    spacing: 10

                    Item {
                        Layout.preferredWidth: 22; Layout.preferredHeight: 22
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
                        Layout.preferredWidth: 6; Layout.preferredHeight: 6
                        Layout.alignment: Qt.AlignTop; Layout.topMargin: 2
                        color: Theme.bad
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.close(); root.viewAllRequested() }
                }
            }
        }
    }
}
