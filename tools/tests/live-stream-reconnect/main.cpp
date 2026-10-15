#include "RtspVideoSource.h"
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
    if (!url.startsWith("rtsp://127.0.0.1:") || !timeoutOk || timeoutMs < 10000 || timeoutMs > 60000) return 2;
    qmlRegisterType<RtspVideoSource>("Watchtower", 1, 0, "RtspVideoSource");
    qmlRegisterSingletonType(QUrl::fromLocalFile(qmlDir + "/ReconnectCoordinator.qml"), "Watchtower", 1, 0, "ReconnectCoordinator");
    QQmlEngine engine;
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
