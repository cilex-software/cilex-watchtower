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
    // Per-group event counts for the ACTIVE triage tab, over the UNscoped feed
    // (a scoped store would dishonestly zero every other group's cell).
    property var _gCounts: ({})
    readonly property string triageTab: triage.filter
    onTriageTabChanged: _recountGroups()
    function _recountGroups() {
        var lk = area._buildLookup();
        var rows = eventModel ? eventModel.all() : [];
        var out = ({ "": 0 });
        for (var i = 0; i < rows.length; i++) {
            var r = rows[i];
            var ts = r.triageState;
            var st = ts === "acknowledged" ? "ack" : ts === "in_progress" ? "progress"
                   : ts === "resolved" ? "resolved" : ts === "dismissed" ? "dismissed"
                   : ts === "new" ? "new" : (r.ack ? "ack" : "new");
            if (area.triageTab === "open" && !(st === "new" || st === "ack" || st === "progress")) continue;
            if (area.triageTab === "critical" && (r.severity ? r.severity : "medium") !== "critical") continue;
            var c = lk[r.camId];
            var z = c ? (c.zone || "") : "";
            out[z === "" ? "__ungrouped__" : z] = (out[z === "" ? "__ungrouped__" : z] || 0) + 1;
            out[""]++;
        }
        area._gCounts = out;
    }
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
                ip: (c.ip ? c.ip : ""),
                zone: (c.groupName ? c.groupName : ""), snapshotUrl: (c.snapshotUrl ? c.snapshotUrl : ""),
                // effective recording profile → the hero clips displayed roll to it
                recMode: (c.recProfileMode ? c.recProfileMode : ""),
                preRollMs: (c.recPreRollMs > 0 ? c.recPreRollMs : -1),
                postRollMs: (c.recPostRollMs > 0 ? c.recPostRollMs : -1),
                x: Math.round((col + 0.5) / cols * 100), y: Math.round((ri + 0.5) / rows * 100) };
        }
        return lk;
    }
    // Rapid sync (operator ask 2026-07-10): while the Events screen is visible,
    // top-merge the newest incidents every 10s — same incident model as the Live
    // sidebar, so the two can never drift. Identical payloads emit nothing.
    Timer {
        interval: 10000; repeat: true; triggeredOnStart: true
        running: area.visible && !area.demo && area.eventModel !== null
        onTriggered: area.eventModel.refreshIncremental()
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
        area._recountGroups();
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
        { id: "triage",   n: "01", label: qsTr("Triage Queue"),      tag: "Clear the backlog",
          why: "<font color='#f0ece4'><b>Inbox triage.</b></font> Work the queue top-down by priority — watch the event clip inline, run the response procedure, and record a disposition. Best when one operator must clear a backlog of unhandled alarms fast." },
        { id: "review",   n: "02", label: qsTr("Verify"),            tag: "See it · sort it",
          why: "<font color='#f0ece4'><b>Verify — Wall + Sessions in one screen.</b></font> Toggle between the snapshot <font color='#f0ece4'><b>Wall</b></font> (confirm a threat or dismiss a false alarm at a glance) and <font color='#f0ece4'><b>Smart Sessions</b></font> (motion fragments collapsed by zone, ranked by priority, bulk-acknowledged)." },
        { id: "timeline", n: "03", label: qsTr("Activity Timeline"), tag: "Patterns & investigation",
          why: "<font color='#f0ece4'><b>Forensic timeline.</b></font> One lane per camera across time; each event extends a bar to the right showing how long it lasted, so clusters and dwell-times become obvious. Best for investigating \"what happened between 5 and 8\"." },
        { id: "map",      n: "04", label: qsTr("Situation Map"),     tag: "Where is it happening",
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

        // ============ sub-nav (38px, gapless): modes · group strip · totals ============
        // Variant B density language: every control is a cell sharing 1px hairlines
        // (designs/handoff-camera-filter §2.5 + variant A §2.6 for the group strip).
        Rectangle {
            id: subnav
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            color: Theme.bg
            z: 30
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }

            // Measured fit: cell widths computed from FontMetrics in ONE pass and
            // written in one assignment (never reset-then-decrement — that needs a
            // repaint per step and silently no-ops when the reset writes the value
            // it already holds). gband.width in the binding = recompute on resize.
            FontMetrics { id: fmLbl; font.family: Theme.fontSans; font.pixelSize: 11 }
            FontMetrics { id: fmCnt; font.family: Theme.fontMono; font.pixelSize: 10 }
            function cellW(lbl, n) { return 24 + fmLbl.advanceWidth(lbl) + 8 + fmCnt.advanceWidth(String(n)); }

            property bool gpopOpen: false
            property real gpopX: 0

            RowLayout {
                anchors.fill: parent
                spacing: 0

                // ---- mode segmented control (rationale copy lives in the tooltip) ----
                Row {
                    Layout.fillHeight: true
                    Repeater {
                        model: area._modes
                        delegate: Rectangle {
                            id: mcell
                            required property var modelData
                            required property int index
                            readonly property bool _on: area.mode === modelData.id
                            height: 37
                            width: mRow.implicitWidth + 24
                            color: _on ? Theme.accent : (mMa.containsMouse ? Theme.panel2 : "transparent")
                            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                            Row {
                                id: mRow; anchors.centerIn: parent; spacing: 7
                                Text { anchors.verticalCenter: parent.verticalCenter; text: mcell.modelData.n
                                    color: mcell._on ? "#8a6417" : Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.9 }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: mcell.modelData.label
                                    color: mcell._on ? "#241a08" : (mMa.containsMouse ? Theme.ink2 : Theme.ink3)
                                    font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.9
                                    font.weight: mcell._on ? Font.Bold : Font.Normal }
                            }
                            MouseArea { id: mMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { area.mode = mcell.modelData.id; subnav.gpopOpen = false } }
                            ToolTip.visible: mMa.containsMouse
                            ToolTip.delay: 700
                            ToolTip.text: mcell.modelData.tag.toUpperCase() + " — "
                                          + String(mcell.modelData.why).replace(/<[^>]*>/g, "")
                        }
                    }
                }
                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.line2 }

                // ---- group strip (variant A §2.6, gapless) ----
                Item {
                    id: gband
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    // configured order, ACTIVE PROMOTED so it can never hide in +M
                    readonly property var gorder: {
                        var out = [];
                        for (var i = 0; i < area._groups.length; i++) out.push({ v: area._groups[i], l: area._groups[i] });
                        if (area._hasUngrouped) out.push({ v: "__ungrouped__", l: qsTr("Ungrouped") });
                        if (area.groupFilter !== "") {
                            var act = out.filter(function (g) { return g.v === area.groupFilter; });
                            var rest = out.filter(function (g) { return g.v !== area.groupFilter; });
                            out = act.concat(rest);
                        }
                        return out;
                    }
                    // one-pass computed fit; floors at 1 while a real group is active
                    readonly property int gvis: {
                        var avail = gband.width;
                        var used = subnav.cellW(qsTr("All groups"), area._gCounts[""] || 0);
                        var k = 0, ord = gband.gorder;
                        for (var i = 0; i < ord.length; i++) {
                            var tail = (i < ord.length - 1) ? subnav.cellW("+" + (ord.length - i - 1), "\u25be") : 0;
                            var w = subnav.cellW(ord[i].l, area._gCounts[ord[i].v] || 0);
                            if (used + w + tail <= avail) { used += w; k++; } else break;
                        }
                        return (area.groupFilter !== "" && k < 1) ? 1 : k;
                    }
                    readonly property var hidden: gorder.slice(gvis)

                    Row {
                        height: parent.height
                        component GCell: Rectangle {
                            id: gcell
                            property string v: ""
                            property string lbl: ""
                            property int n: 0
                            property bool isPlus: false
                            readonly property bool _on: !isPlus && area.groupFilter === v
                            height: 37
                            width: gRow.implicitWidth + 24
                            color: _on ? Theme.accentSoft : (gMa.containsMouse ? Theme.panel2 : "transparent")
                            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                            Rectangle { visible: gcell._on; anchors.bottom: parent.bottom; width: parent.width; height: 2; color: Theme.accent }
                            Row {
                                id: gRow; anchors.centerIn: parent; spacing: 8
                                Text { anchors.verticalCenter: parent.verticalCenter; text: gcell.lbl
                                    color: gcell._on ? Theme.accent : (gcell.n === 0 && !gcell.isPlus ? Theme.ink3 : (gMa.containsMouse ? Theme.ink : Theme.ink2))
                                    font.family: Theme.fontSans; font.pixelSize: 11 }
                                Text { anchors.verticalCenter: parent.verticalCenter
                                    text: gcell.isPlus ? "\u25be" : gcell.n
                                    color: gcell._on ? Theme.accent : Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 10 }
                            }
                            MouseArea {
                                id: gMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (gcell.isPlus) {
                                        subnav.gpopX = gcell.mapToItem(subnav, 0, 0).x;
                                        subnav.gpopOpen = !subnav.gpopOpen;
                                    } else { area.groupFilter = gcell.v; subnav.gpopOpen = false }
                                }
                            }
                        }
                        GCell { lbl: qsTr("All groups"); v: ""; n: area._gCounts[""] || 0 }
                        Repeater {
                            model: gband.gorder.slice(0, gband.gvis)
                            delegate: GCell {
                                required property var modelData
                                v: modelData.v; lbl: modelData.l; n: area._gCounts[modelData.v] || 0
                            }
                        }
                        GCell { visible: gband.hidden.length > 0; isPlus: true; lbl: "+" + gband.hidden.length }
                    }
                }
                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.line2 }

                // ---- section totals (pill cells) ----
                Row {
                    Layout.fillHeight: true
                    Repeater {
                        model: [ { dot: Theme.bad,    n: EventsStore.openCount,    l: qsTr("OPEN") },
                                 { dot: Theme.accent, n: EventsStore.critCount,    l: qsTr("CRITICAL") },
                                 { dot: Theme.good,   n: EventsStore.clearedCount, l: qsTr("CLEARED") } ]
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            height: 37; width: tRow.implicitWidth + 26
                            color: "transparent"
                            Rectangle { visible: index > 0; anchors.left: parent.left; width: 1; height: parent.height; color: Theme.line }
                            Row {
                                id: tRow; anchors.centerIn: parent; spacing: 6
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; color: modelData.dot }
                                Text { anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.n + " " + modelData.l
                                    color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.7 }
                            }
                        }
                    }
                }
            }

            // +M ▾ panel — a plain child Rectangle (never a Popup), under the button
            Rectangle {
                visible: subnav.gpopOpen && gband.hidden.length > 0
                x: Math.min(subnav.gpopX, subnav.width - width - 4)
                y: 38
                z: 40
                width: 206
                height: gpopCol.implicitHeight + 2
                color: Theme.panel; border.width: 1; border.color: Theme.line2
                Column {
                    id: gpopCol
                    x: 1; y: 1; width: parent.width - 2
                    Repeater {
                        model: gband.hidden
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool _on: area.groupFilter === modelData.v
                            width: gpopCol.width; height: 28
                            color: pMa.containsMouse ? Theme.panel2 : "transparent"
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                            Text { anchors.left: parent.left; anchors.leftMargin: 11; anchors.verticalCenter: parent.verticalCenter
                                text: modelData.l; color: parent._on ? Theme.accent : Theme.ink2
                                font.family: Theme.fontSans; font.pixelSize: 11 }
                            Text { anchors.right: parent.right; anchors.rightMargin: 11; anchors.verticalCenter: parent.verticalCenter
                                text: area._gCounts[modelData.v] || 0
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                            MouseArea { id: pMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { area.groupFilter = modelData.v; subnav.gpopOpen = false } }
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
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            StackLayout {
            anchors.fill: parent; clip: true
            currentIndex: area.mode === "triage" ? 0
                        : area.mode === "review" ? 1
                        : area.mode === "timeline" ? 2 : 3
            EvTriage { id: triage; selId: area.selId; playbackClient: heroClient; active: area.visible && area.mode === "triage"
                       onSelect: (id) => area.selId = id
                       onExportClip: (c, s, e, p) => area.exportClip(c, s, e, p) }
            Loader { property bool _seen: false; active: _seen; sourceComponent: reviewC
                     StackLayout.onIsCurrentItemChanged: if (StackLayout.isCurrentItem) _seen = true }
            Loader { property bool _seen: false; active: _seen; sourceComponent: timelineC
                     StackLayout.onIsCurrentItemChanged: if (StackLayout.isCurrentItem) _seen = true }
            Loader { property bool _seen: false; active: _seen; sourceComponent: mapC
                     StackLayout.onIsCurrentItemChanged: if (StackLayout.isCurrentItem) _seen = true }
            }
            MouseArea {                       // outside press closes the +M panel, then passes through
                anchors.fill: parent
                visible: subnav.gpopOpen
                z: 50
                onPressed: (m) => { subnav.gpopOpen = false; m.accepted = false }
            }
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
