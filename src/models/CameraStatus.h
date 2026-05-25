#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

// Live status and recording status are kept strictly separate (design §9): a
// camera can be live yet NOT recording, and that must be visually obvious.
// Exposed to QML as `CameraStatus.<Value>` (e.g. CameraStatus.Live).
class CameraStatus : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("CameraStatus only exposes enums")
public:
    enum LiveState {
        LiveUnknown = 0,
        Live,
        Offline,
        Degraded,
        Loading,
        NoSignal,
        PermissionDenied,
    };
    Q_ENUM(LiveState)

    enum RecState {
        RecUnknown = 0,
        Recording,
        NotRecording,
        RecordingGap,
    };
    Q_ENUM(RecState)
};
