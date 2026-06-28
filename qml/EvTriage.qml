import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import Watchtower

// VIEW 01 — TRIAGE QUEUE (port of view-triage.jsx / triage-queue-spec.md).
// 2-column: 384px priority list | fluid detail pane that plays the event clip
// inline, with the facts grid, per-type SOP checklist, disposition note, and the
// action bar. Reads EventsStore; mutates only via EventsStore.ack/bookmark/dispose.
Item {
    id: tri
    property string selId: ""                    // shared selection (owned by EventsArea)
    property var playbackClient: null            // real-mode inline playback (EvHeroPlayer)
    property bool active: false                   // Events screen visible → keyboard shortcuts live
    signal select(string id)
    signal exportClip(string camId, double startMs, double endMs, string purpose)   // bubbles to Main's export flow

    // move the selection up/down the sorted queue (keyboard ↑/↓)
    function _moveSel(d) {
        var l = tri._list; if (!l.length) return;
        var idx = 0;
        for (var i = 0; i < l.length; i++) if (tri._cur && l[i].id === tri._cur.id) { idx = i; break; }
        tri.select(l[Math.max(0, Math.min(l.length - 1, idx + d))].id);
    }
    // E acknowledge · ↑/↓ move selection · Space play/pause — only when the Events
    // screen is up and the disposition note isn't being typed in.
    Shortcut { sequence: "E"; enabled: tri.active && tri._cur && tri._cur.status === "new" && !noteIn.activeFocus
        onActivated: if (tri._cur) EventsStore.ack(tri._cur.id) }
    Shortcut { sequence: "Up"; enabled: tri.active && !noteIn.activeFocus; onActivated: tri._moveSel(-1) }
    Shortcut { sequence: "Down"; enabled: tri.active && !noteIn.activeFocus; onActivated: tri._moveSel(1) }
    Shortcut { sequence: "Space"; enabled: tri.active && !noteIn.activeFocus
        onActivated: if (heroLoader.item && heroLoader.item.toggle) heroLoader.item.toggle() }

    // ---- WT_HERO_TEST: random-event + scrubber-jump latency stress (inert unless wtHeroTest set) ----
    // Randomly select events (→ hero auto-opens via WT_HERO_AUTOPLAY; we time click→first-frame), then jump
    // +/-1s/10s/30s/1m/5m as the episode length allows, 100 iters/step, timing seek→first-rendered-frame.
    // The hero logs the precise [HT] latencies (frame-signal based); this state machine just sequences them.
    property var _htSteps: [1000, 10000, 30000, 60000, 300000]
    property var _htCount: ({})
    property int _htJumps: 0
    property int _htEvSeeks: 0
    property int _htWaits: 0
    property string _htState: "init"
    readonly property var _ht: heroLoader.item
    readonly property bool _htRun: (typeof wtHeroTest !== "undefined" && wtHeroTest === true) && tri.active && EventsStore.realMode
    readonly property bool _htOpenonly: (typeof wtHeroOpenonly !== "undefined" && wtHeroOpenonly === true)  // leak bisect: open events, no seeks
    property int _htOpens: 0
    Timer {
        interval: 30; repeat: true; running: tri._htRun
        onTriggered: tri._htTick()
    }
    function _htTick() {
        if (_htState === "init") {
            if (EventsStore.events.length === 0) return;        // wait for the real feed to load
            for (var i = 0; i < _htSteps.length; i++) _htCount[_htSteps[i]] = 0;
            console.log("[HT] BEGIN events=" + EventsStore.events.length + " t=" + Date.now());
            _htState = "sel"; return;
        }
        if (_htState === "sel") { _htSelect(); _htState = "waitopen"; _htWaits = 0; return; }
        if (_htState === "waitopen") {
            var ready = _htOpenonly ? (_ht && _ht._armed && !_ht._loading)             // openonly: session ready (no decode/frame needed)
                                    : (_ht && !_ht._htOpenPending && _ht.testFrames > 0 && _ht.testDurMs > 1500);
            if (ready) { _htEvSeeks = 0; _htWaits = 0; _htState = "settle"; }
            else if (++_htWaits > 500) { console.log("[HT] OPEN TIMEOUT t=" + Date.now()); _htState = "sel"; }   // 15s
            return;
        }
        if (_htState === "settle") {                    // let the player play + buffer ahead before seeking
            if (++_htWaits >= 70) {                      // ~2s
                _htWaits = 0;
                if (_htOpenonly) { _htOpens++; if (_htOpens % 20 === 0) console.log("[HT] OPENONLY opens=" + _htOpens + " t=" + Date.now()); _htState = "sel"; }
                else _htState = "seek";
            }
            return;
        }
        if (_htState === "seek") {
            if (_htDone()) { console.log("[HT] DONE jumps=" + _htJumps + _htSummary() + " t=" + Date.now()); Qt.quit(); return; }
            if (_htEvSeeks >= 20) { _htState = "sel"; return; }       // periodically re-open for fresh events too
            var step = _htPickStep();
            if (step <= 0) { _htState = "sel"; return; }
            _ht.testSeek((Math.random() < 0.5 ? 1 : -1) * step);
            _htCount[step] = (_htCount[step] || 0) + 1; _htJumps++; _htEvSeeks++;
            _htState = "waitseek"; _htWaits = 0; return;
        }
        if (_htState === "waitseek") {
            if (_ht && !_ht._htSeekPending) { _htState = "seek"; _htWaits = 0; }       // rendered → next seek same episode
            else if (++_htWaits > 60) {                                                // ~1.8s with no frame = frozen
                console.log("[HT] SEEK TIMEOUT req=" + (_ht ? _ht._htSeekReq : 0) + " t=" + Date.now());
                if (_ht) _ht._htSeekPending = false;
                _htState = "sel"; _htWaits = 0;                                        // a frozen seek sticks the episode → re-open
            }
            return;
        }
    }
    function _htSelect() {
        if (_htOpenonly) {                                  // leak bisect: just open a fresh event (≠ current), no seeks
            var es = EventsStore.events.filter(function (e) { return e.cam && e.cam.id && e.durationSec >= 2 && e.id !== tri.selId; });
            if (es.length) tri.select(es[Math.floor(Math.random() * es.length)].id);
            return;
        }
        var need = _htSteps.filter(function (s) { return (_htCount[s] || 0) < 100; });
        var want = need.length ? need[Math.floor(Math.random() * need.length)] : _htSteps[Math.floor(Math.random() * _htSteps.length)];
        var evs = EventsStore.events.filter(function (e) { return e.cam && e.cam.id && (e.durationSec * 1000) >= (want + 4000); });
        if (!evs.length) evs = EventsStore.events.filter(function (e) { return e.cam && e.cam.id && e.durationSec >= 2; });
        if (evs.length) tri.select(evs[Math.floor(Math.random() * evs.length)].id);
    }
    function _htPickStep() {
        var dur = _ht ? _ht.testDurMs : 0;
        var feas = _htSteps.filter(function (s) { return (s + 4000) <= dur && (_htCount[s] || 0) < 100; });
        if (!feas.length) feas = _htSteps.filter(function (s) { return (s + 4000) <= dur; });
        if (!feas.length) return -1;
        feas.sort(function (a, b) { return (_htCount[a] || 0) - (_htCount[b] || 0); });
        return feas[0];
    }
    function _htDone() {
        if (_htJumps >= 360) return true;                       // hard cap (frozen seeks force a slow re-open each)
        if (_htJumps < 300) return false;
        for (var i = 0; i < _htSteps.length; i++) if ((_htCount[_htSteps[i]] || 0) < 100) return false;
        return true;
    }
    function _htSummary() { var s = ""; for (var i = 0; i < _htSteps.length; i++) s += " " + (_htSteps[i] / 1000) + "s=" + (_htCount[_htSteps[i]] || 0); return s; }

    property string filter: "open"               // open | critical | all
    property string note: ""
    property var done: ({})                       // local SOP ticks, reset per event

    // priority → recency, filtered by the active tab
    readonly property var _list: {
        var es = EventsStore.events.filter(function (e) {
            if (tri.filter === "open") return e.status === "new" || e.status === "ack" || e.status === "progress";
            if (tri.filter === "critical") return e.priority === "critical";
            return true;
        });
        es.sort(function (a, b) {
            return (EventsStore.sevRank[a.priority] - EventsStore.sevRank[b.priority]) || (b.ts.getTime() - a.ts.getTime());
        });
        return es;
    }
    readonly property var _cur: EventsStore.find(tri.selId) || (_list.length ? _list[0] : null)
    readonly property int _openCount: EventsStore.events.filter(function (e) { return e.status === "new" || e.status === "ack" || e.status === "progress"; }).length
    readonly property int _critTab: EventsStore.events.filter(function (e) { return e.priority === "critical"; }).length

    // reset note + SOP ticks whenever the selected event changes
    property string _curId: _cur ? _cur.id : ""
    on_CurIdChanged: { note = ""; done = ({}); }

    readonly property var _sops: ({
        "_default":   ["Watch the clip + confirm subject type", "Confirm intent", "Record disposition"],
        "person":     ["Watch playback at event time", "Confirm person vs. authorized staff (check badge log)", "If unauthorized after-hours → dispatch / call keyholder", "Record disposition + notes"],
        "line_cross": ["Watch the crossing clip", "Verify direction (inbound = priority)", "Escalate to supervisor + dispatch patrol", "Notify keyholder, log incident"],
        "tamper":     ["Switch to nearest overlapping camera", "Verify obstruction vs. fault", "Dispatch to inspect device", "Raise maintenance ticket"],
        "vehicle":    ["Watch playback, read plate if visible", "Check against expected deliveries", "If in fire lane > limit → tannoy / dispatch", "Record disposition"],
        "loiter":     ["Watch the dwell clip", "Assess intent / duration", "Tannoy warning or dispatch", "Log disposition"],
        "offline":    ["Check device health page", "Confirm network vs. power", "Raise maintenance ticket", "Cover area with adjacent camera"],
        "motion":     ["Scrub the motion clip", "Confirm environmental vs. real", "Dismiss or escalate"]
    })
    readonly property var _sop: _cur ? (_sops[_cur.type] || _sops["_default"]) : []

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ======================= LEFT — the queue =======================
        Rectangle {
            Layout.preferredWidth: 384
            Layout.fillHeight: true
            color: "transparent"
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }  // right border

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // ---- filter tabs ----
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 45
                    color: "transparent"
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: 14
                        anchors.bottom: parent.bottom
                        spacing: 4
                        Repeater {
                            model: [ { k: "open",     l: "Open queue", n: tri._openCount },
                                     { k: "critical", l: "Critical",   n: tri._critTab },
                                     { k: "all",      l: "All",        n: EventsStore.events.length } ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool _active: tri.filter === modelData.k
                                height: 34; width: tabRow.implicitWidth + 24; color: "transparent"
                                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: parent._active ? Theme.accent : "transparent" }
                                Row {
                                    id: tabRow; anchors.centerIn: parent; spacing: 7
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l
                                        color: parent.parent._active ? Theme.ink : Theme.ink2
                                        font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: 15; width: nT.implicitWidth + 12; color: Theme.panel2
                                        Text { id: nT; anchors.centerIn: parent; text: modelData.n
                                            color: parent.parent.parent._active ? Theme.accent : Theme.ink3
                                            font.family: Theme.fontMono; font.pixelSize: 10 }
                                    }
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tri.filter = modelData.k }
                            }
                        }
                    }
                }

                // ---- scrolling list ----
                ListView {
                    id: listView
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    model: tri._list
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        readonly property var e: modelData
                        readonly property bool _on: tri._cur && e.id === tri._cur.id
                        width: ListView.view.width; height: 67
                        color: _on ? Theme.panel2 : (rowMa.containsMouse ? Theme.panel : "transparent")
                        opacity: e.status !== "new" ? 0.5 : 1
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                        Rectangle { visible: row._on; anchors.left: parent.left; width: 3; height: parent.height; color: Theme.accent }  // selection bar

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 16; anchors.rightMargin: 16
                            spacing: 11

                            // severity dot (+ halo on critical)
                            Item {
                                Layout.preferredWidth: 8; Layout.preferredHeight: 8; Layout.alignment: Qt.AlignVCenter
                                Rectangle { visible: row.e.priority === "critical"; anchors.centerIn: parent; width: 14; height: 14; radius: 7; color: Theme.badSoft }
                                Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: 4; color: Theme.sevColor(row.e.priority) }
                            }
                            // thumbnail + duration badge
                            Rectangle {
                                Layout.preferredWidth: 74; Layout.preferredHeight: 42; Layout.alignment: Qt.AlignVCenter
                                color: "#000"; border.width: 1; border.color: Theme.line; clip: true
                                EvSnapshot { anchors.fill: parent; anchors.margins: 1; ev: row.e; mini: true; showOsd: false }
                                Rectangle {
                                    visible: row.e.durationSec > 0
                                    anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 2
                                    color: Qt.rgba(0, 0, 0, 0.7); height: 11; width: dB.implicitWidth + 6
                                    Text { id: dB; anchors.centerIn: parent; text: EventsStore.dur(row.e.durationSec); color: "#fff"
                                        font.family: Theme.fontMono; font.pixelSize: 8 }
                                }
                            }
                            // meta
                            ColumnLayout {
                                Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
                                spacing: 4
                                TypePill { type: row.e.type }
                                Text { Layout.fillWidth: true; text: row.e.cam.name; color: Theme.ink; elide: Text.ElideRight
                                    font.family: Theme.fontSans; font.pixelSize: 12 }
                                Text { text: EventsStore.hhmmss(row.e.ts) + " · " + EventsStore.rel(row.e.ts); color: Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 10 }
                            }
                            // state dot
                            StateTag { state: row.e.status; dotOnly: true; dotSize: 7; Layout.alignment: Qt.AlignVCenter }
                        }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tri.select(row.e.id) }
                    }
                }
            }
        }

        // ======================= RIGHT — the detail =======================
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true

            // empty state
            Text {
                visible: !tri._cur; anchors.centerIn: parent
                text: "Queue clear — no open events."; color: Theme.ink3
                font.family: Theme.fontSans; font.pixelSize: 14
            }

            ColumnLayout {
                visible: tri._cur !== null
                anchors.fill: parent
                spacing: 0

                // ---- hero: inline player + tool row ----
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: heroCol.implicitHeight
                    color: "#000"
                    ColumnLayout {
                        id: heroCol
                        width: parent.width
                        spacing: 0
                        // mock → procedural EvPlayer; real → EvHeroPlayer (live recording)
                        Loader {
                            id: heroLoader
                            Layout.fillWidth: true
                            sourceComponent: EventsStore.realMode ? heroRealC : heroMockC
                        }
                        Rectangle {                          // tool row
                            Layout.fillWidth: true; Layout.preferredHeight: 52; color: Theme.panel
                            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 8
                                EvButton { small: true; variant: "ghost"; icon: "export"; label: "Export clip"
                                    enabledBtn: tri._cur && EventsStore.realMode
                                    onClicked: {
                                        if (!tri._cur) return;
                                        var w = EventsStore.episodeWindow(tri._cur);   // export the whole episode (footage span), not a forward 1-min window
                                        tri.exportClip(tri._cur.cam.id, w.startMs - 15000,
                                            w.endMs > w.startMs ? w.endMs + 15000 : w.startMs + 45000,
                                            "Event · " + (EventsStore.types[tri._cur.type] ? EventsStore.types[tri._cur.type].label : tri._cur.type));
                                    } }
                                EvButton {
                                    id: assignBtn
                                    small: true; variant: "ghost"; icon: "assign"
                                    on: tri._cur && tri._cur.assignedTo
                                    label: (tri._cur && tri._cur.assignedTo) ? tri._cur.assignedTo : "Assign"
                                    onClicked: assignPop.opened ? assignPop.close() : assignPop.open()

                                    Popup {
                                        id: assignPop
                                        x: 0; y: assignBtn.height + 4
                                        width: 214; padding: 1
                                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                                        background: Rectangle { color: Theme.panel2; border.width: 1; border.color: Theme.line2 }
                                        contentItem: Column {
                                            id: pickCol
                                            Text { width: parent.width; height: 26; leftPadding: 10; verticalAlignment: Text.AlignVCenter
                                                text: "ASSIGN TO"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.0 }
                                            Repeater {
                                                model: EventsStore.operators
                                                delegate: Rectangle {
                                                    required property var modelData
                                                    readonly property bool _isCur: tri._cur && tri._cur.assignedTo === modelData.username
                                                    width: pickCol.width; height: 30
                                                    color: opMa.containsMouse ? Theme.panel3 : (_isCur ? Theme.accentSoft : "transparent")
                                                    Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                                        text: modelData.display_name ? modelData.display_name : modelData.username
                                                        color: parent._isCur ? Theme.accent : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12 }
                                                    Text { anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                                        text: modelData.role; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                                                    MouseArea { id: opMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: { if (tri._cur) EventsStore.assign(tri._cur.id, modelData.username); assignPop.close() } }
                                                }
                                            }
                                            Rectangle { visible: tri._cur && tri._cur.assignedTo; width: pickCol.width; height: 1; color: Theme.line }
                                            Rectangle {
                                                visible: tri._cur && tri._cur.assignedTo
                                                width: pickCol.width; height: 30; color: unMa.containsMouse ? Theme.panel3 : "transparent"
                                                Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                                    text: "Unassign"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                                                MouseArea { id: unMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { if (tri._cur) EventsStore.assign(tri._cur.id, ""); assignPop.close() } }
                                            }
                                            Text { visible: !EventsStore.operators || EventsStore.operators.length === 0
                                                width: parent.width; height: 30; leftPadding: 10; verticalAlignment: Text.AlignVCenter
                                                text: "No operators available"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
                                        }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                EvButton {
                                    small: true; variant: "ghost"
                                    enabledBtn: !EventsStore.actionsPending
                                    on: tri._cur && tri._cur.bookmarked
                                    icon: (tri._cur && tri._cur.bookmarked) ? "bookmarkF" : "bookmark"
                                    label: (tri._cur && tri._cur.bookmarked) ? "Saved" : "Bookmark"
                                    onClicked: if (tri._cur) EventsStore.bookmark(tri._cur.id)
                                }
                            }
                        }
                    }
                }

                // ---- body (scrolls) ----
                Flickable {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: body.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }

                    ColumnLayout {
                        id: body
                        width: parent.width
                        x: 22; y: 18
                        // 22px right padding too → cap width
                        Component.onCompleted: width = parent.width - 44
                        Connections { target: body.parent; function onWidthChanged() { body.width = body.parent.width - 44; } }
                        spacing: 0

                        // headline
                        RowLayout {
                            Layout.fillWidth: true; spacing: 16
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 4
                                RowLayout {
                                    spacing: 12
                                    Text { text: tri._cur ? EventsStore.types[tri._cur.type].label : ""; color: Theme.ink
                                        font.family: Theme.fontSans; font.pixelSize: 20; font.weight: Font.DemiBold }
                                    Rectangle {
                                        visible: tri._cur && tri._cur.restricted
                                        height: 18; width: rzT.implicitWidth + 12; color: "transparent"
                                        border.width: 1; border.color: Theme.badDim
                                        Text { id: rzT; anchors.centerIn: parent; text: "RESTRICTED ZONE"; color: Theme.bad
                                            font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.9 }
                                    }
                                }
                                Text { Layout.fillWidth: true; text: (tri._cur && tri._cur.note) ? tri._cur.note : "—"; color: Theme.ink2
                                    wrapMode: Text.WordWrap; font.family: Theme.fontSans; font.pixelSize: 13 }
                            }
                            Sev { level: tri._cur ? tri._cur.priority : "low"; Layout.alignment: Qt.AlignTop }
                        }

                        // facts grid (2-col, 1px gridlines)
                        Rectangle {
                            Layout.fillWidth: true; Layout.topMargin: 18; Layout.bottomMargin: 18
                            color: Theme.line
                            Layout.preferredHeight: facts.implicitHeight + 2
                            // Grid POSITIONER (not GridLayout): a QQuickGridLayout SIGSEGVs on
                            // minimize/restore in Qt 6.4.2 (see LiveMonitor camera grid). Grid has no
                            // layout engine to corrupt. Cells get an explicit width (2 equal columns).
                            Grid {
                                id: facts
                                x: 1; y: 1; width: parent.width - 2
                                columns: 2; rowSpacing: 1; columnSpacing: 1
                                Repeater {
                                    model: tri._cur ? [
                                        { k: "Camera",        v: tri._cur.cam.name, mono: false },
                                        { k: "Device",        v: tri._cur.cam.id,   mono: true },
                                        { k: "Zone",          v: tri._cur.cam.zone, mono: false },
                                        { k: "Time",          v: EventsStore.hhmmss(tri._cur.ts) + " · " + Qt.formatDate(tri._cur.ts, "ddd dd MMM"), mono: true },
                                        { k: "Clip length",   v: tri._cur.durationSec ? EventsStore.dur(tri._cur.durationSec) : "—", mono: true },
                                        { k: "AI confidence", v: tri._cur.conf ? (Math.round(tri._cur.conf * 100) + "%") : "n/a", mono: true }
                                    ] : []
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: (facts.width - facts.columnSpacing) / 2
                                        height: 52
                                        color: Theme.bg
                                        ColumnLayout {
                                            anchors.left: parent.left; anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.leftMargin: 13; anchors.rightMargin: 13
                                            spacing: 3
                                            Text { text: modelData.k.toUpperCase(); color: Theme.ink3
                                                font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.8 }
                                            Text { Layout.fillWidth: true; text: modelData.v; color: Theme.ink; elide: Text.ElideRight
                                                font.family: modelData.mono ? Theme.fontMono : Theme.fontSans; font.pixelSize: 13 }
                                        }
                                    }
                                }
                            }
                        }

                        // response procedure (SOP)
                        Text { text: "RESPONSE PROCEDURE"; color: Theme.ink3; Layout.bottomMargin: 10
                            font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.2 }
                        Repeater {
                            model: tri._sop
                            delegate: Item {
                                id: sopItem
                                required property int index
                                required property var modelData
                                readonly property bool _checked: tri.done[index] === true
                                Layout.fillWidth: true
                                implicitHeight: Math.max(32, sopText.implicitHeight)
                                RowLayout {
                                    anchors.fill: parent; spacing: 10
                                    Rectangle {
                                        Layout.preferredWidth: 18; Layout.preferredHeight: 18; Layout.alignment: Qt.AlignTop; Layout.topMargin: 7
                                        color: sopItem._checked ? Theme.good : "transparent"
                                        border.width: 1; border.color: sopItem._checked ? Theme.good : Theme.line2
                                        EvIcon { anchors.centerIn: parent; visible: sopItem._checked; name: "check"; size: 12; color: Theme.bg }
                                    }
                                    Text {
                                        id: sopText
                                        Layout.fillWidth: true; topPadding: 7; bottomPadding: 7
                                        text: sopItem.modelData; wrapMode: Text.WordWrap
                                        color: sopItem._checked ? Theme.ink3 : Theme.ink2
                                        font.family: Theme.fontSans; font.pixelSize: 13
                                        font.strikeout: sopItem._checked
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { var d = Object.assign({}, tri.done); d[sopItem.index] = !sopItem._checked; tri.done = d; }
                                }
                            }
                        }

                        // disposition note
                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: 40; Layout.topMargin: 16
                            color: Theme.panel; border.width: 1; border.color: noteIn.activeFocus ? Theme.accent : Theme.line2
                            TextInput {
                                id: noteIn
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                verticalAlignment: TextInput.AlignVCenter
                                clip: true; color: Theme.ink; selectionColor: Theme.accentDim
                                font.family: Theme.fontSans; font.pixelSize: 13
                                text: tri.note
                                onTextChanged: tri.note = text
                                Text { visible: noteIn.text === ""; text: "Add disposition note (what happened, who responded)…"
                                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
                                    anchors.verticalCenter: parent.verticalCenter }
                            }
                        }
                        Item { Layout.preferredHeight: 6 }   // bottom breathing room
                    }
                }

                // ---- action bar (fixed footer) ----
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 58; color: Theme.panel
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 8
                        EvButton { variant: "good"; icon: "check"; label: "Authorized"; enabledBtn: !EventsStore.actionsPending
                            onClicked: if (tri._cur) EventsStore.dispose(tri._cur.id, "authorized", tri.note) }
                        EvButton { variant: ""; icon: "x"; label: "False alarm"; enabledBtn: !EventsStore.actionsPending
                            onClicked: if (tri._cur) EventsStore.dispose(tri._cur.id, "false_alarm", tri.note) }
                        EvButton { variant: "danger"; icon: "dispatch"; label: "Dispatch guard"; enabledBtn: !EventsStore.actionsPending
                            onClicked: if (tri._cur) EventsStore.dispose(tri._cur.id, "dispatched", tri.note) }
                        Item { Layout.fillWidth: true }
                        EvButton {
                            visible: tri._cur && tri._cur.status === "new"
                            variant: "pri"; icon: "check"; label: "Acknowledge"; kbd: "E"
                            onClicked: if (tri._cur) EventsStore.ack(tri._cur.id)
                        }
                        StateTag {
                            visible: tri._cur && tri._cur.status !== "new"
                            Layout.rightMargin: 8
                            state: tri._cur ? tri._cur.status : "new"
                            label: tri._cur ? (tri._cur.status.toUpperCase() + (tri._cur.dispo ? " · " + EventsStore.dispoDefs[tri._cur.dispo].label : "")) : ""
                        }
                    }
                }
            }
        }
    }

    Component { id: heroMockC; EvPlayer { ev: tri._cur } }
    Component { id: heroRealC; EvHeroPlayer { ev: tri._cur; playbackClient: tri.playbackClient; surfaced: tri.active } }
}
