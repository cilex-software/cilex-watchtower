// Tests for the Labs FINDINGS list (src/models/LabsFindingsData.h): no network, no painting.
// The request each page makes, reading GET /labs/findings, and handing a finding to the
// Events player as if it were an event.
//
// Build + run from the repo root (Qt 6.12):
//   QT=~/Qt/6.12.0/gcc_64
//   g++ -std=c++17 -fPIC -o /tmp/labsfind tools/tests/labs-findings.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -L$QT/lib -lQt6Core && LD_LIBRARY_PATH=$QT/lib /tmp/labsfind
#include "LabsFindingsData.h"
#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <QRegularExpression>
#include <cmath>
#include <cstdio>

static int fails = 0;
static void ok(bool cond, const QString &what)
{
    if (!cond) ++fails;
    std::printf("%s %s\n", cond ? "PASS" : "FAIL", what.toUtf8().constData());
    std::fflush(stdout);
}
static QJsonObject obj(const char *json) { return QJsonDocument::fromJson(QByteArray(json)).object(); }
static QString q(const QUrl &u, const char *k) { return QUrlQuery(u).queryItemValue(QString::fromLatin1(k), QUrl::FullyDecoded); }

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    // ---- the request -------------------------------------------------------------------------
    QUrl u = wtlabs::findingsUrl("http://127.0.0.1:8000", "colour_histogram", "7d", "", "", 40, "ru");
    ok(u.path() == "/labs/findings" && q(u, "analyzer") == "colour_histogram" && q(u, "period") == "7d"
       && q(u, "limit") == "40" && q(u, "lang") == "ru",
       "a first page asks for the analyser, the period, a page's worth, in the UI language");
    ok(!QUrlQuery(u).hasQueryItem("facet") && !QUrlQuery(u).hasQueryItem("cursor"),
       "no filter and no cursor are LEFT OUT, never sent blank");
    u = wtlabs::findingsUrl("http://h", "optical_flow", "all", "left_to_right", "eyJ0IjoiMjAyNi0wOS0yOSJ9+/==", 40, "en");
    ok(q(u, "facet") == "left_to_right" && q(u, "cursor") == "eyJ0IjoiMjAyNi0wOS0yOSJ9+/==",
       "a further page carries the filter and the server's cursor back exactly, '+', '/' and '=' included");
    ok(u.toString(QUrl::FullyEncoded).contains("cursor=eyJ0IjoiMjAyNi0wOS0yOSJ9%2B%2F%3D%3D"),
       "...encoded so the server cannot read '+' as a space");
    ok(q(wtlabs::findingsUrl("http://h", "a", "yesterday", "", "", 40, "de"), "period") == "24h"
       && q(wtlabs::findingsUrl("http://h", "a", "yesterday", "", "", 40, "de"), "lang") == "en",
       "an unknown period or language falls back to 24 h / English, never passed through");
    ok(q(wtlabs::findingsUrl("http://h", "a", "24h", "", "", 5000, "en"), "limit") == "100"
       && q(wtlabs::findingsUrl("http://h", "a", "24h", "", "", 0, "en"), "limit") == "1",
       "a page is 1..100 rows, whatever is asked");

    // ---- the answer --------------------------------------------------------------------------
    const QJsonObject a = obj(R"({
      "generated_at": "2026-09-29T13:30:00.000+00:00", "analyzer": "colour_histogram", "period": "24h",
      "facet": null, "total": 218,
      "facets": [ {"id": "red", "label": "Red", "count": 12}, {"id": "blue", "label": "Blue", "count": null},
                  {"label": "no id"} , {"id": "grey"} ],
      "items": [
        {"observation_id": "o1", "camera_id": "hiwatch-a", "camera_name": "10 Улица 13",
         "start_time": "2026-09-29T09:10:00.000+00:00", "end_time": "2026-09-29T09:12:00.000+00:00",
         "analyzer": "colour_histogram", "text": "Red, 3% of the picture", "metrics": {"colour": "red"}},
        {"observation_id": "o2", "camera_id": "hiwatch-b",
         "start_time": "2026-09-29T09:05:00.000+00:00", "end_time": "2026-09-29T09:04:00.000+00:00",
         "analyzer": "colour_histogram", "metrics": {}},
        {"camera_id": "hiwatch-c", "start_time": "2026-09-29T09:00:00.000+00:00"},
        {"observation_id": "o4", "camera_id": "hiwatch-d", "start_time": "yesterday"}
      ],
      "next_cursor": "c2"})");
    const wtlabs::FindingsPage p = wtlabs::parseFindings(a);
    ok(p.items.size() == 2 && p.dropped == 2,
       "rows without an id or a readable start are DROPPED and COUNTED (2), never shown half-made");
    ok(p.items[0].toMap().value("observation_id").toString() == "o1"
       && p.items[1].toMap().value("observation_id").toString() == "o2",
       "the server's order is kept (newest first): nothing is re-sorted here");
    const QVariantMap r1 = p.items[0].toMap(), r2 = p.items[1].toMap();
    ok(r1.value("endMs").toDouble() - r1.value("startMs").toDouble() == 120000.0
       && r1.value("text").toString() == "Red, 3% of the picture"
       && r1.value("metrics").toMap().value("colour").toString() == "red",
       "a row keeps everything the server sent (the card shows it), plus its start and end in ms");
    ok(r2.value("endMs").toDouble() == r2.value("startMs").toDouble(),
       "an end before the start is read as a point in time, never as a negative span");
    ok(p.total.toDouble() == 218 && p.nextCursor == "c2" && p.generatedAt == "2026-09-29T13:30:00.000+00:00",
       "the total, the next page's cursor and the answer's time are read");
    ok(p.facets.size() == 3,
       "a filter without an id is dropped (it could never be asked for); the others are kept, in order");
    const QVariantMap f1 = p.facets[0].toMap(), f2 = p.facets[1].toMap(), f3 = p.facets[2].toMap();
    ok(f1.value("label").toString() == "Red" && f1.value("count").toDouble() == 12
       && !f2.value("count").isValid() && f3.value("label").toString() == "grey",
       "a filter's count may be unknown (absent, not 0); a filter without a label is named by its id");
    const wtlabs::FindingsPage last = wtlabs::parseFindings(obj(R"({"items": [], "next_cursor": null, "total": null})"));
    ok(last.nextCursor.isEmpty() && !last.total.isValid() && last.items.isEmpty(),
       "the last page: no cursor (no more to ask), and an uncounted total stays unknown");

    // ---- a finding, played as an event ----------------------------------------------------------
    QVariantMap cam; cam["id"] = "hiwatch-a"; cam["name"] = "10 Улица 13"; cam["ip"] = "192.168.1.126";
    cam["preRollMs"] = 8000; cam["postRollMs"] = -1;
    const QVariantMap ev = wtlabs::findingAsEvent(r1, cam);
    ok(ev.value("id").toString() == "labs:o1" && ev.value("rawType").toString() == "labs:colour_histogram",
       "the event's id is the finding's, marked as Labs (never mistaken for a motion event's id)");
    ok(ev.value("durationSec").toDouble() == 120.0
       && ev.value("ts").toDateTime().toMSecsSinceEpoch() == qint64(r1.value("startMs").toDouble()),
       "it plays the finding's own window: from its start, for its length");
    ok(ev.value("cam").toMap().value("preRollMs").toInt() == 8000,
       "the camera's recording profile is used for the roll when the app knows the camera");
    const QVariantMap ev2 = wtlabs::findingAsEvent(r2, QVariantMap());
    const QVariantMap c2 = ev2.value("cam").toMap();
    ok(c2.value("id").toString() == "hiwatch-b" && c2.value("name").toString() == "hiwatch-b"
       && ev2.value("durationSec").toDouble() == 1.0,
       "a camera the app does not know still plays by id, named by its id (nothing invented); a point plays at least 1 s");
    const QVariantMap ev3 = wtlabs::findingAsEvent(r1, QVariantMap());
    ok(ev3.value("cam").toMap().value("name").toString() == "10 Улица 13",
       "...and by the server's camera_name when it sends one");

    // ---- a Paths row's path, decoded (cilex-vision's labs_track_linking.py encoding) --------------
    // Two real rows the operator opened on 2026-09-29, their `path` as stored (labs_observations,
    // be1d6721 and the 10 Улица 4 row of 14:58:42Z), with the entry and exit the same rows state:
    //   10 Улица 2 17:57:47, right to left: entry (0.9924, 0.5557), exit (0.0068, 0.6226)
    //   10 Улица 4 17:58:42, left to right: entry (0.006, 0.3243),  exit (0.9457, 0.7927)
    // Quantised to 64 levels, a decoded point is within half a level (1/128) of the measured one.
    auto near = [](const QVariant &p, double x, double y) {
        const QVariantMap m = p.toMap();
        return std::abs(m.value("x").toDouble() - x) <= 1.0 / 128 + 1e-9
            && std::abs(m.value("y").toDouble() - y) <= 1.0 / 128 + 1e-9;
    };
    const QVariantList w = wtlabs::decodePath("_j_g9g7i5j2jzjvjslnmkmfnamXmTmPkMlJlGlEkCkAjAnAn");
    ok(w.size() == 24 && near(w.first(), 0.9924, 0.5557) && near(w.last(), 0.0068, 0.6226),
       "a real path decodes to 24 points that start at the row's entry and end at its exit (right to left)");
    const QVariantList e = wtlabs::decodePath("AUAUAUAVAVAVAWBWBXCXCXDYEZGaIbKcNeRhXjfnosyx508y");
    ok(e.size() == 24 && near(e.first(), 0.006, 0.3243) && near(e.last(), 0.9457, 0.7927),
       "...and another, left to right");
    ok(wtlabs::decodePath("AUA").isEmpty() && wtlabs::decodePath("AU!U").isEmpty() && wtlabs::decodePath("").isEmpty(),
       "an odd length or a character outside the alphabet is not a path: nothing, never a guessed one");

    // ---- the screen offers exactly these periods ------------------------------------------------
    QFile f("qml/LabsFindings.qml");
    if (!f.open(QIODevice::ReadOnly)) {
        std::printf("SKIP LabsFindings.qml periods -- run from the repo root\n");
    } else {
        const QString src = QString::fromUtf8(f.readAll());
        QStringList offered;
        for (const auto &m : QRegularExpression(QStringLiteral("v: \"(24h|7d|all)\"")).globalMatch(src))
            offered << m.captured(1);
        ok(offered == wtlabs::findingsPeriods(), QStringLiteral("the period switch offers 24h, 7d, all (%1)").arg(offered.join(",")));
    }

    std::printf("%s\n", fails ? QStringLiteral("%1 FAILED").arg(fails).toUtf8().constData() : "all passed");
    return fails ? 1 : 0;
}
