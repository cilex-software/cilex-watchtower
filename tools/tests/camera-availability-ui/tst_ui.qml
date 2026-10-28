import QtQuick
import QtQuick.Controls.Basic
import QtTest
import Watchtower

Item {
    id: screen
    width: 1200; height: 820
    FontLoader { source: "fonts/SpaceGrotesk-Variable.ttf" }
    FontLoader { source: "fonts/JetBrainsMono-Regular.ttf" }
    QtObject {
        id: fixture
        property var status: ({state: "ready", pendingCount: 2})
        property var history: []
        property bool canSync: false
        property bool canViewStationEvents: false
        property bool busy: false
        property int syncCalls: 0
        property var refreshCalls: []
        signal stateChanged()
        onHistoryChanged: stateChanged()
        function syncNow() { ++syncCalls; }
        function refreshHistory(camera, from, until) { refreshCalls = refreshCalls.concat([{camera: camera, from: from, until: until}]); }
    }
    QtObject {
        id: roster
        property var rows: [{camId: "allowed", name: "Permitted camera"}]
        signal countsChanged()
        function page() { return rows; }
    }
    AvailabilityHistory { id: panel; parent: screen; service: fixture; cameraModel: roster }
    TestCase {
        name: "CameraAvailabilityUi"
        when: windowShown
        function row(camera, provenance, domain) {
            return {camera_id: camera, provenance: provenance || "client_observed", domain: domain || "live_delivery",
                    transition: "initial", observed_at: "2026-10-29T12:00:00+03:00", duration_ms: null,
                    delivery_state: "pending", backend_observation: null, details: {}};
        }
        function init() {
            panel.close();
            fixture.canSync = false; fixture.canViewStationEvents = false; fixture.busy = false;
            fixture.syncCalls = 0; fixture.refreshCalls = []; fixture.history = [];
            fixture.status = {state: "ready", pendingCount: 2};
            roster.rows = [{camId: "allowed", name: "Permitted camera"}];
            panel.cameraFilter = ""; panel.domainFilter = ""; panel.sourceFilter = ""; panel.windowHours = 24;
            panel.refreshCameras();
        }
        function cleanup() { panel.close(); }
        function test_syncPermissionAndSingleFlight() {
            panel.requestSync(); compare(fixture.syncCalls, 0);
            fixture.canSync = true;
            panel.requestSync(); compare(fixture.syncCalls, 1);
            fixture.busy = true;
            panel.requestSync(); compare(fixture.syncCalls, 1);
            verify(!findChild(panel, "availabilitySyncNow").enabled);
            fixture.busy = false; fixture.canSync = false;
            panel.requestSync(); compare(fixture.syncCalls, 1);
        }
        function test_currentCameraScopeAndStationPermission() {
            fixture.history = [row("allowed"), row("removed-camera"), row(null, "backend_native", "monitoring")];
            compare(panel.filteredRows.length, 1);
            fixture.canViewStationEvents = true;
            compare(panel.filteredRows.length, 3);
            compare(panel.cameraLabel("removed-camera"), "removed-camera");
            roster.rows = []; roster.countsChanged();
            compare(panel.filteredRows.length, 3);
            fixture.canViewStationEvents = false;
            compare(panel.filteredRows.length, 0);
            compare(panel.cameraChoices.length, 1);
        }
        function test_sourceAndDomainDoNotMergeEvidence() {
            fixture.history = [row("allowed"), row("allowed", "backend_native", "recording_catalogue"), row("allowed", "backend_reported_by_client", "recording_catalogue")];
            compare(panel.filteredRows.length, 3);
            panel.domainFilter = "recording_catalogue"; compare(panel.filteredRows.length, 2);
            panel.sourceFilter = "backend_native"; compare(panel.filteredRows.length, 1);
            verify(panel.sourceText("backend_native") !== panel.sourceText("backend_reported_by_client"));
            verify(panel.domainText("live_delivery") !== panel.domainText("recording_catalogue"));
        }
        function test_reportedOnsetIsSeparateFromObservedTime() {
            var entry = row("allowed", "backend_reported_by_client", "backend_reachability");
            entry.backend_observation = {status_since: "2026-10-20T00:00:00Z", recording_since: "2026-10-21T00:00:00Z"};
            compare(panel.reportedTime(entry), "2026-10-20T00:00:00Z");
            compare(entry.observed_at, "2026-10-29T12:00:00+03:00");
            entry.domain = "recording_catalogue";
            compare(panel.reportedTime(entry), "2026-10-21T00:00:00Z");
        }
        function test_gapsAndOpenConditionsNeverInventDuration() {
            var entry = row("allowed");
            entry.transition = "failure";
            var open = panel.durationText(entry);
            entry.condition_status = "recovery_referenced";
            verify(panel.durationText(entry) !== open);
            entry.condition_status = "not_applicable";
            entry.transition = "monitoring_gap";
            verify(panel.durationText(entry) !== open);
            entry.transition = "initial"; entry.duration_ms = 1200;
            verify(panel.durationText(entry).indexOf("1.2") < 0);
            entry.transition = "recovery";
            verify(panel.durationText(entry).indexOf("1.2") >= 0);
            entry.duration_ms = null;
            verify(panel.durationText(entry).indexOf("1.2") < 0);
        }
        function test_windowIsBoundedAndNoBackgroundPolling() {
            panel.windowHours = 744; panel.refresh();
            compare(fixture.refreshCalls.length, 1);
            var request = fixture.refreshCalls[0];
            compare(request.camera, "");
            compare(new Date(request.until).getTime() - new Date(request.from).getTime(), 31 * 86400000);
            verify(request.until.endsWith("Z") && request.from.endsWith("Z"));
            wait(150); compare(fixture.refreshCalls.length, 1);
        }
        function test_unknownAndDeliveryStatesRemainDifferent() {
            verify(panel.statusText("unknown") !== panel.statusText("ready"));
            verify(panel.deliveryText("pending") !== panel.deliveryText("acknowledged"));
            verify(panel.deliveryText("rejected") !== panel.deliveryText("acknowledged"));
            verify(panel.transitionText("initial") !== panel.transitionText("recovery"));
            compare(panel.ageText("2999-01-01T00:00:00Z"), panel.ageText("invalid"));
        }
        function test_actualWorkerStatesAreExplained() {
            var unknown = panel.statusText("unknown");
            for (var state of ["provisioning_required", "discovering", "storage_error", "protocol_error", "backlog_pending"])
                verify(panel.statusText(state) !== unknown, state + " has a translated explanation");
        }
        function test_blockedRepliesCannotOfferAnInactiveSyncControl() {
            fixture.canSync = true;
            for (var state of ["auth_required", "conflict", "protocol_error"]) {
                fixture.status = {state: state};
                verify(!panel.syncAllowed);
                panel.requestSync();
                compare(fixture.syncCalls, 0);
            }
        }
        function test_openDisplaysRealView() {
            var failure = row("allowed");
            failure.transition = "failure"; failure.state = "unavailable";
            failure.details = {pipeline_id: "preview-1", stream_variant: "sub", transport: "rtsp"};
            var recovery = row("allowed");
            recovery.transition = "recovery"; recovery.state = "available"; recovery.duration_ms = 1500;
            recovery.delivery_state = "acknowledged";
            var gap = row("allowed", "backend_native", "monitoring");
            gap.transition = "monitoring_gap"; gap.state = "unknown"; gap.delivery_state = "native";
            fixture.history = [failure, recovery, gap];
            panel.open(); tryCompare(panel, "opened", true);
            verify(findChild(panel, "availabilityHistoryList").visible);
            verify(findChild(panel, "availabilityHistoryList").height > 120);
            compare(panel.filteredRows.length, 3);
            verify(fixture.refreshCalls.length >= 1);
            grabImage(screen).save("availability-history-ui.png");
        }
    }
}
