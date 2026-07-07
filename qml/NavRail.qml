import QtQuick
import Watchtower

// Left navigation rail (72px). Logo + Live/Groups/Views/Events/Health. Active
// item: accent color + 3px accent left edge. Events carries an unacknowledged
// badge. Preferences/account live behind the avatar in the top bar (design §11).
Item {
    id: root

    property string section: "live"
    property int unackCount: 0
    property bool compact: false   // hidden chrome in full-screen mode

    signal sectionSelected(string sectionId)

    implicitWidth: Theme.railWidth

    Rectangle {
        anchors.fill: parent
        color: Theme.bg

        Rectangle {
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
            width: 1
            color: Theme.line
        }

        Column {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            topPadding: 12

            // logo — Cilex hexagon brand mark
            Item {
                width: parent.width
                height: 48
                Image {
                    anchors.centerIn: parent
                    width: 36; height: 36
                    source: "qrc:/images/cilex-logo.png"
                    fillMode: Image.PreserveAspectFit
                    sourceSize: Qt.size(72, 72)   // crisp downscale (2x for HiDPI)
                    smooth: true
                    mipmap: true
                    antialiasing: true
                }
            }
            Item { width: 1; height: 12 }

            Repeater {
                model: [
                    { id: "live",   icon: "monitor", label: qsTr("Live") },
                    { id: "groups", icon: "layers",  label: qsTr("Groups") },
                    { id: "views",  icon: "grid",    label: qsTr("Views") },
                    { id: "events", icon: "bell",    label: qsTr("Events") },
                    { id: "health", icon: "pulse",   label: qsTr("Health") }
                ]
                delegate: Item {
                    id: navItem
                    required property var modelData
                    width: parent.width
                    height: Theme.navItemHeight
                    readonly property bool active: root.section === modelData.id
                    readonly property bool hovered: navMa.containsMouse
                    readonly property color tint: active ? Theme.accent
                                                          : (hovered ? Theme.ink2 : Theme.ink3)

                    Rectangle {
                        anchors.fill: parent
                        color: (navItem.active || navItem.hovered) ? Theme.panel : "transparent"
                        Rectangle {
                            visible: navItem.active
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: Theme.edgeAccent
                            color: Theme.accent
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 5
                        Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: navItem.modelData.icon
                            size: 20
                            color: navItem.tint
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: navItem.modelData.label
                            color: navItem.tint
                            font.family: Theme.fontMono
                            font.pixelSize: 9
                            font.weight: Font.DemiBold
                            font.letterSpacing: 1.08
                            font.capitalization: Font.AllUppercase
                        }
                    }

                    Rectangle {
                        visible: navItem.modelData.id === "events" && root.unackCount > 0
                        anchors { top: parent.top; topMargin: 8; right: parent.right; rightMargin: 12 }
                        height: 16
                        width: Math.max(16, badgeText.implicitWidth + 8)
                        color: Theme.bad
                        Text {
                            id: badgeText
                            anchors.centerIn: parent
                            text: root.unackCount
                            color: "#ffffff"
                            font.family: Theme.fontMono
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                        }
                    }

                    MouseArea {
                        id: navMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.sectionSelected(navItem.modelData.id)
                    }
                }
            }
        }
    }
}
