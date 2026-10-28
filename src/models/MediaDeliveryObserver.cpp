#include "MediaDeliveryObserver.h"
#include "AvailabilityObservation.h"
#include "AvailabilityObservationBus.h"
#include <QDateTime>
#include <QTimer>
#include <QUuid>
#include <QVideoFrame>
#include <chrono>
#include <unordered_set>

namespace {
qint64 steady()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
std::mutex &aliveMutex() { static std::mutex lock; return lock; }
std::unordered_set<MediaDeliveryObserver *> &alive()
{ static std::unordered_set<MediaDeliveryObserver *> instances; return instances; }
}

MediaDeliveryObserver::MediaDeliveryObserver(QObject *parent) : QObject(parent)
{
    { std::lock_guard<std::mutex> lock(aliveMutex()); alive().insert(this); }
    m_timer = new QTimer(this);
    m_timer->setInterval(5000);
    connect(m_timer, &QTimer::timeout, this, &MediaDeliveryObserver::tick);
    m_timer->start();
}

MediaDeliveryObserver::~MediaDeliveryObserver()
{
    { std::lock_guard<std::mutex> lock(aliveMutex()); alive().erase(this); }
    QObject::disconnect(m_frameConnection);
    close(QStringLiteral("observer_destroyed"));
}

void MediaDeliveryObserver::resetFrameCandidate()
{
    ++m_generation;
    m_lastPts = -1;
    m_advancingFrames = 0;
    rebindFrames();
}

void MediaDeliveryObserver::rebindFrames()
{
    QObject::disconnect(m_frameConnection);
    if (!m_sink) return;
    const quint64 generation = m_generation;
    // Stamp at signal emission, before a potentially delayed GUI delivery. Only
    // scalar evidence is retained, in one coalescing mailbox, never raw frames.
    m_frameConnection = connect(m_sink, &QVideoSink::videoFrameChanged, this,
        [this, generation](const QVideoFrame &frame) {
            std::lock_guard<std::mutex> aliveLock(aliveMutex());
            if (!alive().count(this)) return;
            bool post = false;
            {
                std::lock_guard<std::mutex> lock(m_arrivalMutex);
                m_pendingValid = frame.isValid();
                m_pendingPts = frame.startTime();
                m_pendingSteady = steady();
                m_pendingWall = QDateTime::currentMSecsSinceEpoch();
                m_pendingGeneration = generation;
                if (!m_arrivalQueued) { m_arrivalQueued = true; post = true; }
            }
            if (post) {
                const QPointer<MediaDeliveryObserver> guard(this);
                QMetaObject::invokeMethod(this, [guard] { if (guard) guard->consume(); }, Qt::QueuedConnection);
            }
        }, Qt::DirectConnection);
}

void MediaDeliveryObserver::setPlayer(QObject *object)
{
    auto *player = qobject_cast<QMediaPlayer *>(object);
    if (m_player == player) return;
    close(QStringLiteral("media_player_changed"));
    if (m_player) disconnect(m_player, nullptr, this, nullptr);
    m_player = player;
    m_expectedSource = player ? player->source() : QUrl{};
    resetFrameCandidate();
    if (player) {
        connect(player, &QMediaPlayer::sourceChanged, this, [this] {
            if (!m_player) return;
            close(QStringLiteral("stream_changed"));
            m_expectedSource = m_player->source();
            resetFrameCandidate();
            updateMonitoring();
        });
        connect(player, &QMediaPlayer::playbackStateChanged, this, [this] {
            // Replaying the same source gets fresh decoder evidence, while a
            // confirmed same-source delivery condition keeps its identity.
            resetFrameCandidate();
            updateMonitoring();
        });
        connect(player, &QMediaPlayer::videoOutputChanged, this, &MediaDeliveryObserver::updateMonitoring);
        connect(player, &QMediaPlayer::errorOccurred, this, [this] {
            if (m_monitoring) publish(QStringLiteral("degraded"), QStringLiteral("pipeline_error"));
        });
    }
    emit bindingChanged();
    updateMonitoring();
}

void MediaDeliveryObserver::setVideoSink(QVideoSink *sink)
{
    if (m_sink == sink) return;
    close(QStringLiteral("video_sink_changed"));
    m_sink = sink;
    resetFrameCandidate();
    emit bindingChanged();
    updateMonitoring();
}

void MediaDeliveryObserver::setCameraId(const QString &id)
{
    if (m_camera == id) return;
    close(QStringLiteral("camera_changed")); m_camera = id;
    resetFrameCandidate(); emit bindingChanged(); updateMonitoring();
}

void MediaDeliveryObserver::setStreamVariant(const QString &stream)
{
    const QString normalized = stream == QLatin1String("main") || stream == QLatin1String("sub")
        ? stream : QStringLiteral("unknown");
    if (m_stream == normalized) return;
    close(QStringLiteral("stream_changed")); m_stream = normalized;
    resetFrameCandidate(); emit bindingChanged(); updateMonitoring();
}

void MediaDeliveryObserver::setTransport(const QString &transport)
{
    const QString normalized = transport == QLatin1String("http") || transport == QLatin1String("hls")
        || transport == QLatin1String("rtsp") ? transport : QStringLiteral("unknown");
    if (m_transport == normalized) return;
    close(QStringLiteral("transport_changed")); m_transport = normalized;
    resetFrameCandidate(); emit bindingChanged(); updateMonitoring();
}

void MediaDeliveryObserver::setActive(bool active)
{
    if (m_active == active) return;
    m_active = active; resetFrameCandidate(); emit bindingChanged(); updateMonitoring();
}

void MediaDeliveryObserver::setWarmOnly(bool warm)
{
    if (m_warmOnly == warm) return;
    m_warmOnly = warm; resetFrameCandidate(); emit bindingChanged(); updateMonitoring();
}

void MediaDeliveryObserver::publish(const QString &state, const QString &reason, const QString &hint)
{
    if (!m_monitoring || m_state == state) return;
    QString transition = hint;
    if (transition.isEmpty()) transition = m_state.isEmpty() ? QStringLiteral("initial")
        : state == QLatin1String("available") && (m_state == QLatin1String("unavailable") || m_state == QLatin1String("degraded"))
            ? QStringLiteral("recovery") : QStringLiteral("state_change");
    QVariantMap details {{QStringLiteral("observer_scope"), QStringLiteral("pipeline")},
        {QStringLiteral("pipeline_id"), m_pipelineId}, {QStringLiteral("stream_variant"), m_stream},
        {QStringLiteral("transport"), m_transport}, {QStringLiteral("threshold_ms"), wt::availability::liveConfirmationMs}};
    if (!m_lastPositiveAt.isEmpty()) details[QStringLiteral("last_positive_at")] = m_lastPositiveAt;
    const bool gap = transition == QLatin1String("monitoring_gap") || transition == QLatin1String("monitoring_resumed");
    AvailabilityObservationBus::publish(wt::availability::observation(m_camera,
        gap ? QStringLiteral("monitoring") : QStringLiteral("live_delivery"), QStringLiteral("client_observed"),
        state, transition, reason, details));
    m_state = state;
}

void MediaDeliveryObserver::close(const QString &reason)
{
    if (m_monitoring) publish(QStringLiteral("not_monitored"), reason, QStringLiteral("monitoring_gap"));
    m_monitoring = false; m_state.clear();
}

void MediaDeliveryObserver::updateMonitoring()
{
    const bool eligible = m_active && !m_warmOnly && m_player && m_sink && !m_camera.isEmpty()
        && !m_expectedSource.isEmpty() && m_player->source() == m_expectedSource && m_player->videoSink() == m_sink;
    if (!eligible) { close(QStringLiteral("observer_inactive")); return; }
    if (m_monitoring) return;
    m_monitoring = true;
    m_pipelineId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_started = m_lastTick = steady();
    m_lastWall = QDateTime::currentMSecsSinceEpoch();
    m_lastPositive = -1; m_lastPositiveAt.clear();
    m_timestampsSupported = true;
    m_lastPts = -1; m_advancingFrames = 0;
    publish(QStringLiteral("unknown"), QStringLiteral("awaiting_decoded_frame"));
}

void MediaDeliveryObserver::tick()
{
    updateMonitoring();
    if (!m_monitoring) return;
    const qint64 now = steady(), wall = QDateTime::currentMSecsSinceEpoch();
    if (wt::availability::observationClockGap(m_lastTick, now, m_lastWall, wall)) {
        publish(QStringLiteral("not_monitored"), QStringLiteral("observation_gap"), QStringLiteral("monitoring_gap"));
        m_started = now; m_lastPositive = -1;
        m_lastPts = -1; m_advancingFrames = 0;
        publish(QStringLiteral("unknown"), QStringLiteral("monitor_resumed"), QStringLiteral("monitoring_resumed"));
    }
    m_lastTick = now; m_lastWall = wall;
    if (m_timestampsSupported && wt::availability::confirmedMissingFrame(m_started, m_lastPositive, now))
        publish(QStringLiteral("unavailable"), QStringLiteral("decoded_frame_timeout"));
}

void MediaDeliveryObserver::consume()
{
    qint64 pts, arrived, wall;
    quint64 generation;
    bool valid;
    {
        std::lock_guard<std::mutex> lock(m_arrivalMutex);
        pts = m_pendingPts; arrived = m_pendingSteady; wall = m_pendingWall;
        generation = m_pendingGeneration; valid = m_pendingValid; m_arrivalQueued = false;
    }
    tick();
    if (!valid || generation != m_generation || !m_monitoring || !m_player || !m_sink
        || m_player->source() != m_expectedSource || m_player->videoSink() != m_sink
        || m_player->playbackState() != QMediaPlayer::PlayingState || !m_player->hasVideo()
        || !wt::availability::freshDecoded(arrived, steady(), wall, QDateTime::currentMSecsSinceEpoch())) return;
    if (pts < 0) {
        if (!m_timestampsSupported) return;
        m_timestampsSupported = false;
        publish(QStringLiteral("not_monitored"), QStringLiteral("media_timestamps_unavailable"), QStringLiteral("monitoring_gap"));
        publish(QStringLiteral("unknown"), QStringLiteral("media_timestamps_unavailable"), QStringLiteral("monitoring_resumed"));
        return;
    }
    if (pts == m_lastPts) return; // cached/same-PTS repaint is never recovery evidence
    m_advancingFrames = pts > m_lastPts && m_lastPts >= 0 ? qMin(2, m_advancingFrames + 1) : 1;
    m_lastPts = pts;
    if (m_advancingFrames < 2) return;
    m_timestampsSupported = true;
    m_lastPositive = arrived;
    m_lastPositiveAt = wt::availability::instant();
    publish(QStringLiteral("available"), QStringLiteral("decoded_frame_received"));
}
