import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower
import "WatchNames.js" as WN

// The Watch — TopBar check-in chip + popover (design: docs/plans/guard-
// achievements.md §5; contract thread 2026-07-28-guard-shift-achievements.*).
// Hidden entirely unless the backend answers AND this box is a registered
// station — honest pending, never a dead control. States:
//   nobody on watch  -> ghost "Check in" button -> roster picker
//   on watch         -> "ON WATCH · <name>" chip -> rank/families popover + checkout
// The roster is admin-owned; an empty roster renders an honest empty state,
// never invented names (product rule).
Item {
    id: root
    visible: Watch.available && Watch.stationId !== ""
    implicitHeight: 28
    implicitWidth: chip.width

    readonly property var ws: Watch.watchstate

    function sinceLabel() {
        if (Watch.startedAt === "") return "";
        var ms = Date.now() - new Date(Watch.startedAt).getTime();
        var h = Math.floor(ms / 3600000), m = Math.floor((ms % 3600000) / 60000);
        return h > 0 ? (h + qsTr("h") + " " + m + qsTr("m")) : (m + qsTr("m"));
    }
    property double _tick: 0
    Timer { interval: 60000; running: root.visible && Watch.onWatch; repeat: true
            onTriggered: root._tick = Date.now() }

    Rectangle {
        id: chip
        width: chipRow.implicitWidth + 20
        height: 28
        anchors.verticalCenter: parent.verticalCenter
        radius: 3
        color: chipMa.containsMouse ? Theme.panel2 : "transparent"
        border.width: 1
        border.color: Watch.onWatch ? Theme.accent : (chipMa.containsMouse ? Theme.accent : Theme.line2)

        RowLayout {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6
            Icon { name: "eye"; size: 11
                   color: Watch.onWatch ? Theme.accent : Theme.ink3 }
            Text {
                text: {
                    root._tick;   // minute refresh dep
                    return Watch.onWatch
                        ? qsTr("ON WATCH · %1 · %2").arg(Watch.guardName).arg(root.sinceLabel())
                        : qsTr("Check in");
                }
                color: Watch.onWatch ? Theme.ink : Theme.ink2
                font.family: Theme.fontMono
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 0.5
            }
        }
        MouseArea {
            id: chipMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (pop.visible) { pop.close(); return; }
                if (!Watch.onWatch) Watch.fetchGuards();   // fresh roster for the picker
                else Watch.fetchWatchstate();
                pop.open();
            }
        }
    }

    C.Popup {
        id: pop
        y: chip.height + 8
        x: chip.width - width          // right-align under the chip
        width: 300
        padding: 0
        background: Rectangle { color: Theme.panel; border.width: 1; border.color: Theme.line2 }

        contentItem: ColumnLayout {
            spacing: 0

            // ------------------------------------------------ picker (nobody on watch)
            ColumnLayout {
                visible: !Watch.onWatch
                Layout.fillWidth: true
                Layout.margins: 12
                spacing: 8
                Text {
                    text: qsTr("Who takes the watch?")
                    color: Theme.ink; font.family: Theme.fontSans
                    font.pixelSize: 13; font.weight: Font.DemiBold
                }
                Text {
                    visible: Watch.roster.length === 0
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: qsTr("The guard roster is empty. Names are added by an administrator — nothing is invented here.")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                }
                Repeater {
                    model: Watch.roster
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 32
                        radius: 3
                        color: gMa.containsMouse ? Theme.panel2 : "transparent"
                        border.width: 1
                        border.color: gMa.containsMouse ? Theme.accent : Theme.line2
                        Text {
                            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                            text: modelData.display_name
                            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                        }
                        MouseArea {
                            id: gMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { Watch.checkin(modelData.guard_id); pop.close(); }
                        }
                    }
                }
            }

            // ------------------------------------------------ watchstate (on watch)
            ColumnLayout {
                visible: Watch.onWatch
                Layout.fillWidth: true
                Layout.margins: 12
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    ColumnLayout {
                        spacing: 2
                        Layout.fillWidth: true
                        Text {
                            text: Watch.guardName
                            color: Theme.ink; font.family: Theme.fontSans
                            font.pixelSize: 14; font.weight: Font.DemiBold
                        }
                        Text {
                            readonly property var r: root.ws.rank
                            text: r ? (WN.rankName(r.key) + " · " + Number(r.hours).toFixed(0) + qsTr("h")
                                       + (r.next ? "  →  " + WN.rankName(r.next.key) + " " + qsTr("at %1h").arg(r.next.at_hours) : ""))
                                    : ""
                            color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 10
                        }
                    }
                }

                // rank progress toward the next tier
                Rectangle {
                    Layout.fillWidth: true
                    height: 4; radius: 2; color: Theme.panel3
                    Rectangle {
                        readonly property var r: root.ws.rank
                        width: parent.width * (r && r.next
                               ? Math.min(1, (r.hours - r.at_hours) / Math.max(1, r.next.at_hours - r.at_hours)) : 1)
                        height: parent.height; radius: 2; color: Theme.accent
                    }
                }

                // families — the achievement matrix, v1 (tiers land server-side later)
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Repeater {
                        model: root.ws.families
                                ? ["hours","nightwatch","hollow","sunrise","fullmoon","yearkeeper",
                                   "steadfast","cleanwatch","wayfarer","vigilance","weather"]
                                      .filter(k => root.ws.families[k] !== undefined)
                                : []
                        delegate: RowLayout {
                            required property var modelData
                            readonly property var fam: root.ws.families[modelData]
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                Layout.preferredWidth: 130
                                text: WN.familyName(modelData)
                                color: fam.available ? Theme.ink2 : Theme.ink3
                                font.family: Theme.fontSans; font.pixelSize: 11
                            }
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignRight
                                text: fam.available ? String(fam.current)
                                                    : (fam.reason || qsTr("not available"))
                                color: fam.available ? Theme.ink : Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                Text {
                    visible: root.ws.shift !== undefined && root.ws.shift !== null
                    text: qsTr("Current shift is a projection — badges bank at checkout.")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 10
                    font.italic: true
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 32
                    radius: 3
                    color: coMa.containsMouse ? Theme.bad : "transparent"
                    border.width: 1
                    border.color: coMa.containsMouse ? Theme.bad : Theme.line2
                    Text {
                        anchors.centerIn: parent
                        text: qsTr("Hand over / check out")
                        color: coMa.containsMouse ? Theme.bg : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold
                    }
                    MouseArea {
                        id: coMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { Watch.checkout(); pop.close(); }
                    }
                }
            }
        }
    }
}
