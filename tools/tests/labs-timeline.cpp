// Tests for what the Playback timeline's Labs lane SHOWS (src/models/LabsTimelineData.h):
// no network, no painting. Parsing the server's rows, finding the one under the pointer,
// merging a day of them into paintable runs, the request each row makes -- and that the
// QML side labels the rows in the same order the C++ side paints them.
//
// Build + run from the repo root (Qt 6.12):
//   QT=~/Qt/6.12.0/gcc_64
//   g++ -std=c++17 -fPIC -o /tmp/labstl tools/tests/labs-timeline.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -L$QT/lib -lQt6Core && LD_LIBRARY_PATH=$QT/lib /tmp/labstl
#include "LabsTimelineData.h"
#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSet>
#include <cstdio>

static int fails = 0;
static void ok(bool cond, const QString &what)
{
    if (!cond) ++fails;
    std::printf("%s %s\n", cond ? "PASS" : "FAIL", what.toUtf8().constData());
    std::fflush(stdout);
}

static QJsonArray arr(const char *json) { return QJsonDocument::fromJson(QByteArray(json)).array(); }
static qint64 ms(const char *iso) { return QDateTime::fromString(QString::fromLatin1(iso), Qt::ISODateWithMs).toMSecsSinceEpoch(); }

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    // ---- the rows the lane has, and their order ------------------------------------------
    const QStringList want = {"audio_energy", "blob_geometry", "camera_health", "colour_histogram",
                              "foreground_mask", "frame_difference", "illumination", "optical_flow",
                              "perceptual_hash", "track_linking"};
    ok(wtlabs::laneKeys() == want, "the lane has a row for each of the operator's ten analysers, in that order");
    QFile q("qml/LabsNames.qml");
    if (!q.open(QIODevice::ReadOnly)) {
        std::printf("SKIP LabsNames.qml order -- run from the repo root\n");
    } else {
        const QString src = QString::fromUtf8(q.readAll());
        const auto m = QRegularExpression(QStringLiteral("readonly property var keys:\\s*\\[([^\\]]*)\\]")).match(src);
        QStringList qmlKeys;
        for (const auto &k : QRegularExpression(QStringLiteral("\"([a-z_]+)\"")).globalMatch(m.captured(1)))
            qmlKeys << k.captured(1);
        ok(m.hasMatch() && qmlKeys == wtlabs::laneKeys(),
           "LabsNames.keys (the labels) is the SAME order as laneKeys() (the painted rows): " + qmlKeys.join(","));
    }

    // ---- parsing the server's rows --------------------------------------------------------
    int dropped = -1;
    const auto v = wtlabs::parseObservations(arr(R"([
        {"observation_id": "b", "start_time": "2026-09-26T22:30:25.000+00:00", "end_time": "2026-09-26T22:30:35.000+00:00", "analyzer": "optical_flow"},
        {"observation_id": "a", "start_time": "2026-09-26T22:00:25Z", "end_time": "2026-09-26T22:00:25Z", "analyzer": "blob_geometry"},
        {"observation_id": "",  "start_time": "2026-09-26T22:10:00Z", "end_time": "2026-09-26T22:10:00Z"},
        {"observation_id": "x", "start_time": "not a time", "end_time": "2026-09-26T22:10:00Z"},
        {"observation_id": "c", "start_time": "2026-09-26T22:40:00.500+03:00", "end_time": "2026-09-26T22:39:00+03:00"}
    ])"), &dropped);
    ok(v.size() == 3 && dropped == 2, QStringLiteral("rows with no id or no start are DROPPED and counted (kept %1, dropped %2)")
                                          .arg(v.size()).arg(dropped));
    ok(v.size() == 3 && v[0].id == "c" && v[1].id == "a" && v[2].id == "b", "rows come back sorted by start, whatever the server's order");
    ok(v.size() == 3 && v[1].startMs == ms("2026-09-26T22:00:25Z") && v[2].endMs - v[2].startMs == 10000,
       "Z and +00:00 both parse, to the millisecond");
    ok(v.size() == 3 && v[0].startMs == ms("2026-09-26T19:40:00.500Z"), "a +03:00 offset is honoured");
    ok(v.size() == 3 && v[0].endMs == v[0].startMs, "an end before the start becomes a point, never a negative span");
    ok(v.size() == 3 && v[2].row.value("analyzer").toString() == "optical_flow", "the whole server row is kept for the card");

    // ---- which one is under the pointer ----------------------------------------------------
    QVector<wtlabs::Obs> h;
    auto add = [&h](const char *id, qint64 s, qint64 e) { wtlabs::Obs o; o.id = id; o.startMs = s; o.endMs = e; h << o; };
    add("long", 0, 100000);        // a 100 s span
    add("pt", 50000, 50000);       // a point inside it
    add("late", 200000, 200000);
    ok(wtlabs::hitTest(h, 20000, 500) == 0, "inside a span: that span");
    ok(wtlabs::hitTest(h, 50100, 500, 200) == 1,
       "a point drawn INSIDE a long span: the point (the smallest wins, or it could never be reached)");
    ok(wtlabs::hitTest(h, 50100, 500, 0) == 0,
       "...measured against what is drawn: with no minimum width the point is not under the pointer");
    ok(wtlabs::hitTest(h, 200400, 500) == 2, "within tolerance of a point: the point");
    ok(wtlabs::hitTest(h, 150000, 500) == -1, "between them, beyond tolerance: nothing");
    ok(wtlabs::hitTest(h, 99000, 500) == 0, "late in a LONG earlier span: still found (no early exit on start alone)");
    ok(wtlabs::hitTest({}, 1, 1) == -1, "no rows: nothing");

    // ---- a day of them, as paintable runs --------------------------------------------------
    QVector<wtlabs::Obs> day;
    for (int i = 0; i < 5000; ++i) {             // 5,000 point observations, one every ~17 s
        wtlabs::Obs o; o.id = QString::number(i); o.startMs = o.endMs = qint64(i) * 17280; day << o;
    }
    const auto r = wtlabs::runs(day, 0, 86400000.0, 1000.0);
    int covered = 0;
    for (const auto &x : r) covered += x.count;
    ok(r.size() <= 1000 && covered == 5000,
       QStringLiteral("5,000 observations over 24 h at 1,000 px paint as %1 runs, and every one is counted").arg(r.size()));
    const auto one = wtlabs::runs({h[2]}, 0, 86400000.0, 1000.0);
    ok(one.size() == 1 && one[0].x1 - one[0].x0 >= 2.0, "a lone 1-point observation in a 24 h view is still 2 px wide");
    const auto clip = wtlabs::runs(h, 60000, 160000, 100.0);
    ok(clip.size() == 1 && clip[0].x0 == 0.0, "a span that began before the window is clipped to its left edge, not dropped");
    ok(wtlabs::runs(h, 10, 10, 100.0).isEmpty() && wtlabs::runs(h, 0, 10, 0).isEmpty(), "an empty window or width paints nothing");

    // ---- the request ------------------------------------------------------------------------
    const QUrl u = wtlabs::observationsUrl("http://127.0.0.1:8000", "hiwatch-083bc1df39d1",
                                           ms("2026-09-26T22:00:00Z"), ms("2026-09-26T23:00:00Z"), "track_linking", "ru");
    const QUrlQuery uq(u);
    ok(u.path() == "/labs/observations" && uq.queryItemValue("camera_id") == "hiwatch-083bc1df39d1"
       && uq.queryItemValue("analyzer") == "track_linking" && uq.queryItemValue("lang") == "ru"
       && uq.queryItemValue("limit") == "2000",
       "one analyser per request, the UI language, the endpoint's own ceiling: " + u.toString());
    ok(uq.queryItemValue("start") == "2026-09-26T22:00:00.000Z" && uq.queryItemValue("end") == "2026-09-26T23:00:00.000Z",
       "the window goes out in UTC, to the millisecond");
    ok(QUrlQuery(wtlabs::observationsUrl("h", "c", 0, 1, "a", "de")).queryItemValue("lang") == "en"
       && QUrlQuery(wtlabs::observationsUrl("h", "c", 0, 1, "a", "en", 99999)).queryItemValue("limit") == "2000"
       && QUrlQuery(wtlabs::observationsUrl("h", "c", 0, 1, "a", "en", 50)).queryItemValue("limit") == "50",
       "a language the server does not render falls back to en; the limit never exceeds the ceiling");

    std::printf("%s\n", fails ? QStringLiteral("%1 FAILED").arg(fails).toUtf8().constData() : "all passed");
    return fails ? 1 : 0;
}
