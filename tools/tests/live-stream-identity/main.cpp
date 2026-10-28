#include "RtspVideoSource.h"
#include "AvailabilityObservationBus.h"
#include "AvailabilityObservation.h"

#include <QGuiApplication>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QEvent>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QThread>
#include <QTimer>
#include <QCryptographicHash>
#include <QUrl>
#include <functional>
#include <cstdio>

// These checks inspect decoded pixels from real local RTSP streams, not URL labels.
// No private production fields or test hooks are used.
static void spin(int ms)
{
    QElapsedTimer clock;
    clock.start();
    while (clock.elapsed() < ms) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        QThread::msleep(2);
    }
}

static QJsonObject readiness(const QString &url)
{
    const auto clean = QUrl(url).adjusted(QUrl::RemoveUserInfo | QUrl::RemoveQuery | QUrl::RemoveFragment).toEncoded();
    const QString id = QString::fromLatin1(QCryptographicHash::hash(clean, QCryptographicHash::Sha256).toHex());
    for (const auto &entry : RtspVideoSource::videoReadiness())
        if (entry.toObject().value("id").toString() == id) return entry.toObject();
    return {};
}

struct Probe {
    QVideoSink sink;
    RtspVideoSource source;
    QString expected;
    QJsonArray samples;
    int matches = 0;
    int wrong = 0;

    Probe()
    {
        QObject::connect(&sink, &QVideoSink::videoFrameChanged, &sink, [this](const QVideoFrame &frame) {
            if (!frame.isValid() || expected.isEmpty()) return;
            const QImage image = frame.toImage();
            if (image.isNull()) {
                ++wrong;
                samples.append(QJsonObject{{"error", "valid frame could not convert to image"}});
                return;
            }
            const QColor pixel = image.pixelColor(image.width() / 2, image.height() / 2);
            QString actual = "other";
            if (pixel.red() > 180 && pixel.green() < 70 && pixel.blue() < 70) actual = "red";
            if (pixel.green() > 180 && pixel.red() < 70 && pixel.blue() < 70) actual = "green";
            if (pixel.blue() > 180 && pixel.red() < 70 && pixel.green() < 70) actual = "blue";
            if (actual == expected) ++matches; else ++wrong;
            samples.append(QJsonObject{{"actual", actual}, {"expected", expected},
                {"rgb", QJsonArray{pixel.red(), pixel.green(), pixel.blue()}}});
        });
        source.setLatencyMs(0);
    }
    void begin(const QString &colour)
    {
        source.setCameraId(QStringLiteral("fixture-") + colour);
        source.setStreamVariant(QStringLiteral("sub"));
        expected = colour;
        samples = QJsonArray();
        matches = wrong = 0;
    }
    bool awaitFrames()
    {
        QElapsedTimer clock;
        clock.start();
        while (clock.elapsed() < 2500 && matches < 3) spin(10);
        return matches >= 3 && wrong == 0;
    }
};

static int availabilityStall(const QString &url)
{
    if (!qEnvironmentVariableIsSet("WT_STREAM_WATCHDOG_OFF")) return 2;
    QVideoSink sink;
    RtspVideoSource source;
    QElapsedTimer clock; clock.start();
    QJsonArray events;
    int available = 0, unavailable = 0;
    qint64 firstPositive = -1, failureAt = -1, recoveredAt = -1;
    QObject::connect(AvailabilityObservationBus::instance(), &AvailabilityObservationBus::observationReady,
        &source, [&](const QVariantMap &event) {
            if (event.value("camera_id").toString() != QLatin1String("fixture-availability-stall")
                || event.value("domain").toString() != QLatin1String("live_delivery")) return;
            events.append(QJsonObject::fromVariantMap(event));
            if (event.value("state").toString() == QLatin1String("available")) {
                ++available;
                if (firstPositive < 0) firstPositive = clock.elapsed();
                else recoveredAt = clock.elapsed();
            } else if (event.value("state").toString() == QLatin1String("unavailable")) {
                ++unavailable;
                failureAt = clock.elapsed();
                QTimer::singleShot(0, &source, &RtspVideoSource::reconnect);
            }
        });
    source.setCameraId(QStringLiteral("fixture-availability-stall"));
    source.setStreamVariant(QStringLiteral("sub"));
    source.setUrl(url);
    source.setVideoSink(&sink);
    while (clock.elapsed() < 85000 && recoveredAt < 0) spin(10);
    const bool passed = firstPositive >= 0 && unavailable == 1 && available == 2
        && failureAt - firstPositive >= wt::availability::liveConfirmationMs
        && recoveredAt > failureAt && recoveredAt - failureAt < 5000;
    const QJsonObject result {{"passed", passed}, {"first_positive_ms", firstPositive},
        {"failure_ms", failureAt}, {"recovery_ms", recoveredAt},
        {"unavailable_events", unavailable}, {"available_events", available},
        {"threshold_ms", wt::availability::liveConfirmationMs}, {"events", events}};
    printf("%s\n", QJsonDocument(result).toJson(QJsonDocument::Indented).constData());
    source.setActive(false);
    return passed ? 0 : 1;
}

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    gst_init(nullptr, nullptr);
    if (argc != 2 && argc != 3) {
        fprintf(stderr, "usage: live-stream-identity rtsp://127.0.0.1:18554 [--availability-stall]\n");
        return 2;
    }
    const QString base = QString::fromLocal8Bit(argv[1]);
    if (!base.startsWith("rtsp://127.0.0.1:")) return 2;
    if (argc == 3) {
        if (QString::fromLocal8Bit(argv[2]) != QLatin1String("--availability-stall")) return 2;
        return availabilityStall(base + QStringLiteral("/silent-stall"));
    }
    QJsonArray results;
    QJsonArray observations;
    QObject::connect(AvailabilityObservationBus::instance(), &AvailabilityObservationBus::observationReady,
        &app, [&observations](const QVariantMap &event) { observations.append(QJsonObject::fromVariantMap(event)); });
    auto observed = [&observations](const QString &camera, const QString &domain, const QString &state, int since = 0) {
        int count = 0;
        for (qsizetype i = since; i < observations.size(); ++i) {
            const auto event = observations.at(i).toObject();
            if (event.value("camera_id").toString() == camera && event.value("domain").toString() == domain
                && event.value("state").toString() == state) ++count;
        }
        return count;
    };
    int failures = 0;
    auto result = [&](const QString &name, bool passed, const Probe &probe, QJsonObject extra = {}) {
        extra.insert("name", name);
        extra.insert("passed", passed);
        extra.insert("correct_frames", probe.matches);
        extra.insert("wrong_frames", probe.wrong);
        extra.insert("samples", probe.samples);
        results.append(extra);
        if (!passed) ++failures;
        fprintf(stderr, "%s %s (correct=%d wrong=%d)\n", passed ? "PASS" : "FAIL",
                qPrintable(name), probe.matches, probe.wrong);
    };

    {
        // Inspect requested state before processing any decode/build events.
        // These are synthetic credentials on a loopback-only nonexistent route.
        Probe pending;
        const QString url = base + "/pending?fixture-token=hidden#fixture-fragment";
        QUrl credentialUrl(url);
        credentialUrl.setUserName("fixture-user");
        credentialUrl.setPassword("fixture-password");
        pending.source.setActive(false);
        pending.source.setCameraId(QStringLiteral("fixture-pending"));
        pending.source.setUrl(credentialUrl.toString());
        pending.source.setVideoSink(&pending.sink);
        result("readiness excludes inactive sources", readiness(url).isEmpty(), pending);
        pending.source.setActive(true);
        const QJsonObject before = readiness(url);
        const QByteArray encoded = QJsonDocument(RtspVideoSource::videoReadiness()).toJson(QJsonDocument::Compact);
        result("readiness includes pending source without leaking URL data",
               before.value("frames").toInteger(-1) == 0 && before.value("age_ms").isNull()
               && before.value("id").toString().size() == 64 && !before.value("decoder").toBool()
               && !encoded.contains("fixture-") && !encoded.contains("127.0.0.1")
               && !encoded.contains("pending") && !encoded.contains("rtsp"), pending, {{"readiness", before}});
        pending.source.setWarmOnly(true);
        result("readiness excludes warm-only sources", readiness(url).isEmpty(), pending);
        pending.source.setWarmOnly(false);
        pending.source.setVideoSink(nullptr);
        result("readiness excludes sources without video sink", readiness(url).isEmpty(), pending);
        QCoreApplication::sendPostedEvents(&app, QEvent::MetaCall);
        result("inactive warm-only and no-sink changes never report camera outage",
               observed("fixture-pending", "live_delivery", "unavailable") == 0
               && observed("fixture-pending", "live_delivery", "available") == 0
               && observed("fixture-pending", "monitoring", "not_monitored") >= 1, pending);
    }

    Probe detail;
    detail.begin("red");
    detail.source.setUrl(base + "/red");
    detail.source.setVideoSink(&detail.sink);
    result("initial camera A pixels", detail.awaitFrames(), detail);
    QCoreApplication::sendPostedEvents(&app, QEvent::MetaCall);
    result("decoded incoming pixels establish one camera-bound available observation",
           observed("fixture-red", "live_delivery", "available") == 1, detail);
    const QJsonObject first = readiness(base + "/red");
    spin(450);
    const QJsonObject second = readiness(base + "/red");
    result("readiness advances decoded sink frames with recent monotonic age",
           first.value("frames").toInteger() >= 3
           && second.value("frames").toInteger() > first.value("frames").toInteger()
           && second.value("age_ms").isDouble() && second.value("age_ms").toInteger(-1) >= 0
           && second.value("age_ms").toInteger(9999) < 1000
           && second.value("decoder").toBool() && !second.value("error").toBool(), detail,
           {{"before", first}, {"after", second}});
    // A busy GUI can leave the sink unchanged while streaming threads decode.
    // Reading readiness must expose that elapsed age without inventing frames.
    QThread::msleep(80);
    const QJsonObject undelivered = readiness(base + "/red");
    result("readiness ages while fresh decoded frames have not reached the sink",
           undelivered.value("frames").toInteger() == second.value("frames").toInteger()
           && undelivered.value("age_ms").toInteger() >= second.value("age_ms").toInteger() + 70,
           detail, {{"before", second}, {"after", undelivered}});
    for (const auto &colour : {QString("green"), QString("red"), QString("blue")}) {
        detail.begin(colour);
        detail.source.setUrl(base + "/" + colour);
        const auto reset = readiness(base + "/" + colour);
        result("readiness resets fresh progress on URL change to " + colour,
               reset.value("frames").toInteger(-1) == 0 && reset.value("age_ms").isNull(), detail,
               {{"readiness", reset}});
        result("retarget detail to " + colour, detail.awaitFrames(), detail);
    }

    // Hiding/destroying a detail surface must leave a reusable pipeline under
    // its real URL, and a wall source must receive pixels for that URL.
    detail.source.setActive(false);
    const int parked = RtspVideoSource::parkedPipelineCount();
    Probe wallBlue;
    wallBlue.begin("blue");
    const int beforeAdoption = int(observations.size());
    wallBlue.source.setUrl(base + "/blue");
    wallBlue.source.setVideoSink(&wallBlue.sink);
    const bool adoptedImmediately = wallBlue.source.playing();
    const QJsonObject cached = readiness(base + "/blue");
    QCoreApplication::sendPostedEvents(&app, QEvent::MetaCall);
    result("adopted cached sink frame cannot report availability recovery",
           observed("fixture-blue", "live_delivery", "available", beforeAdoption) == 0, wallBlue);
    result("parked cached picture does not establish fresh readiness progress",
           adoptedImmediately && wallBlue.sink.videoFrame().isValid()
           && cached.value("frames").toInteger(-1) == 0 && cached.value("age_ms").isNull(), wallBlue,
           {{"readiness", cached}});
    result("wall reopens camera C from parked pipeline", wallBlue.awaitFrames() && parked > 0 && adoptedImmediately,
           wallBlue, {{"parked_before", parked}, {"immediate_adoption", adoptedImmediately}});

    Probe wallRed;
    wallRed.begin("red");
    wallRed.source.setUrl(base + "/red");
    wallRed.source.setVideoSink(&wallRed.sink);
    result("wall camera A remains independent", wallRed.awaitFrames(), wallRed);

    detail.begin("green");
    detail.source.setUrl(base + "/green");
    detail.source.setActive(true);
    result("reopened detail camera B remains independent", detail.awaitFrames(), detail);
    wallBlue.begin("blue");
    wallRed.begin("red");
    spin(650);
    result("concurrent wall camera C pixels", wallBlue.matches >= 2 && wallBlue.wrong == 0, wallBlue);
    result("concurrent wall camera A pixels", wallRed.matches >= 2 && wallRed.wrong == 0, wallRed);

    // Warm-only consumers intentionally produce no pictures. Returning to
    // decode must not adopt a depay-only pipeline as though it were a decoder.
    detail.begin("green");
    detail.source.setWarmOnly(true);
    spin(650);
    result("decoded to warm-only produces no frames", detail.matches == 0 && detail.wrong == 0, detail);
    detail.begin("green");
    detail.source.setWarmOnly(false);
    result("warm-only back to decoded camera B", detail.awaitFrames(), detail);
    detail.begin("blue");
    detail.source.setWarmOnly(true);
    detail.source.setUrl(base + "/blue");
    spin(200);
    detail.source.setWarmOnly(false);
    result("warm-only URL switch then camera C decode", detail.awaitFrames(), detail);

    int rapidWrong = 0;
    QJsonArray rapidSamples;
    for (int cycle = 0; cycle < 2; ++cycle) {
        for (const auto &colour : {QString("red"), QString("green"), QString("blue")}) {
            detail.begin(colour);
            detail.source.setUrl(base + "/" + colour);
            spin(20);
            rapidWrong += detail.wrong;
            for (const auto &sample : detail.samples) rapidSamples.append(sample);
        }
    }
    const bool rapidSettled = detail.awaitFrames();
    result("rapid A B C retargets reject every foreign frame", rapidSettled && rapidWrong == 0,
           detail, {{"wrong_frames_during_rapid_changes", rapidWrong}, {"rapid_samples", rapidSamples}});
    bool safe = true, scoped = true;
    for (const auto &value : observations) {
        const auto event = value.toObject();
        const auto details = event.value("details").toObject();
        const auto bytes = QJsonDocument(event).toJson(QJsonDocument::Compact);
        safe = safe && !bytes.contains("fixture-password") && !bytes.contains("fixture-token")
            && !bytes.contains("127.0.0.1") && !bytes.contains("rtsp://");
        scoped = scoped && !details.value("pipeline_id").toString().isEmpty()
            && details.value("observer_scope").toString() == "pipeline";
    }
    result("availability evidence is scoped and excludes credentials and URLs", safe && scoped, detail);

    const QJsonObject report{{"passed", int(results.size()) - failures}, {"failed", failures},
                             {"tests", results}, {"boundary", "RtspVideoSource public API plus decoded QVideoSink pixels; no product QML navigation"}};
    printf("%s\n", QJsonDocument(report).toJson(QJsonDocument::Indented).constData());
    return failures ? 1 : 0;
}
