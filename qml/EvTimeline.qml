import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import Watchtower

// VIEW 03 — ACTIVITY TIMELINE (port of view-timeline.jsx / timeline-screen-spec).
// One swimlane per camera across a shared time axis; each event is a marker at
// its timestamp with a duration bar extending right (length = how long it
// lasted). Click a marker for a popover (snapshot + Review/Bookmark/Ack). A
// dashed "now" line anchors the right edge. Window: 90m / 3.5h / 8h.
Item {
    id: tl
    signal openInTriage(string id)

    property real hours: 3.5
    property string pop: ""                       // id of the event whose popover is open
    readonly property real _winMs: hours * 3600 * 1000
    readonly property var _now: EventsStore.now
    readonly property var _t0: new Date(tl._now.getTime() - tl._winMs)
    readonly property int _gutter: 188

    function _pct(d) { return (d.getTime() - tl._t0.getTime()) / tl._winMs * 100; }

    readonly property var _camKeys: { var a = []; for (var k in EventsStore.cams) a.push(k); return a; }
    readonly property var _ticks: {
        var out = []; var n = Math.ceil(hours);
        for (var i = 0; i <= n; i++) { var tt = new Date(tl._t0.getTime() + i * 3600 * 1000); out.push({ left: tl._pct(tt), label: EventsStore.hhmm(tt) }); }
        return out;
    }
    readonly property var _popEv: tl.pop !== "" ? EventsStore.find(tl.pop) : null
    // Honest empty window: zero markers must never read as "no activity ever".
    readonly property int _inWindow: EventsStore.events.filter(function (e) { return e.ts.getTime() >= tl._t0.getTime(); }).length
    readonly property var _latestTs: EventsStore.events.length > 0 ? EventsStore.events[0].ts : null

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- toolbar ----
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 49; color: Theme.bg
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 16
                Row {
                    spacing: 6
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Activity timeline"; color: Theme.ink
                        font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold }
                    Text { anchors.verticalCenter: parent.verticalCenter
                        text: "· " + tl._camKeys.length + " cameras · " + EventsStore.events.length + " events"; color: Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 11 }
                }
                Item { Layout.fillWidth: true }
                // legend
                Row {
                    spacing: 14
                    Repeater {
                        model: [ { c: Theme.bad, l: "critical" }, { c: Theme.accent, l: "high" }, { c: Theme.ink3, l: "motion / session" } ]
                        delegate: Row {
                            required property var modelData
                            spacing: 6
                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 9; height: 9; radius: 4.5; color: modelData.c }
                            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11 }
                        }
                    }
                }
                // window selector
                Rectangle {
                    Layout.preferredHeight: 32; Layout.preferredWidth: winRow.implicitWidth
                    color: Theme.panel; border.width: 1; border.color: Theme.line2
                    Row {
                        id: winRow; height: parent.height
                        Repeater {
                            model: [ { h: 1.5, l: "90m" }, { h: 3.5, l: "3.5h" }, { h: 8, l: "8h" } ]
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                readonly property bool _active: tl.hours === modelData.h
                                height: parent.height; width: wT.implicitWidth + 24
                                color: _active ? Theme.accent : (wMa.containsMouse ? Theme.panel2 : Theme.panel)
                                Rectangle { visible: index < 2; anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Text { id: wT; anchors.centerIn: parent; text: modelData.l
                                    color: parent._active ? Theme.bg : Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                                MouseArea { id: wMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { tl.hours = modelData.h; tl.pop = ""; } }
                            }
                        }
                    }
                }
            }
        }

        // ---- sticky time axis ----
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 31; color: Theme.bg
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
            Rectangle { anchors.left: parent.left; width: tl._gutter; height: parent.height; color: "transparent"
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line } }
            Item {
                id: axisTrack
                anchors.left: parent.left; anchors.leftMargin: tl._gutter; anchors.right: parent.right; height: parent.height
                Repeater {
                    model: tl._ticks
                    delegate: Item {
                        required property var modelData
                        x: modelData.left / 100 * axisTrack.width; height: axisTrack.height
                        Rectangle { width: 1; height: parent.height; color: Theme.line }
                        Text { x: 6; y: 9; text: modelData.label; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    }
                }
            }
        }

        // ---- honest empty-window banner ----
        Rectangle {
            visible: tl._inWindow === 0 && EventsStore.events.length > 0
            Layout.fillWidth: true; Layout.preferredHeight: 34
            color: Theme.panel
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
            Text {
                anchors.centerIn: parent
                text: qsTr("No events in the last %1 — the most recent activity was %2.")
                        .arg(tl.hours >= 1.5 ? ((tl.hours % 1 === 0 ? tl.hours : tl.hours.toFixed(1))) + qsTr("h") : Math.round(tl.hours * 60) + qsTr("m"))
                        .arg(tl._latestTs ? EventsStore.rel(tl._latestTs) : "—")
                color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12
            }
        }

        // ---- scrolling lanes ----
        Flickable {
            id: grid
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true; contentWidth: width; contentHeight: lanesContent.height
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { }

            Item {
                id: lanesContent
                width: grid.width
                height: Math.max(grid.height, tl._camKeys.length * 64)
                readonly property real trackX: tl._gutter
                readonly property real trackW: width - tl._gutter

                // background: click empties the popover
                MouseArea { anchors.fill: parent; onClicked: tl.pop = "" }

                Column {
                    width: parent.width
                    Repeater {
                        model: tl._camKeys
                        delegate: Item {
                            id: lane
                            required property var modelData
                            readonly property var cam: EventsStore.cams[modelData]
                            readonly property var _laneEvents: EventsStore.events.filter(function (e) { return e.cam.id === lane.cam.id && e.ts.getTime() >= tl._t0.getTime(); })
                            width: lanesContent.width; height: 64
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }

                            // gutter
                            Item {
                                width: tl._gutter; height: parent.height
                                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 14; anchors.right: parent.right; anchors.rightMargin: 14
                                    spacing: 3
                                    Text { width: parent.width; text: lane.cam.name; color: Theme.ink; elide: Text.ElideRight
                                        font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                                    Text { width: parent.width; elide: Text.ElideRight
                                        text: (lane.cam.ip ? lane.cam.ip : "") + (lane.cam.ip && lane.cam.zone ? "  \u00b7  " : "") + (lane.cam.zone ? lane.cam.zone : "")
                                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                }
                            }
                            // track
                            Item {
                                id: laneTrack
                                anchors.left: parent.left; anchors.leftMargin: tl._gutter; anchors.right: parent.right; height: parent.height
                                // vertical gridlines
                                Repeater {
                                    model: tl._ticks
                                    delegate: Rectangle { required property var modelData
                                        x: modelData.left / 100 * laneTrack.width; width: 1; height: parent.height; color: Theme.line; opacity: 0.5 }
                                }
                                // duration bars + markers
                                Repeater {
                                    model: lane._laneEvents
                                    delegate: Item {
                                        required property var modelData
                                        readonly property var e: modelData
                                        readonly property real _left: tl._pct(e.ts)
                                        readonly property real _barW: e.durationSec ? Math.max(0.6, (e.durationSec * 1000 / tl._winMs) * 100) : 0
                                        readonly property bool _big: e.priority === "critical" || e.priority === "high"
                                        anchors.fill: parent

                                        // duration bar
                                        Rectangle {
                                            visible: parent._barW > 0.6
                                            x: parent._left / 100 * laneTrack.width
                                            width: parent._barW / 100 * laneTrack.width
                                            height: 6; radius: 3; anchors.verticalCenter: parent.verticalCenter
                                            color: e.priority === "critical" ? Theme.bad : e.priority === "high" ? Theme.accent : Theme.ink3
                                            opacity: e.priority === "critical" ? 0.7 : e.priority === "high" ? 0.6 : 0.5
                                        }
                                        // marker
                                        Rectangle {
                                            id: mk
                                            readonly property bool _hover: mkMa.containsMouse
                                            x: parent._left / 100 * laneTrack.width - width / 2
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent._big ? 28 : 22; height: width; radius: width / 2
                                            opacity: e.status !== "new" ? 0.4 : 1
                                            scale: _hover ? 1.12 : 1
                                            Behavior on scale { NumberAnimation { duration: 90 } }
                                            color: e.priority === "critical" ? Theme.badSoft : e.priority === "high" ? Theme.accentSoft : Theme.panel2
                                            border.width: 1
                                            border.color: _hover ? Theme.ink2 : (e.priority === "critical" ? Theme.bad : e.priority === "high" ? Theme.accent : Theme.line2)
                                            EvIcon { anchors.centerIn: parent; name: EventsStore.types[mk.parent.e.type].icon; size: mk.parent._big ? 13 : 11
                                                color: mk._hover ? Theme.ink : (mk.parent.e.priority === "critical" ? Theme.bad : mk.parent.e.priority === "high" ? Theme.accent : Theme.ink2) }
                                            MouseArea { id: mkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: tl.pop = (tl.pop === mk.parent.e.id ? "" : mk.parent.e.id) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // now line (across all lanes)
                Rectangle {
                    x: lanesContent.trackX + lanesContent.trackW - 1
                    y: 0; width: 1.5; height: tl._camKeys.length * 64
                    color: "transparent"
                    Repeater {                       // dashed effect
                        model: Math.ceil(parent.height / 8)
                        delegate: Rectangle { required property int index; y: index * 8; width: 1.5; height: 4; color: Theme.bad }
                    }
                    Text { x: -implicitWidth - 4; y: 2; text: "now " + EventsStore.hhmm(tl._now); color: Theme.bad
                        font.family: Theme.fontMono; font.pixelSize: 9 }
                }

                // ---- popover (single overlay, on top of all lanes) ----
                Item {
                    id: popOv
                    visible: tl._popEv !== null
                    z: 20
                    readonly property var e: tl._popEv
                    readonly property int _laneIdx: e ? tl._camKeys.indexOf(e.cam.key) : 0
                    readonly property real _markX: e ? (lanesContent.trackX + tl._pct(e.ts) / 100 * lanesContent.trackW) : 0
                    x: Math.max(4, Math.min(lanesContent.width - 252, _markX - 124))
                    y: _laneIdx * 64 + 52
                    width: 248; height: visible ? popCol.implicitHeight : 0

                    Rectangle {
                        anchors.fill: parent; color: Theme.panel3; border.width: 1; border.color: Theme.line2
                        MouseArea { anchors.fill: parent }   // swallow clicks (keep open)
                        Column {
                            id: popCol; width: parent.width
                            Item {
                                width: parent.width; height: Math.round(width * 9 / 16); clip: true
                                EvSnapshot { anchors.fill: parent; ev: popOv.e; showOsd: false }
                                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                            }
                            Column {
                                width: parent.width
                                topPadding: 10; bottomPadding: 11; leftPadding: 11; rightPadding: 11; spacing: 8
                                TypePill { type: popOv.e ? popOv.e.type : "motion" }
                                Text {
                                    text: popOv.e ? (EventsStore.hhmmss(popOv.e.ts) + " · " + (popOv.e.durationSec ? EventsStore.dur(popOv.e.durationSec) : "instant") + " · " + (popOv.e.conf ? Math.round(popOv.e.conf * 100) + "%" : "—")) : ""
                                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                                }
                                RowLayout {
                                    width: parent.width - 22; spacing: 5
                                    EvButton { Layout.fillWidth: true; small: true; variant: "pri"; icon: "play"; label: "Review"
                                        onClicked: if (popOv.e) tl.openInTriage(popOv.e.id) }
                                    EvButton { small: true; on: popOv.e && popOv.e.bookmarked
                                        icon: (popOv.e && popOv.e.bookmarked) ? "bookmarkF" : "bookmark"
                                        onClicked: if (popOv.e) EventsStore.bookmark(popOv.e.id) }
                                    EvButton { small: true; icon: "check"; label: "Ack"
                                        onClicked: { if (popOv.e) EventsStore.ack(popOv.e.id); tl.pop = ""; } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
