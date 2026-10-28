import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// A bounded view of already authorised worker results; no I/O or polling here.
QC.Popup {
    id: root
    objectName: "availabilityHistory"
    property var service: null
    property var cameraModel: null
    property var cameraChoices: [{label: qsTr("All accessible cameras"), cameraId: ""}]
    property string cameraFilter: ""
    property string domainFilter: ""
    property string sourceFilter: ""
    property int windowHours: 24
    readonly property var syncStatus: service ? service.status : ({})
    readonly property bool syncAllowed: service !== null && service.canSync === true && !service.busy
        && ["auth_required", "conflict", "protocol_error"].indexOf(syncStatus.state || "") < 0
    readonly property bool stationRowsAllowed: service !== null && service.canViewStationEvents === true
    readonly property var filteredRows: filterRows(service ? service.history : [])
    readonly property string summary: statusText(syncStatus.state || syncStatus.identityState || "unknown")

    width: Math.min(parent ? parent.width - 32 : 1120, 1120)
    height: Math.min(parent ? parent.height - 32 : 740, 740)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    modal: true
    focus: true
    padding: 20
    font.family: Theme.fontSans
    palette.window: Theme.panel
    palette.windowText: Theme.ink
    palette.base: Theme.bg
    palette.text: Theme.ink
    palette.button: Theme.panel2
    palette.buttonText: Theme.ink
    palette.highlight: Theme.accent
    palette.highlightedText: Theme.bg
    palette.mid: Theme.line2
    palette.dark: Theme.line2
    closePolicy: QC.Popup.CloseOnEscape | QC.Popup.CloseOnPressOutside
    background: Rectangle { color: Theme.panel; border.color: Theme.line2 }

    function refreshCameras() {
        var choices = [{label: qsTr("All accessible cameras"), cameraId: ""}];
        var rows = cameraModel ? cameraModel.page("", "", "name", 1, 100000) : [];
        var seen = ({});
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i].camId) {
                choices.push({label: rows[i].name || rows[i].camId, cameraId: rows[i].camId});
                seen[rows[i].camId] = true;
            }
        }
        // Administrators may inspect retained history after a camera is removed.
        if (stationRowsAllowed && service) {
            var history = service.history || [];
            for (var j = 0; j < history.length; ++j) {
                var id = history[j].camera_id;
                if (id && !seen[id]) { choices.push({label: id, cameraId: id}); seen[id] = true; }
            }
        }
        if (JSON.stringify(choices) !== JSON.stringify(cameraChoices)) cameraChoices = choices;
        if (cameraFilter && !cameraAccessible(cameraFilter)) cameraFilter = "";
    }
    function cameraAccessible(id) {
        for (var i = 1; i < cameraChoices.length; ++i) if (cameraChoices[i].cameraId === id) return true;
        return false;
    }
    function cameraLabel(id) {
        if (!id) return qsTr("This station");
        for (var i = 1; i < cameraChoices.length; ++i) if (cameraChoices[i].cameraId === id) return cameraChoices[i].label;
        return stationRowsAllowed ? id : "";
    }
    function filterRows(rows) {
        // This second check also hides results immediately when the current roster changes.
        var choices = cameraChoices;
        var permittedStation = stationRowsAllowed;
        return (rows || []).filter(function(row) {
            if (row.camera_id ? (!permittedStation && !cameraAccessible(row.camera_id)) : !permittedStation) return false;
            if (cameraFilter && row.camera_id !== cameraFilter) return false;
            if (domainFilter && row.domain !== domainFilter) return false;
            if (sourceFilter && row.provenance !== sourceFilter) return false;
            return true;
        });
    }
    function refresh() {
        if (!service || typeof service.refreshHistory !== "function") return;
        var until = new Date();
        var from = new Date(until.getTime() - windowHours * 3600000);
        service.refreshHistory(cameraFilter, from.toISOString(), until.toISOString());
    }
    function requestSync() {
        if (syncAllowed) service.syncNow();
    }
    function formatTime(value) {
        if (!value) return qsTr("Not recorded");
        var date = new Date(value);
        return isNaN(date.getTime()) ? qsTr("Unknown") : Qt.formatDateTime(date, "dd MMM yyyy HH:mm:ss");
    }
    function ageText(value) {
        if (!value) return qsTr("None");
        var elapsed = Date.now() - new Date(value).getTime();
        if (!isFinite(elapsed) || elapsed < 0) return qsTr("Time uncertain");
        var minutes = Math.floor(elapsed / 60000);
        return minutes < 60 ? qsTr("%1 min").arg(minutes) : qsTr("%1 h").arg(Math.floor(minutes / 60));
    }
    function durationText(row) {
        if (row.transition === "recovery" && row.duration_ms !== null && row.duration_ms !== undefined
                && isFinite(Number(row.duration_ms)) && Number(row.duration_ms) >= 0) {
            return qsTr("Reported duration: %1 s").arg((Number(row.duration_ms) / 1000).toFixed(1));
        }
        if (row.condition_status === "interrupted_by_monitoring_gap") return qsTr("Observation interrupted; duration unknown");
        if (row.transition === "failure" && row.condition_status === "recovery_referenced")
            return qsTr("Recovery recorded; see the recovery entry");
        if (row.transition === "failure") return qsTr("Unresolved observation; duration unknown");
        if (row.transition === "monitoring_gap" || row.transition === "monitoring_resumed") return qsTr("Unobserved interval; duration unknown");
        return qsTr("Duration not measured");
    }
    function reportedTime(row) {
        var observation = row.backend_observation || ({});
        return row.domain === "recording_catalogue" ? observation.recording_since : observation.status_since;
    }
    function statusText(state) {
        switch (state) {
        case "ready": return qsTr("Local log ready");
        case "syncing": return qsTr("Sending availability log…");
        case "provision_required":
        case "provisioning_required": return qsTr("Station setup required");
        case "starting":
        case "discovering": return qsTr("Checking journal access…");
        case "storage_error": return qsTr("Local journal storage failed; check free disk space and permissions");
        case "protocol_error": return qsTr("Server reply could not be verified; records retained");
        case "backlog_pending": return qsTr("More records are waiting for the next upload");
        case "unsupported": return qsTr("Server does not support availability sync");
        case "auth_required": return qsTr("Station authentication required");
        case "scope_required": return qsTr("Administrator must grant journal access");
        case "conflict": return qsTr("Journal identity conflict; records retained");
        case "rate_limited": return qsTr("Server requested a later retry");
        case "degraded": return qsTr("Availability logging needs attention");
        default: return qsTr("Availability state unknown");
        }
    }
    function domainText(domain) {
        switch (domain) {
        case "backend_reachability": return qsTr("Camera connection reported by Vision");
        case "recording_catalogue": return qsTr("Recording catalogue");
        case "live_delivery": return qsTr("Live video delivery");
        case "snapshot_delivery": return qsTr("Snapshot delivery");
        case "backend_connectivity": return qsTr("Connection to Vision");
        case "monitoring": return qsTr("Monitoring coverage");
        default: return qsTr("Unknown");
        }
    }
    function sourceText(provenance) {
        switch (provenance) {
        case "backend_native": return qsTr("Observed by Vision");
        case "backend_reported_by_client": return qsTr("Vision report received here");
        case "client_observed": return qsTr("Observed on this station");
        default: return qsTr("Unknown source");
        }
    }
    function stateText(state) {
        switch (state) {
        case "available": return qsTr("Available");
        case "unavailable": return qsTr("Unavailable");
        case "degraded": return qsTr("Degraded");
        case "not_monitored": return qsTr("Not monitored");
        default: return qsTr("Unknown");
        }
    }
    function transitionText(transition) {
        switch (transition) {
        case "initial": return qsTr("Baseline");
        case "failure": return qsTr("Problem observed");
        case "recovery": return qsTr("Recovery observed");
        case "state_change": return qsTr("State changed");
        case "monitoring_gap": return qsTr("Observation gap");
        case "monitoring_resumed": return qsTr("Monitoring resumed");
        default: return qsTr("Unknown");
        }
    }
    function deliveryText(state) {
        switch (state) {
        case "pending": return qsTr("Pending upload");
        case "acknowledged": return qsTr("Received by Vision");
        case "rejected": return qsTr("Rejected; retained locally");
        case "native": return qsTr("Vision history");
        default: return qsTr("Delivery unknown");
        }
    }
    onOpened: { refreshCameras(); refresh(); }
    onCameraFilterChanged: if (opened) refresh()
    onWindowHoursChanged: if (opened) refresh()
    onCameraModelChanged: refreshCameras()
    onStationRowsAllowedChanged: refreshCameras()
    Connections {
        target: root.cameraModel
        function onCountsChanged() { root.refreshCameras(); }
    }
    Connections {
        target: root.service
        function onStateChanged() { if (root.opened) root.refreshCameras(); }
    }

    contentItem: ColumnLayout {
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            Text { text: qsTr("Camera availability history"); font.family: Theme.fontSans; font.pixelSize: 20; font.weight: Font.DemiBold; color: Theme.ink; Layout.fillWidth: true }
            QC.Button { objectName: "availabilityClose"; text: qsTr("Close"); onClicked: root.close() }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: statusColumn.implicitHeight + 20
            color: Theme.bg; border.color: Theme.line
            ColumnLayout {
                id: statusColumn
                anchors.fill: parent; anchors.margins: 10; spacing: 5
                RowLayout {
                    Layout.fillWidth: true
                    Text { objectName: "availabilityStatus"; text: root.summary; color: root.syncStatus.state === "ready" ? Theme.ink : Theme.warn; font.family: Theme.fontSans; font.pixelSize: 13; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    QC.Button {
                        objectName: "availabilitySyncNow"
                        text: qsTr("Sync availability log now")
                        enabled: root.syncAllowed
                        onClicked: root.requestSync()
                    }
                }
                Text { text: qsTr("Pending: %1 · Oldest: %2").arg(root.syncStatus.pendingCount === undefined ? "—" : root.syncStatus.pendingCount).arg(root.ageText(root.syncStatus.oldestPendingAt)); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Text { text: qsTr("Last attempt: %1 · Last successful sync: %2").arg(root.formatTime(root.syncStatus.lastAttemptAt)).arg(root.formatTime(root.syncStatus.lastSuccessfulSyncAt)); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Text { text: qsTr("Next attempt: %1 · Automatic sync every 3 hours while running").arg(root.formatTime(root.syncStatus.nextSyncAt)); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Text { visible: root.syncStatus.loggingComplete === false || Number(root.syncStatus.lostObservationCount || 0) > 0; text: qsTr("Some observations could not be saved. Check local storage."); color: Theme.warn; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Text { visible: Number(root.syncStatus.rejectedCount || 0) > 0; text: qsTr("Rejected records retained locally: %1").arg(root.syncStatus.rejectedCount || 0); color: Theme.warn; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Text { visible: Number(root.syncStatus.retainedOtherContextCount || 0) > 0; text: qsTr("Records retained for another station or server: %1").arg(root.syncStatus.retainedOtherContextCount || 0); color: Theme.warn; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Text { visible: root.service !== null && root.service.busy; text: qsTr("Sync in progress; observations continue to be saved locally."); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap }
            }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            QC.ComboBox {
                id: cameras; objectName: "availabilityCameraFilter"; Layout.fillWidth: true
                model: root.cameraChoices; textRole: "label"; valueRole: "cameraId"
                currentIndex: {
                    for (var i = 0; i < root.cameraChoices.length; ++i)
                        if (root.cameraChoices[i].cameraId === root.cameraFilter) return i;
                    return 0;
                }
                onActivated: root.cameraFilter = currentValue
            }
            QC.ComboBox {
                objectName: "availabilityTimeFilter"
                model: [qsTr("Last 24 hours"), qsTr("Last 7 days"), qsTr("Last 31 days")]
                onActivated: root.windowHours = [24, 168, 744][currentIndex]
            }
            QC.Button { objectName: "availabilityRefresh"; text: qsTr("Refresh"); onClicked: root.refresh() }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            QC.ComboBox {
                objectName: "availabilityDomainFilter"; Layout.fillWidth: true
                model: [qsTr("All observation types"), root.domainText("backend_reachability"), root.domainText("recording_catalogue"), root.domainText("live_delivery"), root.domainText("snapshot_delivery"), root.domainText("backend_connectivity"), root.domainText("monitoring")]
                onActivated: root.domainFilter = ["", "backend_reachability", "recording_catalogue", "live_delivery", "snapshot_delivery", "backend_connectivity", "monitoring"][currentIndex]
            }
            QC.ComboBox {
                objectName: "availabilitySourceFilter"; Layout.fillWidth: true
                model: [qsTr("All sources"), root.sourceText("backend_native"), root.sourceText("backend_reported_by_client"), root.sourceText("client_observed")]
                onActivated: root.sourceFilter = ["", "backend_native", "backend_reported_by_client", "client_observed"][currentIndex]
            }
        }
        Text { text: qsTr("Times use this computer's time zone. Reported onset is separate from local observation; gaps do not prove continuous downtime."); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
        Text { visible: root.service !== null && root.service.history.length >= 1000; text: qsTr("View limited to 1,000 observations. Narrow the camera or time filter."); color: Theme.warn; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
        ListView {
            id: entries; objectName: "availabilityHistoryList"
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
            model: root.filteredRows
            QC.ScrollBar.vertical: QC.ScrollBar {}
            delegate: Rectangle {
                id: entry
                required property var modelData
                width: entries.width
                height: eventBody.implicitHeight + 20
                color: Theme.bg; border.color: Theme.line
                ColumnLayout {
                    id: eventBody
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 10; spacing: 3
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: root.cameraLabel(entry.modelData.camera_id) + " · " + root.transitionText(entry.modelData.transition); color: entry.modelData.transition === "failure" ? Theme.bad : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                        Text { text: root.deliveryText(entry.modelData.delivery_state); color: entry.modelData.delivery_state === "rejected" ? Theme.warn : Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11 }
                    }
                    Text { text: root.domainText(entry.modelData.domain) + " · " + root.stateText(entry.modelData.state) + " · " + root.sourceText(entry.modelData.provenance); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Text { text: qsTr("Observed: %1 · Reported onset: %2").arg(root.formatTime(entry.modelData.observed_at)).arg(root.formatTime(root.reportedTime(entry.modelData))); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Text { visible: !!entry.modelData.server_received_at; text: qsTr("Received by Vision: %1").arg(root.formatTime(entry.modelData.server_received_at)); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                    Text { text: root.durationText(entry.modelData); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Text { visible: !!(entry.modelData.details && entry.modelData.details.pipeline_id); text: qsTr("Observer: %1 · %2 · %3").arg((entry.modelData.details || {}).pipeline_id || "—").arg((entry.modelData.details || {}).stream_variant || qsTr("Unknown")).arg((entry.modelData.details || {}).transport || qsTr("Unknown")); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                }
            }
            Text { anchors.centerIn: parent; visible: entries.count === 0; width: parent.width - 24; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; text: qsTr("No observations in this view. Missing history does not mean there were no problems."); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13 }
        }
    }
}
