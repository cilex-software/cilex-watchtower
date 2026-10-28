#include "RtspVideoSource.h"
#include "MediaDeliveryObserver.h"
#include "AvailabilityObservationBus.h"
#include <QGuiApplication>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QImage>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QThread>
#include <QVideoFrameFormat>
#include <cstring>
#include <QFileInfo>
#include <cstdio>

static void spin(int ms)
{
    QElapsedTimer clock; clock.start();
    while (clock.elapsed() < ms) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        QThread::msleep(2);
    }
}
int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    gst_init(nullptr, nullptr);
    if (argc != 4 || !qEnvironmentVariableIsSet("WT_STREAM_WATCHDOG_OFF")) return 2;
    const QString qmlDir = QFileInfo(QString::fromLocal8Bit(argv[1])).absoluteFilePath();
    const QString url = QString::fromLocal8Bit(argv[2]);
    bool timeoutOk = false;
    const int timeoutMs = QString::fromLocal8Bit(argv[3]).toInt(&timeoutOk);
    const bool mediaFixture = QUrl(url).isLocalFile() || url.startsWith("http://127.0.0.1:");
    if ((!url.startsWith("rtsp://127.0.0.1:") && !mediaFixture)
        || !timeoutOk || timeoutMs < (mediaFixture ? 2000 : 10000) || timeoutMs > 60000) return 2;
    qmlRegisterType<RtspVideoSource>("Watchtower", 1, 0, "RtspVideoSource");
    qmlRegisterType<MediaDeliveryObserver>("Watchtower", 1, 0, "MediaDeliveryObserver");
    qmlRegisterSingletonType(QUrl::fromLocalFile(qmlDir + "/ReconnectCoordinator.qml"), "Watchtower", 1, 0, "ReconnectCoordinator");
    QQmlEngine engine;
    engine.rootContext()->setContextProperty("AvailabilityObservations", AvailabilityObservationBus::instance());
    engine.rootContext()->setContextProperty("wtLowLatency", true);
    engine.rootContext()->setContextProperty("wtReconOff", false);
    QQmlComponent component(&engine, QUrl::fromLocalFile(qmlDir + "/VideoSurface.qml"));
    QScopedPointer<QObject> surface(component.create());
    if (!surface) { qWarning() << component.errors(); return 2; }
    auto *item = qobject_cast<QQuickItem *>(surface.data());
    if (!item) return 2;
    QQuickWindow window;
    window.resize(320, 180);
    item->setParentItem(window.contentItem());
    item->setWidth(320); item->setHeight(180);
    window.show();
    if (mediaFixture) {
        QJsonArray events;
        QObject::connect(AvailabilityObservationBus::instance(), &AvailabilityObservationBus::observationReady,
            &window, [&](const QVariantMap &event) { events.append(QJsonObject::fromVariantMap(event)); });
        surface->setProperty("cameraId", "fixture-qml-media");
        surface->setProperty("streamVariant", "sub");
        surface->setProperty("url", url);
        spin(20);
        const auto observers = surface->findChildren<MediaDeliveryObserver *>();
        if (observers.size() != 1 || !observers[0]->videoSink() || !observers[0]->player()) return 2;
        auto *sink = observers[0]->videoSink();
        int decodedFrames = 0;
        QObject::connect(sink, &QVideoSink::videoFrameChanged, &window,
            [&](const QVideoFrame &frame) { if (frame.isValid() && frame.startTime() >= 0) ++decodedFrames; });
        const auto positives = [&] {
            int total = 0;
            for (auto value : events) {
                const auto e = value.toObject();
                if (e.value("domain") == "live_delivery" && e.value("state") == "available") ++total;
            }
            return total;
        };
        QElapsedTimer clock; clock.start();
        while (clock.elapsed() < timeoutMs && (decodedFrames < 8 || positives() < 1)) spin(10);
        const bool live = positives() == 1 && decodedFrames >= 8;
        const QVideoFrame cached = sink->videoFrame();
        const int before = positives();
        auto *actualPlayer = qobject_cast<QMediaPlayer *>(observers[0]->player());
        const auto unknownGaps = [&] {
            int total = 0;
            for (auto value : events) {
                const auto e = value.toObject();
                if (e.value("transition") == "monitoring_gap" && e.value("reason_code") == "media_timestamps_unavailable") ++total;
            }
            return total;
        };
        const int gapsBefore = unknownGaps();
        actualPlayer->setPlaybackRate(0.001); // local fixture only; keep ownership/PlayingState while injecting evidence
        for (int i = 0; i < 16; ++i) {
            // Different buffers force a real callback; setting the identical
            // cached buffer can be elided by QVideoSink before any observer.
            QVideoFrame untimestamped(QVideoFrameFormat(QSize(16, 16), QVideoFrameFormat::Format_RGBA8888));
            if (untimestamped.map(QVideoFrame::WriteOnly)) {
                std::memset(untimestamped.bits(0), 0, size_t(untimestamped.mappedBytes(0)));
                untimestamped.unmap();
            }
            sink->setVideoFrame(untimestamped); spin(1);
        }
        const bool missingPtsBounded = unknownGaps() - gapsBefore == 1 && positives() == before;
        actualPlayer->setPlaybackRate(1);
        actualPlayer->pause();
        sink->setVideoFrame(cached); spin(50); sink->setVideoFrame(cached); spin(50);
        const bool cachedIgnored = positives() == before;
        const QJsonObject result{{"passed", live && cachedIgnored && missingPtsBounded}, {"actual_qml_player_cast", true},
            {"decoded_frames", decodedFrames}, {"available_events", positives()},
            {"cached_frame_ignored", cachedIgnored}, {"untimestamped_frames_bounded", missingPtsBounded}, {"events", events}};
        printf("%s\n", QJsonDocument(result).toJson(QJsonDocument::Compact).constData());
        surface->setProperty("active", false); surface.reset();
        return live && cachedIgnored && missingPtsBounded ? 0 : 1;
    }
    surface->setProperty("url", url);
    spin(10);
    auto sources = surface->findChildren<RtspVideoSource *>();
    if (sources.size() != 1 || !sources[0]->videoSink()) return 2;
    QElapsedTimer clock; clock.start();
    qint64 firstRed = -1, lastRed = -1, firstBlue = -1, lostPlaying = -1;
    int red = 0, blue = 0, other = 0;
    QJsonArray transitions;
    QObject::connect(sources[0]->videoSink(), &QVideoSink::videoFrameChanged, &window, [&](const QVideoFrame &frame) {
        if (!frame.isValid()) return;
        const QImage image = frame.toImage();
        if (image.isNull()) { ++other; return; }
        const QColor p = image.pixelColor(image.width()/2, image.height()/2);
        if (p.red() > 180 && p.green() < 70 && p.blue() < 70) {
            if (firstRed < 0) firstRed = clock.elapsed();
            lastRed = clock.elapsed(); ++red;
        } else if (p.blue() > 180 && p.red() < 70 && p.green() < 70) {
            if (firstBlue < 0) firstBlue = clock.elapsed();
            ++blue;
        } else ++other;
    });
    bool previousPlaying = false;
    while (clock.elapsed() < timeoutMs && blue < 15) {
        spin(10);
        const bool playing = surface->property("playing").toBool();
        if (playing != previousPlaying) {
            transitions.append(QJsonObject{{"elapsed_ms", clock.elapsed()}, {"playing", playing}});
            if (!playing && red >= 10 && lostPlaying < 0) lostPlaying = clock.elapsed();
            previousPlaying = playing;
        }
    }
    const bool passed = red >= 10 && blue >= 15 && other == 0 && lostPlaying > lastRed
        && firstBlue > lostPlaying && firstBlue - lastRed < 15000
        && RtspVideoSource::reconnectRuns() >= 1 && RtspVideoSource::watchdogRebuilds() == 0
        && surface->property("playing").toBool();
    const QJsonObject result{{"passed", passed}, {"initial_red_frames", red}, {"reconnected_blue_frames", blue},
        {"unexpected_pixels", other}, {"first_red_ms", firstRed}, {"last_red_ms", lastRed},
        {"qml_stall_detected_ms", lostPlaying}, {"first_blue_ms", firstBlue},
        {"recovery_from_last_frame_ms", firstBlue < 0 ? -1 : firstBlue - lastRed},
        {"reconnect_runs", RtspVideoSource::reconnectRuns()}, {"watchdog_rebuilds", RtspVideoSource::watchdogRebuilds()},
        {"elapsed_ms", clock.elapsed()}, {"playing_transitions", transitions}};
    printf("%s\n", QJsonDocument(result).toJson(QJsonDocument::Compact).constData());
    fflush(stdout);
    surface->setProperty("active", false);
    surface.reset();
    return passed ? 0 : 1;
}
