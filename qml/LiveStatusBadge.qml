import QtQuick
import Watchtower

// Maps a CameraStatus.LiveState to the badge look. Always shown first in the
// tile badge stack (live state, then recording state — design §9).
StatusBadge {
    property int state: CameraStatus.LiveUnknown
    // Frames arriving too slowly to be video (VideoSurface.degraded). The camera IS
    // connected, so this is not an error state — but it must not read as a healthy
    // green LIVE either. Amber, and the measured rate where there is room for it:
    // "how fast" is the fact the operator needs, and it is self-evidently honest.
    property bool degraded: false
    property real fps: -1

    label: {
        if (degraded) {
            if (tier >= 2 && fps >= 0)
                return (fps < 10 ? fps.toFixed(1) : Math.round(fps)) + qsTr(" FPS");
            return qsTr("SLOW");
        }
        switch (state) {
        case CameraStatus.Live: return qsTr("LIVE");
        case CameraStatus.Offline: return qsTr("OFFLINE");
        case CameraStatus.Degraded: return qsTr("DEGRADED");
        case CameraStatus.Loading: return qsTr("LOADING");
        case CameraStatus.NoSignal: return qsTr("NO SIGNAL");
        case CameraStatus.PermissionDenied: return qsTr("NO ACCESS");
        default: return qsTr("UNKNOWN");
        }
    }
    fg: {
        if (degraded) return Theme.warn;
        switch (state) {
        case CameraStatus.Live: return Theme.good;
        case CameraStatus.Offline:
        case CameraStatus.NoSignal: return Theme.bad;
        case CameraStatus.Degraded: return Theme.accent;
        default: return Theme.ink3;
        }
    }
    bgColor: {
        if (degraded) return Theme.warnDim;
        switch (state) {
        case CameraStatus.Live: return Theme.goodDim;
        case CameraStatus.Offline:
        case CameraStatus.NoSignal: return Theme.badDim;
        case CameraStatus.Degraded: return Theme.accentDim;
        default: return Theme.line;
        }
    }
    dotColor: fg
}
