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
// THE SERVER'S ANSWER: GET /labs/scan/status (the operator's session) describes ONE
// enabled analyser in detail and every analyser briefly (`budget`, `by_analyzer`).
// mergeStatus() turns that into one row per analyser. It never fills a gap with a guess:
// a cost nobody has measured stays unknown, and coverage is known only for analysers
// that are switched on, because only those have a denominator the server will give.
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QString>
#include <QStringList>
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
    QFile f(QDir(dir).filePath(QStringLiteral("control.json")));
    if (!f.exists()) { c.why = QStringLiteral("absent"); return c; }
    if (!f.open(QIODevice::ReadOnly)) { c.why = QStringLiteral("unreadable"); return c; }
    QJsonParseError pe{};
    const QJsonDocument d = QJsonDocument::fromJson(f.readAll(), &pe);
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
        QFile f(path);
        if (f.open(QIODevice::ReadOnly)) {
            const QJsonDocument d = QJsonDocument::fromJson(f.readAll());
            if (d.isObject())
                o = d.object();
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
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        if (err) *err = f.errorString();
        return false;
    }
    f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
    if (!f.commit()) {
        if (err) *err = f.errorString();
        return false;
    }
    return true;
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
    QFile f(QDir(dir).filePath(QStringLiteral("status.json")));
    if (!f.exists()) { s.view = QStringLiteral("absent"); return s; }
    if (!f.open(QIODevice::ReadOnly)) { s.view = QStringLiteral("unreadable"); return s; }
    const QJsonDocument d = QJsonDocument::fromJson(f.readAll());
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

inline QStringList enabledSlugs(const QJsonObject &status)
{
    QStringList out;
    for (const QJsonValue &v : status.value(QStringLiteral("budget")).toArray()) {
        const QJsonObject b = v.toObject();
        if (b.value(QStringLiteral("enabled")).toBool())
            out << b.value(QStringLiteral("analyzer")).toString();
    }
    return out;
}

// One row per analyser, in the server's order (switched-on first). `seed` is the full
// answer for one enabled analyser; `detail` holds the answers for the other enabled
// ones, by slug. An analyser with no detail keeps its coverage unknown.
inline QVariantList mergeStatus(const QJsonObject &seed, const QHash<QString, QJsonObject> &detail)
{
    QHash<QString, QJsonObject> counts;
    for (const QJsonValue &v : seed.value(QStringLiteral("by_analyzer")).toArray()) {
        const QJsonObject o = v.toObject();
        counts.insert(o.value(QStringLiteral("analyzer")).toString(), o);
    }
    const QString seedSlug = seed.value(QStringLiteral("analyzer")).toString();
    QVariantList rows;
    for (const QJsonValue &v : seed.value(QStringLiteral("budget")).toArray()) {
        const QJsonObject b = v.toObject();
        const QString slug = b.value(QStringLiteral("analyzer")).toString();
        if (slug.isEmpty())
            continue;
        QVariantMap r;
        r[QStringLiteral("slug")] = slug;
        r[QStringLiteral("enabled")] = b.value(QStringLiteral("enabled")).toBool();
        r[QStringLiteral("scope")] = b.value(QStringLiteral("scope")).toString();
        r[QStringLiteral("sampleRate")] = numOrNull(b.value(QStringLiteral("sample_rate")));
        r[QStringLiteral("camerasInScope")] = numOrNull(b.value(QStringLiteral("cameras_in_scope")));
        r[QStringLiteral("costCpuS")] = numOrNull(b.value(QStringLiteral("cost_cpu_s_per_camera_hour")));
        r[QStringLiteral("projectedCpuHoursPerDay")] = numOrNull(b.value(QStringLiteral("projected_cpu_hours_per_day")));
        const QJsonObject c = counts.value(slug);
        r[QStringLiteral("done")] = numOrNull(c.value(QStringLiteral("done")));
        r[QStringLiteral("inProgress")] = numOrNull(c.value(QStringLiteral("in_progress")));
        r[QStringLiteral("failed")] = numOrNull(c.value(QStringLiteral("failed")));
        const QJsonObject d = (slug == seedSlug) ? seed : detail.value(slug);
        r[QStringLiteral("analysable")] = numOrNull(d.value(QStringLiteral("camera_hours_analysable")));
        r[QStringLiteral("coveragePct")] = numOrNull(d.value(QStringLiteral("coverage_pct")));
        r[QStringLiteral("observations")] = numOrNull(d.value(QStringLiteral("observations_total")));
        rows.append(r);
    }
    return rows;
}

}   // namespace wtlabs
