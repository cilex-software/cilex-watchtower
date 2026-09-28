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
// Build + run from the repo root (Qt 6.12):
//   Linux:   QT=~/Qt/6.12.0/gcc_64
//            g++ -std=c++17 -fPIC -o /tmp/labsst tools/tests/labs-station.cpp -Isrc/models \
//                -I$QT/include -I$QT/include/QtCore -L$QT/lib -lQt6Core && LD_LIBRARY_PATH=$QT/lib /tmp/labsst
//   Windows: call vcvars64.bat && cl /std:c++17 /permissive- /Zc:__cplusplus /EHsc /MD /O2 /utf-8
//            /I src\models /I %QT%\include /I %QT%\include\QtCore tools\tests\labs-station.cpp
//            /Fe:labsst.exe /link %QT%\lib\Qt6Core.lib        (%QT%\bin on PATH; the booth's line)
//
// IT WRITES control.json AND status.json -- only ever inside its own temporary directory,
// and it REFUSES to run if the station directory would land anywhere else. On a station
// whose scanner is running, a stray control.json from this test would pause or RESUME it
// for real. (The first Windows run wrote into the booth's real %LOCALAPPDATA%: only
// XDG_STATE_HOME was redirected, and stateDir() reads LOCALAPPDATA there.)
#include "LabsStation.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QProcess>
#include <QTemporaryDir>
#include <cstdio>
#include <cstdlib>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

// printf, not qInfo: on Windows Qt logs to OutputDebugString when stderr is not a
// console, so a piped run printed NOTHING and only the exit code spoke.
static void say(const QString &line)
{
    std::printf("%s\n", line.toUtf8().constData());
    std::fflush(stdout);
}

// Point an environment variable at a PATH, exactly. qputenv() takes bytes, and on Windows
// the CRT reads them in the ANSI code page: the booth's profile is "Охрана", and a UTF-8
// "C:/Users/Охрана/..." came back from qEnvironmentVariable as "C:/Users/РћС…СЂР°РЅР°/..."
// -- so the guard in main() refused to run (rightly: that path is not the temp dir).
// The wide CRT call there; the file-name encoding elsewhere.
static void putPath(const char *name, const QString &value)
{
#ifdef Q_OS_WIN
    _wputenv_s(reinterpret_cast<const wchar_t *>(QString::fromLatin1(name).utf16()),
               reinterpret_cast<const wchar_t *>(QDir::toNativeSeparators(value).utf16()));
#else
    qputenv(name, QFile::encodeName(value));
#endif
}

int fails = 0;
static void ok(bool cond, const QString &what)
{
    if (!cond) ++fails;
    say(QString::fromLatin1(cond ? "PASS " : "FAIL ") + what);
}

// A file that is THERE but will not open, as the race makes one on Windows: there, an
// exclusive handle (share mode 0 -- the real mechanism); elsewhere, mode 000. Released
// when this goes out of scope. `held()` says whether it took; if not, the checks skip.
struct Unopenable {
    QString path;
#ifdef Q_OS_WIN
    HANDLE h = INVALID_HANDLE_VALUE;
    explicit Unopenable(const QString &p) : path(p)
    {
        h = CreateFileW(reinterpret_cast<LPCWSTR>(QDir::toNativeSeparators(p).utf16()), GENERIC_READ, 0,
                        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    }
    ~Unopenable() { if (h != INVALID_HANDLE_VALUE) CloseHandle(h); }
#else
    explicit Unopenable(const QString &p) : path(p) { QFile::setPermissions(p, QFileDevice::Permissions()); }
    ~Unopenable() { QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner); }
#endif
    bool held() const
    {
        QFile probe(path);
        return !probe.open(QIODevice::ReadOnly);   // root can open a mode-000 file
    }
};

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
    // BOTH bases, as main() redirects them: station.state_dir() reads LOCALAPPDATA on
    // Windows. (This used to REMOVE it, so there the worker looked in %USERPROFILE%.)
    env.insert(QStringLiteral("XDG_STATE_HOME"), stateHome);
    env.insert(QStringLiteral("LOCALAPPDATA"), stateHome);
    p.setProcessEnvironment(env);
    p.start(QStringLiteral("python3"), {QStringLiteral("-c"),
            QStringLiteral("import sys; sys.path.insert(0, 'tools/labs'); import station as S\n") + code});
    p.waitForFinished(20000);
    return QString::fromUtf8(p.readAllStandardOutput()).trimmed();
}

// THE WINDOWS REPLACE RACE, for a Windows box to run -- Linux never shows it. This app's
// side flat out against the worker's side flat out in another process
// (tools/tests/labs-station-stress.py), in a SCRATCH directory:
//   labsst --stress read-status  <dir> <s>   with   labs-station-stress.py write-status <dir> <s>
//   labsst --stress write-control <dir> <s>  with   labs-station-stress.py read-control <dir> <s>
static int stress(const QString &role, const QString &dir, double secs)
{
    if (QDir(dir).absolutePath() == QDir(wtlabs::stateDir()).absolutePath()) {
        say(QStringLiteral("refusing: that is this station's REAL state directory"));   // it decides scanning
        return 2;
    }
    QDir().mkpath(dir);
    QElapsedTimer t;
    t.start();
    qint64 n = 0, bad = 0;
    bool seen = false;
    while (t.elapsed() < secs * 1000) {
        if (role == QLatin1String("read-status")) {
            const auto st = wtlabs::readStation(dir, QDateTime::currentDateTimeUtc());
            if (st.view == QLatin1String("absent") && !seen)
                continue;                          // the worker's side has not written yet
            seen = true;
            ++n;
            if (st.view == QLatin1String("unreadable") || st.view == QLatin1String("absent"))
                ++bad;
        } else if (role == QLatin1String("write-control")) {
            ++n;
            if (!wtlabs::writeControl(dir, n % 2, QStringLiteral("stress")))
                ++bad;
        } else {
            say(QStringLiteral("roles: read-status | write-control"));
            return 2;
        }
    }
    say(QStringLiteral("%1: %2 failed of %3").arg(role).arg(bad).arg(n));
    return bad ? 1 : 0;
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (argc >= 5 && QString(argv[1]) == QLatin1String("--stress"))
        return stress(QString(argv[2]), QString(argv[3]), QString(argv[4]).toDouble());
    // A deliberately NON-ASCII home, Cyrillic and a character outside every Cyrillic code
    // page, so every run exercises what the booth's "Охрана" profile broke: a path that
    // only survives the environment round trip if it is set as Unicode.
    QTemporaryDir tmp(QDir::tempPath() + QString::fromUtf8(u8"/labsst-Охрана-守-XXXXXX"));
    if (!tmp.isValid()) {
        say(QStringLiteral("REFUSING TO RUN: could not create the temporary directory: ") + tmp.errorString());
        return 2;
    }
    const QString home = tmp.path();

    // ---- where both sides look -----------------------------------------------------------
    // ISOLATION FIRST: both platforms' bases point into this test's temporary directory,
    // and nothing is written unless the station directory really landed there.
    putPath("XDG_STATE_HOME", home);
    putPath("LOCALAPPDATA", home);
    const QString dir = wtlabs::stateDir();
    if (!QDir(dir).absolutePath().startsWith(QDir(home).absolutePath() + QLatin1Char('/'))) {
        say(QStringLiteral("REFUSING TO RUN: the station directory would be %1, outside this test's "
                           "temporary directory %2 -- a write there could pause or resume a real scanner")
                .arg(dir, home));
        return 2;
    }
    ok(dir == QDir(home).filePath("watchtower-labs"), "stateDir honours the redirected base: " + dir);
    const bool havePy = !py("print('ok')", home).isEmpty();
    if (havePy)
        ok(QDir(py("print(S.state_dir())", home)).absolutePath() == QDir(dir).absolutePath(),
           "the worker's station.state_dir() is the SAME directory");
    else
        say(QStringLiteral("SKIP cross-language checks -- no python3 here"));
#ifdef Q_OS_WIN
    qunsetenv("LOCALAPPDATA");
    ok(wtlabs::stateDir() == QDir(QDir::homePath()).filePath("watchtower-labs"),
       "with no LOCALAPPDATA, stateDir falls back to the home directory");
    putPath("LOCALAPPDATA", home);
#else
    qunsetenv("XDG_STATE_HOME");
    ok(wtlabs::stateDir() == QDir::homePath() + "/.local/state/watchtower-labs",
       "stateDir defaults to ~/.local/state/watchtower-labs");
    putPath("XDG_STATE_HOME", home);
#endif
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
    const bool wrote = wtlabs::writeControl(dir, true, "test", &err);   // before err is printed
    ok(wrote, "writeControl succeeds" + (err.isEmpty() ? QString() : ": " + err));
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

    // ---- the wall safety check's HOLD (operator decision 2026-09-28) ------------------------
    writeFile(ctl, R"({"paused": false, "camera_health": true,
                       "hold": {"by": "wall-guard", "why": "dark tiles for 4 s", "at": "2026-09-28T09:01:00Z"}})");
    c = wtlabs::readControl(dir);
    ok(c.hold.value("why").toString() == "dark tiles for 4 s" && c.hold.value("by").toString() == "wall-guard",
       "a hold in the control file is read, with who set it and why");
    QString eh;
    ok(wtlabs::clearHold(dir, "app", &eh) && wtlabs::readControl(dir).hold.isEmpty(), "Release clears the hold" + eh);
    c = wtlabs::readControl(dir);
    ok(!c.paused && c.cameraHealth, "...and keeps everything else, above all the camera_health opt-in");
    if (havePy) {
        py("S.write_hold('stall 3 s', by='wall-guard')", home);
        ok(wtlabs::readControl(dir).hold.value("why").toString() == "stall 3 s",
           "the APP reads a hold the WORKER's station.write_hold wrote");
        wtlabs::clearHold(dir, "app");
        ok(py("print(S.read_control()['hold'])", home) == "None", "the WORKER reads the app's Release");
    }
    QFile::remove(ctl);

    // ---- a file that is THERE but will not open --------------------------------------------
    // On Windows: for a moment, while the other side replaces it. Either way the read must
    // give up in bounded time, and a Pause must not write a fresh document over a file it
    // could not read -- that would drop the camera_health opt-in.
    writeFile(ctl, R"({"paused": false, "camera_health": true})");
    {
        Unopenable lock(ctl);
        if (!lock.held()) {
            say(QStringLiteral("SKIP unopenable-file checks -- could not make the file unopenable (root?)"));
        } else {
            QElapsedTimer t;
            t.start();
            c = wtlabs::readControl(dir);
            const qint64 ms = t.elapsed();
            // >= 50 ms proves it RETRIED (19 sleeps of 5 ms cannot take less); < 1 s that it stops.
            ok(c.paused && c.why == "unreadable" && ms >= 50 && ms < 1000,
               QStringLiteral("a control file that never opens reads as paused, after BOUNDED retries (%1 ms)").arg(ms));
            QString e2;
            const bool refused = !wtlabs::writeControl(dir, true, "test", &e2);   // before e2 is printed
            ok(refused && e2.contains("nothing changed"),
               "Pause REFUSES to write over a control.json it could not read: " + e2);
        }
    }
    c = wtlabs::readControl(dir);
    ok(!c.paused && c.cameraHealth, "...and that file is exactly as it was, opt-in intact");
    QFile::remove(ctl);

    // ---- status.json: believe it only while it is fresh ----------------------------------
    const QString stp = QDir(dir).filePath("status.json");
    const QDateTime now = QDateTime::fromString("2026-09-26T17:00:00Z", Qt::ISODate);
    auto s = wtlabs::readStation(dir, now);
    ok(!s.present && s.view == "absent", "no status file: \"absent\" (scanning not set up here)");
    ok(!s.switchable, "...and NOT switchable: no Start / Pause where no scanner has run (operator 2026-09-28)");
    writeFile(stp, R"({"state":"running","updated_at":"2026-09-26T16:59:30Z","current":"illumination",
                      "registered":["illumination","camera_health"],"skipped":["frame_difference"],
                      "totals":{"done":3},"last_unit":{"analyzer":"illumination","outcome":"done"}})");
    s = wtlabs::readStation(dir, now);
    ok(s.present && !s.stale && s.ageS == 30 && s.view == "running" && s.current == "illumination",
       "a 30 s old `running` is believed");
    ok(s.switchable, "...and a scanner running here can be switched");
    ok(s.registered.size() == 2 && s.skipped == QStringList{"frame_difference"}
       && s.totals.value("done").toInt() == 3 && s.lastUnit.value("outcome") == "done",
       "registered, skipped, totals and the last unit come through");
    writeFile(stp, R"({"state":"running","updated_at":"2026-09-26T16:57:59Z"})");
    s = wtlabs::readStation(dir, now);
    ok(s.stale && s.view == "not_running" && s.ageS == 121,
       "121 s without a heartbeat: \"not_running\", whatever it last claimed");
    ok(!s.switchable, "...and is not switchable: nothing here is listening");
    writeFile(stp, R"({"state":"stopped","updated_at":"2026-09-20T00:00:00Z"})");
    s = wtlabs::readStation(dir, now);
    ok(s.view == "stopped", "a worker that SAID it stopped stays \"stopped\", however old");
    ok(!s.switchable, "...and a stopped scanner is not switchable");
    writeFile(stp, R"({"state":"stopped","updated_at":"2026-09-26T16:59:50Z"})");
    s = wtlabs::readStation(dir, now);
    ok(!s.stale && !s.switchable, "...not even a FRESH `stopped`: the process has ended");
    writeFile(stp, R"({"state":"fatal","updated_at":"2026-09-26T16:59:30Z","note":"no STATION_TOKEN"})");
    s = wtlabs::readStation(dir, now);
    ok(s.view == "fatal" && !s.stale && !s.switchable,
       "a fresh `fatal` is running but NOT switchable: it cannot scan until its note is fixed");
    writeFile(stp, R"({"updated_at":"2026-09-26T16:59:30Z"})");
    s = wtlabs::readStation(dir, now);
    ok(s.present && s.view == "unreadable" && !s.switchable, "a fresh status with no state: unreadable, not switchable");
    writeFile(stp, R"({"state":"running"})");
    s = wtlabs::readStation(dir, now);
    ok(s.stale && s.view == "not_running", "a status with no readable time vouches for nothing");
    writeFile(stp, "garbage");
    s = wtlabs::readStation(dir, now);
    ok(s.view == "unreadable", "an unreadable status file says so");
    ok(!s.switchable, "...and is not switchable");
    writeFile(stp, R"({"state":"stopped_by_server","updated_at":"2026-09-26T16:59:30Z","governed":true,
                      "server_mode":"stopped","server_level":"all","server_at":"2026-09-26T16:00:00Z",
                      "lanes":{"illumination":"running","blob_geometry":"paused"},
                      "hold":{"by":"wall-guard","why":"stall 3 s","at":""}})");
    s = wtlabs::readStation(dir, now);
    ok(s.governed && s.serverMode == "stopped" && s.serverLevel == "all" && s.view == "stopped_by_server"
       && s.lanes.value("blob_geometry").toString() == "paused" && s.hold.value("why").toString() == "stall 3 s",
       "a GOVERNED status reads through: the server's mode, level and lanes, and the hold");
    ok(s.switchable, "a fresh governed scanner the SERVER stopped is switchable: Start asks the server");
    writeFile(stp, R"({"state":"running","updated_at":"2026-09-26T16:59:30Z"})");
    {
        Unopenable lock(stp);
        if (lock.held()) {
            QElapsedTimer t;
            t.start();
            s = wtlabs::readStation(dir, now);
            ok(s.view == "unreadable" && t.elapsed() >= 50 && t.elapsed() < 1000,
               QStringLiteral("a status file that never opens says \"unreadable\", after BOUNDED retries (%1 ms)")
                   .arg(t.elapsed()));
        }
    }

    if (havePy) {
        py("S.write_status({'state': 'idle'})", home);
        s = wtlabs::readStation(dir, QDateTime::currentDateTimeUtc());
        ok(s.present && !s.stale && s.view == "idle", "the WORKER's own write_status reads back fresh here");

        // Reads DURING the worker's replaces: its own write_status flat out in another
        // process. The file is always there (atomic rename), so no read may say otherwise.
        // Qt's member QFile::exists() said "missing" ~1.7% of the time here (measured);
        // one second of this catches that with thousands of misses to spare.
        const QString sd = QDir(home).filePath("stress");
        QProcess w;
        w.start("python3", {QDir::current().filePath("tools/tests/labs-station-stress.py"), "write-status", sd, "1.6"});
        QElapsedTimer t;
        t.start();
        while (!QFileInfo::exists(QDir(sd).filePath("status.json")) && t.elapsed() < 3000)
            QThread::msleep(5);
        if (!QFileInfo::exists(QDir(sd).filePath("status.json"))) {
            say(QStringLiteral("SKIP reads during replaces -- the worker's writer did not start (run from the repo root)"));
            w.waitForFinished(10000);
        } else {
        qint64 n = 0, bad = 0;
        t.restart();
        while (t.elapsed() < 1000) {
            ++n;
            const QString v = wtlabs::readStation(sd, QDateTime::currentDateTimeUtc()).view;
            if (v == "absent" || v == "unreadable")
                ++bad;
        }
        w.waitForFinished(10000);
        ok(n > 1000 && bad == 0,
           QStringLiteral("no read says absent/unreadable while the worker replaces status.json flat out (%1 of %2)")
               .arg(bad).arg(n));
        }
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

    say(fails ? QStringLiteral("%1 FAILED").arg(fails) : QStringLiteral("all passed"));
    return fails ? 1 : 0;
}
