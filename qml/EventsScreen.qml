import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Events & Alerts (S06 nav / design §6 + watchtower.html EventsScreen). Filter
// pills + a table of operational events, with an inline detail panel. Events come
// from EventModel (live cilex-vision /events, or WT_DEMO mock); camera names are
// resolved via CameraModel. Acknowledge is a local, persisted operator action —
// cilex-vision has no acknowledge endpoint yet (see docs/letters/).
//
// Functional filters: Unacknowledged + type (Motion/Offline/Bookmarks). The
// mock's Today/All-cameras/+Filter chips are deferred — we don't fake controls
// that have no data behind them (no per-event date scope, no camera picker yet).
Item {
    id: root

    property var eventModel: null
    property var cameraModel: null

    signal openPlayback(string camId)

    // active filters
    property bool fUnack: true          // default on (design)
    property bool fMotion: false
    property bool fOffline: false
    property bool fBookmark: false

    property var sel: null              // selected event map -> detail panel
    property var rows: []

    // per-column sort + Excel-style value filters (every data column)
    property string sortKey: "time"     // "event" | "camera" | "group" | "time" | "status"
    property int sortDir: -1            // 1 = ascending, -1 = descending (default: newest first)
    property var colExcl: ({})          // columnKey -> [excluded display values] (empty = all shown)
    property string openFilter: ""      // column whose dropdown is open ("" = none)
    property real filterX: 0            // dropdown anchor (mapped to root)
    property real filterY: 0
    property string filterSearch: ""    // checklist search within the open dropdown
    // Distinct values shown in the open dropdown's checklist (search-filtered).
    // Touch root.rows so this re-evaluates when the event set changes (all() is a
    // plain call, not a NOTIFYing property, so it wouldn't track loads on its own).
    readonly property var filterVals: {
        root.rows;
        if (root.openFilter === "") return [];
        var d = root.distinctVals(root.openFilter);
        var s = root.filterSearch.toLowerCase();
        return s === "" ? d : d.filter(function (v) { return ("" + v).toLowerCase().indexOf(s) >= 0; });
    }
    onSortKeyChanged: recompute()
    onSortDirChanged: recompute()
    onColExclChanged: recompute()

    function eventIcon(type) {
        switch (type) {
        case "loitering":
        case "stopped": return "alert";
        default: return "motion";   // entered/exited_scene, motion_started/ended
        }
    }
    function eventColor(type) {
        switch (type) {
        case "loitering": return Theme.bad;
        default: return Theme.accent;
        }
    }
    function camDisplay(ev) {
        var r = root.cameraModel ? root.cameraModel.cameraByBackendId(ev.camId) : null;
        return (r && r.name) ? r.name : (ev.camName ? ev.camName : ev.camId);
    }
    function groupDisplay(ev) {
        var r = root.cameraModel ? root.cameraModel.cameraByBackendId(ev.camId) : null;
        return (r && r.groupName) ? r.groupName : (ev.group ? ev.group : "—");
    }

    function timeToSecs(t) { var p = ("" + t).split(":"); return (+p[0] || 0) * 3600 + (+p[1] || 0) * 60 + (+p[2] || 0); }
    // Display value for a column — drives the filter checklist + alpha sort.
    function cellVal(ev, key) {
        switch (key) {
        case "event":  return (ev.desc && ev.desc !== "") ? ev.desc : ("" + ev.type);
        case "camera": return root.camDisplay(ev);
        case "group":  return root.groupDisplay(ev);
        case "time":   return ev.time;
        case "status": return ev.ack ? "Acknowledged" : "New";
        }
        return "";
    }
    // Sort key for a column — Time sorts chronologically (epoch ms, falling back to
    // same-day seconds for mock rows with no ts); the rest sort case-insensitively.
    function sortVal(ev, key) {
        if (key === "time") return (ev.ts && ev.ts > 0) ? ev.ts : root.timeToSecs(ev.time);
        return ("" + root.cellVal(ev, key)).toLowerCase();
    }
    // Sub-bar pill filters (Unack/Motion/Offline/Bookmarks); column filters + sort layer on top.
    function baseRows() {
        var all = root.eventModel ? root.eventModel.all() : [];
        var types = [];
        if (root.fMotion) types.push("motion");
        if (root.fOffline) types.push("offline");
        if (root.fBookmark) types.push("bookmark");
        var out = [];
        for (var i = 0; i < all.length; i++) {
            var e = all[i];
            if (root.fUnack && e.ack) continue;
            if (types.length && types.indexOf(e.type) < 0) continue;
            out.push(e);
        }
        return out;
    }
    // Distinct display values for a column (over the pill-filtered set), sorted.
    function distinctVals(key) {
        var seen = ({}), out = [], b = root.baseRows();
        for (var i = 0; i < b.length; i++) {
            var v = root.cellVal(b[i], key);
            if (!seen[v]) { seen[v] = true; out.push(v); }
        }
        out.sort(function (a, c) {
            if (key === "time") return root.timeToSecs(a) - root.timeToSecs(c);
            return ("" + a).toLowerCase() < ("" + c).toLowerCase() ? -1 : 1;
        });
        return out;
    }
    function passesCols(ev) {
        for (var key in root.colExcl) {
            var ex = root.colExcl[key];
            if (ex && ex.length && ex.indexOf(root.cellVal(ev, key)) >= 0) return false;
        }
        return true;
    }
    function filtered() {
        var out = root.baseRows().filter(function (e) { return root.passesCols(e); });
        var key = root.sortKey, dir = root.sortDir;
        out.sort(function (a, c) {
            var x = root.sortVal(a, key), y = root.sortVal(c, key);
            return (x < y ? -1 : (x > y ? 1 : 0)) * dir;
        });
        return out;
    }
    function colActive(key) { return root.colExcl[key] && root.colExcl[key].length > 0; }
    function isIncluded(key, val) { var ex = root.colExcl[key]; return !(ex && ex.indexOf(val) >= 0); }
    function toggleVal(key, val) {
        var ex = (root.colExcl[key] || []).slice();
        var i = ex.indexOf(val);
        if (i >= 0) ex.splice(i, 1); else ex.push(val);
        var m = Object.assign({}, root.colExcl); m[key] = ex; root.colExcl = m;
    }
    function setColAll(key, include) {
        var m = Object.assign({}, root.colExcl);
        m[key] = include ? [] : root.distinctVals(key).slice();
        root.colExcl = m;
    }
    function setSort(key, dir) { root.sortKey = key; root.sortDir = dir; }
    function openColumnFilter(key, item) {
        if (root.openFilter === key) { root.openFilter = ""; return; }
        var p = item.mapToItem(root, 0, item.height);
        root.filterX = p.x; root.filterY = p.y; root.filterSearch = ""; root.openFilter = key;
    }
    // Enter in the search box applies the typed text as the filter (keep only the
    // matching values, exclude the rest) and closes the dropdown — Excel behavior.
    function applySearch(key) {
        var s = root.filterSearch.toLowerCase();
        if (s === "") { root.openFilter = ""; return; }
        var excl = root.distinctVals(key).filter(function (v) { return ("" + v).toLowerCase().indexOf(s) < 0; });
        var m = Object.assign({}, root.colExcl); m[key] = excl; root.colExcl = m;
        root.openFilter = "";
    }
    function recompute() {
        root.rows = filtered();
        // keep the selected event in sync with the refreshed data (e.g. after ack)
        if (root.sel) {
            var found = null;
            var all = root.eventModel ? root.eventModel.all() : [];
            for (var i = 0; i < all.length; i++)
                if (all[i].eventId === root.sel.eventId) { found = all[i]; break; }
            root.sel = found;
        }
    }
    onFUnackChanged: recompute()
    onFMotionChanged: recompute()
    onFOfflineChanged: recompute()
    onFBookmarkChanged: recompute()
    Component.onCompleted: recompute()
    onVisibleChanged: if (visible && root.eventModel) root.eventModel.refresh()
    Connections {
        target: root.eventModel
        enabled: root.eventModel !== null
        function onChanged() { root.recompute() }
    }

    // shared button
    component Btn: Rectangle {
        id: b
        property string label: ""
        property string icon: ""
        property bool primary: false
        property bool ghost: false
        property bool small: false
        signal clicked()
        implicitHeight: b.small ? 24 : 34
        implicitWidth: brow.implicitWidth + (b.small ? 16 : 26)
        color: b.primary ? (bma.containsMouse ? "#f0b04e" : Theme.accent)
                         : b.ghost ? (bma.containsMouse ? Theme.panel : "transparent")
                                   : (bma.containsMouse ? Theme.panel : Theme.bg)
        border.width: (b.primary || b.ghost) ? 0 : 1
        border.color: bma.containsMouse ? Theme.accent : Theme.line2
        Row {
            id: brow; anchors.centerIn: parent; spacing: 7
            Icon { visible: b.icon !== ""; anchors.verticalCenter: parent.verticalCenter; name: b.icon; size: b.small ? 12 : 13; color: b.primary ? Theme.bg : (b.ghost ? Theme.ink2 : Theme.ink) }
            Text { anchors.verticalCenter: parent.verticalCenter; text: b.label; color: b.primary ? Theme.bg : (b.ghost ? Theme.ink2 : Theme.ink); font.family: Theme.fontSans; font.pixelSize: b.small ? 11 : 12; font.weight: b.primary ? Font.DemiBold : Font.Medium }
        }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }
    // filter pill
    component Pill: Rectangle {
        id: p
        property string label: ""
        property bool on: false
        signal toggled()
        implicitHeight: 30
        implicitWidth: prow.implicitWidth + 24
        color: p.on ? Theme.accentSoft : (pma.containsMouse ? Theme.panel2 : Theme.panel)
        border.width: 1
        border.color: p.on ? Theme.accent : (pma.containsMouse ? Theme.ink3 : Theme.line2)
        Row {
            id: prow; anchors.centerIn: parent; spacing: 6
            Text { anchors.verticalCenter: parent.verticalCenter; text: p.label; color: p.on ? Theme.accent : Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
            Text { anchors.verticalCenter: parent.verticalCenter; visible: p.on; text: "×"; color: p.on ? Theme.accent : Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 12 }
        }
        MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: p.toggled() }
    }

    // column widths (header + rows share these; Event column fills the rest).
    // wCam/wGroup/wTime/wStatus are drag-resizable from the header (see HCol grip);
    // Event is the flex column and keeps at least minEvent.
    readonly property int wIcon: 36
    property int wCam: 240
    property int wGroup: 150
    property int wTime: 110
    property int wStatus: 170
    readonly property int wAct: 116
    readonly property int minEvent: 120

    // ---- column resize helpers (drag a header grip; Event flexes to absorb) ----
    function othersW(key) {
        var s = root.wIcon + root.wAct;
        if (key !== "camera") s += root.wCam;
        if (key !== "group")  s += root.wGroup;
        if (key !== "time")   s += root.wTime;
        if (key !== "status") s += root.wStatus;
        return s;
    }
    function curColW(key) {
        return key === "camera" ? root.wCam : key === "group" ? root.wGroup
             : key === "time" ? root.wTime : key === "status" ? root.wStatus : 0;
    }
    // Apply a new width to a resizable column, clamped to [60, max] where max keeps
    // the flex Event column >= minEvent (so nothing overflows the table width).
    function resizeCol(key, w) {
        var maxW = Math.max(60, (colHdr.width - 28) - root.minEvent - root.othersW(key));
        w = Math.max(60, Math.min(w, maxW));
        if (key === "camera") root.wCam = w;
        else if (key === "group") root.wGroup = w;
        else if (key === "time") root.wTime = w;
        else if (key === "status") root.wStatus = w;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== sub-bar: filter pills + Clear all =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 6
                Pill { label: "Unacknowledged"; on: root.fUnack; onToggled: root.fUnack = !root.fUnack }
                Pill { label: "Motion"; on: root.fMotion; onToggled: root.fMotion = !root.fMotion }
                Pill { label: "Offline"; on: root.fOffline; onToggled: root.fOffline = !root.fOffline }
                Pill { label: "Bookmarks"; on: root.fBookmark; onToggled: root.fBookmark = !root.fBookmark }
                Item { Layout.fillWidth: true }
                Btn { ghost: true; label: "Clear all"; onClicked: { root.fUnack = false; root.fMotion = false; root.fOffline = false; root.fBookmark = false } }
            }
        }

        // ===== table + detail =====
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ---- table ----
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // header
                Rectangle {
                    id: colHdr
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    color: Theme.bg
                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line2 }
                    component Th: Text {
                        height: 38; verticalAlignment: Text.AlignVCenter
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
                    }
                    // Clickable, sortable, Excel-filterable column header.
                    component HCol: Item {
                        id: hcol
                        property string key: ""
                        property string label: ""
                        property bool resizable: false
                        height: 38
                        readonly property bool isSort: root.sortKey === hcol.key
                        Row {
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 5
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: hcol.label
                                color: (root.colActive(hcol.key) || hcol.isSort || hma.containsMouse) ? Theme.ink2 : Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                                font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter; visible: hcol.isSort
                                text: root.sortDir > 0 ? "▲" : "▼"; color: Theme.accent; font.pixelSize: 7
                            }
                            Icon {
                                anchors.verticalCenter: parent.verticalCenter; name: "funnel"; size: 11
                                color: root.colActive(hcol.key) ? Theme.accent
                                       : ((hma.containsMouse || root.openFilter === hcol.key) ? Theme.ink2 : Theme.ink3)
                            }
                        }
                        MouseArea {
                            id: hma; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openColumnFilter(hcol.key, hcol)
                        }
                        // drag grip on the right edge — resize the column (Excel-style)
                        Item {
                            visible: hcol.resizable
                            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                            width: 9
                            Rectangle {
                                anchors.centerIn: parent; width: 1; height: 18
                                color: (rzMa.containsMouse || rzMa.pressed) ? Theme.accent : Theme.line2
                            }
                            MouseArea {
                                id: rzMa
                                anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.SizeHorCursor
                                property real lastX: 0
                                onPressed: (m) => { lastX = mapToItem(null, m.x, 0).x }
                                onPositionChanged: (m) => {
                                    if (!pressed) return;
                                    var gx = mapToItem(null, m.x, 0).x;
                                    root.resizeCol(hcol.key, root.curColW(hcol.key) + (gx - lastX));
                                    lastX = gx;
                                }
                            }
                        }
                    }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                        Th { text: ""; Layout.preferredWidth: root.wIcon }
                        HCol { key: "event"; label: "Event"; Layout.fillWidth: true; Layout.minimumWidth: root.minEvent }
                        HCol { key: "camera"; label: "Camera"; resizable: true; Layout.preferredWidth: root.wCam }
                        HCol { key: "group"; label: "Group"; resizable: true; Layout.preferredWidth: root.wGroup }
                        HCol { key: "time"; label: "Time"; resizable: true; Layout.preferredWidth: root.wTime }
                        HCol { key: "status"; label: "Status"; resizable: true; Layout.preferredWidth: root.wStatus }
                        Th { text: ""; Layout.preferredWidth: root.wAct }
                    }
                }

                // rows
                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.rows
                    boundsBehavior: Flickable.StopAtBounds
                    QC.ScrollBar.vertical: QC.ScrollBar { }

                    delegate: Rectangle {
                        id: rowItem
                        required property var modelData
                        width: ListView.view.width
                        height: 54
                        readonly property bool isSel: root.sel && root.sel.eventId === modelData.eventId
                        color: isSel ? Theme.accentSoft : (rowMa.containsMouse ? Theme.panel : "transparent")
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sel = modelData }

                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                            // type icon
                            Item { Layout.preferredWidth: root.wIcon; Layout.fillHeight: true
                                Icon { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; name: root.eventIcon(rowItem.modelData.type); size: 16; color: root.eventColor(rowItem.modelData.type) } }
                            // Event (desc + TYPE)
                            ColumnLayout {
                                Layout.fillWidth: true; Layout.minimumWidth: root.minEvent; spacing: 1
                                Text { text: rowItem.modelData.desc; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: ("" + rowItem.modelData.type).toUpperCase(); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.6; Layout.fillWidth: true }
                            }
                            // Camera (name + id). Pin to exactly wCam — without a
                            // max, the nested ColumnLayout's long text + inner
                            // fillWidth Texts balloon past preferredWidth and steal
                            // space from the fillWidth Event column, knocking this
                            // cell out of line with the "Camera" header.
                            ColumnLayout {
                                Layout.preferredWidth: root.wCam
                                Layout.minimumWidth: root.wCam
                                Layout.maximumWidth: root.wCam
                                spacing: 1
                                Text { text: root.camDisplay(rowItem.modelData); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: rowItem.modelData.camId; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            // Group
                            Text { Layout.preferredWidth: root.wGroup; text: root.groupDisplay(rowItem.modelData); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                            // Time
                            Text { Layout.preferredWidth: root.wTime; text: rowItem.modelData.time; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 12 }
                            // Status
                            Item { Layout.preferredWidth: root.wStatus; Layout.fillHeight: true
                                // acknowledged
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                    visible: rowItem.modelData.ack
                                    Row { spacing: 4
                                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 12; color: Theme.accent }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Acknowledged"; color: Theme.accent; font.family: Theme.fontSans; font.pixelSize: 11 }
                                    }
                                    Text { text: (rowItem.modelData.ackBy ? rowItem.modelData.ackBy : "") + (rowItem.modelData.ackTime ? ("  ·  " + rowItem.modelData.ackTime) : ""); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                }
                                // new
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                    visible: !rowItem.modelData.ack
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: Theme.bad }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "NEW"; color: Theme.bad; font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.DemiBold }
                                }
                            }
                            // action
                            Item { Layout.preferredWidth: root.wAct; Layout.fillHeight: true
                                Btn { anchors.verticalCenter: parent.verticalCenter; small: true; ghost: true; icon: "clip"; label: "Playback"; onClicked: root.openPlayback(rowItem.modelData.camId) } }
                        }
                    }

                    // empty / loading state
                    Column {
                        anchors.centerIn: parent
                        spacing: 6
                        visible: root.rows.length === 0
                        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: (root.eventModel && root.eventModel.loading) ? "pulse" : "check"; size: 28; color: Theme.ink3 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                            text: (root.eventModel && root.eventModel.loading) ? "Loading events…"
                                  : ((root.eventModel && root.eventModel.total > 0) ? "No events match these filters." : "No events recorded.")
                            color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13 }
                    }
                }
            }

            // ---- detail panel ----
            Rectangle {
                Layout.preferredWidth: 380
                Layout.fillHeight: true
                visible: root.sel !== null
                color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }

                ColumnLayout {
                    anchors.fill: parent; anchors.leftMargin: 1; spacing: 0

                    // header
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 56; color: Theme.panel
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 10; spacing: 8
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { text: root.sel ? root.sel.desc : ""; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: root.sel ? (("" + root.sel.type).toUpperCase() + "  ·  " + root.sel.time) : ""; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            IconButton { name: "x"; iconColor: Theme.ink2; hoverIcon: Theme.ink; hoverBg: Theme.panel2; hoverBorder: Theme.line2; tip: "Close"; onClicked: root.sel = null }
                        }
                    }

                    // body
                    QC.ScrollView {
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                        contentWidth: availableWidth
                        ColumnLayout {
                            width: 380 - 1
                            spacing: 0

                            // 16:9 preview with a play affordance
                            Rectangle {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14
                                Layout.preferredHeight: width * 9 / 16
                                color: "#000"
                                PlaceholderVid {
                                    anchors.fill: parent
                                    pattern: 2
                                    geom: "parking"
                                    ts: root.sel ? root.sel.time : ""
                                    label: root.sel ? root.sel.camId : ""
                                }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 44; height: 44; radius: 22
                                    color: Qt.rgba(11 / 255, 14 / 255, 18 / 255, 0.85)
                                    border.width: 1; border.color: Theme.line2
                                    Icon { anchors.centerIn: parent; name: "play"; size: 18; color: "#fff" }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (root.sel) root.openPlayback(root.sel.camId) }
                                }
                            }

                            // KV facts
                            component KV: RowLayout {
                                id: kv; property string k: ""; property string v: ""; property color vColor: Theme.ink
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; spacing: 8
                                Text { text: kv.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true }
                                Text { text: kv.v; color: kv.vColor; font.family: Theme.fontMono; font.pixelSize: 11; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                            }
                            Item { Layout.preferredHeight: 10 }
                            KV { k: "Camera"; v: root.sel ? root.camDisplay(root.sel) : "" }
                            KV { k: "Group"; v: root.sel ? root.groupDisplay(root.sel) : "" }
                            KV { k: "Time"; v: root.sel ? root.sel.time : "" }
                            KV { k: "Status"; v: root.sel ? (root.sel.ack ? "ACKNOWLEDGED" : "NEW") : ""; vColor: root.sel && root.sel.ack ? Theme.accent : Theme.bad }
                            KV { k: "Acknowledged by"; v: root.sel ? root.sel.ackBy : ""; visible: root.sel && root.sel.ack }
                            KV { k: "Acknowledged at"; v: root.sel ? root.sel.ackTime : ""; visible: root.sel && root.sel.ack }

                            // actions
                            Flow {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14; Layout.bottomMargin: 14
                                spacing: 6
                                Btn { primary: true; icon: "clip"; label: "Open playback"; onClicked: if (root.sel) root.openPlayback(root.sel.camId) }
                                Btn { icon: "check"; label: "Acknowledge"; visible: root.sel && !root.sel.ack; onClicked: if (root.sel && root.eventModel) root.eventModel.acknowledgeById(root.sel.eventId) }
                            }
                        }
                    }
                }
            }
        }
    }

    // ===== Excel-style column sort/filter dropdown =====
    // Dismiss on click outside the panel.
    MouseArea {
        anchors.fill: parent
        visible: root.openFilter !== ""
        z: 50
        onClicked: root.openFilter = ""
    }
    Rectangle {
        id: filterPanel
        visible: root.openFilter !== ""
        z: 51
        width: 256
        x: Math.max(8, Math.min(root.filterX, root.width - width - 8))
        y: root.filterY
        height: panelCol.implicitHeight + 16
        color: Theme.panel2
        border.width: 1; border.color: Theme.line2
        // swallow clicks on empty panel area so the outside-catcher doesn't fire
        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }

        ColumnLayout {
            id: panelCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
            spacing: 6

            // sort
            RowLayout {
                Layout.fillWidth: true; spacing: 6
                Repeater {
                    model: [ { l: "Sort ↑ A–Z", d: 1 }, { l: "Sort ↓ Z–A", d: -1 } ]
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true; Layout.preferredHeight: 26
                        readonly property bool on: root.sortKey === root.openFilter && root.sortDir === modelData.d
                        color: on ? Theme.accentSoft : (sma.containsMouse ? Theme.panel : "transparent")
                        border.width: 1; border.color: on ? Theme.accent : Theme.line2
                        Text { anchors.centerIn: parent; text: parent.modelData.l; color: parent.on ? Theme.accent : Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11 }
                        MouseArea { id: sma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.setSort(root.openFilter, parent.modelData.d); root.openFilter = "" } }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.line }

            // search
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 28
                color: Theme.bg; border.width: 1; border.color: searchIn.activeFocus ? Theme.accent : Theme.line2
                Row {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 6
                    Icon { anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 12; color: Theme.ink3 }
                    TextInput {
                        id: searchIn
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 22
                        text: root.filterSearch
                        onTextChanged: root.filterSearch = text
                        onAccepted: root.applySearch(root.openFilter)   // Enter → apply + close
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; clip: true
                        Text { visible: parent.text === ""; text: "Search values…"; color: Theme.ink3; font: parent.font }
                    }
                }
            }

            // select all / clear
            RowLayout {
                Layout.fillWidth: true; spacing: 14
                Text { text: "Select all"; color: Theme.accent; font.family: Theme.fontSans; font.pixelSize: 11
                    MouseArea { anchors.fill: parent; anchors.margins: -5; cursorShape: Qt.PointingHandCursor; onClicked: root.setColAll(root.openFilter, true) } }
                Text { text: "Clear"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                    MouseArea { anchors.fill: parent; anchors.margins: -5; cursorShape: Qt.PointingHandCursor; onClicked: root.setColAll(root.openFilter, false) } }
                Item { Layout.fillWidth: true }
            }

            // value checklist
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(root.filterVals.length * 28, 220)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                QC.ScrollBar.vertical: QC.ScrollBar { }
                model: root.filterVals
                delegate: Rectangle {
                    required property var modelData
                    width: ListView.view.width; height: 28
                    color: cma.containsMouse ? Theme.panel : "transparent"
                    Row {
                        anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 4; spacing: 8
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 15; height: 15; radius: 2
                            readonly property bool on: root.isIncluded(root.openFilter, parent.parent.modelData)
                            color: on ? Theme.accent : "transparent"
                            border.width: 1; border.color: on ? Theme.accent : Theme.line2
                            Icon { visible: parent.on; anchors.centerIn: parent; name: "check"; size: 10; color: Theme.bg }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 27
                            text: "" + parent.parent.modelData; color: Theme.ink2; elide: Text.ElideRight
                            font.family: Theme.fontSans; font.pixelSize: 12
                        }
                    }
                    MouseArea { id: cma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleVal(root.openFilter, modelData) }
                }
            }
        }
    }
}
