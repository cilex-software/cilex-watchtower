import QtQuick
import Watchtower

// Maps a CameraStatus.RecState to the badge look. Shown second in the badge
// stack. "REC" pulses; "NOT REC" / "GAP" use a hollow accent ring so a
// live-but-not-recording camera never reads as healthy (design §9).
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
    // ms epoch of the newest motion_* event seen for this camera (-1 = none seen
    // in the loaded feed — shows plain ARMED, no claim either way).
    property double lastMotionAtMs: -1
    // Observed onset of the CURRENT recording state (badge timer, e.g. "REC · 12m").
    // ARMED deliberately keeps its motion-EVENT age instead (more useful there).
    property double stateSinceMs: -1
    sinceMs: state === CameraStatus.Armed ? -1 : stateSinceMs

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
    // 1cc987d). Paired with lastSegmentAtMs it catches the 2026-08-07 P1: a
    // camera detecting motion every few minutes whose recorder pipeline died
    // 21-37 h ago. Detection fresh + segments stale is a machine-checkable
    // contradiction — the operator found 12 such cameras before the UI did.
    property double lastVmdAtMs: -1
    readonly property bool _deafArmed: state === CameraStatus.Armed && motionKnown && !motionReady
    readonly property double _vmdAgeS: lastVmdAtMs > 0 ? Math.max(0, (Date.now() - lastVmdAtMs) / 1000) : -1
    // fresh detection (<3 h) while the newest segment is >1 h older than that
    // detection = the recorder is not writing this camera's footage.
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
        switch (state) {
        case CameraStatus.Recording: return qsTr("REC");
        case CameraStatus.Stalled: return qsTr("STALLED");
        case CameraStatus.Armed:
            if (_deafArmed) return "ARMED · " + qsTr("NOT READY");
            if (_notRecording) return "ARMED · " + qsTr("NOT RECORDING");
            if (_age !== "") return qsTr("ARMED · ") + _age;
            if (_silentArmed) return qsTr("ARMED · ") + (_silentAge !== ""
                ? qsTr("silent %1").arg(_silentAge) : qsTr("no motion ever"));
            return qsTr("ARMED");
        case CameraStatus.Disabled: return qsTr("OFF");
        case CameraStatus.NotRecording: return qsTr("NOT REC");
        case CameraStatus.RecordingGap: return qsTr("GAP");
        default: return qsTr("REC ?");
        }
    }
    fg: {
        switch (state) {
        case CameraStatus.Recording: return Theme.bad;
        case CameraStatus.Stalled: return Theme.bad;          // a real failure → red
        case CameraStatus.NotRecording:
        case CameraStatus.RecordingGap: return Theme.accent;
        case CameraStatus.Armed: return (_deafArmed || _notRecording) ? Theme.bad
            : (_staleArmed || _silentArmed) ? Theme.warn : Theme.ink2;   // deaf → red; eventless/segmentless → amber
        default: return Theme.ink3;                            // disabled / unknown
        }
    }
    bgColor: {
        switch (state) {
        case CameraStatus.Recording:
        case CameraStatus.Stalled: return Theme.badDim;
        case CameraStatus.NotRecording:
        case CameraStatus.RecordingGap: return Theme.accentDim;
        default: return Theme.line;                            // armed / disabled / unknown
        }
    }
    dotColor: fg
    dotPulse: state === CameraStatus.Recording || _flash
    // Solid only when actively recording; everything else (incl. the STALLED
    // failure and motion-ARMED idle) reads as a hollow ring.
    dotHollow: state !== CameraStatus.Recording && !_flash
}
