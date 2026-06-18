import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import Watchtower

// Verify · LAYOUT A — Verification Wall (port of view-wall.jsx / WallBody).
// Snapshot-first grid: each card previews its clip on hover, shows severity +
// clip-duration badge, and confirms (Threat) or clears (Dismiss) in one click.
// Clicking a snapshot jumps to Triage with that event selected. Size S/M/L
// (5/4/3 columns) comes from the Verify toolbar.
Item {
    id: wall
    property string size: "m"
    signal openInTriage(string id)

    property string tab: "toverify"              // toverify | ai | all

    readonly property var _cards: {
        var es = EventsStore.events.filter(function (e) {
            if (wall.tab === "toverify") return e.status === "new" || e.status === "ack";
            if (wall.tab === "ai") return e.type === "person" || e.type === "vehicle" || e.type === "line_cross" || e.type === "loiter";
            return true;
        });
        es.sort(function (a, b) {
            return (EventsStore.sevRank[a.priority] - EventsStore.sevRank[b.priority]) || (b.ts.getTime() - a.ts.getTime());
        });
        return es;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- sub-bar: filter tabs + hint ----
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 45; color: Theme.bg
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 16
                Row {
                    spacing: 4
                    Repeater {
                        model: [ { k: "toverify", l: "To verify" }, { k: "ai", l: "AI detections" }, { k: "all", l: "All" } ]
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool _active: wall.tab === modelData.k
                            height: 30; width: tT.implicitWidth + 28
                            color: _active ? Theme.accentSoft : "transparent"
                            border.width: 1; border.color: _active ? Theme.accent : "transparent"
                            Text { id: tT; anchors.centerIn: parent; text: modelData.l
                                color: parent._active ? Theme.accent : Theme.ink2
                                font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: wall.tab = modelData.k }
                        }
                    }
                }
                Row {
                    Layout.fillWidth: true
                    spacing: 8
                    EvIcon { anchors.verticalCenter: parent.verticalCenter; name: "person"; size: 13; color: Theme.accent }
                    Text { anchors.verticalCenter: parent.verticalCenter
                        text: "Verify what you see — confirm a real threat or dismiss a false alarm without leaving the grid."
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                }
            }
        }

        // ---- card grid ----
        GridView {
            id: grid
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            readonly property int cols: wall.size === "s" ? 5 : wall.size === "m" ? 4 : 3
            leftMargin: 12; rightMargin: 12; topMargin: 10; bottomMargin: 10
            cellWidth: Math.floor((width - 24) / cols)
            cellHeight: Math.round((cellWidth - 16) * 9 / 16) + 136
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { }
            model: wall._cards

            delegate: Item {
                id: cell
                required property var modelData
                readonly property var e: modelData
                readonly property bool _verified: e.status === "resolved" || e.status === "dismissed"
                width: grid.cellWidth; height: grid.cellHeight

                Rectangle {
                    anchors.fill: parent; anchors.margins: 8
                    color: Theme.panel
                    border.width: 1; border.color: snapMa.containsMouse ? Theme.line2 : Theme.line
                    opacity: cell._verified ? 0.62 : 1

                    Column {
                        anchors.fill: parent
                        // snapshot
                        Item {
                            id: snap
                            width: parent.width; height: Math.round(width * 9 / 16)
                            clip: true
                            Rectangle { anchors.fill: parent; color: "#000" }
                            EvSnapshot { anchors.fill: parent; ev: cell.e; playing: snapMa.containsMouse && !cell._verified }
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }

                            // severity tag
                            Rectangle {
                                anchors.top: parent.top; anchors.right: parent.right; anchors.topMargin: 8; anchors.rightMargin: 8
                                color: Qt.rgba(0, 0, 0, 0.6); height: 16; width: svT.implicitWidth + 12
                                Text { id: svT; anchors.centerIn: parent; text: cell.e.priority.toUpperCase()
                                    color: Theme.sevColor(cell.e.priority)
                                    font.family: Theme.fontMono; font.pixelSize: 9; font.weight: Font.Bold; font.letterSpacing: 0.5 }
                            }
                            // clip-duration badge / "no clip"
                            Rectangle {
                                visible: cell.e.durationSec > 0 || cell.e.type === "offline"
                                anchors.bottom: parent.bottom; anchors.right: parent.right; anchors.bottomMargin: 8; anchors.rightMargin: 8
                                color: Qt.rgba(0, 0, 0, 0.72); height: 18; width: durRow.implicitWidth + 12
                                Row {
                                    id: durRow; anchors.centerIn: parent; spacing: 4
                                    EvIcon { visible: cell.e.type !== "offline"; anchors.verticalCenter: parent.verticalCenter; name: "play"; size: 10; color: "#fff" }
                                    Text { anchors.verticalCenter: parent.verticalCenter
                                        text: cell.e.type === "offline" ? "no clip" : EventsStore.dur(cell.e.durationSec)
                                        color: cell.e.type === "offline" ? Theme.ink2 : "#fff"
                                        font.family: Theme.fontMono; font.pixelSize: 10 }
                                }
                            }
                            // verified stamp
                            Rectangle {
                                visible: cell._verified; anchors.fill: parent; color: Qt.rgba(10/255, 9/255, 8/255, 0.55)
                                Text { anchors.centerIn: parent
                                    text: cell.e.status === "resolved" ? "CLEARED" : "DISMISSED"
                                    color: cell.e.status === "resolved" ? Theme.good : Theme.ink2
                                    font.family: Theme.fontMono; font.pixelSize: 13; font.weight: Font.Bold; font.letterSpacing: 2.6 }
                            }
                            MouseArea { id: snapMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; onClicked: wall.openInTriage(cell.e.id) }
                        }
                        // info
                        Column {
                            width: parent.width
                            topPadding: 10; leftPadding: 11; rightPadding: 11; spacing: 5
                            TypePill { type: cell.e.type
                                text: EventsStore.types[cell.e.type].label + (cell.e.conf ? " · " + Math.round(cell.e.conf * 100) + "%" : "") }
                            Text { width: parent.width - 22; text: cell.e.cam.name; color: Theme.ink; elide: Text.ElideRight
                                font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                            Text { text: EventsStore.hhmmss(cell.e.ts) + " · " + EventsStore.rel(cell.e.ts); color: Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 10 }
                        }
                    }

                    // action row (un-verified only) — pinned to the card bottom
                    RowLayout {
                        visible: !cell._verified
                        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                        anchors.leftMargin: 11; anchors.rightMargin: 11; anchors.bottomMargin: 11
                        spacing: 5
                        EvButton { Layout.fillWidth: true; small: true; variant: "good"; icon: "escalate"; label: "Threat"
                            enabledBtn: !EventsStore.actionsPending
                            onClicked: EventsStore.dispose(cell.e.id, "verified", "") }
                        EvButton { Layout.fillWidth: true; small: true; variant: ""; icon: "x"; label: "Dismiss"
                            enabledBtn: !EventsStore.actionsPending
                            onClicked: EventsStore.dispose(cell.e.id, "false_alarm", "") }
                        EvButton { small: true; variant: ""; on: cell.e.bookmarked
                            enabledBtn: !EventsStore.actionsPending
                            icon: cell.e.bookmarked ? "bookmarkF" : "bookmark"
                            onClicked: EventsStore.bookmark(cell.e.id) }
                    }
                }
            }
        }
    }
}
