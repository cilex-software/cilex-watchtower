// Tests for what the Labs screen SAYS (src/models/LabsStation.h): no network.
//
// Two halves, each where a mistake is silent:
//   * the station's local files, shared with tools/labs/station.py. The app and the
//     worker must agree on the directory and on every reading of control.json -- above
//     all that anything but an explicit `"paused": false` means PAUSED. So the
//     agreement is tested ACROSS languages: the app's writes read back through the
//     worker's own Python, and the worker's writes through the app's C++.
//   * the server's answer (GET /labs/pipeline) merged into rows, and a switch's answer
//     folded in: a cost nobody measured stays unknown, never 0, and a projected load that
//     leaves one out says it is a floor.
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

    // ---- the server's answer: GET /labs/pipeline ------------------------------------------
    // Shape copied from a real answer on the pilot (2026-09-26 17:01Z), trimmed to three rows.
    const QJsonObject pipe = QJsonDocument::fromJson(R"({
        "generated_at": "2026-09-26T17:01:29.337+00:00",
        "analyzers": [
          {"analyzer": "frame_difference", "title": "Keyframe-only frame differencing", "enabled": true,
           "scope": "outside", "sample_rate": 1.0, "cost_cpu_s_per_camera_hour": 96.8, "cameras_in_scope": 56,
           "queue_remaining": 11886, "done": 0, "claimed": 0, "failed": 1, "observations": 0,
           "budget": {"cpu_hours_per_day": 36.1, "gb_per_day_if_all_segments": 804.7}},
          {"analyzer": "illumination", "title": "Day/night/dusk/IR scene-light state", "enabled": true,
           "scope": "all", "sample_rate": 1.0, "cost_cpu_s_per_camera_hour": null, "cameras_in_scope": 133,
           "queue_remaining": 20060, "done": 1, "claimed": 0, "failed": 0, "observations": 2,
           "budget": {"cpu_hours_per_day": null, "gb_per_day_if_all_segments": 830.4}},
          {"analyzer": "audio_energy", "title": "RMS envelope", "enabled": false,
           "scope": "outside", "sample_rate": 1.0, "cost_cpu_s_per_camera_hour": null, "cameras_in_scope": 56,
           "queue_remaining": null, "done": 0, "claimed": 0, "failed": 0, "observations": 0,
           "budget": {"cpu_hours_per_day": null, "gb_per_day_if_all_segments": 804.7}}]
    })").object();
    QVariantList rows = wtlabs::mergePipeline(pipe);
    ok(rows.size() == 3, "one row per analyser, switched-off ones INCLUDED");
    QVariantMap fd = rows.at(0).toMap(), il = rows.at(1).toMap(), au = rows.at(2).toMap();
    ok(fd.value("slug") == "frame_difference" && fd.value("costCpuS").toDouble() == 96.8
       && fd.value("cpuHoursPerDay").toDouble() == 36.1 && fd.value("waiting").toDouble() == 11886
       && fd.value("failed").toDouble() == 1,
       "an enabled analyser: cost, projected CPU-h/day, hours waiting, failed");
    ok(il.value("done").toDouble() == 1 && il.value("observations").toDouble() == 2,
       "counts come through as the server gave them");
    ok(!il.value("costCpuS").isValid() && !il.value("cpuHoursPerDay").isValid(),
       "a cost NOBODY MEASURED stays unknown -- never 0");
    ok(au.value("enabled").toBool() == false && !au.value("waiting").isValid(),
       "a switched-off analyser has no queue figure, rather than 0");

    wtlabs::Load l = wtlabs::projectedLoad(rows);
    ok(l.enabled == 2 && l.cpuHoursPerDay.toDouble() == 36.1 && l.unmeasured,
       "projected load sums the measured costs and says it is a FLOOR when one is unmeasured");
    QVariantList measured = wtlabs::mergePipeline(pipe);
    measured.removeAt(1);   // without the unmeasured enabled one
    l = wtlabs::projectedLoad(measured);
    ok(l.enabled == 1 && !l.unmeasured && l.cpuHoursPerDay.toDouble() == 36.1,
       "...and is exact when every enabled cost is measured");
    ok(!wtlabs::projectedLoad(QVariantList{au}).cpuHoursPerDay.isValid(),
       "with nothing measured and switched on, the load is unknown, not 0");

    // The switch answer folds into the rows: no second request.
    const QJsonObject patched = QJsonDocument::fromJson(R"({"analyzer": "audio_energy", "title": "RMS envelope",
        "enabled": true, "scope": "outside", "sample_rate": 1.0, "cost_cpu_s_per_camera_hour": null})").object();
    ok(wtlabs::applyPatch(rows, patched), "a PATCH answer finds its row");
    au = rows.at(2).toMap();
    ok(au.value("enabled").toBool() && au.value("done").toDouble() == 0 && !au.value("waiting").isValid(),
       "...switches it ON from the SERVER's answer, keeps its counts, queue unknown until the next refresh");
    const QJsonObject off = QJsonDocument::fromJson(R"({"analyzer": "frame_difference", "enabled": false,
        "scope": "outside", "sample_rate": 1.0, "cost_cpu_s_per_camera_hour": 96.8})").object();
    wtlabs::applyPatch(rows, off);
    ok(!rows.at(0).toMap().value("enabled").toBool() && !rows.at(0).toMap().value("waiting").isValid(),
       "switching one OFF drops its queue figure (the server counts a queue only while on)");
    ok(!wtlabs::applyPatch(rows, QJsonDocument::fromJson(R"({"analyzer": "nope", "enabled": true})").object()),
       "an answer for an analyser not on screen changes nothing");

    qInfo().noquote() << (fails ? QString("%1 FAILED").arg(fails) : QStringLiteral("all passed"));
    return fails ? 1 : 0;
}
