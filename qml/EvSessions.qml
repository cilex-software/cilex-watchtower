import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import Watchtower

// Verify · LAYOUT B — Smart Sessions (port of view-sessions.jsx / SessionsBody).
// Noise reduction: motion fragments collapse into sessions, grouped by zone,
// ranked by priority, with per-row Ack/Bookmark and a floating bulk bar. Sort
// (Priority / Recent) comes from the Verify toolbar.
Item {
    id: ses
    property string sortBy: "priority"           // priority | recent

    property var picked: ({})                     // {id: true}
    property var collapsed: ({})                  // {zone: true}
    readonly property var _pickedIds: {
        var out = []; for (var k in ses.picked) if (ses.picked[k]) out.push(k); return out;
    }

    readonly property var _zones: {
        var zmap = {}; var es = EventsStore.events;
        for (var i = 0; i < es.length; i++) { var z = es[i].cam.zone; (zmap[z] = zmap[z] || []).push(es[i]); }
        var list = [];
        for (var zone in zmap) {
            var evs = zmap[zone];
            var rank = 99; for (var j = 0; j < evs.length; j++) rank = Math.min(rank, EventsStore.sevRank[evs[j].priority]);
            evs.sort(function (a, b) { return (EventsStore.sevRank[a.priority] - EventsStore.sevRank[b.priority]) || (b.ts.getTime() - a.ts.getTime()); });
            var open = evs.filter(function (e) { return e.status === "new"; }).length;
            list.push({ zone: zone, evs: evs, rank: rank, open: open });
        }
        list.sort(function (a, b) { return ses.sortBy === "priority" ? a.rank - b.rank : b.evs[0].ts.getTime() - a.evs[0].ts.getTime(); });
        return list;
    }
    readonly property var _rankName: ["critical", "high", "medium", "low"]

    function _toggle(id) { var p = Object.assign({}, ses.picked); p[id] = !p[id]; ses.picked = p; }
    function _toggleZone(z) { var c = Object.assign({}, ses.collapsed); c[z] = !c[z]; ses.collapsed = c; }
    function _bulkAck() { for (var i = 0; i < ses._pickedIds.length; i++) EventsStore.ack(ses._pickedIds[i]); ses.picked = ({}); }
    function _bulkDismiss() { for (var i = 0; i < ses._pickedIds.length; i++) EventsStore.dispose(ses._pickedIds[i], "false_alarm", ""); ses.picked = ({}); }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- stat header ----
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 56; color: Theme.bg
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
            Row {
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20
                spacing: 24
                Repeater {
                    model: [ { n: "38", c: Theme.ink,  a: "motion fragments", b: "collapsed into sessions" },
                             { n: "" + EventsStore.events.filter(function (e) { return e.status === "new" && (e.priority === "critical" || e.priority === "high"); }).length, c: Theme.bad,  a: "high-priority", b: "need action" },
                             { n: "" + EventsStore.events.filter(function (e) { return e.status !== "new"; }).length, c: Theme.good, a: "handled", b: "this shift" } ]
                    delegate: Row {
                        required property var modelData
                        height: parent.height; spacing: 10
                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.n; color: modelData.c
                            font.family: Theme.fontSans; font.pixelSize: 26; font.weight: Font.Bold; font.letterSpacing: -0.5 }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter; spacing: 1
                            Text { text: modelData.a.toUpperCase(); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.6 }
                            Text { text: modelData.b.toUpperCase(); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.6 }
                        }
                    }
                }
            }
        }

        // ---- zone list (scrolls) ----
        Flickable {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true; contentWidth: width; contentHeight: zoneCol.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { }

            Column {
                id: zoneCol
                width: scroll.width
                Repeater {
                    model: ses._zones
                    delegate: Column {
                        id: zoneItem
                        required property var modelData
                        readonly property bool _collapsed: ses.collapsed[modelData.zone] === true
                        width: zoneCol.width

                        // zone header
                        Rectangle {
                            width: parent.width; height: 43
                            color: zhMa.containsMouse ? Theme.panel2 : Theme.panel
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 10
                                EvIcon { name: "chev"; size: 14; color: Theme.ink3
                                    rotation: zoneItem._collapsed ? 0 : 90
                                    Behavior on rotation { NumberAnimation { duration: 120 } } }
                                Item {
                                    Layout.preferredWidth: 8; Layout.preferredHeight: 8
                                    Rectangle { visible: zoneItem.modelData.rank === 0; anchors.centerIn: parent; width: 14; height: 14; radius: 7; color: Theme.badSoft }
                                    Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: 4; color: Theme.sevColor(ses._rankName[zoneItem.modelData.rank]) }
                                }
                                Text { text: zoneItem.modelData.zone; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                                Text { text: zoneItem.modelData.evs.length + " sessions"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                                Item { Layout.fillWidth: true }
                                Rectangle {
                                    visible: zoneItem.modelData.open > 0
                                    height: 18; width: zoT.implicitWidth + 14; color: "transparent"
                                    border.width: 1; border.color: Theme.badDim
                                    Text { id: zoT; anchors.centerIn: parent; text: zoneItem.modelData.open + " open"; color: Theme.bad
                                        font.family: Theme.fontMono; font.pixelSize: 10 }
                                }
                            }
                            MouseArea { id: zhMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: ses._toggleZone(zoneItem.modelData.zone) }
                        }

                        // rows
                        Column {
                            width: parent.width; visible: !zoneItem._collapsed
                            Repeater {
                                model: zoneItem._collapsed ? [] : zoneItem.modelData.evs
                                delegate: Rectangle {
                                    id: srow
                                    required property var modelData
                                    readonly property var e: modelData
                                    readonly property bool _picked: ses.picked[e.id] === true
                                    width: zoneItem.width; height: 58
                                    color: _picked ? Theme.accentSoft : (srMa.containsMouse ? Theme.panel : "transparent")
                                    opacity: e.status !== "new" ? 0.5 : 1
                                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                                    MouseArea { id: srMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }

                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 12

                                        // checkbox
                                        Rectangle {
                                            Layout.preferredWidth: 18; Layout.preferredHeight: 18
                                            color: srow._picked ? Theme.accent : "transparent"
                                            border.width: 1; border.color: srow._picked ? Theme.accent : Theme.line2
                                            EvIcon { anchors.centerIn: parent; visible: srow._picked; name: "check"; size: 12; color: Theme.bg }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: ses._toggle(srow.e.id) }
                                        }
                                        // thumbnail
                                        Rectangle {
                                            Layout.preferredWidth: 64; Layout.preferredHeight: 38
                                            color: "#000"; border.width: 1; border.color: Theme.line; clip: true
                                            EvSnapshot { anchors.fill: parent; anchors.margins: 1; ev: srow.e; mini: true; showOsd: false }
                                        }
                                        // main: type pill + note
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: 4
                                            TypePill { type: srow.e.type }
                                            Text { Layout.fillWidth: true; elide: Text.ElideRight
                                                text: srow.e.note ? srow.e.note : (srow.e.type === "motion" ? "Motion session" : "—")
                                                color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                                        }
                                        // camera
                                        Text { Layout.preferredWidth: 150; text: srow.e.cam.name; color: Theme.ink; elide: Text.ElideRight
                                            font.family: Theme.fontSans; font.pixelSize: 12 }
                                        // duration
                                        Row {
                                            Layout.preferredWidth: 84; spacing: 5
                                            EvIcon { anchors.verticalCenter: parent.verticalCenter; name: "clock"; size: 12; color: Theme.ink3 }
                                            Text { anchors.verticalCenter: parent.verticalCenter
                                                text: srow.e.durationSec ? EventsStore.dur(srow.e.durationSec) : "—"
                                                color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                                        }
                                        // time
                                        ColumnLayout {
                                            Layout.preferredWidth: 88; spacing: 0
                                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; text: EventsStore.hhmmss(srow.e.ts)
                                                color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                                            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; text: EventsStore.rel(srow.e.ts)
                                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                        }
                                        // severity
                                        Item { Layout.preferredWidth: 92
                                            Sev { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; level: srow.e.priority } }
                                        // row actions
                                        Item {
                                            Layout.preferredWidth: 150
                                            Row {
                                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 5
                                                visible: srow.e.status === "new"
                                                EvButton { small: true; icon: "check"; label: "Ack"; onClicked: EventsStore.ack(srow.e.id) }
                                                EvButton { small: true; on: srow.e.bookmarked
                                                    icon: srow.e.bookmarked ? "bookmarkF" : "bookmark"; onClicked: EventsStore.bookmark(srow.e.id) }
                                            }
                                            StateTag {
                                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                                visible: srow.e.status !== "new"
                                                state: srow.e.status
                                                label: srow.e.dispo ? EventsStore.dispoDefs[srow.e.dispo].label : srow.e.status.toUpperCase()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- floating bulk bar ----
    Rectangle {
        visible: ses._pickedIds.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: 18
        height: 56; width: Math.max(480, bulkRow.implicitWidth + 28)
        color: Theme.panel3; border.width: 1; border.color: Theme.line2
        RowLayout {
            id: bulkRow
            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
            Text { text: ses._pickedIds.length + " selected"; color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 12 }
            Item { Layout.fillWidth: true }
            EvButton { small: true; icon: "x"; label: "Dismiss as noise"; onClicked: ses._bulkDismiss() }
            EvButton { small: true; variant: "pri"; icon: "check"; label: "Acknowledge selected"; onClicked: ses._bulkAck() }
            EvButton { small: true; variant: "ghost"; label: "Clear"; onClicked: ses.picked = ({}) }
        }
    }
}
