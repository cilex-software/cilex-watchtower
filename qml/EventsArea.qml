import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import Watchtower

// The Events redesign area (port of designs/events-v2 app.jsx shell, minus the
// app-level rail/top bar which the real Watchtower shell already provides). It
// owns the Events-specific sub-chrome: the mode switcher (01–04) + rationale and
// the live OPEN / CRITICAL / CLEARED status strip, over ONE shared EventsStore.
// The stage hosts the four views; selection (selId) is shared across them.
Item {
    id: area
    property string mode: "triage"
    property string selId: ""                     // shared event selection across views

    // Data source. demo (or no eventModel) → the events-v2 mock showcase; otherwise
    // the live cilex-vision feed via EventModel + CameraModel, mapped honestly in
    // EventsStore.ingestReal (neutral severity, no fabricated fields).
    property var eventModel: null
    property var cameraModel: null
    property bool demo: false
    signal exportClip(string camId, double startMs, double endMs, string purpose)   // → Main's export flow
    signal openWall(var camIds)                                    // Situation-Map selection → wall playback
    signal openLive(var camIds)                                    // Situation-Map selection → live grid
    readonly property int _camCount: cameraModel ? cameraModel.total : 0

    // Camera-group scope: "" = all, "__ungrouped__" = cameras with no group, else a
    // group name. Filters every view (queue, wall/sessions, timeline lanes, map pins).
    property string groupFilter: ""
    readonly property var _groups: {
        var seen = ({}), out = [];
        var n = cameraModel ? cameraModel.total : 0;
        for (var i = 0; i < n; i++) {
            var c = cameraModel.get(i);
            var g = (c && c.groupName) ? c.groupName : "";
            if (g !== "" && !seen[g]) { seen[g] = true; out.push(g); }
        }
        out.sort();
        return out;
    }
    readonly property bool _hasUngrouped: {
        var n = cameraModel ? cameraModel.total : 0;
        for (var i = 0; i < n; i++) { var c = cameraModel.get(i); if (c && c.camId && !c.groupName) return true; }
        return false;
    }
    onGroupFilterChanged: if (!demo && eventModel) area._ingestReal()

    // WT_GUARD_SOAK: select a random playable event → drives the hero player (i.e. "play a video").
    // Works from whatever tab is active (selId is shared across triage/review/timeline/map).
    function selectRandomEvent() {
        if (typeof EventsStore === "undefined" || !EventsStore.events) return;
        var es = EventsStore.events.filter(function (e) { return e.cam && e.cam.id && e.durationSec >= 2; });
        if (es.length > 0) area.selId = es[Math.floor(Math.random() * es.length)].id;
    }

    function _buildLookup() {
        var lk = ({});
        var n = cameraModel ? cameraModel.total : 0;
        var cols = Math.max(1, Math.ceil(Math.sqrt(n)));
        var rows = Math.max(1, Math.ceil(n / cols));
        for (var i = 0; i < n; i++) {
            var c = cameraModel.get(i);
            if (!c || !c.camId) continue;
            var col = i % cols, ri = Math.floor(i / cols);
            // No site-plan coords from the backend yet — spread pins on a grid so the
            // Map stays usable (a layout fallback, not invented positions).
            lk[c.camId] = { key: c.camId, id: c.camId, name: (c.name ? c.name : c.camId),
                zone: (c.groupName ? c.groupName : ""), snapshotUrl: (c.snapshotUrl ? c.snapshotUrl : ""),
                x: Math.round((col + 0.5) / cols * 100), y: Math.round((ri + 0.5) / rows * 100) };
        }
        return lk;
    }
    function _ingestReal() {
        if (!eventModel) { EventsStore.loadMock(); return; }
        var fullLk = area._buildLookup();
        var lk = fullLk, rows = eventModel.all();
        if (groupFilter !== "") {                       // scope cams + events to the group
            lk = ({});
            for (var k in fullLk) {
                var z = fullLk[k].zone;
                if ((groupFilter === "__ungrouped__") ? (!z || z === "") : (z === groupFilter)) lk[k] = fullLk[k];
            }
            rows = rows.filter(function (r) { return lk[r.camId] !== undefined; });
        }
        EventsStore.ingestReal(rows, lk);
    }

    Component.onCompleted: {
        if (typeof wtEventsView !== "undefined" && wtEventsView)   // dev: open a sub-view directly
            area.mode = wtEventsView;
        if (demo || !eventModel) {
            EventsStore.loadMock();
        } else {
            EventsStore.realAck = function (id) { if (area.eventModel) area.eventModel.acknowledgeById(id); };
            EventsStore.realDispose = function (id, d, note) { if (area.eventModel) area.eventModel.setDisposition(id, d, note); };
            EventsStore.realBookmark = function (id, value) { if (area.eventModel) area.eventModel.setBookmark(id, value); };
            EventsStore.realAssign = function (id, who) { if (area.eventModel) area.eventModel.assignEvent(id, who); };
            area.eventModel.fetchOperators();
            EventsStore.operators = area.eventModel.operators();
            area._ingestReal();
        }
    }
    Connections {
        target: area.eventModel
        enabled: !area.demo && area.eventModel !== null
        function onChanged() { area._ingestReal(); }
        function onOperatorsChanged() { EventsStore.operators = area.eventModel.operators(); }
    }
    on_CamCountChanged: if (!demo && eventModel) area._ingestReal()    // cameras load async → re-resolve names/zones

    // Dedicated playback client for the Triage hero's inline recording (real mode),
    // isolated from the main Playback screen's session so they never collide.
    PlaybackClient { id: heroClient }

    // ===== Events stress-test driver (WT_EVENTS_TEST) =====
    // For 15 min, cycles tabs + selects events to stress the Events area, and times each event-select
    // to the hero playback session opening (click -> playback-open). [EV] lines feed the analyzer.
    property bool   _evActive: (typeof wtEventsTest !== "undefined" && wtEventsTest === true)
    property double _evStart: 0
    property int    _evN: 0
    property double _evOpenT0: -1
    Timer {
        id: _evBoot; interval: 500; repeat: true; running: area._evActive
        onTriggered: {
            if (EventsStore.events.length > 0) {
                _evBoot.stop(); area._evStart = Date.now();
                console.log("[EV] BEGIN events=" + EventsStore.events.length + " t=" + Date.now());
                _evTick.start();
            }
        }
    }
    Connections {
        target: heroClient; enabled: area._evActive
        function onSessionReady(sid, dur, frags, meta) {
            if (area._evOpenT0 >= 0) {
                console.log("[EV] open lat=" + (Date.now() - area._evOpenT0) + " t=" + Date.now());
                area._evOpenT0 = -1;
            }
        }
    }
    Timer {
        id: _evTick; interval: 1500; repeat: true; running: false
        readonly property var tabs: ["triage", "review", "timeline", "map"]
        onTriggered: {
            if (Date.now() - area._evStart > 900000) {
                console.log("[EV] DONE n=" + area._evN + " t=" + Date.now()); Qt.quit(); return;
            }
            area._evN++;
            if (Math.random() < 0.5 && EventsStore.events.length > 0) {
                area.mode = "triage";
                var ev = EventsStore.events[Math.floor(Math.random() * EventsStore.events.length)];
                area._evOpenT0 = Date.now();
                area.selId = ev.id;
                console.log("[EV] select id=" + ev.id + " n=" + area._evN + " t=" + Date.now());
            } else {
                var tb = _evTick.tabs[Math.floor(Math.random() * 4)];
                area.mode = tb;
                console.log("[EV] tab=" + tb + " n=" + area._evN + " t=" + Date.now());
            }
        }
    }

    readonly property var _modes: [
        { id: "triage",   n: "01", label: "Triage Queue",      tag: "Clear the backlog",
          why: "<font color='#f0ece4'><b>Inbox triage.</b></font> Work the queue top-down by priority — watch the event clip inline, run the response procedure, and record a disposition. Best when one operator must clear a backlog of unhandled alarms fast." },
        { id: "review",   n: "02", label: "Verify",            tag: "See it · sort it",
          why: "<font color='#f0ece4'><b>Verify — Wall + Sessions in one screen.</b></font> Toggle between the snapshot <font color='#f0ece4'><b>Wall</b></font> (confirm a threat or dismiss a false alarm at a glance) and <font color='#f0ece4'><b>Smart Sessions</b></font> (motion fragments collapsed by zone, ranked by priority, bulk-acknowledged)." },
        { id: "timeline", n: "03", label: "Activity Timeline", tag: "Patterns & investigation",
          why: "<font color='#f0ece4'><b>Forensic timeline.</b></font> One lane per camera across time; each event extends a bar to the right showing how long it lasted, so clusters and dwell-times become obvious. Best for investigating \"what happened between 5 and 8\"." },
        { id: "map",      n: "04", label: "Situation Map",     tag: "Where is it happening",
          why: "<font color='#f0ece4'><b>Spatial awareness.</b></font> Events pulse on the site plan where they physically occur. Best for supervisors and owners who think in places, not log lines, and need to dispatch in context." }
    ]
    readonly property var _curMode: {
        for (var i = 0; i < _modes.length; i++) if (_modes[i].id === mode) return _modes[i];
        return _modes[0];
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ============ mode bar: switcher + rationale + status strip ============
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(58, modeRow.implicitHeight + 16)
            color: Theme.bg
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }

            RowLayout {
                id: modeRow
                anchors.fill: parent
                anchors.leftMargin: 20; anchors.rightMargin: 20
                spacing: 16

                // ---- mode switcher (segmented) ----
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: 40
                    Layout.preferredWidth: seg.implicitWidth
                    color: Theme.panel; border.width: 1; border.color: Theme.line2
                    Row {
                        id: seg
                        height: parent.height
                        Repeater {
                            model: area._modes
                            delegate: Rectangle {
                                id: segBtn
                                required property var modelData
                                required property int index
                                readonly property bool _active: area.mode === modelData.id
                                height: seg.height
                                width: segRow.implicitWidth + 32
                                color: _active ? Theme.accent : (segMa.containsMouse ? Theme.panel2 : Theme.panel)
                                Rectangle { visible: segBtn.index < area._modes.length - 1
                                    anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Row {
                                    id: segRow; anchors.centerIn: parent; spacing: 8
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: segBtn.modelData.n
                                        color: segBtn._active ? Qt.rgba(26/255, 24/255, 22/255, 0.6) : Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 10 }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: segBtn.modelData.label
                                        color: segBtn._active ? Theme.bg : (segMa.containsMouse ? Theme.ink : Theme.ink2)
                                        font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                                }
                                MouseArea { id: segMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: area.mode = segBtn.modelData.id }
                            }
                        }
                    }
                }

                // ---- camera-group scope ----
                Rectangle {
                    id: grpBtn
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: 32; Layout.preferredWidth: 168
                    color: grpMa.containsMouse ? Theme.panel2 : Theme.panel
                    border.width: 1; border.color: area.groupFilter !== "" ? Theme.accent : Theme.line2
                    EvIcon { id: grpChev; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                        name: "chev"; size: 12; rotation: 90; color: Theme.ink3 }
                    Text {
                        anchors.left: parent.left; anchors.leftMargin: 11; anchors.right: grpChev.left; anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight
                        text: area.groupFilter === "" ? "All groups" : area.groupFilter === "__ungrouped__" ? "Ungrouped" : area.groupFilter
                        color: area.groupFilter !== "" ? Theme.accent : Theme.ink2
                        font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold
                    }
                    MouseArea { id: grpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: grpPop.opened ? grpPop.close() : grpPop.open() }
                    Popup {
                        id: grpPop
                        y: grpBtn.height + 4; x: 0; width: 188; padding: 1
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                        background: Rectangle { color: Theme.panel2; border.width: 1; border.color: Theme.line2 }
                        contentItem: Column {
                            id: grpCol
                            Repeater {
                                model: {
                                    var m = [{ v: "", l: "All groups" }];
                                    for (var i = 0; i < area._groups.length; i++) m.push({ v: area._groups[i], l: area._groups[i] });
                                    if (area._hasUngrouped) m.push({ v: "__ungrouped__", l: "Ungrouped" });
                                    return m;
                                }
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool _on: area.groupFilter === modelData.v
                                    width: grpCol.width; height: 30
                                    color: gma.containsMouse ? Theme.panel3 : (_on ? Theme.accentSoft : "transparent")
                                    Text { anchors.left: parent.left; anchors.leftMargin: 11; anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.l; color: parent._on ? Theme.accent : Theme.ink
                                        font.family: Theme.fontSans; font.pixelSize: 12 }
                                    MouseArea { id: gma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { area.groupFilter = modelData.v; grpPop.close() } }
                                }
                            }
                        }
                    }
                }

                // ---- rationale (tag + why) ----
                ColumnLayout {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.maximumWidth: 440
                    Layout.fillWidth: true
                    spacing: 2
                    Text { text: area._curMode.tag.toUpperCase(); color: Theme.accent
                        font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.0 }
                    Text { Layout.fillWidth: true; text: area._curMode.why; color: Theme.ink2
                        textFormat: Text.StyledText; wrapMode: Text.WordWrap; lineHeight: 1.25
                        font.family: Theme.fontSans; font.pixelSize: 12 }
                }

                Item { Layout.fillWidth: true }

                // ---- status strip (OPEN / CRITICAL / CLEARED) ----
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: 38
                    Layout.preferredWidth: chipRow.implicitWidth
                    color: Theme.panel; border.width: 1; border.color: Theme.line2
                    Row {
                        id: chipRow
                        height: parent.height
                        Repeater {
                            model: [ { dot: Theme.bad,    n: EventsStore.openCount,    l: "open" },
                                     { dot: Theme.accent, n: EventsStore.critCount,    l: "critical" },
                                     { dot: Theme.good,   n: EventsStore.clearedCount, l: "cleared" } ]
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                height: chipRow.height; width: cRow.implicitWidth + 28; color: "transparent"
                                Rectangle { visible: index < 2; anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Row {
                                    id: cRow; anchors.centerIn: parent; spacing: 8
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; color: modelData.dot }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.n; color: Theme.ink
                                        font.family: Theme.fontSans; font.pixelSize: 18; font.weight: Font.Bold }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l.toUpperCase(); color: Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 11; font.letterSpacing: 0.9 }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ============ stage — the active view ============
        // The old Loader recreated a view on every tab-switch; recreating ANY view interleaved with event
        // selections leaked ~+44 MB/min (measured: select-only flat, tab-only flat, but select+recreate
        // leaks — and keeping only Triage alive still leaked). So views must persist once created.
        // Triage (default + most-used) is always resident; the other three LAZY-load on first visit and
        // then STAY (latched `active` — never destroyed, so no recreate-leak). A triage-focused session
        // keeps the low ~580MB baseline; only the tabs an operator actually opens add their cost.
        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
            currentIndex: area.mode === "triage" ? 0
                        : area.mode === "review" ? 1
                        : area.mode === "timeline" ? 2 : 3
            EvTriage { selId: area.selId; playbackClient: heroClient; active: area.visible && area.mode === "triage"
                       onSelect: (id) => area.selId = id
                       onExportClip: (c, s, e, p) => area.exportClip(c, s, e, p) }
            Loader { property bool _seen: false; active: _seen; sourceComponent: reviewC
                     StackLayout.onIsCurrentItemChanged: if (StackLayout.isCurrentItem) _seen = true }
            Loader { property bool _seen: false; active: _seen; sourceComponent: timelineC
                     StackLayout.onIsCurrentItemChanged: if (StackLayout.isCurrentItem) _seen = true }
            Loader { property bool _seen: false; active: _seen; sourceComponent: mapC
                     StackLayout.onIsCurrentItemChanged: if (StackLayout.isCurrentItem) _seen = true }
        }
    }

    Component { id: reviewC;   EvVerify   { onOpenInTriage: (id) => { area.selId = id; area.mode = "triage"; } } }
    Component { id: timelineC; EvTimeline { onOpenInTriage: (id) => { area.selId = id; area.mode = "triage"; } } }
    Component { id: mapC;      EvMap {
        onOpenInTriage: (id) => { area.selId = id; area.mode = "triage"; }
        onOpenWall: (ids) => area.openWall(ids)
        onOpenLive: (ids) => area.openLive(ids)
    } }
}
