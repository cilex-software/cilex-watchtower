import QtQml
QtObject {
    enum LiveState { LiveUnknown, Live, Offline, Degraded, Loading, NoSignal, PermissionDenied }
    enum RecState { RecUnknown, Recording, NotRecording, RecordingGap, Stalled, Armed, Disabled }
}
