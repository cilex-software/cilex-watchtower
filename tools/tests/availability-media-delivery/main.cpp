#include "MediaDeliveryObserver.h"
#include "AvailabilityObservationBus.h"
#include <QGuiApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMediaPlayer>
#include <QRegularExpression>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTest>
#include <QTextStream>
#include <QVideoSink>
#include <QVideoFrame>
#include <functional>

namespace {
bool waitFor(const std::function<bool()> &predicate, int ms = 10000)
{
    QElapsedTimer clock; clock.start();
    while (!predicate() && clock.elapsed() < ms) QTest::qWait(20);
    return predicate();
}
class ClipServer : public QTcpServer {
public:
    QByteArray clip;
    explicit ClipServer(QByteArray bytes) : clip(std::move(bytes)) {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (hasPendingConnections()) {
                auto *socket = nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    if (socket->property("handled").toBool()) return;
                    const auto request = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", request);
                    if (!request.contains("\r\n\r\n")) return;
                    socket->setProperty("handled", true);
                    const auto range = QRegularExpression("(?i)Range: bytes=(\\d+)-(\\d*)").match(QString::fromLatin1(request));
                    qint64 first = range.hasMatch() ? range.captured(1).toLongLong() : 0;
                    qint64 last = range.hasMatch() && !range.captured(2).isEmpty() ? range.captured(2).toLongLong() : clip.size() - 1;
                    last = qMin(last, qint64(clip.size() - 1));
                    if (first < 0 || first > last) { socket->write("HTTP/1.1 416 Range Not Satisfiable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"); socket->disconnectFromHost(); return; }
                    QByteArray headers = range.hasMatch() ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
                    headers += "Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nConnection: close\r\nContent-Length: " + QByteArray::number(last-first+1) + "\r\n";
                    if (range.hasMatch()) headers += "Content-Range: bytes " + QByteArray::number(first) + '-' + QByteArray::number(last) + '/' + QByteArray::number(clip.size()) + "\r\n";
                    socket->write(headers + "\r\n");
                    if (!request.startsWith("HEAD ")) socket->write(clip.mid(first, last-first+1));
                    socket->disconnectFromHost();
                });
            }
        });
    }
};
}

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    if (app.arguments().size() != 2) return 2;
    QFile input(app.arguments().at(1)); if (!input.open(QIODevice::ReadOnly)) return 2;
    ClipServer server(input.readAll()); if (!server.listen(QHostAddress::LocalHost, 0)) return 2;
    QJsonArray checks, events;
    auto check = [&](const QString &name, bool passed) { checks.append(QJsonObject{{"check", name}, {"passed", passed}}); };
    auto *bus = AvailabilityObservationBus::instance();
    QObject::connect(bus, &AvailabilityObservationBus::observationReady, &app, [&](const QVariantMap &event) { events.append(QJsonObject::fromVariantMap(event)); });
    QMediaPlayer player;
    QVideoSink sink;
    QVideoFrame lastDecoded;
    QObject::connect(&sink, &QVideoSink::videoFrameChanged, &app, [&](const QVideoFrame &frame) { if (frame.isValid()) lastDecoded = frame; });
    player.setVideoSink(&sink);
    MediaDeliveryObserver observer;
    observer.setProperty("player", QVariant::fromValue<QObject*>(&player));
    observer.setProperty("videoSink", QVariant::fromValue(&sink));
    observer.setProperty("cameraId", "fixture-media-http");
    observer.setProperty("streamVariant", "sub");
    observer.setProperty("transport", "http");
    observer.setProperty("active", true);
    const auto count = [&](const QString &state) { int total = 0; for (auto value : events) { const auto event = value.toObject(); if (event.value("domain") == "live_delivery" && event.value("state") == state) ++total; } return total; };
    player.setSource(QUrl("http://127.0.0.1:" + QString::number(server.serverPort()) + "/clip.mp4"));
    player.play();
    const bool decoded = waitFor([&] { return count("available") > 0 && sink.videoFrame().isValid(); });
    check("actual QtMultimedia HTTP decoded frames establish delivery", decoded);
    if (decoded) {
        check("fixture clip reaches its end", waitFor([&] { return player.mediaStatus() == QMediaPlayer::EndOfMedia; }));
        const auto cached = lastDecoded; const int positive = count("available");
        sink.setVideoFrame(cached); QTest::qWait(100);
        check("a cached frame without advancing media does not establish recovery", count("available") == positive);
        observer.setProperty("active", false); QTest::qWait(40);
        const auto hiddenCount = events.size(); sink.setVideoFrame(cached); QTest::qWait(100);
        check("hidden observer does not report delivery or a camera failure", events.size() == hiddenCount);
        observer.setProperty("active", true);
        check("missing actual media is confirmed at the fixed 75-second threshold", waitFor([&] { return count("unavailable") == 1; }, 82000));
        const int failedPositive = count("available"); sink.setVideoFrame(cached); QTest::qWait(100);
        check("cached end frame cannot recover the confirmed loss", count("available") == failedPositive);
        player.setPosition(0); player.play();
        check("fresh advancing decoded frames establish real recovery", waitFor([&] { return count("available") > failedPositive; }));
        observer.setProperty("cameraId", "fixture-media-other");
        observer.setProperty("active", false); QTest::qWait(50);
        check("every observation uses canonical camera identity and bounded metadata", [&] {
            for (auto value : events) {
                const auto e = value.toObject();
                if (e.value("camera_id") != "fixture-media-http" && e.value("camera_id") != "fixture-media-other") return false;
                if (QJsonDocument(e).toJson().contains("127.0.0.1")) return false;
            }
            return true;
        }());
    }
    observer.setProperty("active", false); player.setSource({});
    int failures = 0; for (auto value : checks) if (!value.toObject().value("passed").toBool()) ++failures;
    QTextStream(stdout) << QJsonDocument(QJsonObject{{"checks", checks}, {"events", events}, {"failures", failures}, {"passed", failures == 0}}).toJson(QJsonDocument::Compact) << Qt::endl;
    return failures ? 1 : 0;
}
