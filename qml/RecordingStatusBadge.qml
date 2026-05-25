import QtQuick
import Watchtower

// Maps a CameraStatus.RecState to the badge look. Shown second in the badge
// stack. "REC" pulses; "NOT REC" / "GAP" use a hollow accent ring so a
// live-but-not-recording camera never reads as healthy (design §9).
StatusBadge {
    property int state: CameraStatus.RecUnknown

    label: {
        switch (state) {
        case CameraStatus.Recording: return "REC";
        case CameraStatus.NotRecording: return "NOT REC";
        case CameraStatus.RecordingGap: return "GAP";
        default: return "REC ?";
        }
    }
    fg: {
        switch (state) {
        case CameraStatus.Recording: return Theme.bad;
        case CameraStatus.NotRecording:
        case CameraStatus.RecordingGap: return Theme.accent;
        default: return Theme.ink3;
        }
    }
    bgColor: {
        switch (state) {
        case CameraStatus.Recording: return Theme.badDim;
        case CameraStatus.NotRecording:
        case CameraStatus.RecordingGap: return Theme.accentDim;
        default: return Theme.line;
        }
    }
    dotColor: fg
    dotPulse: state === CameraStatus.Recording
    dotHollow: state === CameraStatus.NotRecording || state === CameraStatus.RecordingGap
}
