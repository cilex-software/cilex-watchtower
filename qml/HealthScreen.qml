import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower
import "HealthFilters.js" as Filters

// Health (S07) — design handoff README §7 + watchtower.html HealthScreen.
// A full-width strip of stat cards over CameraModel's live counts, a camera
// table filtered by the active card and column inclusions, and a 380px detail panel. This is a pure
// view over CameraModel — camera live/recording status is whatever the store
// holds (from provisioning import), the same source the rest of the app uses;
// there is no separate live health feed yet, so we never fabricate durations.
Item {
    id: root

    property var cameraModel: null
    property var storageHealth: null
    property var playbackClient: null          // for the playback-subsystem strip
    property var availabilityService: typeof CameraAvailability !== "undefined" ? CameraAvailability : null
    readonly property bool backendStatusStale: cameraModel !== null && cameraModel.backendEvidenceFresh === false

    signal openLive(var cam)
    signal openPlayback(var cam)
    signal openEvents(var cam)

    // WT_DEMO drives the mock store, which DOES populate both of the states the real
    // backend never sends (MockData.cpp:102-104 degraded, :106-107 recording gaps). That is
    // how two dead cards survived: under demo the strip shows DEGRADED 3 and RECENT GAPS 2,
    // so anyone checking whether the screen works sees working cards. Real data or an honest
    // empty state is a house rule; this was its inverse — mock data lending confidence to an
    // indicator that is structurally zero in production.
    readonly property bool demoStore: (typeof wtDemo !== "undefined") && wtDemo

    property string activeFilter: ""           // default to Visible (all) — real fleets are mostly healthy, so an Offline default (per the mock) would open empty
    property var sel: null                     // selected camera map -> detail panel

    // Storage subsystem health (cilex-vision /health/storage), refreshed while visible.
    onVisibleChanged: {
        if (visible && storageHealth) storageHealth.refresh();
        if (!visible) columnPopup.close();
    }
    Component.onCompleted: { _refreshRows(); if (storageHealth) storageHealth.refresh() }
    Timer { interval: 30000; running: root.visible && root.storageHealth !== null; repeat: true; onTriggered: root.storageHealth.refresh() }
    // Ticks the "last ok Ns ago" age. The endpoint is cached server-side now, so
    // the age must advance between refreshes rather than freezing at fetch time.
    property double nowMs: Date.now()
    Timer { interval: 1000; running: root.visible; repeat: true; onTriggered: root.nowMs = Date.now() }

    // table rows for the active filter (status-sorted; all of them — the table scrolls).
    // page() is a Q_INVOKABLE, so QML cannot track it: a plain binding evaluates
    // once before the first /streams fetch and the table stays empty forever
    // (caught by a WT_SECTION=health boot smoke). Refresh on countsChanged, but
    // only reassign when content actually changed — countsChanged fires every
    // 15s poll, and a fresh array each time would reset the table's scroll
    // position (the CameraGroups delegate-churn lesson).
    readonly property var rows: viewRows
    property var colFilters: ({camera: null, group: null, live: null, rec: null, issue: null})
    readonly property bool anyColumnFilter: Filters.columns.some(function(col) { return colFilters[col] !== null })
    property var viewRows: []
    property string _viewRowsSig: "\u0000unset"
    property int _viewRevision: 0
    property int _filterDataRevision: 0
    property var _rows: []
    property string _rowsSig: "\u0000unset"
    function _refreshRows() {
        if (!cameraModel) { _rows = []; _rowsSig = ""; sel = null; _refreshViewRows(); return; }
        var r = cameraModel.page("", activeFilter, "status", 1, 100000);
        var sig = activeFilter + "\u0001";
        for (var i = 0; i < r.length; i++) {
            var c = r[i];
            sig += rowSignature(c) + "\u0001";
        }
        if (sig !== _rowsSig) { _rowsSig = sig; _rows = r; }
        if (sel) {
            var selectedId = sel.camId;
            var current = selectedId && typeof cameraModel.cameraByBackendId === "function"
                ? cameraModel.cameraByBackendId(selectedId) : null;
            sel = current && current.camId === selectedId ? current : null;
        }
        ++_filterDataRevision;
        _refreshViewRows();
    }
    function rowSignature(c) {
        return JSON.stringify([c.camId, c.name, c.groupName, c.live, c.recording, c.lastSeen,
            c.lastSegmentAt, c.motionKnown, c.motionReady, c.motionConfirmed, c.motionLastVmdAt,
            Filters.keys(c, health(c))]);
    }
    function _refreshViewRows() {
        var next = _rows.filter(function(cam) { return Filters.passes(Filters.keys(cam, health(cam)), colFilters, "") });
        var sig = JSON.stringify(colFilters) + "\u0001" + next.map(rowSignature).join("\u0001");
        if (sig === _viewRowsSig) return;
        var oldY = list.contentY, oldX = list.contentX, oldIndex = Math.max(0, Math.floor((oldY - list.originY) / 52));
        var anchor = viewRows[oldIndex] ? viewRows[oldIndex].camId : "";
        var offset = oldY - list.originY - oldIndex * 52;
        _viewRowsSig = sig; viewRows = next;
        var revision = ++_viewRevision;
        Qt.callLater(function() {
            if (revision !== root._viewRevision) return;
            list.forceLayout();
            var index = next.findIndex(function(cam) { return cam.camId === anchor });
            var y = index >= 0 ? list.originY + index * 52 + offset : oldY;
            list.contentY = Math.max(list.originY, Math.min(y, list.originY + Math.max(0, list.contentHeight - list.height)));
            list.contentX = Math.max(0, Math.min(oldX, list.contentWidth - list.width));
        });
    }
    onColFiltersChanged: { _refreshViewRows(); columnPopup.refreshValues() }
    onActiveFilterChanged: _refreshRows()
    onCameraModelChanged: _refreshRows()
    Connections { target: root.cameraModel; function onCountsChanged() { root._refreshRows() } function onHealthRevChanged() { root._refreshRows() } }

    // column widths (header + row delegate share these; Camera column fills the rest)
    readonly property int wGroup: 150
    readonly property int wLive: 110
    readonly property int wRec: 170
    readonly property int wSeen: 110
    readonly property int wIssue: 220
    readonly property int wAct: 72
    readonly property int tableMinimumWidth: 160 + wGroup + wLive + wRec + wSeen + wIssue + wAct + 28

    function columnKeys(column) {
        // Normalise against the entire known fleet, not a metric/cascade subset.
        var all = !activeFilter ? _rows : (cameraModel ? cameraModel.page("", "", "status", 1, 100000) : []);
        var keys = [];
        all.forEach(function(cam) {
            var key = Filters.keys(cam, health(cam))[column];
            if (keys.indexOf(key) < 0) keys.push(key);
        });
        return keys;
    }
    function setIncluded(column, keys) {
        var all = columnKeys(column), next = Object.assign({}, colFilters);
        next[column] = all.length > 0 && all.every(function(key) { return keys.indexOf(key) >= 0 }) ? null : keys;
        colFilters = next;
    }
    function clearColumnFilters() {
        colFilters = {camera: null, group: null, live: null, rec: null, issue: null};
        columnPopup.close();
    }
    function columnValues(column) {
        if (!column) return [];
        var values = [];
        _rows.forEach(function(cam) {
            var keys = Filters.keys(cam, health(cam));
            if (!Filters.passes(keys, colFilters, column)) return;
            var item = values.find(function(value) { return value.key === keys[column] });
            if (item) ++item.count;
            else values.push({key: keys[column], cam: cam, count: 1});
        });
        var order = column === "live" ? Filters.liveOrder : column === "rec" ? Filters.recOrder : Filters.issueOrder;
        if (column === "group") values.sort(function(a, b) {
            if (!a.key) return 1;
            if (!b.key) return -1;
            return a.key.localeCompare(b.key);
        });
        else if (column !== "camera") values.sort(function(a, b) { return order.indexOf(a.key) - order.indexOf(b.key) });
        return values;
    }
    function recordingCategoryLabel(key) {
        if (key === "ARMED · no motion") return qsTr("ARMED · no motion");
        if (key === "ARMED · NOT READY") return "ARMED · " + qsTranslate("RecordingStatusBadge", "NOT READY");
        if (key === "ARMED · ARCHIVE DELAY") return "ARMED · " + qsTranslate("RecordingStatusBadge", "ARCHIVE DELAY");
        return qsTranslate("RecordingStatusBadge", key);
    }
    function toggleColumnPopup(column, trigger) {
        if (columnPopup.visible && columnPopup.column === column) { columnPopup.close(); return; }
        columnPopup.column = column; columnPopup.trigger = trigger;
        columnPopup.query = ""; columnPopup.refreshValues(); columnPopup.open();
        if (columnPopup.hasSearch) searchInput.forceActiveFocus();
        else columnPopup.forceActiveFocus();
    }
    on_FilterDataRevisionChanged: columnPopup.refreshValues()

    function liveText(s) {
        switch (s) {
        case CameraStatus.Live: return qsTr("Live");
        case CameraStatus.Offline: return qsTr("Offline");
        case CameraStatus.Degraded: return qsTr("Degraded");
        case CameraStatus.NoSignal: return qsTr("No signal");
        case CameraStatus.Loading: return qsTr("Loading");
        default: return qsTr("Unknown");
        }
    }
    function health(cam) {
        if (!cam) return ({});
        return cameraModel && typeof cameraModel.recordingHealthFor === "function"
            ? (cameraModel.healthRev, cameraModel.recordingHealthFor(cam.camId))
            : (cam.recordingHealth || ({}));
    }
    function recText(cam) {
        var capture = health(cam).capture_state || "unknown";
        switch (capture) {
        case "progressing": return qsTr("Recording continues");
        case "stopped": return qsTr("Recording stopped");
        case "idle": return qsTr("Motion armed");
        case "disabled": return qsTr("Disabled");
        default: return qsTr("Unknown");
        }
    }
    function archiveText(cam) {
        var state = health(cam).archive_state || "unknown";
        if (state === "current") return qsTr("Current in catalogue");
        if (state === "delayed") return qsTr("Archive delayed");
        if (state === "unavailable") return qsTr("Archive unavailable");
        if (state === "idle") return qsTr("Idle");
        if (state === "disabled") return qsTr("Disabled");
        return qsTr("Unknown");
    }
    function issueText(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal) return qsTr("No signal");
        var h = health(cam);
        if (h.capture_state === "stopped") return qsTr("Recording stopped");
        if (h.archive_state === "delayed" || h.archive_state === "unavailable") return archiveText(cam);
        if (cam.recording === CameraStatus.Armed && cam.motionKnown && !cam.motionReady) return qsTr("Motion detector not ready");
        if (cam.live === CameraStatus.Degraded) return qsTr("Stream degraded");
        return h.capture_state === "unknown" || h.archive_state === "unknown" ? qsTr("Status unknown") : "—";
    }
    function issueColor(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal || health(cam).capture_state === "stopped") return Theme.bad;
        return issueText(cam) === "—" ? Theme.ink3 : Theme.warn;
    }
    function calloutColor(cam) { return issueColor(cam); }
    function calloutText(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal)
            return qsTr("Camera is offline. Earlier recordings may still be available.");
        var h = health(cam);
        if (h.capture_state === "stopped") return qsTr("Recorder progress has stopped. Check the recording service; live video does not confirm recording.");
        if (h.archive_state === "delayed" || h.archive_state === "unavailable")
            return h.capture_state === "progressing"
                ? qsTr("Recording continues locally. Archive publication is delayed; recent playback may be unavailable.")
                : qsTr("Archive publication is delayed. Local recording progress is unverified.");
        if (h.capture_state === "progressing" && h.archive_state === "unknown")
            return qsTr("Recording continues. Archive status is unknown.");
        if (h.capture_state === "progressing")
            return qsTr("Recorder progress is current. Catalogue freshness does not prove complete, readable footage; verify playback for the required interval.");
        if (h.capture_state === "disabled") return qsTr("Recording is disabled.");
        if (h.capture_state === "idle") return qsTr("Motion recording is idle. This does not certify the next motion recording.");
        return qsTr("Recording status is unknown. Live video and an older catalogue entry do not establish current recording.");
    }
    readonly property bool selOffline: sel && (sel.live === CameraStatus.Offline || sel.live === CameraStatus.NoSignal)

    // shared button
    component Btn: Rectangle {
        id: b
        property string label: ""
        property string icon: ""
        property bool ghost: false
        property bool small: false
        signal clicked()
        implicitHeight: b.small ? 24 : 34
        implicitWidth: brow.implicitWidth + (b.small ? 16 : 26)
        color: b.ghost ? (bma.containsMouse ? Theme.panel : "transparent")
                       : (bma.containsMouse ? Theme.panel : Theme.bg)
        border.width: b.ghost ? 0 : 1
        border.color: bma.containsMouse ? Theme.accent : Theme.line2
        Row {
            id: brow; anchors.centerIn: parent; spacing: 7
            Icon { visible: b.icon !== ""; anchors.verticalCenter: parent.verticalCenter; name: b.icon; size: 13; color: b.ghost ? Theme.ink2 : Theme.ink }
            Text { anchors.verticalCenter: parent.verticalCenter; text: b.label; color: b.ghost ? Theme.ink2 : Theme.ink; font.family: Theme.fontSans; font.pixelSize: b.small ? 11 : 12; font.weight: Font.Medium }
        }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }

    component FilterCheck: Rectangle {
        property int checkState: Qt.Unchecked
        width: 14; height: 14
        color: checkState === Qt.Unchecked ? "transparent" : Theme.accent
        border.width: 1
        border.color: checkState === Qt.Unchecked ? Theme.line2 : Theme.accent
        Icon { anchors.centerIn: parent; visible: parent.checkState === Qt.Checked; name: "filterCheck"; size: 10; color: Theme.bg }
        Rectangle { anchors.centerIn: parent; visible: parent.checkState === Qt.PartiallyChecked; width: 8; height: 2; color: Theme.bg }
    }
    component FilterTrigger: Item {
        id: trigger
        property string column: ""
        property string label: ""
        readonly property bool filtered: root.colFilters[column] !== null
        readonly property bool opened: columnPopup.visible && columnPopup.column === column
        readonly property real buttonWidth: Math.min(width + 6, triggerLabel.implicitWidth + 5 + (filtered ? 11 : 10) + 12)
        implicitHeight: 38
        Rectangle {
            x: -6; anchors.verticalCenter: parent.verticalCenter
            width: trigger.buttonWidth; height: 24
            color: trigger.opened || triggerMouse.containsMouse ? Theme.panel : "transparent"
            Row {
                anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6; spacing: 5
                Text {
                    id: triggerLabel
                    width: Math.max(0, parent.width - 5 - triggerIcon.width)
                    anchors.verticalCenter: parent.verticalCenter
                    text: trigger.label; elide: Text.ElideRight
                    color: trigger.filtered ? Theme.accent : trigger.opened ? Theme.ink : Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                    font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
                }
                Icon {
                    id: triggerIcon; anchors.verticalCenter: parent.verticalCenter
                    name: trigger.filtered ? "funnelFill" : "filterChev"; size: trigger.filtered ? 11 : 10
                    color: trigger.filtered ? Theme.accent : trigger.opened ? Theme.ink : Theme.ink3
                }
            }
            MouseArea {
                id: triggerMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleColumnPopup(trigger.column, triggerMouse.parent)
            }
        }
    }

    QC.Popup {
        id: columnPopup
        objectName: "healthColumnPopup"
        property string column: ""
        property var trigger: null
        property string query: ""
        property var valueRows: []
        property string valuesSignature: ""
        readonly property bool hasSearch: column === "camera" || column === "group"
        readonly property string searchQuery: query.trim().toLowerCase()
        readonly property var listed: valueRows.filter(function(value) {
            return !searchQuery || (column === "camera"
                ? String(value.cam.name).toLowerCase().indexOf(searchQuery) >= 0 || value.key.toLowerCase().indexOf(searchQuery) >= 0
                : value.key.toLowerCase().indexOf(searchQuery) >= 0);
        })
        readonly property int checkedCount: listed.filter(function(value) { return isChecked(value.key) }).length
        readonly property bool allChecked: listed.length > 0 && checkedCount === listed.length
        readonly property int totalCount: valueRows.reduce(function(sum, value) { return sum + value.count }, 0)
        readonly property bool canClear: column !== "" && root.colFilters[column] !== null
        function refreshValues() {
            if (!column) return;
            var values = root.columnValues(column);
            var signature = column + JSON.stringify(values.map(function(value) { return [value.key, value.count, root.rowSignature(value.cam)] }));
            if (signature !== valuesSignature) { valuesSignature = signature; valueRows = values; }
        }
        function isChecked(key) { return root.colFilters[column] === null || root.colFilters[column].indexOf(key) >= 0 }
        function includedKeys() { return root.colFilters[column] === null ? root.columnKeys(column) : root.colFilters[column].slice() }
        function toggleValue(key) {
            var keys = includedKeys(), index = keys.indexOf(key);
            if (index >= 0) keys.splice(index, 1); else keys.push(key);
            root.setIncluded(column, keys);
        }
        function toggleListed() {
            if (!listed.length) return;
            var keys = includedKeys(), remove = allChecked;
            listed.forEach(function(value) {
                var index = keys.indexOf(value.key);
                if (remove && index >= 0) keys.splice(index, 1);
                if (!remove && index < 0) keys.push(value.key);
            });
            root.setIncluded(column, keys);
        }
        function applySearch() {
            if (!searchQuery || !listed.length) return;
            root.setIncluded(column, listed.map(function(value) { return value.key }));
            close();
        }
        parent: trigger || tableColumn
        readonly property real tableLeft: {
            list.contentX; tableColumn.width;
            return trigger ? trigger.mapToItem(tableColumn, 0, 0).x : 8;
        }
        readonly property real clampedLeft: Math.max(8, Math.min(tableLeft, tableColumn.width - width - 8))
        x: trigger ? tableColumn.mapToItem(trigger, clampedLeft, 0).x : 8
        y: trigger ? tableHeader.mapToItem(trigger, 0, tableHeader.height - 1).y : tableHeader.height - 1
        width: Math.min(column === "camera" ? 300 : column === "group" ? 240 : column === "live" ? 220 : column === "rec" ? 270 : 260,
                        Math.max(0, tableColumn.width - 16))
        height: popupBody.implicitHeight
        padding: 0; focus: true
        closePolicy: QC.Popup.CloseOnEscape | QC.Popup.CloseOnPressOutsideParent
        background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
        contentItem: Column {
            id: popupBody; width: columnPopup.width; spacing: 0
            Item {
                visible: columnPopup.hasSearch; width: parent.width; height: visible ? 42 : 0
                Rectangle {
                    x: 8; y: 8; width: parent.width - 16; height: 30
                    color: Theme.bg; border.width: 1; border.color: searchInput.activeFocus ? Theme.accent : Theme.line2
                    Icon { x: 9; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 13; color: Theme.ink3 }
                    TextInput {
                        id: searchInput; objectName: "healthFilterSearch"
                        x: 30; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x - (enterHint.visible ? enterHint.width + 13 : 9)
                        text: columnPopup.query; onTextEdited: columnPopup.query = text
                        color: Theme.ink; selectionColor: Theme.accent; selectedTextColor: Theme.bg
                        font.family: Theme.fontSans; font.pixelSize: 12; clip: true; selectByMouse: true
                        Keys.onReturnPressed: columnPopup.applySearch()
                        Keys.onEnterPressed: columnPopup.applySearch()
                        Text {
                            anchors.fill: parent; visible: searchInput.text === ""; elide: Text.ElideRight
                            text: columnPopup.column === "camera" ? qsTr("Search names or IDs…") : qsTr("Search groups…")
                            color: Theme.ink3; font: searchInput.font
                        }
                    }
                    Rectangle {
                        id: enterHint; visible: columnPopup.searchQuery !== ""
                        anchors.right: parent.right; anchors.rightMargin: 5; anchors.verticalCenter: parent.verticalCenter
                        width: enterText.implicitWidth + 10; height: 18; color: "transparent"; border.width: 1; border.color: Theme.line2
                        Text { id: enterText; anchors.centerIn: parent; text: qsTr("ENTER"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                        MouseArea { id: enterHintMouse; anchors.fill: parent; hoverEnabled: true }
                        QC.ToolTip.visible: enterHintMouse.containsMouse
                        QC.ToolTip.text: qsTr("Show only matching values"); QC.ToolTip.delay: 300
                    }
                }
            }
            Item { width: 1; height: 2 }
            Rectangle {
                objectName: "healthFilterSelectAll"; width: parent.width; height: 30
                color: selectAllMouse.containsMouse ? Theme.panel2 : "transparent"
                FilterCheck {
                    x: 10; anchors.verticalCenter: parent.verticalCenter
                    checkState: columnPopup.allChecked ? Qt.Checked : columnPopup.checkedCount ? Qt.PartiallyChecked : Qt.Unchecked
                }
                Text {
                    x: 34; anchors.verticalCenter: parent.verticalCenter; width: parent.width - x - 10 - (selectCount.visible ? selectCount.width + 10 : 0)
                    text: columnPopup.searchQuery ? qsTr("Select all results (%1)").arg(columnPopup.listed.length) : qsTr("Select all")
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium; elide: Text.ElideRight
                }
                Text {
                    id: selectCount; visible: !columnPopup.searchQuery
                    anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                    text: columnPopup.totalCount; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                }
                MouseArea { id: selectAllMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: columnPopup.toggleListed() }
            }
            Item { width: parent.width; height: 5; Rectangle { y: 2; width: parent.width; height: 1; color: Theme.line } }
            ListView {
                id: valueList; objectName: "healthFilterValues"
                width: parent.width; height: Math.min(300, contentHeight + topMargin + bottomMargin)
                topMargin: 2; bottomMargin: 4; clip: true; boundsBehavior: Flickable.StopAtBounds
                model: columnPopup.listed
                QC.ScrollBar.vertical: QC.ScrollBar { }
                delegate: Rectangle {
                    id: valueRow
                    required property var modelData
                    width: valueList.width; height: 28
                    readonly property bool checked: columnPopup.isChecked(modelData.key)
                    color: valueMouse.containsMouse || onlyMouse.containsMouse ? Theme.panel2 : "transparent"
                    MouseArea { id: valueMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: columnPopup.toggleValue(valueRow.modelData.key) }
                    FilterCheck { x: 10; anchors.verticalCenter: parent.verticalCenter; checkState: valueRow.checked ? Qt.Checked : Qt.Unchecked }
                    Item {
                        x: 34; anchors.verticalCenter: parent.verticalCenter; height: 28
                        width: Math.max(0, parent.width - x - 10 - (onlyButton.visible ? onlyButton.width + 10 : valueCount.visible ? valueCount.width + 10 : 0))
                        opacity: valueRow.checked ? 1 : 0.6
                        LiveStatusBadge { anchors.verticalCenter: parent.verticalCenter; visible: columnPopup.column === "live"; state: valueRow.modelData.cam.live }
                        RecordingStatusBadge {
                            anchors.verticalCenter: parent.verticalCenter; visible: columnPopup.column === "rec"
                            state: valueRow.modelData.cam.recording; health: root.health(valueRow.modelData.cam)
                            motionKnown: valueRow.modelData.cam.motionKnown === true; motionReady: valueRow.modelData.cam.motionReady === true
                            lastSegmentAtMs: valueRow.modelData.cam.lastSegmentAt ? Date.parse(valueRow.modelData.cam.lastSegmentAt) : -1
                            lastVmdAtMs: valueRow.modelData.cam.motionLastVmdAt ? Date.parse(valueRow.modelData.cam.motionLastVmdAt) : -1
                            label: root.recordingCategoryLabel(valueRow.modelData.key)
                        }
                        Row {
                            anchors.verticalCenter: parent.verticalCenter; width: parent.width; spacing: 8
                            visible: columnPopup.column !== "rec" && columnPopup.column !== "live"
                            Text {
                                width: columnPopup.column === "camera" ? Math.min(implicitWidth, parent.width * 0.55) : parent.width
                                text: columnPopup.column === "camera" ? valueRow.modelData.cam.name
                                    : columnPopup.column === "group" ? (valueRow.modelData.key || qsTr("— (no group)"))
                                    : valueRow.modelData.key === "—" ? qsTr("— (none shown)") : root.issueText(valueRow.modelData.cam)
                                color: columnPopup.column === "issue" ? root.issueColor(valueRow.modelData.cam) : Theme.ink
                                font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
                            }
                            Text {
                                visible: columnPopup.column === "camera"
                                width: Math.max(0, parent.width - parent.children[0].width - 8)
                                text: valueRow.modelData.key; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; elide: Text.ElideRight
                            }
                        }
                    }
                    Text {
                        id: valueCount; visible: columnPopup.column !== "camera" && !onlyButton.visible
                        anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(18, implicitWidth); horizontalAlignment: Text.AlignRight
                        text: valueRow.modelData.count; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                    Rectangle {
                        id: onlyButton; objectName: "healthFilterOnly"
                        visible: valueMouse.containsMouse || onlyMouse.containsMouse
                        anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                        height: 20; width: onlyText.implicitWidth + 12
                        color: onlyMouse.containsMouse ? Theme.accentDim : "transparent"; border.width: 1; border.color: Theme.accentDim
                        Text { id: onlyText; anchors.centerIn: parent; text: qsTr("Only"); color: onlyMouse.containsMouse ? Theme.ink : Theme.accent; font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.Medium }
                        MouseArea { id: onlyMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setIncluded(columnPopup.column, [valueRow.modelData.key]) }
                        QC.ToolTip.visible: onlyMouse.containsMouse
                        QC.ToolTip.text: qsTr("Show only this value"); QC.ToolTip.delay: 300
                    }
                }
            }
            Text {
                visible: columnPopup.listed.length === 0; width: parent.width
                height: visible ? implicitHeight : 0; topPadding: 10; leftPadding: 10; rightPadding: 10; bottomPadding: 8
                text: qsTr("No values match “%1”.").arg(columnPopup.query)
                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap
            }
            Rectangle {
                width: parent.width; height: 40; color: "transparent"
                Rectangle { width: parent.width; height: 1; color: Theme.line }
                Rectangle {
                    id: clearButton; objectName: "healthFilterClear"
                    x: 8; anchors.verticalCenter: parent.verticalCenter; height: 24; width: clearContents.implicitWidth + 16
                    color: clearMouse.containsMouse && columnPopup.canClear ? Theme.panel2 : "transparent"
                    Row {
                        id: clearContents; anchors.centerIn: parent; spacing: 6
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "funnelClear"; size: 11; color: columnPopup.canClear ? Theme.ink2 : Theme.ink3 }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Clear filter"); color: columnPopup.canClear ? Theme.ink2 : Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.Medium }
                    }
                    MouseArea {
                        id: clearMouse; anchors.fill: parent; enabled: columnPopup.canClear; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { var next = Object.assign({}, root.colFilters); next[columnPopup.column] = null; root.colFilters = next; columnPopup.close() }
                    }
                }
                Rectangle {
                    objectName: "healthFilterDone"; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                    height: 24; width: doneText.implicitWidth + 20
                    color: doneMouse.containsMouse ? Theme.panel : Theme.bg; border.width: 1; border.color: doneMouse.containsMouse ? Theme.accent : Theme.line2
                    Text { id: doneText; anchors.centerIn: parent; text: qsTr("Done"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.Medium }
                    MouseArea { id: doneMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: columnPopup.close() }
                }
            }
        }
    }

    AvailabilityHistory {
        id: availabilityHistory
        parent: QC.Overlay.overlay
        service: root.availabilityService
        cameraModel: root.cameraModel
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== storage subsystem status =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            readonly property var sh: root.storageHealth
            Row {
                anchors.left: parent.left; anchors.leftMargin: 18; anchors.right: parent.right; anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter; spacing: 8
                // CV's `state` is rendered VERBATIM (their 912dc73, §2 of the reply
                // to our false-unreachable letter). We used to re-derive a verdict
                // from the booleans and paint one timed-out probe as a confident
                // red — the mirror image of a false green, and just as dishonest.
                // `intermittent` is a Docker stall burst with a healthy agent: it
                // is warn, never bad, and it carries the age of the last good check
                // so the operator can see how stale the failure is.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; radius: 4
                    color: (!parent.parent.sh || !parent.parent.sh.loaded) ? Theme.ink3
                         : (parent.parent.sh.state === "ok"
                            ? (parent.parent.sh.degraded ? Theme.warn : Theme.good)
                         : parent.parent.sh.state === "intermittent" ? Theme.warn
                         : parent.parent.sh.state === "unreachable" ? Theme.bad
                         : parent.parent.sh.state === "unknown" ? Theme.ink3
                         : (parent.parent.sh.ok ? Theme.good
                            : ((!parent.parent.sh.reachable || parent.parent.sh.circuitOpen) ? Theme.bad : Theme.warn)))
                }
                Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("STORAGE SUBSYSTEM"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.2 }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        var sh = parent.parent.sh;
                        if (!sh || !sh.loaded) return qsTr("Status unknown");
                        switch (sh.state) {
                        // `state` ALONE IS NOT THE VERDICT. When the breaker latches, CV
                        // reports state "ok" with degraded true and circuit_open true —
                        // the agent answers, the service has stopped asking
                        // (storage_health_state.py:112, `degraded = st == "unreachable" or
                        // open_`). This switch used to return "Operational" there, over a
                        // green dot, for a subsystem whose checks were paused; the
                        // pre-912dc73 fallback below had caught it via circuitOpen and the
                        // switch made that line unreachable. Flagged by CV's reply14 §4 with
                        // the serialised row. Degraded is never green here again.
                        case "ok":           return sh.degraded ? qsTr("Degraded") : qsTr("Operational");
                        case "intermittent": return qsTr("Intermittent");
                        case "unreachable":  return qsTr("Unreachable");
                        case "unknown":      return qsTr("Status unknown");
                        }
                        // pre-912dc73 backend: fall back to the old derivation
                        if (sh.ok) return qsTr("Operational");
                        if (!sh.reachable || sh.circuitOpen) return qsTr("Unreachable");
                        if (sh.degraded) return qsTr("Degraded");
                        return sh.status ? sh.status : qsTr("Unknown");
                    }
                    color: {
                        var sh = parent.parent.sh;
                        if (!sh || !sh.loaded) return Theme.ink3;
                        if (sh.state === "ok") return sh.degraded ? Theme.warn : Theme.ink2;
                        if (sh.state === "intermittent") return Theme.warn;
                        if (sh.state === "unreachable") return Theme.bad;
                        if (sh.state === "unknown") return Theme.ink3;
                        if (sh.ok) return Theme.ink2;
                        if (!sh.reachable || sh.circuitOpen) return Theme.bad;
                        return Theme.warn;
                    }
                    font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium
                }
                // "last ok 40s ago" — the age of the last good check, which is what
                // turns "failing" into "failing, and here is how briefly".
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.parent.sh && parent.parent.sh.loaded
                             && parent.parent.sh.state !== "ok" && parent.parent.sh.lastOkAt !== ""
                    text: {
                        var sh = parent.parent.sh;
                        if (!sh || sh.lastOkAt === "") return "";
                        var t = Date.parse(sh.lastOkAt);
                        if (isNaN(t)) return "";
                        var s = Math.max(0, Math.round((root.nowMs - t) / 1000));
                        var age = s < 60 ? qsTr("%1s").arg(s)
                                : s < 3600 ? qsTr("%1m").arg(Math.floor(s / 60))
                                : qsTr("%1h").arg(Math.floor(s / 3600));
                        return "· " + qsTr("last ok %1 ago").arg(age);
                    }
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                }
                // CORRECTION 2026-09-20: this row used to render `reason` as prose, in sans.
                // `reason` is a stable CODE — `storage_agent_unreachable` — and CV's
                // storage_health_state.py:113 names this client as the one printing it
                // verbatim. A guard was being shown a snake_case identifier in the app's own
                // voice, which is the exact mirror of the traceback-as-chrome defect fixed
                // one commit earlier. `reason_text` (CV e8b0a4a) is the sentence, so the
                // sentence is what goes here.
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.parent.sh && parent.parent.sh.reasonText !== ""
                    text: parent.parent.sh ? ("· " + parent.parent.sh.reasonText) : ""
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11; elide: Text.ElideRight
                }
                // The code itself, shown ONLY when CV sent no sentence — an older backend, or
                // a degraded state it has no text for. Mono, because it is a machine fact and
                // must not read as copy. Hiding it instead would trade a mismatched font for a
                // silent fault, which is the worse of the two.
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.parent.sh && parent.parent.sh.reasonText === ""
                             && parent.parent.sh.reason !== ""
                    text: parent.parent.sh ? ("· " + parent.parent.sh.reason) : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight
                }
                // `last_error` is NOT a status phrase — it is str(exc) from the storage agent
                // (cilex-vision agent_client.py:150), truncated to 160 chars server-side. Until
                // 2026-09-20 the model collapsed it into `reason` and this row rendered a raw
                // traceback in the same grey sans as curated copy, with no way to tell them
                // apart. Kept visually distinct now: mono, because the repo renders machine
                // facts in mono, and a guard should never mistake an exception for a sentence
                // the app chose to say. The ask that follows from this went to CV as reply9,
                // narrowed by cilex-pro-mobile's reply11: a code beside the prose for anything
                // the UI states in its OWN voice — never for a foreign error text, which is
                // evidence and stays as it came.
                //
                // Capped and elided because the strip is 32px and one line: the full string
                // lives in the tooltip, so truncation costs nothing. Eliding evidence with no
                // way to read the rest would be the same dishonesty one layer down.
                Text {
                    id: lastErrText
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.parent.sh && parent.parent.sh.lastError !== ""
                    text: parent.parent.sh ? ("· " + parent.parent.sh.lastError) : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                    width: Math.min(implicitWidth, 360); elide: Text.ElideRight
                    MouseArea { id: lastErrMa; anchors.fill: parent; hoverEnabled: true }
                    QC.ToolTip.visible: lastErrMa.containsMouse && lastErrText.truncated
                    QC.ToolTip.text: parent.parent.sh ? parent.parent.sh.lastError : ""
                    QC.ToolTip.delay: 300
                }
                // PLAYBACK subsystem — the 2026-08-10 P0 must never be silent again:
                // a playback auth fault is a station-level fault with its own strip,
                // not a sentence buried inside one camera's video pane.
                Rectangle { width: 1; height: 14; color: Theme.line2; anchors.verticalCenter: parent.verticalCenter
                    visible: root.playbackClient !== null }
                Rectangle {
                    visible: root.playbackClient !== null
                    anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; radius: 4
                    color: (root.playbackClient && root.playbackClient.authFault) ? Theme.bad : Theme.good
                }
                Text {
                    visible: root.playbackClient !== null
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("PLAYBACK"); color: Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.2
                }
                Text {
                    visible: root.playbackClient !== null
                    anchors.verticalCenter: parent.verticalCenter
                    text: (root.playbackClient && root.playbackClient.authFault)
                          ? qsTr("Not authorised — recorded playback and export are DOWN")
                          : qsTr("Operational")
                    color: (root.playbackClient && root.playbackClient.authFault) ? Theme.bad : Theme.ink2
                    font.family: Theme.fontSans; font.pixelSize: 12
                    font.weight: (root.playbackClient && root.playbackClient.authFault) ? Font.DemiBold : Font.Medium
                }
                Text {
                    visible: root.playbackClient && root.playbackClient.authFault && root.playbackClient.authFaultDetail !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.playbackClient ? ("· " + root.playbackClient.authFaultDetail) : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight
                }
            }
        }

        Rectangle {
            objectName: "availabilityLastKnownNotice"
            visible: root.backendStatusStale
            Layout.fillWidth: true
            implicitHeight: lastKnownNotice.implicitHeight + 16
            color: Theme.warnDim
            Text {
                id: lastKnownNotice
                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 18; anchors.rightMargin: 18
                text: qsTr("Camera statuses are last known; Vision updates are unavailable.")
                color: Theme.warn; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap
            }
        }

        // Journal activity is independent from current camera/recording status.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.bg
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 12
                Text { text: qsTr("Availability log"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                Text { text: availabilityHistory.summary; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideRight }
                Text { text: qsTr("Pending: %1").arg(root.availabilityService && root.availabilityService.status.pendingCount !== undefined ? root.availabilityService.status.pendingCount : "—"); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                QC.Button { objectName: "availabilityOpenHistory"; text: qsTr("History and sync"); enabled: root.availabilityService !== null; onClicked: availabilityHistory.open() }
            }
        }

        // ===== stat cards strip =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 96
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

            component Card: Item {
                id: card
                objectName: "healthMetric-" + key
                property string key: ""
                property string label: ""
                property int value: 0
                property color numColor: Theme.ink
                property bool last: false
                // The backend cannot report this figure at all. A stat card is read as a
                // measurement, so a hard 0 here would be a green-by-default for a condition
                // nobody is measuring — "absent data renders as unknown, never as healthy".
                // Renders an em dash, carries the reason, and is NOT a filter (filtering on
                // a state no camera can hold just empties the table).
                property bool unknown: false
                property string unknownWhy: ""
                Layout.fillWidth: true
                Layout.fillHeight: true
                readonly property bool active: root.activeFilter === card.key
                Rectangle {
                    anchors.fill: parent
                    color: (card.active || cardMa.containsMouse) ? Theme.panel : Theme.bg
                    Rectangle { visible: !card.last; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                    Rectangle { visible: card.active; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 3; color: Theme.accent }
                    Column {
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.leftMargin: 18; anchors.rightMargin: 8; anchors.topMargin: card.active ? 15 : 18
                        spacing: 8
                        Text {
                            text: card.unknown ? "\u2014" : String(card.value)
                            color: card.unknown ? Theme.ink3 : card.numColor
                            font.family: Theme.fontSans; font.pixelSize: 32
                            font.weight: Font.Bold; font.letterSpacing: -1
                        }
                        Text { width: parent.width; text: card.label; color: Theme.ink3; font.family: Theme.fontMono
                            font.pixelSize: card.width < 150 ? 9 : 10; font.weight: Font.DemiBold
                            font.letterSpacing: card.width < 150 ? 0.5 : 1.4; font.capitalization: Font.AllUppercase
                            wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                    }
                    MouseArea {
                        id: cardMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: card.unknown ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: { if (card.unknown) return; root.activeFilter = card.key; root.sel = null }
                    }
                    QC.ToolTip.visible: card.unknown && cardMa.containsMouse
                    QC.ToolTip.text: card.unknownWhy
                    QC.ToolTip.delay: 300
                }
            }

            RowLayout {
                anchors.fill: parent
                spacing: 0
                Card { key: "";         label: qsTr("Visible");       value: root.cameraModel ? root.cameraModel.total : 0;            numColor: Theme.ink }
                Card { key: "online";   label: qsTr("Online");        value: root.cameraModel ? root.cameraModel.onlineCount : 0;      numColor: Theme.good }
                Card { key: "offline";  label: qsTr("Offline");       value: root.cameraModel ? root.cameraModel.offlineCount : 0;     numColor: Theme.bad }
                // DEGRADED is the same dead end as RECENT GAPS below, confirmed from both
                // sides. It counts CameraStatus::Degraded, set ONLY from the camera `status`
                // strings "maintenance" or "error" (CameraModel.cpp:409-410, :620-621).
                // CV measured it 2026-09-20: NOTHING writes either value — the health loop
                // writes only online|offline (camera_health.py:121,126), provisioner_import
                // COMPUTES status rather than reading it from the upload (:156), no request
                // model exposes the field, and the two literals appear in their repo only in
                // migration 0001's CHECK constraint that permits them. Live pilot: 133 online,
                // 3 offline, zero of either.
                Card {
                    key: "degraded"; label: qsTr("Degraded"); numColor: Theme.accent
                    value: root.cameraModel ? root.cameraModel.degradedCount : 0
                    unknown: !root.demoStore
                    unknownWhy: qsTr("The server never reports a camera as degraded. This is not a count of zero — nothing is measuring it.")
                }
                Card { key: "notrec"; label: qsTr("Recording stopped"); value: root.cameraModel ? root.cameraModel.notRecordingCount : 0; numColor: Theme.bad }
                Card { key: "archive"; label: qsTr("Archive delayed"); value: root.cameraModel && root.cameraModel.archiveDelayedCount !== undefined ? root.cameraModel.archiveDelayedCount : 0; numColor: Theme.warn }
                Card { key: "recunknown"; label: qsTr("Recording unknown"); value: root.cameraModel ? root.cameraModel.recUnknownCount : 0; numColor: Theme.warn }
                Card { key: "archiveunknown"; label: qsTr("Archive unknown"); value: root.cameraModel && root.cameraModel.archiveUnknownCount !== undefined ? root.cameraModel.archiveUnknownCount : 0; numColor: Theme.warn }
                // RECENT GAPS reads UNKNOWN, not 0, and the reason is a dead end on the wire.
                // `recordingGapCount` counts cameras in CameraStatus::RecordingGap, which is
                // reachable only from the string "recording_gap" (CameraModel.cpp:64). CV's
                // /streams never sends it: recording_state() (streams.py:162) returns exactly
                // armed | disabled | offline | recording | stalled | unknown, and the token
                // appears nowhere in their repo except one playback test's function name
                // (verified 2026-09-20). So this card has read 0 since it was written, and
                // read 0 through the 21.9 GB footage loss of 2026-09-14 — the very event an
                // operator would look at it to catch.
                // Not deleted: the concept is real and CV has no recording-gap signal at all
                // (their reply to the 2026-09-15 letter: the counter built for it,
                // cilex_recorder_segments_dropped_total, exists and is never incremented).
                // An em dash says "nobody is measuring this"; a 0 said "measured, all clear".
                Card {
                    key: "gap"; label: qsTr("Recent gaps"); numColor: Theme.accent; last: true
                    value: root.cameraModel ? root.cameraModel.recordingGapCount : 0
                    unknown: !root.demoStore
                    unknownWhy: qsTr("The server does not report recording gaps. This is not a count of zero — nothing is measuring it.")
                }
            }
        }

        // ===== table + detail =====
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ---- table ----
            ColumnLayout {
                id: tableColumn
                objectName: "healthCameraTable"
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // header
                Rectangle {
                    id: tableHeader
                    objectName: "healthCameraHeader"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    color: Theme.bg
                    clip: true
                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line2 }
                    component Th: Text {
                        height: 38; verticalAlignment: Text.AlignVCenter
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
                    }
                    RowLayout {
                        x: 14 - list.contentX; width: list.contentWidth - 28; height: parent.height; spacing: 0
                        Item {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            z: 2; transform: Translate { x: list.contentX }
                            Rectangle { x: -14; width: parent.width + 14; height: parent.height - 1; color: Theme.bg }
                            FilterTrigger {
                                id: cameraTrigger; objectName: "healthFilterCamera"; column: "camera"; label: qsTr("Camera")
                                height: parent.height; width: Math.max(0, parent.width - (root.anyColumnFilter ? countReadout.implicitWidth + 10 : 0))
                            }
                            Text {
                                id: countReadout; objectName: "healthFilterCount"; visible: root.anyColumnFilter
                                x: cameraTrigger.buttonWidth - 6 + 10; anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("%1 of %2").arg(root.viewRows.length).arg(root._rows.length)
                                color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.Medium
                            }
                        }
                        FilterTrigger { objectName: "healthFilterGroup"; column: "group"; label: qsTr("Group"); Layout.preferredWidth: root.wGroup }
                        FilterTrigger { objectName: "healthFilterLive"; column: "live"; label: qsTr("Live"); Layout.preferredWidth: root.wLive }
                        FilterTrigger { objectName: "healthFilterRecording"; column: "rec"; label: qsTr("Recording"); Layout.preferredWidth: root.wRec }
                        Th { text: qsTr("Last seen"); Layout.preferredWidth: root.wSeen }
                        FilterTrigger { objectName: "healthFilterIssue"; column: "issue"; label: qsTr("Recent issue"); Layout.preferredWidth: root.wIssue }
                        Item {
                            Layout.preferredWidth: root.wAct; Layout.fillHeight: true
                            TextMetrics {
                                id: clearMeasure; text: qsTr("Clear").toUpperCase()
                                font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.2
                            }
                            Rectangle {
                                objectName: "healthFilterClearAll"; visible: root.anyColumnFilter
                                readonly property bool showLabel: clearMeasure.advanceWidth + 26 <= parent.width
                                x: -6; anchors.verticalCenter: parent.verticalCenter; height: 24
                                width: showLabel ? clearMeasure.advanceWidth + 26 : 22
                                color: clearAllMouse.containsMouse ? Theme.panel : "transparent"
                                Row {
                                    anchors.centerIn: parent; spacing: 4
                                    Icon { anchors.verticalCenter: parent.verticalCenter; name: "x"; size: 10; color: Theme.accent }
                                    Text { visible: parent.parent.showLabel; text: qsTr("Clear").toUpperCase(); color: Theme.accent; font: clearMeasure.font }
                                }
                                MouseArea { id: clearAllMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.clearColumnFilters() }
                                QC.ToolTip.visible: clearAllMouse.containsMouse
                                QC.ToolTip.text: qsTr("Clear all column filters")
                                QC.ToolTip.delay: 300
                            }
                        }
                    }
                }

                // rows
                ListView {
                    id: list
                    objectName: "healthCameraList"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: Math.max(width, root.tableMinimumWidth)
                    flickableDirection: Flickable.AutoFlickDirection
                    model: root.viewRows
                    boundsBehavior: Flickable.StopAtBounds
                    QC.ScrollBar.vertical: QC.ScrollBar { }
                    QC.ScrollBar.horizontal: QC.ScrollBar {
                        objectName: "healthColumnScroll"
                        policy: list.contentWidth > list.width ? QC.ScrollBar.AlwaysOn : QC.ScrollBar.AlwaysOff
                        active: list.contentWidth > list.width
                    }

                    delegate: Rectangle {
                        id: rowItem
                        objectName: "healthRow-" + modelData.camId
                        required property var modelData
                        required property int index
                        width: ListView.view.contentWidth
                        height: 52
                        readonly property bool isSel: root.sel && root.sel.camId === modelData.camId
                        color: isSel ? Theme.accentSoft : (rowMa.containsMouse ? Theme.panel : "transparent")
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sel = modelData }

                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                            // Camera
                            Item {
                                z: 2; transform: Translate { x: list.contentX }
                                Layout.fillWidth: true; Layout.fillHeight: true
                                Rectangle {
                                    x: -14; width: parent.width + 14; height: parent.height - 1
                                    color: rowItem.isSel ? Qt.tint(Theme.bg, Theme.accentSoft) : rowMa.containsMouse ? Theme.panel : Theme.bg
                                }
                                ColumnLayout {
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                    Text { text: rowItem.modelData.name; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: rowItem.modelData.camId; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                            }
                            // Group
                            Text { objectName: "healthCellGroup"; Layout.preferredWidth: root.wGroup; text: rowItem.modelData.groupName; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                            // Live
                            Item { objectName: "healthCellLive"; Layout.preferredWidth: root.wLive; Layout.fillHeight: true
                                LiveStatusBadge { anchors.verticalCenter: parent.verticalCenter; state: rowItem.modelData.live } }
                            // Recording
                            Item { objectName: "healthCellRecording"; Layout.preferredWidth: root.wRec; Layout.fillHeight: true
                                RecordingStatusBadge { anchors.verticalCenter: parent.verticalCenter; health: root.health(rowItem.modelData); state: rowItem.modelData.recording
                                    motionKnown: rowItem.modelData.motionKnown === true; motionReady: rowItem.modelData.motionReady === true
                                    lastSegmentAtMs: rowItem.modelData.lastSegmentAt ? Date.parse(rowItem.modelData.lastSegmentAt) : -1
                                    lastVmdAtMs: rowItem.modelData.motionLastVmdAt ? Date.parse(rowItem.modelData.motionLastVmdAt) : -1 } }
                            // Last seen
                            Text { Layout.preferredWidth: root.wSeen; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 12
                                text: (rowItem.modelData.live === CameraStatus.Offline || rowItem.modelData.live === CameraStatus.NoSignal)
                                      ? (rowItem.modelData.lastSeen ? rowItem.modelData.lastSeen : "—") : "now" }
                            // Recent issue
                            Text { objectName: "healthCellIssue"; Layout.preferredWidth: root.wIssue; color: root.issueColor(rowItem.modelData); font.family: Theme.fontSans; font.pixelSize: 11; elide: Text.ElideRight; text: root.issueText(rowItem.modelData) }
                            // action
                            Item { Layout.preferredWidth: root.wAct; Layout.fillHeight: true
                                Btn { anchors.verticalCenter: parent.verticalCenter; small: true; ghost: true; label: qsTr("Open"); onClicked: root.openLive(rowItem.modelData) } }
                        }
                    }

                    // empty state
                    EmptyState {
                        objectName: "healthFilterEmptyState"
                        x: list.contentX; y: list.contentY; width: list.width; height: list.height
                        visible: root.viewRows.length === 0
                        icon: "check"
                        title: qsTr("Nothing here")
                        subtitle: qsTr("No cameras match this filter.")
                        actionLabel: root.anyColumnFilter ? qsTr("Clear column filters") : ""
                        onAction: root.clearColumnFilters()
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
                    anchors.fill: parent
                    anchors.leftMargin: 1
                    spacing: 0

                    // header
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 56; color: Theme.panel
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 10; spacing: 8
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { text: root.sel ? root.sel.name : ""; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: root.sel ? (root.sel.camId + "  ·  " + root.sel.groupName) : ""; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            IconButton { name: "x"; iconColor: Theme.ink2; hoverIcon: Theme.ink; hoverBg: Theme.panel2; hoverBorder: Theme.line2; tip: qsTr("Close"); onClicked: root.sel = null }
                        }
                    }

                    // body
                    QC.ScrollView {
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                        contentWidth: availableWidth
                        ColumnLayout {
                            width: 380 - 1
                            spacing: 0

                            // 16:9 preview
                            Rectangle {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14
                                Layout.preferredHeight: (width) * 9 / 16
                                color: "#000"
                                // offline -> NO SIGNAL, else placeholder schematic
                                Rectangle {
                                    anchors.fill: parent; visible: root.selOffline; color: "#0a0d11"
                                    Column {
                                        anchors.centerIn: parent; spacing: 4
                                        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 28; color: Theme.bad }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("NO SIGNAL"); color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 13; font.letterSpacing: 1.3 }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; visible: root.sel && root.sel.lastSeen; text: root.sel ? ("last seen " + root.sel.lastSeen) : ""; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                    }
                                }
                                PlaceholderVid {
                                    anchors.fill: parent; visible: !root.selOffline
                                    pattern: root.sel ? (root.sel.pattern || 0) : 0
                                    geom: "lobby"
                                    label: root.sel ? root.sel.camId : ""
                                }
                                // badges
                                Row {
                                    anchors.top: parent.top; anchors.left: parent.left; anchors.margins: 6; spacing: 4
                                    LiveStatusBadge { state: root.sel ? root.sel.live : CameraStatus.LiveUnknown }
                                    RecordingStatusBadge { health: root.health(root.sel); state: root.sel ? root.sel.recording : CameraStatus.RecUnknown
                                        motionKnown: root.sel ? root.sel.motionKnown === true : false
                                        motionReady: root.sel ? root.sel.motionReady === true : false
                                        lastSegmentAtMs: (root.sel && root.sel.lastSegmentAt) ? Date.parse(root.sel.lastSegmentAt) : -1
                                        lastVmdAtMs: (root.sel && root.sel.motionLastVmdAt) ? Date.parse(root.sel.motionLastVmdAt) : -1 }
                                }
                            }

                            // status callout
                            Rectangle {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 12
                                color: Theme.bg
                                implicitHeight: calloutText.implicitHeight + 20
                                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 3; color: root.sel ? root.calloutColor(root.sel) : Theme.ink3 }
                                Text {
                                    id: calloutText
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: 12; anchors.rightMargin: 12
                                    textFormat: Text.StyledText; wrapMode: Text.WordWrap
                                    text: root.sel ? root.calloutText(root.sel) : ""
                                    color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; lineHeight: 1.35
                                }
                            }

                            // KV facts
                            component KV: RowLayout {
                                id: kv; property string k: ""; property string v: ""
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; spacing: 8
                                Text { text: kv.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true }
                                Text { text: kv.v; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                            }
                            Item { Layout.preferredHeight: 8 }
                            KV { k: "Live status"; v: root.sel ? root.liveText(root.sel.live) : "" }
                            KV { k: "Recording status"; v: root.sel ? root.recText(root.sel) : "" }
                            KV { k: "Last seen"; v: root.sel ? (root.selOffline ? (root.sel.lastSeen ? root.sel.lastSeen : "—") : "now") : "" }
                            KV { k: qsTr("Archive status"); v: root.sel ? root.archiveText(root.sel) : "" }
                            KV { k: qsTr("Last catalogue end"); v: root.sel && root.health(root.sel).last_available_end ? Qt.formatDateTime(new Date(root.health(root.sel).last_available_end), "ddd d MMM, HH:mm:ss") : "—" }
                            KV { k: qsTr("Last fragment start"); v: (root.sel && root.sel.lastSegmentAt) ? Qt.formatDateTime(new Date(root.sel.lastSegmentAt), "ddd d MMM, HH:mm:ss") : "—" }
                            KV { visible: root.sel !== null && root.sel.motionKnown === true; k: "Motion detector"
                                 v: !root.sel ? "" : (!root.sel.motionReady ? ("Not ready" + (root.sel.motionStatus ? " · " + root.sel.motionStatus : ""))
                                    : (root.sel.motionConfirmed ? qsTr("Verified") : qsTr("Ready, never verified"))) }
                            KV { visible: root.sel !== null && root.sel.motionKnown === true; k: "Last verified motion"
                                 v: (root.sel && root.sel.motionLastVmdAt) ? Qt.formatDateTime(new Date(root.sel.motionLastVmdAt), "ddd d MMM, HH:mm:ss") : "—" }
                            KV { k: "Group"; v: root.sel ? root.sel.groupName : "" }

                            // actions
                            Flow {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14; Layout.bottomMargin: 14
                                spacing: 6
                                Btn { icon: "monitor"; label: qsTr("Open live"); onClicked: if (root.sel) root.openLive(root.sel) }
                                Btn { icon: "playback"; label: qsTr("Playback"); onClicked: if (root.sel) root.openPlayback(root.sel) }
                                Btn { icon: "bell"; label: qsTr("Events"); ghost: true; onClicked: if (root.sel) root.openEvents(root.sel) }
                            }
                        }
                    }
                }
            }
        }
    }
}
