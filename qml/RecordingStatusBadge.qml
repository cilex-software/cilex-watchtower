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
        case CameraStatus.Stalled: return "STALLED";
        case CameraStatus.Armed: return "ARMED";
        case CameraStatus.Disabled: return "OFF";
        case CameraStatus.NotRecording: return "NOT REC";
        case CameraStatus.RecordingGap: return "GAP";
        default: return "REC ?";
        }
    }
    fg: {
        switch (state) {
        case CameraStatus.Recording: return Theme.bad;
        case CameraStatus.Stalled: return Theme.bad;          // a real failure → red
        case CameraStatus.NotRecording:
        case CameraStatus.RecordingGap: return Theme.accent;
        case CameraStatus.Armed: return Theme.ink2;           // motion-armed, idle — not a fault
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
    dotPulse: state === CameraStatus.Recording
    // Solid only when actively recording; everything else (incl. the STALLED
    // failure and motion-ARMED idle) reads as a hollow ring.
    dotHollow: state !== CameraStatus.Recording
}
