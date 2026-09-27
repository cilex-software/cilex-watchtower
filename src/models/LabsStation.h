#pragma once
// Labs — the parts that decide what the Labs screen SAYS, kept free of the network so
// tools/tests/labs-station.cpp can pin them (the StationEnrolment.h pattern).
//
// THE STATION'S TWO LOCAL FILES, shared with tools/labs/station.py:
//   control.json  written HERE (Pause / Resume) and by `run_worker.py --pause|--resume`;
//                 the worker re-reads it before every claim.
//   status.json   written by the worker (`run_worker.py --loop`), refreshed by a
//                 heartbeat thread every 30 s; read here.
// No network and no credential: an app and a worker on one machine, talking through two
// files in a directory they both compute the same way. If stateDir() and
// station.state_dir() ever differ, a running worker is invisible here -- change both.
//
// THE SERVER'S ANSWER: GET /labs/pipeline (admin session) lists every analyser with its
// state, cost and counts; mergePipeline() turns it into one row each. It never fills a
// gap with a guess: a cost nobody has measured stays unknown, never 0.
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QString>
#include <QStringList>
#include <QThread>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

namespace wtlabs {   // not `labs`: that is <cstdlib>'s labs(), which Qt pulls in

// MUST match tools/labs/station.py state_dir().
inline QString stateDir()
{
#ifdef Q_OS_WIN
    QString base = qEnvironmentVariable("LOCALAPPDATA");
    if (base.isEmpty())
        base = QDir::homePath();
#else
    QString base = qEnvironmentVariable("XDG_STATE_HOME");
    if (base.isEmpty())
        base = QDir::homePath() + QStringLiteral("/.local/state");
#endif
    return QDir(base).filePath(QStringLiteral("watchtower-labs"));
}

// station.py RETRIES / RETRY_S, for the same reason. ON WINDOWS an open fails while the
// worker is replacing the file, and the worker's replace fails while this side holds it
// open (Qt, like Python, opens without FILE_SHARE_DELETE); Linux does neither. Measured
// on the booth 2026-09-27 (Windows agent): writer and reader flat out for 5 s, 3,501 of
// 5,494 replaces and 3,096 of 38,163 opens failed; with BOTH sides retrying 20 x 5 ms,
// none did. A failed read used to show as "unreadable" for a whole 5 s poll -- flicker
// -- and a failed read inside writeControl() dropped the camera_health opt-in.
constexpr int kRetries = 20;
constexpr int kRetryMs = 5;

enum class Read { Ok, Absent, Failed };

// The whole file. Absent returns at once (no worker on this station is the common case,
// and must not cost a sleep per poll); only a file that is THERE but will not open is
// retried.
// QFileInfo::exists(path), NOT QFile(path).exists(): measured on Linux with Qt 6.12 while
// station.py replaced the file flat out, the member call said "missing" 9,657 times in
// 576,467 -- the file never was (static QFileInfo::exists and ::stat: 0 misses, and strace
// shows a plain atomic rename). That read as "absent", i.e. "scanning is not set up here".
inline Read readRetrying(const QString &path, QByteArray *out, QString *err = nullptr)
{
    for (int attempt = 0; attempt < kRetries; ++attempt) {
        if (!QFileInfo::exists(path))
            return Read::Absent;
        QFile f(path);
        if (f.open(QIODevice::ReadOnly)) {
            *out = f.readAll();
            return Read::Ok;
        }
        if (err)
            *err = f.errorString();
        if (attempt + 1 < kRetries)
            QThread::msleep(kRetryMs);
    }
    return Read::Failed;
}

// station.py STALE_AFTER_S: four missed 30 s heartbeats. A worker killed without a
// chance to say "stopped" leaves its last state behind; past this age that state is
// no longer evidence of anything.
constexpr qint64 kStaleAfterS = 120;

// The WORKER's reading of the control file, mirrored exactly: default-deny. Anything but
// an explicit `"paused": false` means paused, and `why` says which case it was.
struct Control {
    bool paused = true;
    bool cameraHealth = false;
    QString why;   // "absent" | "unreadable" | "no_flag" | "" (the file said so)
};

inline Control readControl(const QString &dir)
{
    Control c;
    QByteArray bytes;
    switch (readRetrying(QDir(dir).filePath(QStringLiteral("control.json")), &bytes)) {
    case Read::Absent: c.why = QStringLiteral("absent"); return c;
    case Read::Failed: c.why = QStringLiteral("unreadable"); return c;
    case Read::Ok: break;
    }
    QJsonParseError pe{};
    const QJsonDocument d = QJsonDocument::fromJson(bytes, &pe);
    if (pe.error != QJsonParseError::NoError || !d.isObject()) { c.why = QStringLiteral("unreadable"); return c; }
    const QJsonObject o = d.object();
    const QJsonValue p = o.value(QStringLiteral("paused"));
    if (!p.isBool()) { c.why = QStringLiteral("no_flag"); return c; }
    c.paused = p.toBool();
    c.cameraHealth = o.value(QStringLiteral("camera_health")) == QJsonValue(true);
    return c;
}

// Pause or resume, keeping everything else the file says -- above all the station's
// camera_health opt-in, which only one station may hold. Atomic like the worker's own
// writes: QSaveFile commits the whole document or nothing, so the worker never reads
// half a file (and half a file would read as PAUSED anyway).
inline bool writeControl(const QString &dir, bool paused, const QString &by, QString *err = nullptr)
{
    const QString path = QDir(dir).filePath(QStringLiteral("control.json"));
    QJsonObject o;
    {
        QByteArray bytes;
        QString why;
        switch (readRetrying(path, &bytes, &why)) {
        case Read::Absent:
            break;                       // first write on this station: a fresh document
        case Read::Failed:
            // THERE but will not open. Writing a fresh document over it would silently
            // drop what it holds -- above all the camera_health opt-in. It used to.
            if (err) *err = QStringLiteral("control.json would not open (%1); nothing changed").arg(why);
            return false;
        case Read::Ok: {
            const QJsonDocument d = QJsonDocument::fromJson(bytes);
            if (d.isObject())
                o = d.object();          // not JSON: nothing in it can be kept
            break;
        }
        }
    }
    o.insert(QStringLiteral("v"), 1);
    o.insert(QStringLiteral("paused"), paused);
    o.insert(QStringLiteral("updated_at"), QDateTime::currentDateTimeUtc().toString(Qt::ISODate));
    o.insert(QStringLiteral("updated_by"), by);
    if (!QDir().mkpath(dir)) {
        if (err) *err = QStringLiteral("cannot create %1").arg(dir);
        return false;
    }
    const QByteArray doc = QJsonDocument(o).toJson(QJsonDocument::Indented);
    QString last;
    for (int attempt = 0; attempt < kRetries; ++attempt) {
        // A fresh QSaveFile each time: one that failed to commit cannot commit again. On
        // Windows the commit's replace is refused while the worker has the file open.
        QSaveFile f(path);
        if (f.open(QIODevice::WriteOnly)) {
            f.write(doc);
            if (f.commit())
                return true;
        }
        last = f.errorString();
        if (attempt + 1 < kRetries)
            QThread::msleep(kRetryMs);
    }
    if (err) *err = last;
    return false;
}

// What the worker last said, and whether that can still be believed.
struct Station {
    bool present = false;
    bool stale = false;
    qint64 ageS = -1;
    QString state;   // the worker's own: starting|paused|running|idle|unreachable|fatal|stopped
    QString view;    // what the screen shows: absent|unreadable|not_running|stopped|<state>
    QString note, current, updatedAt, startedAt, host, workerVersion, serverVersion;
    QVariantMap lastUnit, totals;
    QStringList runs, registered, skipped;
    bool cameraHealth = false;
};

inline Station readStation(const QString &dir, const QDateTime &nowUtc)
{
    Station s;
    QByteArray bytes;
    switch (readRetrying(QDir(dir).filePath(QStringLiteral("status.json")), &bytes)) {
    case Read::Absent: s.view = QStringLiteral("absent"); return s;
    case Read::Failed: s.view = QStringLiteral("unreadable"); return s;
    case Read::Ok: break;
    }
    const QJsonDocument d = QJsonDocument::fromJson(bytes);
    if (!d.isObject()) { s.view = QStringLiteral("unreadable"); return s; }
    const QJsonObject o = d.object();
    s.present = true;
    s.state = o.value(QStringLiteral("state")).toString();
    s.note = o.value(QStringLiteral("note")).toString();
    s.current = o.value(QStringLiteral("current")).toString();
    s.updatedAt = o.value(QStringLiteral("updated_at")).toString();
    s.startedAt = o.value(QStringLiteral("started_at")).toString();
    s.host = o.value(QStringLiteral("host")).toString();
    s.workerVersion = o.value(QStringLiteral("worker_version")).toString();
    s.serverVersion = o.value(QStringLiteral("server_version")).toString();
    s.lastUnit = o.value(QStringLiteral("last_unit")).toObject().toVariantMap();
    s.totals = o.value(QStringLiteral("totals")).toObject().toVariantMap();
    for (const QJsonValue &v : o.value(QStringLiteral("runs")).toArray())
        s.runs << v.toString();
    for (const QJsonValue &v : o.value(QStringLiteral("registered")).toArray())
        s.registered << v.toString();
    for (const QJsonValue &v : o.value(QStringLiteral("skipped")).toArray())
        s.skipped << v.toString();
    s.cameraHealth = o.value(QStringLiteral("camera_health")) == QJsonValue(true);
    const QDateTime at = QDateTime::fromString(s.updatedAt, Qt::ISODate);
    if (at.isValid()) {
        s.ageS = at.secsTo(nowUtc);
        s.stale = s.ageS > kStaleAfterS;
    } else {
        s.stale = true;   // a status with no readable time cannot vouch for anything
    }
    if (s.state == QLatin1String("stopped"))
        s.view = QStringLiteral("stopped");
    else if (s.stale)
        s.view = QStringLiteral("not_running");
    else
        s.view = s.state.isEmpty() ? QStringLiteral("unreadable") : s.state;
    return s;
}

// A number, or an honest "unknown" (null). Never 0 for a field the server left null.
inline QVariant numOrNull(const QJsonValue &v)
{
    return v.isDouble() ? QVariant(v.toDouble()) : QVariant();
}

// One row per analyser from GET /labs/pipeline, in the server's order (switched-on
// first). Every analyser is listed, switched-off ones included, and nothing here scans
// footage except `queue_remaining`, which the server caches for 120 s and computes once
// per expiry however many screens ask. (The per-analyser /labs/scan/status this used
// before cost 5.26 s and ~1 GB of page reads per call, measured by cilex-vision with
// EXPLAIN (ANALYZE, BUFFERS) on 2026-09-26: churn that slows playback opens on the pilot.)
inline QVariantList mergePipeline(const QJsonObject &pipeline)
{
    QVariantList rows;
    for (const QJsonValue &v : pipeline.value(QStringLiteral("analyzers")).toArray()) {
        const QJsonObject a = v.toObject();
        const QString slug = a.value(QStringLiteral("analyzer")).toString();
        if (slug.isEmpty())
            continue;
        QVariantMap r;
        r[QStringLiteral("slug")] = slug;
        r[QStringLiteral("serverTitle")] = a.value(QStringLiteral("title")).toString();
        r[QStringLiteral("enabled")] = a.value(QStringLiteral("enabled")).toBool();
        r[QStringLiteral("scope")] = a.value(QStringLiteral("scope")).toString();
        r[QStringLiteral("sampleRate")] = numOrNull(a.value(QStringLiteral("sample_rate")));
        r[QStringLiteral("camerasInScope")] = numOrNull(a.value(QStringLiteral("cameras_in_scope")));
        r[QStringLiteral("costCpuS")] = numOrNull(a.value(QStringLiteral("cost_cpu_s_per_camera_hour")));
        r[QStringLiteral("cpuHoursPerDay")] = numOrNull(
            a.value(QStringLiteral("budget")).toObject().value(QStringLiteral("cpu_hours_per_day")));
        // Unclaimed camera-hours, for switched-ON analysers only (null otherwise). The
        // server notes it can over-count failed units that will not be handed out again.
        r[QStringLiteral("waiting")] = numOrNull(a.value(QStringLiteral("queue_remaining")));
        r[QStringLiteral("done")] = numOrNull(a.value(QStringLiteral("done")));
        r[QStringLiteral("inProgress")] = numOrNull(a.value(QStringLiteral("claimed")));
        r[QStringLiteral("failed")] = numOrNull(a.value(QStringLiteral("failed")));
        r[QStringLiteral("observations")] = numOrNull(a.value(QStringLiteral("observations")));
        rows.append(r);
    }
    return rows;
}

// The projected load of what is switched on: the server's per-analyser figures summed.
// `unmeasured` says an enabled analyser had no measured cost, so the sum is a FLOOR.
struct Load { QVariant cpuHoursPerDay; bool unmeasured = false; int enabled = 0; };
inline Load projectedLoad(const QVariantList &rows)
{
    Load l;
    double sum = 0;
    bool any = false;
    for (const QVariant &v : rows) {
        const QVariantMap r = v.toMap();
        if (!r.value(QStringLiteral("enabled")).toBool())
            continue;
        ++l.enabled;
        const QVariant c = r.value(QStringLiteral("cpuHoursPerDay"));
        if (c.isValid() && !c.isNull()) { sum += c.toDouble(); any = true; }
        else l.unmeasured = true;
    }
    if (any)
        l.cpuHoursPerDay = sum;
    return l;
}

// Fold the PATCH answer (one Analyzer row) into the rows already on screen, so a switch
// change costs no second request. Fields the PATCH does not carry (counts, queue) stay
// as they were until the next refresh.
inline bool applyPatch(QVariantList &rows, const QJsonObject &analyzer)
{
    const QString slug = analyzer.value(QStringLiteral("analyzer")).toString();
    for (QVariant &v : rows) {
        QVariantMap r = v.toMap();
        if (r.value(QStringLiteral("slug")).toString() != slug)
            continue;
        r[QStringLiteral("enabled")] = analyzer.value(QStringLiteral("enabled")).toBool();
        r[QStringLiteral("scope")] = analyzer.value(QStringLiteral("scope")).toString();
        r[QStringLiteral("sampleRate")] = numOrNull(analyzer.value(QStringLiteral("sample_rate")));
        r[QStringLiteral("costCpuS")] = numOrNull(analyzer.value(QStringLiteral("cost_cpu_s_per_camera_hour")));
        if (!r.value(QStringLiteral("enabled")).toBool())
            r[QStringLiteral("waiting")] = QVariant();   // the server counts a queue only while on
        v = r;
        return true;
    }
    return false;
}

}   // namespace wtlabs
