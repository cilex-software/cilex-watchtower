import QtQuick
import QtQuick.Layouts
import Watchtower

// VIEW 02 — VERIFY (port of view-review.jsx / ReviewView). One screen, two
// layouts toggled top-left: Verification Wall (sized S/M/L) and Smart Sessions
// (sorted Priority/Recent). The right-hand control is contextual — S/M/L only on
// the Wall, Priority/Recent only on Sessions — and each remembers its value.
Item {
    id: rev
    signal openInTriage(string id)

    property string layoutMode: "wall"           // wall | sessions
    property string size: "m"                     // s | m | l
    property string sortBy: "priority"            // priority | recent

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- toolbar ----
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 57; color: Theme.bg
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 14

                // layout toggle (segmented)
                Rectangle {
                    Layout.preferredHeight: 40; Layout.preferredWidth: tgl.implicitWidth
                    color: Theme.panel; border.width: 1; border.color: Theme.line2
                    Row {
                        id: tgl; height: parent.height
                        Repeater {
                            model: [ { k: "wall", l: "Verification Wall", ic: "person" }, { k: "sessions", l: "Smart Sessions", ic: "motion" } ]
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                readonly property bool _active: rev.layoutMode === modelData.k
                                height: tgl.height; width: tRow.implicitWidth + 36
                                color: _active ? Theme.accent : (tMa.containsMouse ? Theme.panel2 : Theme.panel)
                                Rectangle { visible: index === 0; anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Row {
                                    id: tRow; anchors.centerIn: parent; spacing: 8
                                    EvIcon { anchors.verticalCenter: parent.verticalCenter; name: modelData.ic; size: 14
                                        color: parent.parent._active ? Theme.bg : (tMa.containsMouse ? Theme.ink : Theme.ink2) }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l
                                        color: parent.parent._active ? Theme.bg : (tMa.containsMouse ? Theme.ink : Theme.ink2)
                                        font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                                }
                                MouseArea { id: tMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: rev.layoutMode = modelData.k }
                            }
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                // contextual control — Size (Wall) or Sort (Sessions)
                Text { text: rev.layoutMode === "wall" ? "Size" : "Sort"; color: Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: 11 }

                // S / M / L (Wall only)
                Rectangle {
                    visible: rev.layoutMode === "wall"
                    Layout.preferredHeight: 30; Layout.preferredWidth: 90
                    color: "transparent"; border.width: 1; border.color: Theme.line2
                    Row {
                        anchors.fill: parent
                        Repeater {
                            model: ["s", "m", "l"]
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                readonly property bool _active: rev.size === modelData
                                width: 30; height: 30
                                color: _active ? Theme.accent : (szMa.containsMouse ? Theme.panel2 : "transparent")
                                Rectangle { visible: index < 2; anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Text { anchors.centerIn: parent; text: modelData.toUpperCase()
                                    color: parent._active ? Theme.bg : Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                                MouseArea { id: szMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rev.size = modelData }
                            }
                        }
                    }
                }

                // Priority / Recent (Sessions only)
                Rectangle {
                    visible: rev.layoutMode === "sessions"
                    Layout.preferredHeight: 32; Layout.preferredWidth: srtRow.implicitWidth
                    color: Theme.panel; border.width: 1; border.color: Theme.line2
                    Row {
                        id: srtRow; height: parent.height
                        Repeater {
                            model: [ { k: "priority", l: "Priority" }, { k: "recent", l: "Recent" } ]
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                readonly property bool _active: rev.sortBy === modelData.k
                                height: parent.height; width: srtT.implicitWidth + 28
                                color: _active ? Theme.accent : (srtMa.containsMouse ? Theme.panel2 : Theme.panel)
                                Rectangle { visible: index === 0; anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Text { id: srtT; anchors.centerIn: parent; text: modelData.l
                                    color: parent._active ? Theme.bg : Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.DemiBold }
                                MouseArea { id: srtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rev.sortBy = modelData.k }
                            }
                        }
                    }
                }
            }
        }

        // ---- body ----
        Loader {
            id: bodyLoader
            Layout.fillWidth: true; Layout.fillHeight: true
            sourceComponent: rev.layoutMode === "wall" ? wallC : sessionsC
        }
    }

    Component { id: wallC; EvWall { size: rev.size; onOpenInTriage: (id) => rev.openInTriage(id) } }
    Component { id: sessionsC; EvSessions { sortBy: rev.sortBy } }
}
