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
#include <QJsonArray>
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

    // ---- cilex-vision's own answer, as they built it (2c9da8e / 9876f16) ------------------------
    // The shape is copied from their code (routers/labs.py:3255-3345, the stats route at
    // :3363). The 24 h and "all" figures are theirs: reply §3 (measured against the pilot
    // database at 14:29Z on 2026-09-28) and §2's per-analyser row counts
    // (docs/letters/2026-09-28-labs-statistics-by-period.reply-cilex-vision.md); "all"
    // waiting is camera_hours - checked, by their invariant. NOT theirs: every 7 d figure
    // (the reply gives none; copied from a neighbouring period to fill the shape) and
    // segments_scanned (not in the reply; their code always emits an integer there).
    const QJsonObject cv = obj(R"({
      "generated_at": "2026-09-28T14:29:05.123+00:00", "computed_at": "2026-09-28T14:29:00.000+00:00",
      "windows": {"24h": {"from": "2026-09-27T14:29:00.000+00:00", "to": "2026-09-28T14:29:00.000+00:00"},
                  "7d":  {"from": "2026-09-21T14:29:00.000+00:00", "to": "2026-09-28T14:29:00.000+00:00"},
                  "all": {"from": "2026-09-17T12:00:00.000+00:00", "to": "2026-09-28T14:29:00.000+00:00"}},
      "analyzers": [
        {"analyzer": "frame_difference", "enabled": true, "windows": {
          "24h": {"camera_hours": 1283, "checked": 11, "in_progress": 0, "waiting": 1272, "given_up": 0,
                  "segments_scanned": 0, "records": 11, "findings": 0},
          "7d":  {"camera_hours": 1283, "checked": 11, "in_progress": 0, "waiting": 1272, "given_up": 0,
                  "segments_scanned": 0, "records": 11, "findings": 0},
          "all": {"camera_hours": 14393, "checked": 12, "in_progress": 0, "waiting": 14381, "given_up": 0,
                  "segments_scanned": 0, "records": 12, "findings": 1, "checked_ever": 12}}},
        {"analyzer": "illumination", "enabled": true, "windows": {
          "24h": {"camera_hours": 2055, "checked": 11, "in_progress": 0, "waiting": 2044, "given_up": 0,
                  "segments_scanned": 0, "records": 22, "findings": 0},
          "7d":  {"camera_hours": 2055, "checked": 11, "in_progress": 0, "waiting": 2044, "given_up": 0,
                  "segments_scanned": 0, "records": 22, "findings": 0},
          "all": {"camera_hours": 24073, "checked": 12, "in_progress": 0, "waiting": 24061, "given_up": 0,
                  "segments_scanned": 0, "records": 26, "findings": 0, "checked_ever": 12}}},
        {"analyzer": "blob_geometry", "enabled": false, "windows": {
          "24h": {"camera_hours": null, "waiting": null, "checked": 21, "in_progress": 0, "given_up": 0,
                  "segments_scanned": 0, "records": 599, "findings": 576},
          "7d":  {"camera_hours": null, "waiting": null, "checked": 22, "in_progress": 0, "given_up": 0,
                  "segments_scanned": 0, "records": 911, "findings": 888},
          "all": {"camera_hours": null, "waiting": null, "checked": 22, "in_progress": 0, "given_up": 0,
                  "segments_scanned": 0, "records": 911, "findings": 888, "checked_ever": 22}}},
        {"analyzer": "image_embedding", "enabled": false, "windows": {
          "24h": {"camera_hours": null, "waiting": null, "checked": 0, "in_progress": 0, "given_up": 0,
                  "segments_scanned": 0, "records": 0, "findings": null},
          "7d":  {"camera_hours": null, "waiting": null, "checked": 0, "in_progress": 0, "given_up": 0,
                  "segments_scanned": 0, "records": 0, "findings": null},
          "all": {"camera_hours": null, "waiting": null, "checked": 0, "in_progress": 0, "given_up": 0,
                  "segments_scanned": 0, "records": 0, "findings": null, "checked_ever": 0}}}
      ]})");
    const QVariantMap c = wtlabs::parseStats(cv);
    ok(c.value("windows").toMap().keys() == QStringList({"24h", "7d", "all"}),
       "cilex-vision's answer (2c9da8e): all three periods are read");
    bool adds = true;
    for (const QString &p : wtlabs::statsWindows())
        for (const char *slug : {"frame_difference", "illumination"}) {
            const QVariantMap r = rowOf(c, p, slug);
            adds = adds && r.value("checked").toDouble() + r.value("inProgress").toDouble() + r.value("waiting").toDouble()
                               + r.value("givenUp").toDouble() == r.value("cameraHours").toDouble();
        }
    ok(adds, "their figures read back so the bar adds up for both enabled analysers in every period, as they measured");
    const QVariantMap fdc = rowOf(c, "24h", "frame_difference"), blc = rowOf(c, "24h", "blob_geometry");
    ok(fdc.value("cameraHours").toDouble() == 1283 && fdc.value("waiting").toDouble() == 1272
       && !absent(fdc.value("findings")) && fdc.value("findings").toDouble() == 0 && fdc.value("records").toDouble() == 11,
       "frame_difference, 24 h: 1,283 camera-hours, 1,272 waiting, 0 findings in 11 records -- their §3");
    ok(absent(blc.value("cameraHours")) && absent(blc.value("waiting"))
       && blc.value("findings").toDouble() == 576 && blc.value("records").toDouble() == 599,
       "switched off (blob_geometry): no bar total or waiting, but its 576 findings in 599 records are kept");
    ok(absent(rowOf(c, "all", "image_embedding").value("findings")),
       "an analyser with no finding rule (image_embedding) has findings ABSENT, not 0");
    ok(rowOf(c, "all", "blob_geometry").value("checkedEver").toDouble() == 22,
       "'checked ever' comes through in 'all'");
    ok(!wtlabs::barWidthsVariant({fdc.value("checked"), fdc.value("inProgress"), fdc.value("waiting"), fdc.value("givenUp")}, 1000, 3).isEmpty()
       && wtlabs::barWidthsVariant({blc.value("checked"), blc.value("inProgress"), blc.value("waiting"), blc.value("givenUp")}, 1000, 3).isEmpty(),
       "an enabled analyser gets a bar; a switched-off one (waiting not counted) gets none");

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

    // ---- BY CAMERA (operator request 2026-09-30): records per camera, split by analyser --------
    const QJsonObject perCam = obj(R"({
      "generated_at": "2026-09-30T10:00:00.000Z", "computed_at": "2026-09-30T09:58:00.000Z",
      "windows": {"24h": {"from": "2026-09-29T10:00:00Z", "to": "2026-09-30T10:00:00Z"}},
      "analyzers": [
        {"analyzer": "track_linking", "enabled": true, "windows": {
          "24h": {"camera_hours": 900, "checked": 40, "in_progress": 0, "waiting": 860, "given_up": 0,
                  "findings": 30, "records": 700, "records_by_camera": {"cam-b": 500, "cam-a": 200}}}},
        {"analyzer": "blob_geometry", "enabled": true, "windows": {
          "24h": {"camera_hours": 900, "checked": 40, "in_progress": 0, "waiting": 860, "given_up": 0,
                  "findings": 5, "records": 250, "records_by_camera": {"cam-a": 100, "cam-c": 150}}}},
        {"analyzer": "illumination", "enabled": false, "windows": {
          "24h": {"camera_hours": null, "checked": 0, "in_progress": 0, "waiting": null, "given_up": 0,
                  "findings": null, "records": 0, "records_by_camera": {}}}}
      ]})");
    const QVariantMap pc = wtlabs::parseStats(perCam).value(QStringLiteral("windows")).toMap()
                               .value(QStringLiteral("24h")).toMap();
    const QVariantList cams = pc.value(QStringLiteral("cameras")).toList();
    auto camAt = [&](int i) { return cams.value(i).toMap(); };
    auto partsOf = [&](int i) {
        QStringList out;
        for (const QVariant &v : camAt(i).value(QStringLiteral("parts")).toList())
            out << QStringLiteral("%1=%2").arg(v.toMap().value(QStringLiteral("slug")).toString())
                                            .arg(v.toMap().value(QStringLiteral("records")).toDouble());
        return out.join(QLatin1Char(','));
    };
    ok(pc.value(QStringLiteral("byCamera")).toBool() && pc.value(QStringLiteral("camerasAddUp")).toBool(),
       "by camera: counted when EVERY analyser carries records_by_camera -- an empty one included -- and each adds up to its records");
    ok(cams.size() == 3 && camAt(0).value(QStringLiteral("cameraId")).toString() == "cam-b"
           && camAt(1).value(QStringLiteral("cameraId")).toString() == "cam-a"
           && camAt(2).value(QStringLiteral("cameraId")).toString() == "cam-c",
       QStringLiteral("by camera: busiest first (cam-b 500, cam-a 300, cam-c 150), only cameras with records (%1 cameras)").arg(cams.size()));
    ok(near(camAt(1).value(QStringLiteral("records")).toDouble(), 300)
           && partsOf(1) == "track_linking=200,blob_geometry=100,illumination=0",
       QStringLiteral("by camera: a camera's total is the sum of its analysers, and its parts list EVERY analyser in the window's order, zeros included, so each colour sits in one place (%1)").arg(partsOf(1)));
    ok(partsOf(2) == "track_linking=0,blob_geometry=150,illumination=0",
       QStringLiteral("by camera: an analyser that filed nothing for a camera is a zero part, not a missing one (%1)").arg(partsOf(2)));

    QJsonObject oneMissing = perCam;
    {
        QJsonArray an = oneMissing.value(QStringLiteral("analyzers")).toArray();
        QJsonObject a1 = an[1].toObject();
        QJsonObject w1 = a1.value(QStringLiteral("windows")).toObject();
        QJsonObject d1 = w1.value(QStringLiteral("24h")).toObject();
        d1.remove(QStringLiteral("records_by_camera"));
        w1[QStringLiteral("24h")] = d1; a1[QStringLiteral("windows")] = w1; an[1] = a1;
        oneMissing[QStringLiteral("analyzers")] = an;
    }
    const QVariantMap pm = wtlabs::parseStats(oneMissing).value(QStringLiteral("windows")).toMap()
                               .value(QStringLiteral("24h")).toMap();
    ok(!pm.value(QStringLiteral("byCamera")).toBool() && !pm.contains(QStringLiteral("cameras")),
       "by camera: ONE analyser not counted by camera means the window is not -- a total from the others alone would read as all of them");
    ok(pm.value(QStringLiteral("rows")).toList().size() == 3,
       "...and the by-analyser rows of that window are untouched");

    const QJsonObject badCount = obj(R"({"windows": {"24h": {}}, "analyzers": [
        {"analyzer": "track_linking", "enabled": true, "windows": {"24h": {"records": 5,
         "records_by_camera": {"cam-a": 3, "cam-b": "2"}}}}]})");
    ok(!wtlabs::parseStats(badCount).value(QStringLiteral("windows")).toMap().value(QStringLiteral("24h")).toMap()
            .value(QStringLiteral("byCamera")).toBool(),
       "by camera: a count that is not a number makes that analyser NOT COUNTED -- never a camera quietly dropped");

    const QJsonObject noAddUp = obj(R"({"windows": {"24h": {}}, "analyzers": [
        {"analyzer": "track_linking", "enabled": true, "windows": {"24h": {"records": 9,
         "records_by_camera": {"cam-a": 3, "cam-b": 2}}}}]})");
    const QVariantMap pn = wtlabs::parseStats(noAddUp).value(QStringLiteral("windows")).toMap().value(QStringLiteral("24h")).toMap();
    ok(pn.value(QStringLiteral("byCamera")).toBool() && !pn.value(QStringLiteral("camerasAddUp")).toBool(),
       "by camera: cameras that do not add up to the analyser's records are shown, and flagged (the screen says so)");

    const QJsonObject ties = obj(R"({"windows": {"24h": {}}, "analyzers": [
        {"analyzer": "track_linking", "enabled": true, "windows": {"24h": {"records": 12,
         "records_by_camera": {"cam-z": 4, "cam-a": 4, "cam-m": 4}}}}]})");
    const QVariantList tc = wtlabs::parseStats(ties).value(QStringLiteral("windows")).toMap().value(QStringLiteral("24h")).toMap()
                                .value(QStringLiteral("cameras")).toList();
    ok(tc.size() == 3 && tc[0].toMap().value(QStringLiteral("cameraId")) == "cam-a" && tc[2].toMap().value(QStringLiteral("cameraId")) == "cam-z",
       "by camera: equal counts keep one order (by camera id), so rows do not swap between refreshes");

    const QVariantMap viaPipe = wtlabs::statsFromPipeline({}, obj(R"({"generated_at": "2026-09-30T10:00:00Z"})"),
                                                          QDateTime::currentDateTimeUtc());
    ok(!viaPipe.value(QStringLiteral("windows")).toMap().value(QStringLiteral("all")).toMap()
            .value(QStringLiteral("byCamera"), true).toBool(),
       "by camera: never from /labs/pipeline, which counts nothing by camera");

    // ---- the screen: Statistics first, "Analyser Settings", and BY CAMERA | BY ANALYSER ------
    QFile q2("qml/LabsScreen.qml");
    if (!q2.open(QIODevice::ReadOnly)) {
        std::printf("SKIP LabsScreen.qml tabs -- run from the repo root\n");
    } else {
        const QString src = QString::fromUtf8(q2.readAll());
        const auto tabs = QRegularExpression(QStringLiteral(
            "qsTr\\(\"Statistics\"\\), v: \"stats\" \\}, \\{ k: qsTr\\(\"Analyser Settings\"\\), v: \"table\""));
        ok(tabs.match(src).hasMatch(), "the operator's tab order: Statistics first, then Analyser Settings (2026-09-30)");
        ok(src.contains(QStringLiteral("property string view: \"stats\"")), "...and the screen opens on Statistics, the first tab");
        QStringList by;
        for (const auto &m : QRegularExpression(QStringLiteral("v: \"(camera|analyser)\"")).globalMatch(src))
            by << m.captured(1);
        ok(by == QStringList({QStringLiteral("camera"), QStringLiteral("analyser")}),
           QStringLiteral("the grouping switch offers BY CAMERA then BY ANALYSER, the operator's order (%1)").arg(by.join(",")));
    }

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
