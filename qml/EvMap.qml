import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import Watchtower

// VIEW 04 — SITUATION MAP (port of view-map.jsx / map-screen-spec.md). Spatial
// awareness: a schematic site plan with a camera pin where each camera sits;
// open events pulse on their pin (count badge), colour-coded by severity. The
// right rail is the live feed; click a pin (or feed row) to drop into a
// per-camera panel and Verify / Dispatch / Clear in context.
Item {
    id: map
    signal openInTriage(string id)

    property string active: ""                    // selected camera id, or ""

    readonly property var _byCam: {
        var m = {}; var es = EventsStore.events;
        for (var i = 0; i < es.length; i++) { var k = es[i].cam.id; if (!m[k] || es[i].ts.getTime() > m[k].ts.getTime()) m[k] = es[i]; }
        return m;
    }
    readonly property var _openByCam: {
        var m = {}; var es = EventsStore.events;
        for (var i = 0; i < es.length; i++) if (es[i].status === "new") { var k = es[i].cam.id; m[k] = (m[k] || 0) + 1; }
        return m;
    }
    readonly property var _feed: {
        var es = EventsStore.events.filter(function (e) { return e.status === "new"; });
        es.sort(function (a, b) { return (EventsStore.sevRank[a.priority] - EventsStore.sevRank[b.priority]) || (b.ts.getTime() - a.ts.getTime()); });
        return es;
    }
    readonly property var _camList: { var a = []; for (var k in EventsStore.cams) a.push(EventsStore.cams[k]); return a; }
    readonly property var _cur: {
        if (active === "") return null;
        for (var i = 0; i < _camList.length; i++) if (_camList[i].id === active) return _camList[i];
        return null;
    }
    readonly property var _curEvents: {
        if (!_cur) return [];
        var es = EventsStore.events.filter(function (e) { return e.cam.id === map._cur.id; });
        es.sort(function (a, b) { return b.ts.getTime() - a.ts.getTime(); });
        return es;
    }
    readonly property var _curEv: _curEvents.length ? _curEvents[0] : null

    function _pinState(cam) {
        var e = _byCam[cam.id]; var open = _openByCam[cam.id] || 0;
        return (e && open) ? e.priority : (e && e.type === "offline" ? "offline" : "idle");
    }
    function _pinStateForId(id) {
        var e = _byCam[id]; var open = _openByCam[id] || 0;
        return (e && open) ? e.priority : (e && e.type === "offline" ? "offline" : "idle");
    }

    // Real mode → load cilex-vision's active Camera Map (background + placements).
    // Fire once both real mode AND auth are ready (whichever lands last; ingestReal
    // can flip realMode before autologin finishes).
    SiteMapModel { id: siteMap }
    function _maybeLoadMap() { if (EventsStore.realMode && AuthController.authenticated && !siteMap.ready) siteMap.load(); }
    Component.onCompleted: map._maybeLoadMap()
    Connections { target: EventsStore; function onRealModeChanged() { map._maybeLoadMap() } }
    Connections { target: AuthController; function onAuthenticatedChanged() { map._maybeLoadMap() } }

    // One pin visual, shared by the mock grid and the real Camera Map placements.
    component MapPin: Item {
        id: pin
        property string camId: ""
        property real cx: 0        // pixel centre within the parent layer
        property real cy: 0
        property real facing: -1   // camera facing degrees (0 = up); -1 = none
        readonly property string st: map._pinStateForId(camId)
        readonly property int open: map._openByCam[camId] || 0
        readonly property bool _sel: map.active === camId
        width: 30; height: 30
        x: cx - 15; y: cy - 15
        z: _sel ? 5 : 1

        Rectangle {                                   // ping ring (open events)
            id: pingRing
            visible: pin.open > 0
            anchors.centerIn: parent; width: 30; height: 30; radius: 15
            color: "transparent"; border.width: 2
            border.color: pin.st === "critical" ? Theme.bad : Theme.accent
            ParallelAnimation {
                running: pin.open > 0; loops: Animation.Infinite
                NumberAnimation { target: pingRing; property: "scale"; from: 1; to: 2.4; duration: 1800; easing.type: Easing.OutCubic }
                NumberAnimation { target: pingRing; property: "opacity"; from: 0.8; to: 0; duration: 1800 }
            }
        }
        Rectangle { visible: pin._sel; anchors.centerIn: parent; width: 36; height: 36; radius: 18   // selection halo
            color: "transparent"; border.width: 3; border.color: Theme.accent }
        Item {                                        // FOV cone (camera direction + field of view)
            visible: pin.facing >= 0
            width: 132; height: 132; anchors.centerIn: parent
            rotation: pin.facing; z: 0
            Canvas {
                id: fov
                anchors.fill: parent
                // Tint mirrors the map legend: critical→red, offline→blue,
                // clear (idle)→olive, anything else with open activity→amber.
                readonly property color tint: pin.st === "critical" ? Theme.bad
                    : pin.st === "offline" ? Theme.info
                    : pin.st === "idle" ? Theme.good
                    : Theme.accent
                onTintChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onVisibleChanged: if (visible) requestPaint()
                Component.onCompleted: requestPaint()
                onPaint: {
                    var ctx = getContext("2d"); ctx.reset();
                    var cx = width / 2, cy = height / 2, r = 58, ha = 34 * Math.PI / 180;
                    var a0 = -Math.PI / 2 - ha, a1 = -Math.PI / 2 + ha;
                    // filled wedge — never fades fully to zero so the whole cone
                    // keeps a faint presence even over the busy isometric plan
                    ctx.beginPath(); ctx.moveTo(cx, cy);
                    ctx.arc(cx, cy, r, a0, a1); ctx.closePath();
                    var g = ctx.createRadialGradient(cx, cy, 4, cx, cy, r);
                    g.addColorStop(0.0, Qt.rgba(tint.r, tint.g, tint.b, 0.42));
                    g.addColorStop(0.65, Qt.rgba(tint.r, tint.g, tint.b, 0.17));
                    g.addColorStop(1.0, Qt.rgba(tint.r, tint.g, tint.b, 0.03));
                    ctx.fillStyle = g; ctx.fill();
                    // crisp outline (two radial edges + arc) so the cone shape
                    // stays legible even where the fill is subtle
                    ctx.strokeStyle = Qt.rgba(tint.r, tint.g, tint.b, 0.7);
                    ctx.lineWidth = 1.5; ctx.lineJoin = "round";
                    ctx.beginPath(); ctx.moveTo(cx, cy);
                    ctx.lineTo(cx + r * Math.cos(a0), cy + r * Math.sin(a0));
                    ctx.arc(cx, cy, r, a0, a1);
                    ctx.lineTo(cx, cy); ctx.stroke();
                }
            }
        }
        Rectangle {                                   // dot
            anchors.fill: parent; radius: 15; z: 2
            color: pin.st === "critical" ? Theme.badSoft : pin.st === "high" ? Theme.accentSoft : Theme.panel3
            border.width: 1
            border.color: pin.st === "critical" ? Theme.bad : pin.st === "high" ? Theme.accent
                        : pin.st === "idle" ? Theme.goodDim : pin.st === "offline" ? Theme.infoDim : Theme.line2
            EvIcon { anchors.centerIn: parent; name: "pin"; size: 14
                color: pin.st === "critical" ? Theme.bad : pin.st === "high" ? Theme.accent
                     : pin.st === "idle" ? Theme.good : pin.st === "offline" ? Theme.info
                     : (pin.st === "medium" || pin.st === "low") ? Theme.ink : Theme.ink2 }
        }
        Rectangle {                                   // count badge
            visible: pin.open > 0; z: 3
            anchors.right: parent.right; anchors.top: parent.top; anchors.rightMargin: -4; anchors.topMargin: -4
            height: 16; width: Math.max(16, bdg.implicitWidth + 8); radius: 8; color: Theme.bad
            Text { id: bdg; anchors.centerIn: parent; text: pin.open; color: "#fff"
                font.family: Theme.fontMono; font.pixelSize: 9; font.weight: Font.Bold }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: map.active = pin.camId }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ======================= LEFT — map canvas =======================
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 24
                spacing: 0

                // ---- site plan ----
                Rectangle {
                    id: plan
                    Layout.fillWidth: true; Layout.fillHeight: true
                    color: Theme.panel; border.width: 1; border.color: Theme.line2

                    // real Camera Map background (real mode) — pre-signed floor-plan image
                    Image {
                        id: planBg
                        visible: EventsStore.realMode && siteMap.ready
                        anchors.fill: parent; fillMode: Image.PreserveAspectFit
                        asynchronous: true; cache: true
                        source: siteMap.ready ? siteMap.backgroundUrl : ""
                    }

                    // rooms (schematic backdrop — mock mode only)
                    Item {
                        visible: !EventsStore.realMode
                        anchors.fill: parent
                        Repeater {
                            model: [ { x: 8, y: 8, w: 34, h: 30 }, { x: 44, y: 8, w: 22, h: 30 }, { x: 68, y: 8, w: 24, h: 44 },
                                     { x: 8, y: 40, w: 34, h: 26 }, { x: 44, y: 40, w: 22, h: 26 }, { x: 8, y: 68, w: 58, h: 24 },
                                     { x: 68, y: 54, w: 24, h: 38 } ]
                            delegate: Rectangle {
                                required property var modelData
                                x: modelData.x / 100 * plan.width; y: modelData.y / 100 * plan.height
                                width: modelData.w / 100 * plan.width; height: modelData.h / 100 * plan.height
                                color: Qt.rgba(1, 1, 1, 0.012); border.width: 1; border.color: Theme.line
                            }
                        }
                        // outer wall
                        Rectangle {
                            x: 2 / 100 * plan.width; y: 2 / 100 * plan.height
                            width: 96 / 100 * plan.width; height: 96 / 100 * plan.height
                            color: "transparent"; border.width: 1; border.color: Theme.line2
                        }
                        // door gap (erase a slice of the left wall)
                        Rectangle { x: 1 / 100 * plan.width; y: 54 / 100 * plan.height - 1; width: 8 / 100 * plan.width; height: 3; color: Theme.panel }
                    }

                    // zone labels — the fixed schematic names match the mock site plan;
                    // hidden in real mode (real cameras have no site-plan coords yet, so
                    // they sit on a neutral grid — see docs/letters/2026-06-18).
                    Repeater {
                        model: EventsStore.realMode ? [] : [ { l: "Rear Yard", x: 16, y: 30 }, { l: "N. Perimeter", x: 50, y: 10 }, { l: "Stockroom", x: 30, y: 42 },
                                 { l: "Server Rm", x: 68, y: 30 }, { l: "Parking E.", x: 84, y: 46 }, { l: "Loading", x: 24, y: 70 },
                                 { l: "Reception", x: 60, y: 70 }, { l: "Main Ent.", x: 50, y: 90 } ]
                        delegate: Text {
                            required property var modelData
                            x: modelData.x / 100 * plan.width - implicitWidth / 2
                            y: modelData.y / 100 * plan.height - implicitHeight / 2
                            text: modelData.l.toUpperCase(); color: Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.6
                        }
                    }

                    // camera pins — mock: schematic grid positions
                    Repeater {
                        model: EventsStore.realMode ? [] : map._camList
                        delegate: MapPin {
                            required property var modelData
                            camId: modelData.id
                            cx: modelData.x / 100 * plan.width
                            cy: modelData.y / 100 * plan.height
                        }
                    }
                    // camera pins — real: placements on the Camera Map background image
                    Item {
                        id: placedLayer
                        visible: EventsStore.realMode && siteMap.ready && planBg.status === Image.Ready
                        width: planBg.paintedWidth; height: planBg.paintedHeight
                        x: (plan.width - width) / 2; y: (plan.height - height) / 2
                        Repeater {
                            model: (EventsStore.realMode && siteMap.ready) ? siteMap.placements() : []
                            delegate: MapPin {
                                required property var modelData
                                camId: modelData.cameraId
                                cx: modelData.x * placedLayer.width
                                cy: modelData.y * placedLayer.height
                                facing: modelData.rotation
                            }
                        }
                    }
                    // unplaced note (real mode) — the rest are reachable via the feed
                    Rectangle {
                        visible: EventsStore.realMode && siteMap.ready
                        anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 10
                        height: 22; width: unpT.implicitWidth + 18; color: Qt.rgba(0, 0, 0, 0.5)
                        border.width: 1; border.color: Theme.line2
                        Text { id: unpT; anchors.centerIn: parent
                            text: siteMap.placedCount + " of " + map._camList.length + " cameras placed · others in the feed"
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                    }
                }

                // ---- legend ----
                Row {
                    Layout.topMargin: 14
                    spacing: 16
                    Repeater {
                        model: [ { c: Theme.bad, l: "critical activity" }, { c: Theme.accent, l: "elevated" },
                                 { c: Theme.info, l: "offline" }, { c: Theme.good, l: "clear" } ]
                        delegate: Row {
                            required property var modelData
                            spacing: 6
                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 9; height: 9; radius: 4.5; color: modelData.c }
                            Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11 }
                        }
                    }
                }
            }
        }

        // ======================= RIGHT — side rail =======================
        Rectangle {
            Layout.preferredWidth: 360; Layout.fillHeight: true
            color: Theme.bg
            Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.line }

            // ---- State A: live feed ----
            ColumnLayout {
                visible: map._cur === null
                anchors.fill: parent; spacing: 0
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 45; color: Theme.bg
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
                        Text { text: "LIVE FEED"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; font.letterSpacing: 1.0 }
                        Item { Layout.fillWidth: true }
                        Text { text: map._feed.length + " open"; color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 11 }
                    }
                }
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                    model: map._feed
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Rectangle {
                        id: frow
                        required property var modelData
                        readonly property var e: modelData
                        width: ListView.view.width; height: 67
                        color: fMa.containsMouse ? Theme.panel : "transparent"
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.rightMargin: 16; spacing: 10
                            Rectangle { Layout.preferredWidth: 3; Layout.fillHeight: true; color: Theme.sevColor(frow.e.priority) }
                            Rectangle {
                                Layout.preferredWidth: 76; Layout.preferredHeight: 44
                                color: "#000"; border.width: 1; border.color: Theme.line; clip: true
                                EvSnapshot { anchors.fill: parent; anchors.margins: 1; ev: frow.e; mini: true; showOsd: false }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 4
                                TypePill { type: frow.e.type }
                                Text { text: frow.e.cam.zone; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12 }
                                Text { text: EventsStore.rel(frow.e.ts); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                            }
                        }
                        MouseArea { id: fMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: map.active = frow.e.cam.id }
                    }
                }
            }

            // ---- State B: camera detail ----
            Flickable {
                id: detail
                visible: map._cur !== null
                anchors.fill: parent; clip: true
                contentWidth: width; contentHeight: detailCol.implicitHeight + 32
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { }
                Column {
                    id: detailCol
                    x: 16; y: 16; width: parent.width - 32; spacing: 6

                    Text {
                        text: "‹ All zones"; color: backMa.containsMouse ? Theme.accent : Theme.ink2
                        font.family: Theme.fontSans; font.pixelSize: 12
                        MouseArea { id: backMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: map.active = "" }
                    }
                    Text { text: map._cur ? map._cur.name : ""; color: Theme.ink; topPadding: 4
                        font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
                    Text { text: map._cur ? (map._cur.zone + " · " + map._cur.id) : ""; color: Theme.ink3; bottomPadding: 6
                        font.family: Theme.fontMono; font.pixelSize: 11 }

                    Rectangle {
                        visible: map._curEv !== null
                        width: parent.width; height: Math.round(width * 9 / 16)
                        color: "#000"; border.width: 1; border.color: Theme.line; clip: true
                        EvSnapshot { anchors.fill: parent; anchors.margins: 1; ev: map._curEv }
                    }
                    Item { width: 1; height: 6 }

                    // action row
                    RowLayout {
                        visible: map._curEv !== null
                        width: parent.width; spacing: 6
                        EvButton { Layout.fillWidth: true; small: true; variant: "pri"; icon: "play"; label: "Verify"
                            onClicked: if (map._curEv) map.openInTriage(map._curEv.id) }
                        EvButton { Layout.fillWidth: true; small: true; variant: "danger"; icon: "dispatch"; label: "Dispatch"
                            enabledBtn: !EventsStore.actionsPending
                            onClicked: if (map._curEv) EventsStore.dispose(map._curEv.id, "dispatched", "") }
                        EvButton { Layout.fillWidth: true; small: true; variant: "good"; icon: "check"; label: "Clear"
                            enabledBtn: !EventsStore.actionsPending
                            onClicked: if (map._curEv) EventsStore.dispose(map._curEv.id, "authorized", "") }
                    }
                    Item { width: 1; height: 10 }

                    Text { visible: map._curEv !== null; text: "RECENT AT THIS CAMERA"; color: Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.0 }
                    Text { visible: map._curEv === null; text: "No events at this camera."; color: Theme.ink3
                        font.family: Theme.fontSans; font.pixelSize: 12; topPadding: 10 }

                    Repeater {
                        model: map._curEv ? map._curEvents.slice(0, 6) : []
                        delegate: Item {
                            id: drow
                            required property var modelData
                            readonly property var e: modelData
                            width: detailCol.width; height: 37
                            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
                            RowLayout {
                                anchors.fill: parent; spacing: 10
                                Item {
                                    Layout.preferredWidth: 8; Layout.preferredHeight: 8
                                    Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: 4; color: Theme.sevColor(drow.e.priority) }
                                }
                                EvIcon { name: EventsStore.types[drow.e.type].icon; size: 12; color: Theme.ink2 }
                                Text { text: EventsStore.types[drow.e.type].label; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                                Item { Layout.fillWidth: true }
                                Text { text: EventsStore.hhmmss(drow.e.ts); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                                StateTag { state: drow.e.status; dotOnly: true; dotSize: 6 }
                            }
                        }
                    }
                }
            }
        }
    }
}
