import QtQuick
import Watchtower

// Recorder progress and archive availability are separate v1 dimensions.
// Legacy catalogue states remain warnings, without claiming stopped capture.
//
// ARMED additionally reads out motion-EVENT freshness ("ARMED · 4m"): the mode
// being on says nothing about events actually flowing — a clock-vetoed or
// subscription-dead camera looks identical to a healthy idle one without this
// (operator-reported 2026-07-08: visible movement, zero events, no way to see
// it). Fresh events pulse the dot briefly; >24 h with no event turns the badge
// amber so the mismatch is visible at a glance.
StatusBadge {
    id: badge
    property int state: CameraStatus.RecUnknown
    property var health: ({})
    readonly property string captureState: health && health.capture_state ? health.capture_state : "unknown"
    readonly property string archiveState: health && health.archive_state ? health.archive_state
        : (state === CameraStatus.Stalled || state === CameraStatus.NotRecording || state === CameraStatus.RecordingGap ? "delayed" : "unknown")
    readonly property bool captureStopped: captureState === "stopped"
    readonly property bool captureProgressing: captureState === "progressing"
    readonly property bool archiveDelayed: archiveState === "delayed" || archiveState === "unavailable"
    readonly property bool healthDisabled: state === CameraStatus.Disabled || captureState === "disabled"
    readonly property bool healthIdle: captureState === "idle" || (state === CameraStatus.Armed && !archiveDelayed && captureState === "unknown")
    readonly property bool issueVisible: !healthDisabled
        && (captureStopped || archiveDelayed || (!healthIdle && captureState === "unknown") || archiveState === "unknown")
    readonly property color issueColor: captureStopped ? Theme.bad : Theme.warn
    readonly property string issueText: {
        if (captureStopped) return qsTr("Recording stopped");
        if (archiveDelayed) {
            var delay = health ? health.archive_delay_s : null;
            var age = typeof delay === "number" && isFinite(delay) && delay >= 0
                ? qsTr("%1 min").arg(Math.ceil(delay / 60)) : "";
            if (captureProgressing) return age !== ""
                ? qsTr("Recording continues · archive delayed %1").arg(age)
                : archiveState === "delayed" ? qsTr("Recording continues · archive delayed")
                : qsTr("Recording continues · archive unavailable");
            return age !== "" ? qsTr("Archive delayed %1 · recording unverified").arg(age)
                : archiveState === "delayed" ? qsTr("Archive delayed · recording unverified")
                : qsTr("Archive unavailable · recording unverified");
        }
        if (captureProgressing && archiveState === "unknown") return qsTr("Recording continues · archive unknown");
        if (captureState === "idle" && archiveState === "unknown") return qsTr("Archive status unknown");
        return qsTr("Recording status unknown");
    }
    // ms epoch of the newest motion_* event seen for this camera (-1 = none seen
    // in the loaded feed — shows plain ARMED, no claim either way).
    property double lastMotionAtMs: -1
    // Observed onset of the CURRENT recording state (badge timer, e.g. "REC · 12m").
    // ARMED deliberately keeps its motion-EVENT age instead (more useful there).
    property double stateSinceMs: -1
    // Legacy recording_since tracks a catalogue verdict, not capture failure.
    // Only an explicit health incident onset may be used for capture timing.
    sinceMs: captureStopped && health && health.incident_started_at
        ? Date.parse(health.incident_started_at) : -1

    property int _nowTick: 0
    Timer {
        interval: 30000; repeat: true
        running: badge.visible && badge.state === CameraStatus.Armed && badge.lastMotionAtMs > 0
        onTriggered: badge._nowTick++
    }
    readonly property real _ageS: {
        _nowTick;                                    // re-evaluate on the 30s tick
        return lastMotionAtMs > 0 ? Math.max(0, (Date.now() - lastMotionAtMs) / 1000) : -1;
    }
    readonly property string _age: {
        if (_ageS < 0) return "";
        if (_ageS < 90) return qsTr("now");
        if (_ageS < 3600) return Math.floor(_ageS / 60) + qsTr("m");
        if (_ageS < 86400) return Math.floor(_ageS / 3600) + qsTr("h");
        return Math.floor(_ageS / 86400) + qsTr("d");
    }
    // Last recorded SEGMENT (backend last_segment_at) — the truth that survives
    // an empty event feed. The 2026-08-04 P1: 20 armed cameras had NEVER fired
    // motion, and with lastMotionAtMs = -1 this badge showed a clean confident
    // "ARMED" on every one of them. An armed camera with no motion event in the
    // feed AND no segment for >24 h now says so out loud.
    property double lastSegmentAtMs: -1
    // Backend motion-readiness truth (/streams `motion.ready`, P1 thread e841f1c):
    // a provably-deaf detector (ready=false) outranks the silence heuristic —
    // that is the exact defect class (sensitivity 0) that hid behind ARMED for
    // the fleet's whole life. Absent field (motionKnown=false) = unknown, and
    // unknown falls back to the silence heuristic — never to green.
    property bool motionKnown: false
    property bool motionReady: false
    // Last VERIFIED detection (/streams motion.last_vmd_at, monotone since
    // 1cc987d). A mismatch with the catalogue raises an archive warning;
    // it does not establish that capture stopped.
    property double lastVmdAtMs: -1
    readonly property bool _deafArmed: state === CameraStatus.Armed && motionKnown && !motionReady
    readonly property double _vmdAgeS: lastVmdAtMs > 0 ? Math.max(0, (Date.now() - lastVmdAtMs) / 1000) : -1
    // Fresh detection with stale catalogue data is an archive warning; it does
    // not establish that the local recorder stopped writing.
    readonly property bool _notRecording: state === CameraStatus.Armed
        && lastVmdAtMs > 0 && _vmdAgeS < 10800
        && (lastSegmentAtMs <= 0 || (lastVmdAtMs - lastSegmentAtMs) > 3600000)
    readonly property double _segAgeS: lastSegmentAtMs > 0 ? Math.max(0, (Date.now() - lastSegmentAtMs) / 1000) : -1
    readonly property bool _silentArmed: state === CameraStatus.Armed && lastMotionAtMs <= 0
                                         && (_segAgeS < 0 || _segAgeS > 86400)
    readonly property string _silentAge: _segAgeS < 0 ? ""
        : _segAgeS >= 86400 ? Math.floor(_segAgeS / 86400) + qsTr("d")
        : Math.floor(_segAgeS / 3600) + qsTr("h")
    readonly property bool _staleArmed: state === CameraStatus.Armed && _ageS > 86400

    // A fresh event just registered — pulse the dot for a beat so "events are
    // flowing NOW" is visible without reading the age.
    property bool _flash: false
    onLastMotionAtMsChanged: if (state === CameraStatus.Armed && lastMotionAtMs > 0) { _flash = true; flashOff.restart(); }
    Timer { id: flashOff; interval: 2500; onTriggered: badge._flash = false }

    label: {
        if (healthDisabled) return qsTr("OFF");
        if (captureStopped) return qsTr("REC STOPPED");
        if (archiveDelayed) return qsTr("ARCHIVE DELAY");
        if (captureProgressing) return qsTr("REC");
        switch (state) {
        case CameraStatus.Recording: return qsTr("REC ?");
        case CameraStatus.Stalled: return qsTr("ARCHIVE DELAY");
        case CameraStatus.Armed:
            if (_deafArmed) return "ARMED · " + qsTr("NOT READY");
            if (_notRecording) return "ARMED · " + qsTr("ARCHIVE DELAY");
            // Below tier 2 the qualifier is dropped, but only the INFORMATIONAL
            // ones — how long it has been armed, how long it has been silent.
            // The two fault qualifiers above keep their words at every tier that
            // has words at all: "armed but not recording" is not something an
            // operator should have to infer from a colour.
            if (tier < 2) return qsTr("ARMED");
            if (_age !== "") return qsTr("ARMED · ") + _age;
            if (_silentArmed) return qsTr("ARMED · ") + (_silentAge !== ""
                ? qsTr("silent %1").arg(_silentAge) : qsTr("no motion ever"));
            return qsTr("ARMED");
        case CameraStatus.Disabled: return qsTr("OFF");
        case CameraStatus.NotRecording: return qsTr("REC ?");
        case CameraStatus.RecordingGap: return qsTr("ARCHIVE DELAY");
        default: return qsTr("REC ?");
        }
    }
    fg: captureStopped ? Theme.bad : archiveDelayed ? Theme.warn
        : captureProgressing ? Theme.bad
        : state === CameraStatus.Armed ? (_deafArmed ? Theme.bad
            : (_staleArmed || _silentArmed || _notRecording) ? Theme.warn : Theme.ink2)
        : Theme.ink3
    bgColor: captureStopped || captureProgressing ? Theme.badDim
        : archiveDelayed ? Theme.warnDim : Theme.line
    dotColor: fg
    dotPulse: captureProgressing || _flash
    // Solid only with fresh recorder progress; other states remain hollow.
    dotHollow: !captureProgressing && !_flash
}
