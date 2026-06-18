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
    signal openWall(var camIds)                   // "play selected" → synchronized wall playback

    property string active: ""                    // selected camera id, or ""

    // ---- multi-select (Ctrl/Option-click pins + marquee drag) → wall playback ----
    // The selection is capped at 16 (the wall's cell limit). Selecting any camera(s)
    // surfaces a "Play in wall" action that jumps to the synchronized wall over only
    // the chosen cameras.
    property var selIds: ({})                     // backend camId -> true (≤16)
    readonly property int selCount: { var n = 0; for (var k in selIds) n++; return n }
    function _isSel(id) { return selIds[id] === true; }
    function _toggleSel(id) {
        var m = ({}); for (var k in selIds) m[k] = true;
        if (m[id]) delete m[id];
        else { if (selCount >= 16) return; m[id] = true; }   // hard cap: first 16
        selIds = m;
    }
    function _clearSel() { selIds = ({}); }
    function _playSelected() {
        var ids = []; for (var k in selIds) ids.push(k);
        if (ids.length > 0) map.openWall(ids);
    }
    // marquee (rubber-band) drag state, in `plan` pixel coords
    property bool _mqActive: false
    property real _mqx: 0; property real _mqy: 0; property real _mqx2: 0; property real _mqy2: 0
    // Select every visible camera pin whose centre falls inside the box. `add` keeps
    // the existing selection (Ctrl/Option-drag); otherwise it replaces it.
    function _selectInRect(x0, y0, x1, y1, add) {
        var m = ({}), cnt = 0;
        if (add) { for (var k in selIds) { m[k] = true; cnt++; } }
        function tryAdd(id) { if (cnt < 16 && !m[id]) { m[id] = true; cnt++; } }   // first 16 only
        if (EventsStore.realMode) {
            var ps = map._placements;
            for (var i = 0; i < ps.length && cnt < 16; i++) {
                var px = placedLayer.x + ps[i].x * placedLayer.width;
                var py = placedLayer.y + ps[i].y * placedLayer.height;
                if (px >= x0 && px <= x1 && py >= y0 && py <= y1) tryAdd(ps[i].cameraId);
            }
        } else {
            var cl = map._camList;
            for (var j = 0; j < cl.length && cnt < 16; j++) {
                var mx = cl[j].x / 100 * plan.width, my = cl[j].y / 100 * plan.height;
                if (mx >= x0 && mx <= x1 && my >= y0 && my <= y1) tryAdd(cl[j].id);
            }
        }
        selIds = m;
    }
    // a stale selection from another scope is just noise — reset on source switch
    Connections { target: EventsStore; function onRealModeChanged() { map._clearSel() } }

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
    // Real Camera-Map placements, scoped to the cameras currently in view (the group
    // filter narrows EventsStore.cams, so the map pins follow the selected group).
    readonly property var _placements: {
        if (!(EventsStore.realMode && siteMap.ready)) return [];
        var all = siteMap.placements(), cams = EventsStore.cams, out = [];
        for (var i = 0; i < all.length; i++) if (cams[all[i].cameraId] !== undefined) out.push(all[i]);
        return out;
    }
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
        readonly property bool _selected: map._isSel(camId)
        width: 30; height: 30
        x: cx - 15; y: cy - 15
        z: _selected ? 6 : _sel ? 5 : 1

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
        Rectangle { visible: pin._sel; anchors.centerIn: parent; width: 36; height: 36; radius: 18   // active-detail halo
            color: "transparent"; border.width: 3; border.color: Theme.accent }
        Rectangle {                                   // multi-select indicator (filled accent disc)
            visible: pin._selected; z: 1
            anchors.centerIn: parent; width: 34; height: 34; radius: 17
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.22)
            border.width: 2; border.color: Theme.accent
        }
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
        Rectangle {                                   // selected check badge (top-left)
            visible: pin._selected; z: 7
            anchors.left: parent.left; anchors.top: parent.top; anchors.leftMargin: -3; anchors.topMargin: -3
            width: 14; height: 14; radius: 7; color: Theme.accent; border.width: 1; border.color: Theme.bg
            Text { anchors.centerIn: parent; text: "✓"; color: Theme.bg; font.pixelSize: 9; font.weight: Font.Bold }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            // Ctrl-click (or Option/Alt on Mac) toggles this camera into the wall
            // selection; a plain click opens the camera detail as before.
            onClicked: (m) => {
                if (m.modifiers & (Qt.ControlModifier | Qt.AltModifier)) map._toggleSel(pin.camId);
                else map.active = pin.camId;
            }
        }
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

                    // marquee (rubber-band) select — press in empty space and drag a
                    // box. Pins sit ON TOP of this, so a press that lands on a pin goes
                    // to the pin (its own MouseArea); only empty-space presses start a box.
                    MouseArea {
                        id: marquee
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        property real sx: 0
                        property real sy: 0
                        onPressed: (m) => { marquee.sx = m.x; marquee.sy = m.y; map._mqx = m.x; map._mqy = m.y; map._mqx2 = m.x; map._mqy2 = m.y; map._mqActive = true; }
                        onPositionChanged: (m) => { if (map._mqActive) { map._mqx2 = m.x; map._mqy2 = m.y; } }
                        onReleased: (m) => {
                            map._mqActive = false;
                            var moved = Math.abs(m.x - marquee.sx) > 4 || Math.abs(m.y - marquee.sy) > 4;
                            var addMod = (m.modifiers & (Qt.ControlModifier | Qt.AltModifier)) !== 0;
                            if (moved)
                                map._selectInRect(Math.min(marquee.sx, m.x), Math.min(marquee.sy, m.y),
                                                  Math.max(marquee.sx, m.x), Math.max(marquee.sy, m.y), addMod);
                            else if (!addMod) { map._clearSel(); map.active = ""; }   // plain click on empty space clears
                        }
                        onCanceled: map._mqActive = false
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
                            model: map._placements
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
                            text: map._placements.length + " of " + map._camList.length + " cameras placed · others in the feed"
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                    }

                    // marquee drag rectangle (drawn over the pins while dragging)
                    Rectangle {
                        visible: map._mqActive
                        x: Math.min(map._mqx, map._mqx2); y: Math.min(map._mqy, map._mqy2)
                        width: Math.abs(map._mqx2 - map._mqx); height: Math.abs(map._mqy2 - map._mqy)
                        z: 8
                        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
                        border.width: 1; border.color: Theme.accent
                    }

                    // how-to hint (only when nothing is selected yet, real mode)
                    Rectangle {
                        visible: map.selCount === 0 && EventsStore.realMode && siteMap.ready
                        anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter; anchors.topMargin: 10
                        height: 22; width: hintT.implicitWidth + 18; radius: 11; color: Qt.rgba(0, 0, 0, 0.55)
                        border.width: 1; border.color: Theme.line2; z: 19
                        Text { id: hintT; anchors.centerIn: parent
                            text: "Ctrl/Option-click pins or drag a box to select cameras for wall playback"
                            color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 10 }
                    }

                    // selection action bar (bottom-centre) — jump to wall playback
                    Rectangle {
                        visible: map.selCount > 0 && EventsStore.realMode
                        z: 20
                        anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 16
                        width: selRow.implicitWidth + 24; height: 46; radius: 5
                        color: Theme.panel2; border.width: 1; border.color: Theme.accent
                        Row {
                            id: selRow; anchors.centerIn: parent; spacing: 12
                            Text { anchors.verticalCenter: parent.verticalCenter
                                text: map.selCount + (map.selCount === 1 ? " camera" : " cameras") + " selected"
                                color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                            Rectangle {                            // Play in wall
                                anchors.verticalCenter: parent.verticalCenter
                                width: pwRow.implicitWidth + 22; height: 32; radius: 3
                                color: pwMa.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent
                                Row { id: pwRow; anchors.centerIn: parent; spacing: 6
                                    EvIcon { anchors.verticalCenter: parent.verticalCenter; name: "play"; size: 13; color: Theme.bg }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Play in wall"; color: Theme.bg
                                        font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold } }
                                MouseArea { id: pwMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: map._playSelected() }
                            }
                            Rectangle {                            // Clear
                                anchors.verticalCenter: parent.verticalCenter
                                width: clrT.implicitWidth + 20; height: 32; radius: 3
                                color: "transparent"; border.width: 1; border.color: clrMa.containsMouse ? Theme.ink3 : Theme.line2
                                Text { id: clrT; anchors.centerIn: parent; text: "Clear"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                                MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: map._clearSel() }
                            }
                        }
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
