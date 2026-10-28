#pragma once

#include <QObject>
#include <QPointer>
#include <QMediaPlayer>
#include <QVideoSink>
#include <QUrl>
#include <QtQml/qqmlregistration.h>
#include <mutex>

class QTimer;

// Observe QMediaPlayer's owned sink at the C++ decoded-frame boundary. No
// pixel comparisons, QML playing flags, URLs or credentials enter the journal.
class MediaDeliveryObserver : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QObject *player READ player WRITE setPlayer NOTIFY bindingChanged)
    Q_PROPERTY(QVideoSink *videoSink READ videoSink WRITE setVideoSink NOTIFY bindingChanged)
    Q_PROPERTY(QString cameraId READ cameraId WRITE setCameraId NOTIFY bindingChanged)
    Q_PROPERTY(QString streamVariant READ streamVariant WRITE setStreamVariant NOTIFY bindingChanged)
    Q_PROPERTY(QString transport READ transport WRITE setTransport NOTIFY bindingChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY bindingChanged)
    Q_PROPERTY(bool warmOnly READ warmOnly WRITE setWarmOnly NOTIFY bindingChanged)
public:
    explicit MediaDeliveryObserver(QObject *parent = nullptr);
    ~MediaDeliveryObserver() override;
    QObject *player() const { return m_player; }
    void setPlayer(QObject *player);
    QVideoSink *videoSink() const { return m_sink; }
    void setVideoSink(QVideoSink *sink);
    QString cameraId() const { return m_camera; }
    void setCameraId(const QString &id);
    QString streamVariant() const { return m_stream; }
    void setStreamVariant(const QString &stream);
    QString transport() const { return m_transport; }
    void setTransport(const QString &transport);
    bool active() const { return m_active; }
    void setActive(bool active);
    bool warmOnly() const { return m_warmOnly; }
    void setWarmOnly(bool warm);
signals:
    void bindingChanged();
private:
    void rebindFrames();
    void resetFrameCandidate();
    void updateMonitoring();
    void tick();
    void consume();
    void close(const QString &reason);
    void publish(const QString &state, const QString &reason, const QString &transition = {});

    QPointer<QMediaPlayer> m_player;
    QPointer<QVideoSink> m_sink;
    QUrl m_expectedSource;
    QMetaObject::Connection m_frameConnection;
    QString m_camera, m_stream = QStringLiteral("unknown"), m_transport = QStringLiteral("http");
    QString m_pipelineId, m_state, m_lastPositiveAt;
    bool m_active = true, m_warmOnly = false, m_monitoring = false;
    bool m_timestampsSupported = true;
    qint64 m_started = 0, m_lastPositive = -1, m_lastTick = 0, m_lastWall = 0;
    qint64 m_lastPts = -1;
    int m_advancingFrames = 0;
    quint64 m_generation = 0;
    QTimer *m_timer = nullptr;
    std::mutex m_arrivalMutex;
    bool m_arrivalQueued = false;
    bool m_pendingValid = false;
    qint64 m_pendingPts = -1, m_pendingSteady = -1, m_pendingWall = -1;
    quint64 m_pendingGeneration = 0;
};
