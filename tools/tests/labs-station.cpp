// Tests for what the Labs screen SAYS (src/models/LabsStation.h): no network.
//
// Two halves, each where a mistake is silent:
//   * the station's local files, shared with tools/labs/station.py. The app and the
//     worker must agree on the directory and on every reading of control.json -- above
//     all that anything but an explicit `"paused": false` means PAUSED. So the
//     agreement is tested ACROSS languages: the app's writes read back through the
//     worker's own Python, and the worker's writes through the app's C++.
//   * the server's answer merged into rows: a cost nobody measured stays unknown,
//     never 0, and coverage exists only where the server gave a denominator.
//
// Build + run (Qt 6.12):
//   QT=~/Qt/6.12.0/gcc_64
//   g++ -std=c++17 -fPIC -o /tmp/labsst tools/tests/labs-station.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -L$QT/lib -lQt6Core && LD_LIBRARY_PATH=$QT/lib /tmp/labsst
#include "LabsStation.h"
#include <QCoreApplication>
#include <QDebug>
#include <QProcess>
#include <QTemporaryDir>

int fails = 0;
static void ok(bool cond, const QString &what)
{
    if (!cond) ++fails;
    qInfo().noquote() << (cond ? "PASS" : "FAIL") << what;
}

static void writeFile(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        qFatal("cannot write %s", qPrintable(path));
    f.write(bytes);
}

// Ask the WORKER's own code (station.py) what it reads, or make it write.
static QString py(const QString &code, const QString &stateHome)
{
    QProcess p;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("XDG_STATE_HOME"), stateHome);
    env.remove(QStringLiteral("LOCALAPPDATA"));
    p.setProcessEnvironment(env);
    p.start(QStringLiteral("python3"), {QStringLiteral("-c"),
            QStringLiteral("import sys; sys.path.insert(0, 'tools/labs'); import station as S\n") + code});
    p.waitForFinished(20000);
    return QString::fromUtf8(p.readAllStandardOutput()).trimmed();
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QTemporaryDir tmp;
    const QString home = tmp.path();

    // ---- where both sides look -----------------------------------------------------------
    qputenv("XDG_STATE_HOME", home.toUtf8());
    const QString dir = wtlabs::stateDir();
    ok(dir == QDir(home).filePath("watchtower-labs"), "stateDir honours XDG_STATE_HOME: " + dir);
    const bool havePy = !py("print('ok')", home).isEmpty();
    if (havePy)
        ok(py("print(S.state_dir())", home) == dir, "the worker's station.state_dir() is the SAME directory");
    else
        qInfo() << "SKIP cross-language checks -- no python3 here";
    qunsetenv("XDG_STATE_HOME");
    ok(wtlabs::stateDir() == QDir::homePath() + "/.local/state/watchtower-labs",
       "stateDir defaults to ~/.local/state/watchtower-labs");
    QDir().mkpath(dir);

    // ---- control.json: default-deny, exactly as the worker reads it ---------------------
    const QString ctl = QDir(dir).filePath("control.json");
    auto c = wtlabs::readControl(dir);
    ok(c.paused && c.why == "absent", "NO control file means paused (\"absent\")");
    writeFile(ctl, "{not json");
    c = wtlabs::readControl(dir);
    ok(c.paused && c.why == "unreadable", "an UNREADABLE control file means paused");
    writeFile(ctl, R"({"paused": "no"})");
    c = wtlabs::readControl(dir);
    ok(c.paused && c.why == "no_flag", "anything but a boolean `paused` means paused");
    writeFile(ctl, R"({"paused": false, "camera_health": true})");
    c = wtlabs::readControl(dir);
    ok(!c.paused && c.cameraHealth && c.why.isEmpty(), "an explicit `paused: false` is honoured, with camera_health");

    // ---- writeControl: keeps the rest, whole document only -------------------------------
    QString err;
    ok(wtlabs::writeControl(dir, true, "test", &err), "writeControl succeeds: " + err);
    c = wtlabs::readControl(dir);
    ok(c.paused && c.cameraHealth, "pausing KEEPS the station's camera_health opt-in");
    const QStringList left = QDir(dir).entryList(QDir::Files | QDir::Hidden);
    ok(left == QStringList{"control.json"}, "no temporary file is left behind: " + left.join(","));

    // ---- across languages ---------------------------------------------------------------
    if (havePy) {
        wtlabs::writeControl(dir, false, "app");
        ok(py("print(S.read_control()['paused'])", home) == "False", "the WORKER reads the app's Resume as running");
        wtlabs::writeControl(dir, true, "app");
        ok(py("print(S.read_control()['paused'])", home) == "True", "...and the app's Pause as paused");
        ok(py("print(S.read_control()['camera_health'])", home) == "True", "...and keeps its camera_health opt-in");
        py("S.write_control(False, by='cli')", home);
        c = wtlabs::readControl(dir);
        ok(!c.paused && c.cameraHealth, "the APP reads the CLI's --resume as running, opt-in intact");
        QFile::remove(ctl);
        ok(py("r = S.read_control(); print(r['paused'], r['why'])", home).startsWith("True"),
           "with no file, the worker too says paused");
    }

    // ---- status.json: believe it only while it is fresh ----------------------------------
    const QString stp = QDir(dir).filePath("status.json");
    const QDateTime now = QDateTime::fromString("2026-09-26T17:00:00Z", Qt::ISODate);
    auto s = wtlabs::readStation(dir, now);
    ok(!s.present && s.view == "absent", "no status file: \"absent\" (scanning not set up here)");
    writeFile(stp, R"({"state":"running","updated_at":"2026-09-26T16:59:30Z","current":"illumination",
                      "registered":["illumination","camera_health"],"skipped":["frame_difference"],
                      "totals":{"done":3},"last_unit":{"analyzer":"illumination","outcome":"done"}})");
    s = wtlabs::readStation(dir, now);
    ok(s.present && !s.stale && s.ageS == 30 && s.view == "running" && s.current == "illumination",
       "a 30 s old `running` is believed");
    ok(s.registered.size() == 2 && s.skipped == QStringList{"frame_difference"}
       && s.totals.value("done").toInt() == 3 && s.lastUnit.value("outcome") == "done",
       "registered, skipped, totals and the last unit come through");
    writeFile(stp, R"({"state":"running","updated_at":"2026-09-26T16:57:59Z"})");
    s = wtlabs::readStation(dir, now);
    ok(s.stale && s.view == "not_running" && s.ageS == 121,
       "121 s without a heartbeat: \"not_running\", whatever it last claimed");
    writeFile(stp, R"({"state":"stopped","updated_at":"2026-09-20T00:00:00Z"})");
    s = wtlabs::readStation(dir, now);
    ok(s.view == "stopped", "a worker that SAID it stopped stays \"stopped\", however old");
    writeFile(stp, R"({"state":"running"})");
    s = wtlabs::readStation(dir, now);
    ok(s.stale && s.view == "not_running", "a status with no readable time vouches for nothing");
    writeFile(stp, "garbage");
    s = wtlabs::readStation(dir, now);
    ok(s.view == "unreadable", "an unreadable status file says so");
    if (havePy) {
        py("S.write_status({'state': 'idle'})", home);
        s = wtlabs::readStation(dir, QDateTime::currentDateTimeUtc());
        ok(s.present && !s.stale && s.view == "idle", "the WORKER's own write_status reads back fresh here");
    }

    // ---- the server's answer ------------------------------------------------------------
    const QJsonObject seed = QJsonDocument::fromJson(R"({
        "analyzer": "frame_difference", "camera_hours_analysable": 11884, "camera_hours_done": 3,
        "coverage_pct": 0.0, "observations_total": 3, "projected_cpu_hours_per_day_enabled": 36.1,
        "generated_at": "2026-09-26T16:45:12.345Z",
        "budget": [
          {"analyzer": "frame_difference", "enabled": true, "scope": "outside", "sample_rate": 1.0,
           "cameras_in_scope": 56, "cost_cpu_s_per_camera_hour": 96.8, "projected_cpu_hours_per_day": 36.1},
          {"analyzer": "illumination", "enabled": true, "scope": "all", "sample_rate": 1.0,
           "cameras_in_scope": 133, "cost_cpu_s_per_camera_hour": null, "projected_cpu_hours_per_day": null},
          {"analyzer": "audio_energy", "enabled": false, "scope": "outside", "sample_rate": 1.0,
           "cameras_in_scope": 56, "cost_cpu_s_per_camera_hour": null, "projected_cpu_hours_per_day": null}],
        "by_analyzer": [
          {"analyzer": "frame_difference", "enabled": true, "done": 3, "in_progress": 0, "failed": 1},
          {"analyzer": "illumination", "enabled": true, "done": 1, "in_progress": 0, "failed": 0},
          {"analyzer": "audio_energy", "enabled": false, "done": 0, "in_progress": 0, "failed": 0}]
    })").object();
    ok(wtlabs::enabledSlugs(seed) == QStringList({"frame_difference", "illumination"}),
       "enabledSlugs reads the switched-on ones, in the server's order");
    QHash<QString, QJsonObject> detail;
    detail.insert("illumination", QJsonDocument::fromJson(
        R"({"analyzer":"illumination","camera_hours_analysable":20051,"coverage_pct":0.0,"observations_total":2})").object());
    const QVariantList rows = wtlabs::mergeStatus(seed, detail);
    ok(rows.size() == 3, "one row per analyser in the budget");
    const QVariantMap fd = rows.at(0).toMap(), il = rows.at(1).toMap(), au = rows.at(2).toMap();
    ok(fd.value("slug") == "frame_difference" && fd.value("costCpuS").toDouble() == 96.8
       && fd.value("analysable").toDouble() == 11884 && fd.value("failed").toDouble() == 1,
       "the seed analyser: cost, its own denominator, and its failed count");
    ok(il.value("analysable").toDouble() == 20051 && il.value("done").toDouble() == 1,
       "another enabled analyser: coverage from its own answer");
    ok(!il.value("costCpuS").isValid() && !il.value("projectedCpuHoursPerDay").isValid(),
       "a cost NOBODY MEASURED stays unknown -- never 0");
    ok(au.value("enabled").toBool() == false && !au.value("analysable").isValid() && !au.value("coveragePct").isValid(),
       "a switched-off analyser has no coverage figure, rather than 0 %");
    const QVariantList noDetail = wtlabs::mergeStatus(seed, {});
    ok(!noDetail.at(1).toMap().value("analysable").isValid(),
       "an enabled analyser whose own answer failed keeps its coverage UNKNOWN");

    qInfo().noquote() << (fails ? QString("%1 FAILED").arg(fails) : QStringLiteral("all passed"));
    return fails ? 1 : 0;
}
