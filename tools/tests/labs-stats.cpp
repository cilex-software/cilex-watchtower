// Tests for the Labs screen's STATISTICS view (src/models/LabsStatsData.h): no network, no
// painting. Reading GET /labs/stats, reading the "all" period from /labs/pipeline while the
// server has no /labs/stats, which leases are live, the stacked bar's widths -- and that the
// screen offers exactly the periods the data has.
//
// Build + run from the repo root (Qt 6.12):
//   QT=~/Qt/6.12.0/gcc_64
//   g++ -std=c++17 -fPIC -o /tmp/labsstats tools/tests/labs-stats.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -L$QT/lib -lQt6Core && LD_LIBRARY_PATH=$QT/lib /tmp/labsstats
#include "LabsStatsData.h"
#include "LabsStation.h"
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
static bool absent(const QVariant &v) { return !v.isValid() || v.isNull(); }
static QVariantMap rowOf(const QVariantMap &stats, const QString &window, const QString &slug)
{
    const QVariantList rows = stats.value(QStringLiteral("windows")).toMap().value(window).toMap()
                                   .value(QStringLiteral("rows")).toList();
    for (const QVariant &r : rows)
        if (r.toMap().value(QStringLiteral("slug")).toString() == slug)
            return r.toMap();
    return {};
}
static bool near(double a, double b) { return std::fabs(a - b) < 1e-9; }

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    // ---- GET /labs/stats ------------------------------------------------------------------
    const QJsonObject answer = obj(R"({
      "generated_at": "2026-09-28T13:40:00.000Z", "computed_at": "2026-09-28T13:39:12.000Z",
      "windows": {"24h": {"from": "2026-09-27T13:40:00Z", "to": "2026-09-28T13:40:00Z"},
                  "7d":  {"from": "2026-09-21T13:40:00Z", "to": "2026-09-28T13:40:00Z"},
                  "all": {"from": "2026-08-20T00:00:00Z", "to": "2026-09-28T13:40:00Z"}},
      "analyzers": [
        {"analyzer": "frame_difference", "enabled": true, "windows": {
          "24h": {"camera_hours": 3109, "checked": 9, "in_progress": 1, "waiting": 3097, "given_up": 2,
                  "findings": 0, "records": 9, "segments_scanned": 36},
          "7d":  {"camera_hours": 21000, "checked": 12, "in_progress": 1, "waiting": 20985, "given_up": 2,
                  "findings": 4, "records": 12},
          "all": {"camera_hours": 90000, "checked": 12, "in_progress": 1, "waiting": 89985, "given_up": 2,
                  "findings": 4, "records": 12, "checked_ever": 15}}},
        {"analyzer": "audio_energy", "enabled": false, "windows": {
          "24h": {"camera_hours": null, "checked": 20, "in_progress": 0, "waiting": null, "given_up": 0,
                  "findings": null, "records": 20},
          "7d": "not an object"}}
      ]})");
    const QVariantMap s = wtlabs::parseStats(answer);
    const QVariantMap fd24 = rowOf(s, "24h", "frame_difference");
    ok(s.value("source").toString() == "server" && s.value("computedAt").toString() == "2026-09-28T13:39:12.000Z",
       "the server's answer is marked as the server's, with WHEN its counts were made");
    ok(fd24.value("checked").toDouble() == 9 && fd24.value("inProgress").toDouble() == 1
       && fd24.value("waiting").toDouble() == 3097 && fd24.value("givenUp").toDouble() == 2
       && fd24.value("cameraHours").toDouble() == 3109 && fd24.value("segmentsScanned").toDouble() == 36,
       "every count of a period is read as the server gave it");
    ok(!absent(fd24.value("findings")) && fd24.value("findings").toDouble() == 0,
       "0 findings is a count -- looked, found nothing -- and stays 0");
    const QVariantMap ae24 = rowOf(s, "24h", "audio_energy");
    ok(absent(ae24.value("findings")) && absent(ae24.value("waiting")) && absent(ae24.value("cameraHours")),
       "a null count stays ABSENT, never 0 (findings the server has no rule for; waiting while switched off)");
    ok(ae24.value("enabled").toBool() == false && ae24.value("checked").toDouble() == 20,
       "a switched-off analyser keeps what it checked while it was on");
    ok(rowOf(s, "7d", "audio_energy").isEmpty() && !rowOf(s, "7d", "frame_difference").isEmpty(),
       "an analyser whose period is malformed is left out of that period, not filled in");
    ok(rowOf(s, "all", "frame_difference").value("checkedEver").toDouble() == 15
       && absent(fd24.value("checkedEver")),
       "'checked ever' (footage since deleted included) is read in 'all' only");
    const QVariantMap onlyAll = wtlabs::parseStats(obj(R"({"analyzers": [
        {"analyzer": "illumination", "enabled": true, "windows": {"all": {"checked": 3}}}]})"));
    ok(onlyAll.value("windows").toMap().keys() == QStringList{"all"},
       "a period the server did not count is MISSING -- never filled from another period");
    ok(wtlabs::parseStats(obj(R"({"generated_at": "x"})")).value("windows").toMap().isEmpty(),
       "an answer with no analysers has no periods at all");

    // ---- live leases -------------------------------------------------------------------------
    const QJsonObject pipeline = obj(R"({
      "generated_at": "2026-09-28T13:40:00.000Z", "queue_computed_at": "2026-09-28T13:38:30.000Z",
      "analyzers": [
        {"analyzer": "frame_difference", "title": "fd", "enabled": true, "queue_remaining": 13932,
         "done": 12, "claimed": 2, "failed": 1, "observations": 12},
        {"analyzer": "audio_energy", "title": "ae", "enabled": false, "queue_remaining": null,
         "done": 28, "claimed": 3, "failed": 3, "observations": 28}],
      "in_flight": [
        {"analyzer": "frame_difference", "lease_expires_at": "2026-09-28T13:55:00.000Z"},
        {"analyzer": "frame_difference", "lease_expires_at": "2026-09-28T07:32:25.000Z"},
        {"analyzer": "audio_energy", "lease_expires_at": "2026-09-28T07:25:25.000Z"},
        {"analyzer": "audio_energy", "lease_expires_at": "not a time"}]})");
    const QDateTime now = QDateTime::fromString("2026-09-28T13:40:00.000Z", Qt::ISODateWithMs);
    const auto live = wtlabs::liveLeases(pipeline, now);
    ok(live.value("frame_difference") == 1 && live.value("audio_energy") == 0,
       "only leases still live count as in progress -- not the ones 8 h past expiry, nor an unreadable time");

    // ---- "all", from the pipeline, before /labs/stats exists --------------------------------
    const QVariantMap f = wtlabs::statsFromPipeline(wtlabs::mergePipeline(pipeline), pipeline, now);
    ok(f.value("source").toString() == "pipeline"
       && f.value("windows").toMap().keys() == QStringList{"all"},
       "from the pipeline there is 'all' and nothing else: the periods wait for the server");
    const QVariantMap fdA = rowOf(f, "all", "frame_difference");
    ok(fdA.value("checked").toDouble() == 12 && fdA.value("waiting").toDouble() == 13932
       && fdA.value("inProgress").toDouble() == 1 && fdA.value("failed").toDouble() == 1,
       "checked = done, waiting = the queue, in progress = LIVE leases (1, not the 2 claimed)");
    ok(absent(fdA.value("findings")) && absent(fdA.value("givenUp")) && absent(fdA.value("cameraHours")),
       "findings, given up and the period's total are unknown there -- absent, not 0");
    ok(absent(rowOf(f, "all", "audio_energy").value("waiting")),
       "a switched-off analyser's waiting stays unknown (the server counts a queue only while on)");
    ok(f.value("computedAt").toString() == "2026-09-28T13:38:30.000Z",
       "the time shown is the queue's own (it is cached), not the page's");

    // ---- the stacked bar ----------------------------------------------------------------------
    auto w = wtlabs::barWidths({9, 0, 3100, 0}, 400, 3);
    ok(w.size() == 4 && near(w[0], 3) && near(w[1], 0) && near(w[3], 0) && near(w[0] + w[2], 400),
       "9 checked beside 3,100 waiting stays visible (3 px); zeros draw nothing; the bar is exactly its width");
    w = wtlabs::barWidths({1, 1, 1, 1}, 400, 3);
    ok(near(w[0], 100) && near(w[1], 100) && near(w[2], 100) && near(w[3], 100), "equal parts, equal widths");
    w = wtlabs::barWidths({5000, 1, 1, 1}, 400, 3);
    ok(near(w[1], 3) && near(w[2], 3) && near(w[3], 3) && near(w[0], 391), "three slivers at the floor, the rest to the big one");
    ok(wtlabs::barWidths({0, 0, 0}, 400, 3).isEmpty(), "nothing at all to show: no bar, not an empty-looking one");
    ok(wtlabs::barWidths({1, -1}, 400, 3).isEmpty() && wtlabs::barWidths({1, std::nan("")}, 400, 3).isEmpty(),
       "a negative or NaN count draws no bar");
    w = wtlabs::barWidths({1, 1, 1}, 6, 3);
    ok(near(w[0], 2) && near(w[1], 2) && near(w[2], 2), "too narrow to honour the floor: shared equally, still its width");
    // Every case: zeros are 0, the others at least the floor, and the widths add up.
    unsigned seed = 12345;
    auto rnd = [&seed]() { seed = seed * 1103515245u + 12345u; return (seed >> 8) % 100000; };
    int bad = 0;
    for (int n = 0; n < 2000; ++n) {
        QVector<double> v;
        const int k = 2 + int(rnd() % 3);
        for (int i = 0; i < k; ++i) { const auto r = rnd(); v.append(r % 4 == 0 ? 0.0 : double(r % 5 == 0 ? r : r % 50)); }
        const double width = 50 + rnd() % 900;
        const auto ww = wtlabs::barWidths(v, width, 3);
        double sum = 0;
        bool any = false;
        for (double x : v) any = any || x > 0;
        if (!any) { if (!ww.isEmpty()) ++bad; continue; }
        for (int i = 0; i < v.size(); ++i) {
            sum += ww[i];
            if (v[i] == 0 && ww[i] != 0) ++bad;
            if (v[i] > 0 && ww[i] < 3 - 1e-9) ++bad;
        }
        if (std::fabs(sum - width) > 1e-6) ++bad;
    }
    ok(bad == 0, QStringLiteral("2,000 random bars: zeros 0, the rest >= the floor, widths sum to the bar (%1 violations)").arg(bad));

    const QVariantList wv = wtlabs::barWidthsVariant({QVariant(9.0), QVariant(), QVariant(3100.0)}, 400, 3);
    ok(wv.isEmpty(), "an ABSENT segment (not counted) draws no bar -- never a bar that reads it as 0");
    ok(wtlabs::barWidthsVariant({QVariant(9.0), QVariant(0.0), QVariant(3100.0)}, 400, 3).size() == 3,
       "a zero segment is a count, and the bar is drawn");

    // ---- the screen offers exactly the periods the data has -----------------------------------
    QFile q("qml/LabsScreen.qml");
    if (!q.open(QIODevice::ReadOnly)) {
        std::printf("SKIP LabsScreen.qml periods -- run from the repo root\n");
    } else {
        const QString src = QString::fromUtf8(q.readAll());
        QStringList offered;
        for (const auto &m : QRegularExpression(QStringLiteral("v: \"(24h|7d|all)\"")).globalMatch(src))
            offered << m.captured(1);
        ok(offered == wtlabs::statsWindows(), QStringLiteral("the period switch offers 24h, 7d, all -- in that order (%1)").arg(offered.join(",")));
    }

    std::printf("%s\n", fails ? QStringLiteral("%1 FAILED").arg(fails).toUtf8().constData() : "all passed");
    return fails ? 1 : 0;
}
