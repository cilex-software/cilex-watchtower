import QtQuick
import QtQuick.Controls.Basic
import QtTest
import Watchtower
import "imports/Watchtower/HealthFilters.js" as Filters

Item {
    id: stage
    width: 1440; height: 900
    property bool captured: false
    property int pollCount: 0
    FontLoader { source: "fonts/SpaceGrotesk-Variable.ttf" }
    FontLoader { source: "fonts/JetBrainsMono-Regular.ttf" }
    FontLoader { source: "fonts/JetBrainsMono-Medium.ttf" }
    FontLoader { source: "fonts/JetBrainsMono-SemiBold.ttf" }
    Rectangle { anchors.fill: parent; color: Theme.bg }
    TitleBar { width: stage.width; height: 36; win: stage.Window.window; subtitle: qsTranslate("Main", "Health") }
    NavRail { y: 36; width: 72; height: stage.height - 36; section: "health"; isAdmin: true; unackCount: 200 }
    TopBar { x: 72; y: 36; width: stage.width - 72; height: 52; cameraModel: roster; initials: "AD" }
    QtObject {
        id: storage
        property bool loaded: true
        property string state: "ok"
        property bool degraded: false
        property string lastOkAt: ""
        property string reasonText: ""
        property string reason: ""
        property string lastError: ""
        function refresh() { }
    }
    QtObject { id: playback; property bool authFault: false; property string authFaultDetail: "" }
    QtObject {
        id: availability
        property var status: ({state: "provisioning_required", pendingCount: 2690})
        property var history: []
        property bool canSync: false
        property bool canViewStationEvents: false
        property bool busy: false
        signal stateChanged()
    }
    QtObject {
        id: roster
        property var cameras: []
        property int total: cameras.length
        property int onlineCount: total - 2
        property int offlineCount: 2
        property int degradedCount: 0
        property int recordingGapCount: 0
        property int notRecordingCount: 2
        property int archiveDelayedCount: 27
        property int recUnknownCount: 24
        property int archiveUnknownCount: 0
        property int recordingHealthUnknownCount: 24
        property int healthRev: 0
        property bool backendEvidenceFresh: true
        signal countsChanged()
        function page(query, metric, sort, page, size) {
            return cameras.filter(function(c) {
                if (metric === "online") return c.live === CameraStatus.Live;
                if (metric === "offline") return c.live === CameraStatus.Offline;
                if (metric === "notrec") return c.recordingHealth.capture_state === "stopped";
                if (metric === "archive") return c.recordingHealth.archive_state === "delayed";
                if (metric === "recunknown") return c.recordingHealth.capture_state === "unknown";
                if (metric === "archiveunknown") return c.recordingHealth.archive_state === "unknown";
                return true;
            });
        }
        function recordingHealthFor(id) {
            var c = cameras.find(function(cam) { return cam.camId === id });
            return c ? c.recordingHealth : ({});
        }
        function cameraByBackendId(id) {
            return cameras.find(function(cam) { return cam.camId === id }) || ({});
        }
    }
    HealthScreen {
        id: health; x: 72; y: 88; width: stage.width - 72; height: stage.height - 88
        cameraModel: roster; availabilityService: availability; storageHealth: storage; playbackClient: playback
    }
    Timer { id: polls; interval: 15000; repeat: true; onTriggered: { ++roster.healthRev; roster.countsChanged(); ++stage.pollCount } }
    Component { id: recordingBadge; RecordingStatusBadge { } }
    Component { id: liveBadge; LiveStatusBadge { } }
    TestCase {
        id: tests
        name: "HealthColumnFilters"
        when: windowShown
        function fixture() {
            var rows = [], now = Date.now();
            for (var i = 0; i < 133; ++i) {
                var offline = i < 2, group = offline ? "4стр" : ["Внутри", "Entrances", "Крыша", "Лифты", "Улица"][i % 5];
                var capture = offline ? "stopped" : i < 29 ? "progressing" : i < 53 ? "unknown" : "idle";
                var archive = i >= 2 && i < 29 ? "delayed" : capture === "idle" ? "idle" : "current";
                rows.push({camId: "fixture-camera-"+String(i).padStart(3, "0"), name: offline ? (i ? "4.1.6 Холл" : "4.1 Крыша") : "Камера "+i,
                    groupName: group, live: offline ? CameraStatus.Offline : CameraStatus.Live,
                    recording: capture === "idle" ? CameraStatus.Armed : CameraStatus.Recording,
                    lastSeen: offline ? "26 Oct 22:52" : "now", lastSegmentAt: new Date(now - 120000).toISOString(),
                    motionKnown: capture === "idle", motionReady: true, motionConfirmed: true,
                    motionLastVmdAt: new Date(now - 14400000).toISOString(),
                    recordingHealth: {capture_state: capture, archive_state: archive}});
            }
            rows[54].name = rows[55].name = "Одинаковое имя";
            rows[56].groupName = "";
            rows[57].lastSegmentAt = "";
            rows[58].motionReady = false;
            rows[59].motionLastVmdAt = new Date(now - 60000).toISOString(); rows[59].lastSegmentAt = "";
            return rows;
        }
        function initTestCase() { roster.cameras = fixture(); roster.countsChanged(); wait(100) }
        function init() {
            polls.stop(); roster.cameras = fixture(); roster.countsChanged(); health.visible = true;
            health.clearColumnFilters(); health.activeFilter = ""; health.sel = "@PANEL@" === "true" ? roster.cameras[60] : null;
            stage.width = Number("@WIDTH@"); stage.height = 900; stage.Window.window.width = Number("@WIDTH@"); stage.Window.window.height = 900;
            wait(30);
        }
        function cleanup() { item("healthColumnPopup").close(); polls.stop() }
        function item(name) { var found = findChild(stage, name); verify(found !== null, name); return found }
        function open(column, name) {
            var trigger = item(name);
            var list = item("healthCameraList"), table = item("healthCameraTable");
            if (column !== "camera") {
                var x = trigger.mapToItem(table, 0, 0).x;
                if (x < 174) list.contentX = Math.max(0, list.contentX + x - 174);
                if (x + 100 > table.width) list.contentX = Math.min(list.contentWidth - list.width, list.contentX + x + 100 - table.width);
            }
            mouseClick(trigger, 4, 19);
            tryCompare(item("healthColumnPopup"), "visible", true);
            compare(item("healthColumnPopup").column, column);
            return item("healthColumnPopup");
        }
        function capture(name) {
            stage.captured = false;
            stage.Window.window.contentItem.grabToImage(function(image) {
                image.saveToFile("@OUTPUT@/"+name+".png"); stage.captured = true;
            });
            tryCompare(stage, "captured", true);
        }
        function test_instantApplyAndNormalization() {
            compare(health.viewRows.length, 133);
            var popup = open("live", "healthFilterLive");
            compare(popup.valueRows.length, 2);
            verify(popup.allChecked); compare(popup.checkedCount, 2);
            popup.toggleValue("LIVE");
            compare(health.viewRows.length, 2);
            compare(health.colFilters.live.length, 1); compare(health.colFilters.live[0], "OFFLINE");
            compare(popup.checkedCount, 1); verify(!popup.allChecked);
            verify(item("healthFilterLive").filtered);
            popup.toggleValue("LIVE");
            compare(health.colFilters.live, null); verify(!item("healthFilterLive").filtered);
            compare(health.viewRows.length, 133); verify(popup.allChecked);
            popup.toggleListed(); compare(health.colFilters.live.length, 0); compare(health.viewRows.length, 0);
            compare(popup.checkedCount, 0); verify(item("healthFilterLive").filtered);
            popup.toggleListed(); compare(health.colFilters.live, null);
        }
        function test_cascadeAndHiddenIncludedKeys() {
            health.setIncluded("live", ["OFFLINE"]);
            health.setIncluded("group", ["4стр", "Крыша"]);
            var popup = open("group", "healthFilterGroup");
            compare(popup.valueRows.length, 1); compare(popup.valueRows[0].key, "4стр"); compare(popup.valueRows[0].count, 2);
            compare(popup.totalCount, 2); compare(health.viewRows.length, 2);
            popup.query = "4стр"; compare(popup.listed.length, 1);
            popup.toggleListed(); compare(health.viewRows.length, 0);
            verify(health.colFilters.group.indexOf("Крыша") >= 0);
            popup.toggleListed(); compare(health.viewRows.length, 2);
            verify(health.colFilters.group.indexOf("Крыша") >= 0);
        }
        function test_cameraSearchNamesIdsDuplicateNamesAndEnter() {
            var popup = open("camera", "healthFilterCamera"), search = item("healthFilterSearch");
            verify(search.activeFocus);
            keyClick(Qt.Key_F); compare(popup.query, "f");
            popup.query = "одинаковое ИМЯ"; compare(popup.listed.length, 2);
            capture("camera-search-@LANGUAGE@");
            keyClick(Qt.Key_Return); tryCompare(popup, "visible", false);
            compare(health.viewRows.length, 2); compare(health.colFilters.camera.length, 2);
            verify(health.colFilters.camera[0] !== health.colFilters.camera[1]);
            compare(item("healthFilterCount").text, qsTranslate("HealthScreen", "%1 of %2").arg(2).arg(133));
            popup = open("camera", "healthFilterCamera");
            popup.query = "FIXTURE-CAMERA-001"; compare(popup.listed.length, 1);
            keyClick(Qt.Key_Enter); tryCompare(popup, "visible", false);
            compare(health.viewRows.length, 1); compare(health.viewRows[0].camId, "fixture-camera-001");
            popup = open("camera", "healthFilterCamera");
            popup.query = "no-match"; compare(popup.listed.length, 0);
            keyClick(Qt.Key_Return); verify(popup.visible); // Prototype leaves an empty search open.
            keyClick(Qt.Key_Escape); tryCompare(popup, "visible", false);
        }
        function test_searchSelectAllOnlyAndFooter() {
            var popup = open("group", "healthFilterGroup");
            popup.query = "внут"; compare(popup.listed.length, 1);
            popup.toggleListed(); verify(!popup.isChecked("Внутри"));
            verify(popup.isChecked("Крыша"));
            popup.query = ""; verify(popup.checkedCount > 0 && popup.checkedCount < popup.listed.length);
            mouseMove(item("healthFilterValues"), 80, 16); wait(10);
            var only = findChild(item("healthFilterValues"), "healthFilterOnly");
            verify(only !== null && only.visible);
            capture("only-hover-@LANGUAGE@");
            mouseClick(only); compare(health.colFilters.group.length, 1); verify(popup.visible);
            mouseClick(item("healthFilterDone")); tryCompare(popup, "visible", false);
            popup = open("group", "healthFilterGroup");
            verify(popup.canClear);
            mouseClick(item("healthFilterClear")); tryCompare(popup, "visible", false);
            compare(health.colFilters.group, null);
            popup = open("group", "healthFilterGroup");
            verify(!popup.canClear); mouseClick(item("healthFilterClear")); verify(popup.visible);
        }
        function test_onePopupToggleEscapeAndOutside() {
            var popup = open("live", "healthFilterLive");
            mouseClick(item("healthFilterLive"), 4, 19); tryCompare(popup, "visible", false);
            popup = open("live", "healthFilterLive");
            mouseClick(item("healthFilterRecording"), 4, 19);
            tryCompare(popup, "column", "rec"); verify(popup.visible);
            keyClick(Qt.Key_Escape); tryCompare(popup, "visible", false);
            popup = open("live", "healthFilterLive");
            mouseClick(health, 15, 50); tryCompare(popup, "visible", false);
        }
        function test_metricAndSelectionLifetimeAndEmptyAction() {
            var selected = roster.cameras[60]; health.sel = selected;
            health.setIncluded("live", ["OFFLINE"]);
            compare(health.sel.camId, selected.camId);
            health.visible = false; health.visible = true;
            compare(health.colFilters.live[0], "OFFLINE");
            mouseClick(item("healthMetric-offline")); compare(health.sel, null);
            compare(health.colFilters.live[0], "OFFLINE"); compare(health._rows.length, 2);
            compare(health.viewRows.length, 2);
            health.setIncluded("live", ["LIVE"]); compare(health.viewRows.length, 0);
            var empty = item("healthFilterEmptyState"); verify(empty.visible);
            compare(empty.actionLabel, qsTranslate("HealthScreen", "Clear column filters"));
            wait(30); // Let the detail-panel close and the centred action finish layout.
            mouseClick(empty.children[0].children[3]); compare(health.activeFilter, "offline"); compare(health.viewRows.length, 2);
            health.setIncluded("camera", ["fixture-camera-000"]);
            mouseClick(item("healthMetric-")); compare(health.activeFilter, "");
            compare(health.viewRows.length, 1);
            mouseClick(item("healthFilterClearAll")); verify(!health.anyColumnFilter);
        }
        function test_newKeysRemainExcludedAndBackgroundPollsKeepScroll() {
            health.setIncluded("live", ["LIVE"]); wait(30);
            var list = item("healthCameraList"); list.contentY = 1500;
            var y = list.contentY, revision = health._viewRevision;
            roster.countsChanged(); ++roster.healthRev; roster.countsChanged(); wait(30);
            compare(list.contentY, y); compare(health._viewRevision, revision);
            var next = roster.cameras.slice();
            next[10] = Object.assign({}, next[10], {live: CameraStatus.NoSignal}); roster.cameras = next; roster.countsChanged(); wait(30);
            compare(health.viewRows.length, 130);
            verify(health.colFilters.live.indexOf("NO SIGNAL") < 0);
            open("live", "healthFilterLive");
            verify(item("healthColumnPopup").valueRows.some(function(value) { return value.key === "NO SIGNAL" }));
            item("healthColumnPopup").close();
            compare(list.contentY, y - 52); // The same top camera survives removal of an earlier row.
        }
        function test_recordingCategoriesMatchShippingBadgePrecedence() {
            var badge = recordingBadge.createObject(stage), live = liveBadge.createObject(stage);
            var captures = ["unknown", "progressing", "stopped", "idle", "disabled"];
            var archives = [undefined, "unknown", "current", "delayed", "unavailable", "idle", "disabled"];
            for (var state = 0; state <= 6; ++state) {
                live.state = state;
                compare(Filters.liveKey({live: state}), Filters.liveOrder.find(function(key) { return qsTranslate("LiveStatusBadge", key) === live.label }));
                for (var freshness = 0; freshness < 3; ++freshness)
                for (var c = 0; c < captures.length; ++c) for (var a = 0; a < archives.length; ++a) {
                    var cam = {recording: state, motionKnown: true, motionReady: true, lastSegmentAt: new Date().toISOString()};
                    var h = {capture_state: captures[c], archive_state: archives[a]};
                    if (freshness > 0) { h.version = 1; h.fresh = freshness === 2; }
                    badge.state = state; badge.health = h; badge.motionKnown = true; badge.motionReady = true;
                    badge.lastSegmentAtMs = Date.parse(cam.lastSegmentAt); badge.lastVmdAtMs = -1;
                    compare(badge.label, health.recordingCategoryLabel(Filters.recCategory(cam, h)), JSON.stringify([state,h]));
                }
            }
            var armed = {recording: CameraStatus.Armed, motionKnown: true, motionReady: false};
            compare(Filters.recCategory(armed, {}), "ARMED · NOT READY");
            armed.motionReady = true; compare(Filters.recCategory(armed, {}), "ARMED · no motion");
            armed.lastMotionAtMs = Date.now() - 7200000; compare(Filters.recCategory(armed, {}), "ARMED");
            armed.motionLastVmdAt = new Date().toISOString(); compare(Filters.recCategory(armed, {}), "ARMED · ARCHIVE DELAY");
            armed.motionLastVmdAt = ""; armed.lastMotionAtMs = -1;
            armed.lastSegmentAt = "invalid"; compare(Filters.recCategory(armed, {}), "ARMED · no motion");
            armed.lastSegmentAt = new Date(Date.now() - 259200000).toISOString();
            compare(Filters.recCategory(armed, {}), "ARMED · no motion");
            badge.destroy(); live.destroy();
        }
        function test_matrix_data() {
            return [{tag:"1440-closed", width:1440, panel:false}, {tag:"1440-open", width:1440, panel:true},
                    {tag:"1200-closed", width:1200, panel:false}, {tag:"1200-open", width:1200, panel:true}];
        }
        function test_matrix(data) {
            stage.width = data.width; stage.Window.window.width = data.width;
            if (data.panel) health.sel = roster.cameras[60];
            wait(30);
            var definitions = [["camera","healthFilterCamera"], ["group","healthFilterGroup"], ["live","healthFilterLive"],
                               ["rec","healthFilterRecording"], ["issue","healthFilterIssue"]];
            for (var d = 0; d < definitions.length; ++d) {
                var def = definitions[d], trigger = item(def[1]);
                verify(!trigger.filtered && !trigger.opened);
                mouseMove(trigger, 4, 19); wait(5);
                var popup = open(def[0], def[1]); verify(trigger.opened);
                var table = item("healthCameraTable"), point = popup.parent.mapToItem(table, popup.x, popup.y);
                verify(point.x >= 7.9, "left inset "+data.tag+"/"+def[0]);
                verify(point.x + popup.width <= table.width - 7.9, "right clamp "+data.tag+"/"+def[0]);
                compare(Math.round(point.y), 37);
                compare(popup.width, [300,240,220,270,260][d]);
                if (d === 3) capture("recording-@LANGUAGE@-"+data.tag);
                health.setIncluded(def[0], [popup.valueRows[0].key]); verify(trigger.filtered);
                verify(item("healthFilterCount").visible);
                if (def[0] === "issue") {
                    var list = item("healthCameraList");
                    list.contentX = list.contentWidth - list.width;
                    var count = item("healthFilterCount"), p = count.mapToItem(table, 0, 0);
                    verify(p.x >= 0 && p.x + count.width < table.width, "count stays visible on horizontal scroll");
                    var clear = item("healthFilterClearAll");
                    compare(clear.showLabel, "@LANGUAGE@" !== "ru");
                    if (data.width === 1200 && data.panel) capture("scroll-@LANGUAGE@-"+data.tag);
                }
                popup.close();
                health.clearColumnFilters();
            }
            var first = findChild(item("healthCameraList"), "healthRow-fixture-camera-000"); verify(first !== null);
            for (var col of ["Group","Live","Recording","Issue"]) {
                var header = item("healthFilter"+col), cell = findChild(first, "healthCell"+col);
                verify(Math.abs(header.mapToItem(health, 0, 0).x - cell.mapToItem(health, 0, 0).x) < 1,
                       "header aligns with "+col+"/"+data.tag);
            }
            item("healthCameraList").contentX = 0;
            health.setIncluded("live", ["OFFLINE"]); wait(20);
            verify(item("healthFilterCount").visible);
            var popup = open("group", "healthFilterGroup");
            compare(popup.valueRows.length, 1); compare(popup.valueRows[0].key, "4стр");
            capture("health-@LANGUAGE@-"+data.tag);
            popup.close();
            health.setIncluded("group", ["Крыша"]); wait(20);
            capture("empty-@LANGUAGE@-"+data.tag);
            verify(item("healthFilterEmptyState").actionLabel !== "");
        }
        function test_russianCopyAndUnmeasuredIssue() {
            var popup = open("group", "healthFilterGroup");
            verify(popup.valueRows[popup.valueRows.length - 1].key === "");
            compare(health.recordingCategoryLabel("ARMED · no motion"),
                    "@LANGUAGE@" === "ru" ? "ARMED · нет движения" : "ARMED · no motion");
            if ("@LANGUAGE@" === "ru") {
                compare(qsTranslate("HealthScreen", "Clear filter"), "Сбросить фильтр");
                compare(qsTranslate("HealthScreen", "— (none shown)"), "— (не указано)");
            }
            popup.close();
            popup = open("issue", "healthFilterIssue");
            verify(popup.valueRows.some(function(value) { return value.key === "—" }));
        }
        function test_twoRealBackgroundPolls() {
            health.setIncluded("live", ["LIVE"]); wait(20);
            var list = item("healthCameraList"); list.contentY = 1600;
            var y = list.contentY, revision = health._viewRevision;
            stage.pollCount = 0; polls.start();
            tryCompare(stage, "pollCount", 2, 32000);
            compare(list.contentY, y); compare(health._viewRevision, revision);
            capture("after-two-polls-@LANGUAGE@");
        }
    }
}
