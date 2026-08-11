import QtQuick
import Watchtower

// Maps a CameraStatus.LiveState to the badge look. Always shown first in the
// tile badge stack (live state, then recording state — design §9).
StatusBadge {
    property int state: CameraStatus.LiveUnknown

    label: {
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
        switch (state) {
        case CameraStatus.Live: return Theme.good;
        case CameraStatus.Offline:
        case CameraStatus.NoSignal: return Theme.bad;
        case CameraStatus.Degraded: return Theme.accent;
        default: return Theme.ink3;
        }
    }
    bgColor: {
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
