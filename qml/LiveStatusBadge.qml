import QtQuick
import Watchtower

// Maps a CameraStatus.LiveState to the badge look. Always shown first in the
// tile badge stack (live state, then recording state — design §9).
StatusBadge {
    property int state: CameraStatus.LiveUnknown

    label: {
        switch (state) {
        case CameraStatus.Live: return "LIVE";
        case CameraStatus.Offline: return "OFFLINE";
        case CameraStatus.Degraded: return "DEGRADED";
        case CameraStatus.Loading: return "LOADING";
        case CameraStatus.NoSignal: return "NO SIGNAL";
        case CameraStatus.PermissionDenied: return "NO ACCESS";
        default: return "UNKNOWN";
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
