#include "RtspVideoSource.h"

#include <QGuiApplication>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QThread>
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

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    gst_init(nullptr, nullptr);
    if (argc != 2) {
        fprintf(stderr, "usage: live-stream-identity rtsp://127.0.0.1:18554\n");
        return 2;
    }
    const QString base = QString::fromLocal8Bit(argv[1]);
    if (!base.startsWith("rtsp://127.0.0.1:")) return 2;
    QJsonArray results;
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

    Probe detail;
    detail.begin("red");
    detail.source.setUrl(base + "/red");
    detail.source.setVideoSink(&detail.sink);
    result("initial camera A pixels", detail.awaitFrames(), detail);
    for (const auto &colour : {QString("green"), QString("red"), QString("blue")}) {
        detail.begin(colour);
        detail.source.setUrl(base + "/" + colour);
        result("retarget detail to " + colour, detail.awaitFrames(), detail);
    }

    // Hiding/destroying a detail surface must leave a reusable pipeline under
    // its real URL, and a wall source must receive pixels for that URL.
    detail.source.setActive(false);
    const int parked = RtspVideoSource::parkedPipelineCount();
    Probe wallBlue;
    wallBlue.begin("blue");
    wallBlue.source.setUrl(base + "/blue");
    wallBlue.source.setVideoSink(&wallBlue.sink);
    const bool adoptedImmediately = wallBlue.source.playing();
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

    const QJsonObject report{{"passed", int(results.size()) - failures}, {"failed", failures},
                             {"tests", results}, {"boundary", "RtspVideoSource public API plus decoded QVideoSink pixels; no product QML navigation"}};
    printf("%s\n", QJsonDocument(report).toJson(QJsonDocument::Indented).constData());
    return failures ? 1 : 0;
}
