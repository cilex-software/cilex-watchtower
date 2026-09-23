import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower
import "GroupsStatus.js" as St

// Health (S07) — design handoff README §7 + watchtower.html HealthScreen.
// A full-width strip of 6 stat cards over CameraModel's live counts, a camera
// table filtered by the active card, and a 380px detail panel. This is a pure
// view over CameraModel — camera live/recording status is whatever the store
// holds (from provisioning import), the same source the rest of the app uses;
// there is no separate live health feed yet, so we never fabricate durations.
Item {
    id: root

    property var cameraModel: null
    property var storageHealth: null
    property var playbackClient: null          // for the playback-subsystem strip

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
    onVisibleChanged: if (visible && storageHealth) storageHealth.refresh()
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
    readonly property var rows: _rows
    property var _rows: []
    property string _rowsSig: "\u0000unset"
    function _refreshRows() {
        if (!cameraModel) { _rows = []; _rowsSig = ""; return; }
        var r = cameraModel.page("", activeFilter, "status", 1, 100000);
        var sig = activeFilter + "\u0001";
        for (var i = 0; i < r.length; i++) {
            var c = r[i];
            sig += c.camId + "|" + c.name + "|" + c.groupName + "|" + c.live + "|" + c.recording
                 + "|" + c.lastSeen + "|" + c.lastSegmentAt + "|" + c.motionKnown + "|" + c.motionReady
                 + "|" + c.motionConfirmed + "|" + c.motionLastVmdAt + "\u0001";
        }
        if (sig !== _rowsSig) { _rowsSig = sig; _rows = r; }
    }
    onActiveFilterChanged: _refreshRows()
    onCameraModelChanged: _refreshRows()
    Connections { target: root.cameraModel; function onCountsChanged() { root._refreshRows() } }

    // column widths (header + row delegate share these; Camera column fills the rest)
    readonly property int wGroup: 150
    readonly property int wLive: 110
    readonly property int wRec: 170
    readonly property int wSeen: 110
    readonly property int wIssue: 220
    readonly property int wAct: 72

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
    function recText(s) {
        switch (s) {
        case CameraStatus.Recording: return qsTr("Recording");
        case CameraStatus.Stalled: return qsTr("Stalled");
        case CameraStatus.Armed: return qsTr("Motion armed");
        case CameraStatus.Disabled: return qsTr("Disabled");
        case CameraStatus.NotRecording: return qsTr("Not recording");
        case CameraStatus.RecordingGap: return qsTr("Recording gap");
        default: return qsTr("Unknown");
        }
    }
    // Delegates to the ONE classifier (GroupsStatus.js). This was a byte-faithful
    // copy of St.notRecordingNow until 2026-09-22 — which is precisely what that
    // file's own header warns against ("ad-hoc filters at call sites are how a
    // facet says 21 while 13 tiles wear the ring"). It also meant the NaN
    // narrowing had to be made twice or it would have been made once and believed
    // twice. One predicate, four screens.
    function _notRec(cam) { return St.notRecordingNow(cam); }
    function issueText(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal) return qsTr("No signal");
        if (cam.recording === CameraStatus.Armed && cam.motionKnown && !cam.motionReady) return qsTr("Motion detector not ready");
        if (root._notRec(cam)) return qsTr("Detecting but NOT recording");
        if (cam.recording === CameraStatus.Stalled) return qsTr("Recording stalled");
        if (cam.recording === CameraStatus.RecordingGap) return qsTr("Recent recording gap");
        if (cam.live === CameraStatus.Degraded) return qsTr("Stream degraded");
        if (cam.recording === CameraStatus.NotRecording) return qsTr("Live but not recording");
        if (cam.recording === CameraStatus.Armed && cam.motionKnown && cam.motionReady && !cam.motionConfirmed)
            return qsTr("Motion never verified");   // unproven is not broken — neutral, not a fault
        return "—";
    }
    function issueColor(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal) return Theme.bad;
        if (cam.recording === CameraStatus.Armed && cam.motionKnown && !cam.motionReady) return Theme.bad;
        if (root._notRec(cam)) return Theme.bad;
        if (cam.live === CameraStatus.Degraded || cam.recording === CameraStatus.NotRecording
            || cam.recording === CameraStatus.RecordingGap || cam.recording === CameraStatus.Stalled) return Theme.warn;
        return Theme.ink3;
    }
    function calloutColor(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal) return Theme.bad;
        if (cam.recording === CameraStatus.Armed && cam.motionKnown && !cam.motionReady) return Theme.bad;
        if (root._notRec(cam)) return Theme.bad;
        if (cam.live === CameraStatus.Degraded || cam.recording === CameraStatus.NotRecording
            || cam.recording === CameraStatus.RecordingGap || cam.recording === CameraStatus.Stalled) return Theme.warn;
        if (cam.live === CameraStatus.Live && cam.recording === CameraStatus.Recording) return Theme.accent;
        if (cam.live === CameraStatus.Live) return Theme.good;   // live, recording not reported (incl. motion-armed)
        return Theme.ink3;
    }
    function calloutText(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal)
            return qsTr("<b>Camera is offline.</b> ") + (cam.lastSeen ? ("Last seen " + cam.lastSeen + ". ") : "")
                 + "Playback may still be available for footage recorded before the outage.";
        if (cam.recording === CameraStatus.Stalled)
            return qsTr("<b>Recording stalled.</b> The recorder stopped producing footage for this camera; it's being restarted automatically.");
        if (cam.live === CameraStatus.Live && cam.recording === CameraStatus.NotRecording)
            return qsTr("<b>Camera is live but not recording.</b> Live monitoring works; no new footage is being saved.");
        if (cam.recording === CameraStatus.RecordingGap)
            return qsTr("<b>Recording gap detected.</b> Some footage in the recent window is missing.");
        if (cam.live === CameraStatus.Degraded)
            return qsTr("<b>Stream degraded.</b> Reduced bitrate due to network conditions; recording continues.");
        if (root._notRec(cam))
            return qsTr("<b>Detecting motion, but not recording.</b> This camera reported motion at ")
                 + Qt.formatDateTime(new Date(cam.motionLastVmdAt), "HH:mm:ss")
                 + ", yet its newest recorded footage is older than that — the recorder is not writing this camera. Reported to the backend; playback for recent events will be empty.";
        if (cam.recording === CameraStatus.Armed && cam.motionKnown) {
            // /streams motion{ready,confirmed,last_vmd_at} — sticky semantics
            // (1cc987d): confirmed survives config-only passes; last_vmd_at is
            // monotone. Absent key falls through to the no-claim text below.
            if (!cam.motionReady)
                return qsTr("<b>Motion detector not ready.</b> The camera is armed but the backend preflight says its detector cannot fire")
                     + (cam.motionStatus ? " (" + cam.motionStatus + ")" : "") + ". Motion will not be recorded until this is repaired.";
            if (!cam.motionConfirmed)
                return qsTr("<b>Motion-armed, never verified.</b> Configuration checks out, but this camera has never produced a verified detection. A short walk through its field of view would prove the chain.");
            return qsTr("<b>Motion-armed and verified.</b> Recording on motion; idle between events — not a fault.")
                 + (cam.motionLastVmdAt ? (" Last verified motion " + Qt.formatDateTime(new Date(cam.motionLastVmdAt), "ddd d MMM, HH:mm:ss") + ".") : "");
        }
        if (cam.recording === CameraStatus.Armed)
            return qsTr("<b>Motion-armed.</b> Recording on motion; idle between events — not a fault.");
        if (cam.live === CameraStatus.Live && cam.recording === CameraStatus.Recording)
            return qsTr("<b>Camera is live and recording.</b> No issues detected.");
        if (cam.live === CameraStatus.Live)
            return qsTr("<b>Camera is live.</b> Recording status isn't being reported for this camera.");
        return qsTr("<b>Status unknown.</b> No recent health signal for this camera.");
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

        // ===== stat cards strip =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

            component Card: Item {
                id: card
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
                        anchors.left: parent.left; anchors.top: parent.top
                        anchors.leftMargin: 18; anchors.topMargin: card.active ? 15 : 18
                        spacing: 8
                        Text {
                            text: card.unknown ? "\u2014" : String(card.value)
                            color: card.unknown ? Theme.ink3 : card.numColor
                            font.family: Theme.fontSans; font.pixelSize: 32
                            font.weight: Font.Bold; font.letterSpacing: -1
                        }
                        Text { text: card.label; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase }
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
                Card { key: "notrec";   label: qsTr("Not recording"); value: root.cameraModel ? root.cameraModel.notRecordingCount : 0; numColor: Theme.accent }
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
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // header
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    color: Theme.bg
                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line2 }
                    component Th: Text {
                        height: 38; verticalAlignment: Text.AlignVCenter
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
                    }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                        Th { text: qsTr("Camera"); Layout.fillWidth: true }
                        Th { text: qsTr("Group"); Layout.preferredWidth: root.wGroup }
                        Th { text: qsTr("Live"); Layout.preferredWidth: root.wLive }
                        Th { text: qsTr("Recording"); Layout.preferredWidth: root.wRec }
                        Th { text: qsTr("Last seen"); Layout.preferredWidth: root.wSeen }
                        Th { text: qsTr("Recent issue"); Layout.preferredWidth: root.wIssue }
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
                        required property int index
                        width: ListView.view.width
                        height: 52
                        readonly property bool isSel: root.sel && root.sel.camId === modelData.camId
                        color: isSel ? Theme.accentSoft : (rowMa.containsMouse ? Theme.panel : "transparent")
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sel = modelData }

                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                            // Camera
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { text: rowItem.modelData.name; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: rowItem.modelData.camId; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            // Group
                            Text { Layout.preferredWidth: root.wGroup; text: rowItem.modelData.groupName; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                            // Live
                            Item { Layout.preferredWidth: root.wLive; Layout.fillHeight: true
                                LiveStatusBadge { anchors.verticalCenter: parent.verticalCenter; state: rowItem.modelData.live } }
                            // Recording
                            Item { Layout.preferredWidth: root.wRec; Layout.fillHeight: true
                                RecordingStatusBadge { anchors.verticalCenter: parent.verticalCenter; state: rowItem.modelData.recording
                                    motionKnown: rowItem.modelData.motionKnown === true; motionReady: rowItem.modelData.motionReady === true
                                    lastSegmentAtMs: rowItem.modelData.lastSegmentAt ? Date.parse(rowItem.modelData.lastSegmentAt) : -1
                                    lastVmdAtMs: rowItem.modelData.motionLastVmdAt ? Date.parse(rowItem.modelData.motionLastVmdAt) : -1 } }
                            // Last seen
                            Text { Layout.preferredWidth: root.wSeen; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 12
                                text: (rowItem.modelData.live === CameraStatus.Offline || rowItem.modelData.live === CameraStatus.NoSignal)
                                      ? (rowItem.modelData.lastSeen ? rowItem.modelData.lastSeen : "—") : "now" }
                            // Recent issue
                            Text { Layout.preferredWidth: root.wIssue; color: root.issueColor(rowItem.modelData); font.family: Theme.fontSans; font.pixelSize: 11; elide: Text.ElideRight; text: root.issueText(rowItem.modelData) }
                            // action
                            Item { Layout.preferredWidth: root.wAct; Layout.fillHeight: true
                                Btn { anchors.verticalCenter: parent.verticalCenter; small: true; ghost: true; label: qsTr("Open"); onClicked: root.openLive(rowItem.modelData) } }
                        }
                    }

                    // empty state
                    EmptyState {
                        anchors.centerIn: parent
                        visible: root.rows.length === 0
                        icon: "check"
                        title: qsTr("Nothing here")
                        subtitle: qsTr("No cameras match this filter.")
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
                                    RecordingStatusBadge { state: root.sel ? root.sel.recording : CameraStatus.RecUnknown
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
                            KV { k: "Recording status"; v: root.sel ? root.recText(root.sel.recording) : "" }
                            KV { k: "Last seen"; v: root.sel ? (root.selOffline ? (root.sel.lastSeen ? root.sel.lastSeen : "—") : "now") : "" }
                            KV { k: "Last recording"; v: (root.sel && root.sel.lastSegmentAt) ? Qt.formatDateTime(new Date(root.sel.lastSegmentAt), "ddd d MMM, HH:mm:ss") : "—" }
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
