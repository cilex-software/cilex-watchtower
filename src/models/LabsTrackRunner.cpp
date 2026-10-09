#include "LabsTrackRunner.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>

#include "LabsStation.h"        // wtlabs::stateDir()

namespace {

// One JSON document per line (the helper's verify protocol); returns false when the
// line was blank. Anything that is not JSON is ignored by the caller.
bool parseLine(const QByteArray &line, QVariantMap *out)
{
    const QByteArray t = line.trimmed();
    if (t.isEmpty()) return false;
    QJsonParseError err{};
    const QJsonDocument d = QJsonDocument::fromJson(t, &err);
    if (err.error != QJsonParseError::NoError || !d.isObject()) return false;
    *out = d.object().toVariantMap();
    return true;
}

QString isoNow()
{
    return QDateTime::currentDateTime().toString(Qt::ISODateWithMs);
}

} // namespace

LabsTrackRunner::LabsTrackRunner(QObject *parent)
    : QObject(parent)
{
    probeHelper();
    refreshRuns();
}

LabsTrackRunner::~LabsTrackRunner()
{
    // Never leave a decoder/tracker behind the closing app (the task's rule).
    killJob();
}

QString LabsTrackRunner::evidenceDir() const
{
    return QDir(wtlabs::stateDir()).filePath(QStringLiteral("track-runs"));
}

QString LabsTrackRunner::helperScript() const
{
    const QString env = qEnvironmentVariable("WT_LABS_TRACK_HELPER");
    if (!env.isEmpty()) return env;
    // Dev builds run from <repo>/build*/: the helper is at <repo>/tools/labs/.
    const QString appDir = QCoreApplication::applicationDirPath();
    const QStringList candidates = {
        appDir + QStringLiteral("/../tools/labs/track_run.py"),
        appDir + QStringLiteral("/../../tools/labs/track_run.py"),
        QDir::currentPath() + QStringLiteral("/tools/labs/track_run.py"),
    };
    for (const QString &c : candidates)
        if (QFileInfo::exists(c)) return QDir(c).canonicalPath();
    return candidates.first();
}

QString LabsTrackRunner::pythonExe() const
{
    const QString env = qEnvironmentVariable("WT_LABS_PYTHON");
    if (!env.isEmpty()) return env;
    const QString found = QStandardPaths::findExecutable(QStringLiteral("python3"));
    return found.isEmpty() ? QStringLiteral("python3") : found;
}

void LabsTrackRunner::probeHelper()
{
    const QString script = helperScript();
    if (!QFileInfo::exists(script)) {
        m_helperOk = false;
        m_helperProblem = QStringLiteral("helper not found: %1").arg(script);
        emit helperChanged();
        return;
    }
    if (pythonExe().isEmpty()) {
        m_helperOk = false;
        m_helperProblem = QStringLiteral("python3 not found on PATH");
        emit helperChanged();
        return;
    }
    // Capability probe, async like ClipTranscoder's: does this python have what
    // the pipeline needs? The answer lands on this object's thread.
    auto *probe = new QProcess(this);
    connect(probe, &QProcess::finished, this,
            [this, probe](int code, QProcess::ExitStatus) {
        m_helperOk = (code == 0);
        m_helperProblem = m_helperOk ? QString()
            : QStringLiteral("python lacks a dependency: ")
                + QString::fromUtf8(probe->readAllStandardError()).trimmed()
                      .section(QLatin1Char('\n'), -1).left(200);
        emit helperChanged();
        probe->deleteLater();
    });
    connect(probe, &QProcess::errorOccurred, this, [this, probe](QProcess::ProcessError) {
        m_helperOk = false;
        m_helperProblem = QStringLiteral("could not start python3");
        emit helperChanged();
        probe->deleteLater();
    });
    probe->start(pythonExe(), {QStringLiteral("-c"), QStringLiteral("import numpy, cv2")});
}

void LabsTrackRunner::setState(const QString &s)
{
    if (m_state == s) return;
    m_state = s;
    emit stateChanged();
}

void LabsTrackRunner::setProgress(double p, const QString &detail)
{
    m_progress = p;
    m_progressDetail = detail;
    emit progressChanged();
}

void LabsTrackRunner::setLastError(const QString &e)
{
    if (m_lastError == e) return;
    m_lastError = e;
    emit lastErrorChanged();
}

void LabsTrackRunner::startJob(Job job, const QStringList &args)
{
    killJob();
    m_cancelled = false;
    m_stderrTail.clear();
    m_stdoutBuf.clear();
    m_proc = new QProcess(this);
    m_proc->setProcessChannelMode(QProcess::SeparateChannels);
    m_proc->setProgram(pythonExe());
    m_proc->setArguments(args);

    connect(m_proc, &QProcess::readyReadStandardError, this, [this]() {
        const QString chunk = QString::fromUtf8(m_proc->readAllStandardError());
        m_stderrTail = (m_stderrTail + chunk).right(1200);
        // track_run.py progress: "WTTRACK progress <permille> <message>"
        static const QRegularExpression re(
            QStringLiteral("WTTRACK progress (-?\\d+)\\s*([^\\n]*)"));
        auto it = re.globalMatch(chunk);
        QRegularExpressionMatch last;
        while (it.hasNext()) last = it.next();
        if (last.hasMatch())
            setProgress(last.captured(1).toDouble() / 1000.0, last.captured(2).trimmed());
    });
    connect(m_proc, &QProcess::readyReadStandardOutput, this, [this]() {
        m_stdoutBuf += m_proc->readAllStandardOutput();
        if (m_job != Job::Verify) return;
        int nl;
        while ((nl = m_stdoutBuf.indexOf('\n')) >= 0) {
            const QByteArray line = m_stdoutBuf.left(nl);
            m_stdoutBuf.remove(0, nl + 1);
            QVariantMap obj;
            if (!parseLine(line, &obj)) continue;
            if (obj.value(QStringLiteral("type")).toString() == QLatin1String("summary")) {
                m_verifySummary = obj;
            } else if (obj.value(QStringLiteral("type")).toString()
                       == QLatin1String("measurement")) {
                QVariantMap row = obj;
                row.insert(QStringLiteral("status"), QStringLiteral("info"));
                row.insert(QStringLiteral("name"),
                           obj.contains(QStringLiteral("note"))
                               ? obj.value(QStringLiteral("note")).toString()
                               : QStringLiteral("measurement"));
                m_checks.append(row);
            } else {
                m_checks.append(obj);
            }
            emit checksChanged();
        }
    });
    connect(m_proc, &QProcess::finished, this,
            [this](int code, QProcess::ExitStatus st) {
        switch (m_job) {
        case Job::Probe:  finishProbe(code, st);  break;
        case Job::Run:    finishRun(code, st);    break;
        case Job::Verify: finishVerify(code, st); break;
        case Job::None:   break;
        }
    });
    connect(m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        if (!m_proc) return;
        const QString err = m_proc->errorString();
        const Job job = m_job;
        m_proc->deleteLater();
        m_proc = nullptr;
        m_job = Job::None;
        setState(QStringLiteral("idle"));
        setLastError(err.isEmpty() ? QStringLiteral("could not start the helper") : err);
        if (job == Job::Probe) emit probeFailed(m_lastError);
        else if (job == Job::Run) emit runFinished(QString(), QStringLiteral("failed"));
        else if (job == Job::Verify) emit verifyFinished(m_verifySuite, -1);
    });
    m_job = job;
    m_proc->start();
}

void LabsTrackRunner::killJob()
{
    if (!m_proc) return;
    m_cancelled = true;
    QProcess *p = m_proc;
    m_proc = nullptr;
    p->disconnect(this);
    p->kill();
    p->waitForFinished(3000);
    p->deleteLater();
    m_job = Job::None;
}

// ---------------------------------------------------------------------------
// probe
// ---------------------------------------------------------------------------
void LabsTrackRunner::probeFile(const QString &path)
{
    if (path.isEmpty()) return;
    setState(QStringLiteral("probing"));
    setLastError(QString());
    startJob(Job::Probe, {helperScript(), QStringLiteral("probe"),
                          QStringLiteral("--file"), path});
}

void LabsTrackRunner::finishProbe(int code, QProcess::ExitStatus st)
{
    const QByteArray out = m_stdoutBuf;
    const QString tail = m_stderrTail;
    QProcess *p = m_proc;
    m_proc = nullptr;
    m_job = Job::None;
    if (p) p->deleteLater();
    setState(QStringLiteral("idle"));
    QVariantMap obj;
    const QList<QByteArray> lines = out.split('\n');
    for (auto it = lines.crbegin(); it != lines.crend(); ++it)
        if (parseLine(*it, &obj)) break;
    const bool ok = (st == QProcess::NormalExit && code == 0
                     && obj.value(QStringLiteral("ok")).toBool());
    if (ok) {
        emit probeReady(obj.value(QStringLiteral("result")).toMap());
    } else {
        const QString msg = obj.value(QStringLiteral("error")).toMap()
                                .value(QStringLiteral("message")).toString();
        emit probeFailed(!msg.isEmpty() ? msg
                         : !tail.trimmed().isEmpty() ? tail.trimmed().section(QLatin1Char('\n'), -1)
                         : QStringLiteral("probe exited %1").arg(code));
    }
}

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------
void LabsTrackRunner::startRun(const QString &path, const QString &cameraId,
                               const QString &startIso, const QString &origin,
                               const QString &configJson, bool synthetic)
{
    if (state() == QLatin1String("running")) return;
    QDir().mkpath(evidenceDir());
    m_pendingOut = evidenceDir() + QStringLiteral("/inflight-%1.json")
                                       .arg(QDateTime::currentMSecsSinceEpoch());
    m_pending = QVariantMap{
        {QStringLiteral("path"), path},
        {QStringLiteral("camera_id"), cameraId},
        {QStringLiteral("start_time"), startIso},
        {QStringLiteral("origin"), origin},
        {QStringLiteral("synthetic"), synthetic},
    };
    QStringList args{helperScript(), QStringLiteral("run"),
                     QStringLiteral("--file"), path,
                     QStringLiteral("--camera"), cameraId,
                     QStringLiteral("--unit"), QStringLiteral("local-review"),
                     QStringLiteral("--start"), startIso,
                     QStringLiteral("--origin"), origin,
                     QStringLiteral("--out"), m_pendingOut};
    if (!configJson.trimmed().isEmpty())
        args << QStringLiteral("--config") << configJson;
    if (synthetic)
        args << QStringLiteral("--synthetic");
    setState(QStringLiteral("running"));
    setProgress(-1.0, QString());
    setLastError(QString());
    startJob(Job::Run, args);
}

void LabsTrackRunner::cancel()
{
    if (!m_proc || m_job != Job::Run) return;
    killJob();
    // A cancelled run is recorded AS cancelled: never completed, never silent.
    QVariantMap stub{
        {QStringLiteral("schema"), QStringLiteral("labs-track-run/v1")},
        {QStringLiteral("run_id"),
         QStringLiteral("cancelled-%1").arg(QDateTime::currentMSecsSinceEpoch())},
        {QStringLiteral("created_local"), isoNow()},
        {QStringLiteral("status"), QStringLiteral("cancelled")},
        {QStringLiteral("synthetic"), m_pending.value(QStringLiteral("synthetic"))},
        {QStringLiteral("input"), QVariantMap{{QStringLiteral("path"), m_pending.value(QStringLiteral("path"))}}},
        {QStringLiteral("scope"), QVariantMap{{QStringLiteral("camera_id"), m_pending.value(QStringLiteral("camera_id"))}}},
        {QStringLiteral("wall"), QVariantMap{{QStringLiteral("start_time"), m_pending.value(QStringLiteral("start_time"))}}},
        {QStringLiteral("assignments"), QVariantList{}},
        {QStringLiteral("episodes"), QVariantList{}},
        {QStringLiteral("stats"), QVariantMap{}},
    };
    const QString path = evidenceDir() + QStringLiteral("/%1.json")
                                             .arg(stub.value(QStringLiteral("run_id")).toString());
    QSaveFile f(path);
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(QJsonObject::fromVariantMap(stub)).toJson(QJsonDocument::Compact));
        f.commit();
    }
    QFile::remove(m_pendingOut);
    setState(QStringLiteral("idle"));
    setProgress(-1.0, QString());
    refreshRuns();
    emit runFinished(stub.value(QStringLiteral("run_id")).toString(),
                     QStringLiteral("cancelled"));
}

void LabsTrackRunner::finishRun(int code, QProcess::ExitStatus st)
{
    const QByteArray out = m_stdoutBuf;
    const QString tail = m_stderrTail;
    QProcess *p = m_proc;
    m_proc = nullptr;
    m_job = Job::None;
    if (p) p->deleteLater();
    setState(QStringLiteral("idle"));
    setProgress(-1.0, QString());

    QVariantMap obj;
    const QList<QByteArray> lines = out.split('\n');
    for (auto it = lines.crbegin(); it != lines.crend(); ++it)
        if (parseLine(*it, &obj)) break;

    const QVariantMap result = obj.value(QStringLiteral("result")).toMap();
    const QString runId = result.value(QStringLiteral("run_id")).toString();
    const QString evPath = result.value(QStringLiteral("evidence")).toString();
    const bool ok = (st == QProcess::NormalExit && code == 0
                     && obj.value(QStringLiteral("ok")).toBool() && !runId.isEmpty()
                     && QFileInfo::exists(evPath));

    QString finalId = runId;
    if (ok) {
        // Name the record by its content-addressed run id; rerunning the same
        // input and config replaces the earlier record rather than duplicating it.
        const QString named = evidenceDir() + QStringLiteral("/%1.json").arg(runId);
        QFile::remove(named);
        if (!QFile::rename(evPath, named)) {
            setLastError(QStringLiteral("could not store the run record"));
            emit runFinished(QString(), QStringLiteral("failed"));
            return;
        }
        setLastError(QString());
        refreshRuns();
        openRun(runId);
        emit runFinished(runId, QStringLiteral("completed"));
        return;
    }
    // A genuinely failed run is recorded as failed, with the helper's own words.
    QVariantMap stub = m_pending;
    const QString failId = QStringLiteral("failed-%1").arg(QDateTime::currentMSecsSinceEpoch());
    const QString msg = tail.trimmed().isEmpty()
        ? QStringLiteral("helper exited %1").arg(code)
        : tail.trimmed().section(QLatin1Char('\n'), -1);
    stub.insert(QStringLiteral("schema"), QStringLiteral("labs-track-run/v1"));
    stub.insert(QStringLiteral("run_id"), failId);
    stub.insert(QStringLiteral("created_local"), isoNow());
    stub.insert(QStringLiteral("status"), QStringLiteral("failed"));
    stub.insert(QStringLiteral("error"), msg);
    stub.insert(QStringLiteral("assignments"), QVariantList{});
    stub.insert(QStringLiteral("episodes"), QVariantList{});
    stub.insert(QStringLiteral("stats"), QVariantMap{});
    QSaveFile f(evidenceDir() + QStringLiteral("/%1.json").arg(failId));
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(QJsonObject::fromVariantMap(stub)).toJson(QJsonDocument::Compact));
        f.commit();
    }
    QFile::remove(m_pendingOut);
    setLastError(msg);
    refreshRuns();
    emit runFinished(failId, QStringLiteral("failed"));
}

// ---------------------------------------------------------------------------
// verify
// ---------------------------------------------------------------------------
void LabsTrackRunner::verify(const QString &suite, bool failureControl)
{
    if (state() == QLatin1String("verifying")) return;
    m_checks.clear();
    m_verifySummary = QVariantMap();
    m_verifySuite = suite;
    emit checksChanged();
    emit verifySummaryChanged();
    QStringList args{helperScript(), QStringLiteral("verify"),
                     QStringLiteral("--suite"), suite};
    if (failureControl)
        args << QStringLiteral("--failure-control");
    setState(QStringLiteral("verifying"));
    setProgress(-1.0, QString());
    setLastError(QString());
    startJob(Job::Verify, args);
}

void LabsTrackRunner::cancelVerify()
{
    if (!m_proc || m_job != Job::Verify) return;
    killJob();
    QVariantMap row{
        {QStringLiteral("type"), QStringLiteral("check")},
        {QStringLiteral("name"), QStringLiteral("verification cancelled by the operator")},
        {QStringLiteral("status"), QStringLiteral("skip")},
        {QStringLiteral("detail"), QStringLiteral("cancelled")},
    };
    m_checks.append(row);
    m_verifySummary = QVariantMap{{QStringLiteral("cancelled"), true}};
    setState(QStringLiteral("idle"));
    emit checksChanged();
    emit verifySummaryChanged();
}

void LabsTrackRunner::finishVerify(int code, QProcess::ExitStatus st)
{
    QProcess *p = m_proc;
    m_proc = nullptr;
    m_job = Job::None;
    if (p) p->deleteLater();
    setState(QStringLiteral("idle"));
    if (st != QProcess::NormalExit) {
        setLastError(QStringLiteral("the verification helper was stopped"));
        emit verifyFinished(m_verifySuite, -1);
        return;
    }
    if (m_verifySummary.isEmpty()) {
        // A suite that produced no summary never proves anything.
        m_verifySummary = QVariantMap{{QStringLiteral("failed"), 1},
                                      {QStringLiteral("note"),
                                       QStringLiteral("no summary line from the suite")}};
    }
    m_verifySummary.insert(QStringLiteral("exit_code"), code);
    emit verifySummaryChanged();
    emit verifyFinished(m_verifySuite,
                        m_verifySummary.value(QStringLiteral("failed"), 1).toInt());
}

// ---------------------------------------------------------------------------
// the evidence store
// ---------------------------------------------------------------------------
QVariantMap LabsTrackRunner::runSummary(const QVariantMap &ev)
{
    const QVariantMap input = ev.value(QStringLiteral("input")).toMap();
    const QVariantMap scope = ev.value(QStringLiteral("scope")).toMap();
    const QVariantMap wall = ev.value(QStringLiteral("wall")).toMap();
    const QVariantMap stats = ev.value(QStringLiteral("stats")).toMap();
    const QVariantList episodes = ev.value(QStringLiteral("episodes")).toList();
    QVariantMap s{
        {QStringLiteral("run_id"), ev.value(QStringLiteral("run_id")).toString()},
        {QStringLiteral("status"), ev.value(QStringLiteral("status")).toString()},
        {QStringLiteral("synthetic"), ev.value(QStringLiteral("synthetic")).toBool()},
        {QStringLiteral("created_local"), ev.value(QStringLiteral("created_local")).toString()},
        {QStringLiteral("path"), input.value(QStringLiteral("path")).toString()},
        {QStringLiteral("sha256"), input.value(QStringLiteral("sha256")).toString()},
        {QStringLiteral("camera_id"), scope.value(QStringLiteral("camera_id")).toString()},
        {QStringLiteral("start_time"), wall.value(QStringLiteral("start_time")).toString()},
        {QStringLiteral("end_time"), wall.value(QStringLiteral("end_time")).toString()},
        {QStringLiteral("episodes"), episodes.size()},
        {QStringLiteral("detections"), stats.value(QStringLiteral("detections")).toInt()},
        {QStringLiteral("wall_seconds"), stats.value(QStringLiteral("wall_seconds")).toDouble()},
        {QStringLiteral("error"), ev.value(QStringLiteral("error")).toString()},
    };
    int ambiguous = 0;
    for (const QVariant &e : episodes)
        ambiguous += e.toMap().value(QStringLiteral("ambiguous_batches")).toInt();
    s.insert(QStringLiteral("ambiguous_batches"), ambiguous);
    return s;
}

void LabsTrackRunner::refreshRuns()
{
    QVariantList out;
    QDir dir(evidenceDir());
    const QStringList files = dir.entryList({QStringLiteral("*.json")}, QDir::Files,
                                            QDir::Time);      // newest first
    for (const QString &name : files) {
        QFile f(dir.filePath(name));
        if (!f.open(QIODevice::ReadOnly)) continue;
        QJsonParseError err{};
        const QJsonDocument d = QJsonDocument::fromJson(f.readAll(), &err);
        if (err.error != QJsonParseError::NoError || !d.isObject()) continue;
        const QVariantMap ev = d.object().toVariantMap();
        if (ev.value(QStringLiteral("schema")).toString()
            != QLatin1String("labs-track-run/v1")) continue;
        out.append(runSummary(ev));
    }
    m_runs = out;
    emit runsChanged();
}

void LabsTrackRunner::openRun(const QString &runId)
{
    QFile f(evidenceDir() + QStringLiteral("/%1.json").arg(runId));
    if (!f.open(QIODevice::ReadOnly)) {
        setLastError(QStringLiteral("run record not found: %1").arg(runId));
        return;
    }
    QJsonParseError err{};
    const QJsonDocument d = QJsonDocument::fromJson(f.readAll(), &err);
    if (err.error != QJsonParseError::NoError || !d.isObject()) {
        setLastError(QStringLiteral("run record is unreadable"));
        return;
    }
    m_selectedRun = d.object().toVariantMap();
    setLastError(QString());
    emit selectedRunChanged();
}

void LabsTrackRunner::deleteRun(const QString &runId)
{
    QFile::remove(evidenceDir() + QStringLiteral("/%1.json").arg(runId));
    if (m_selectedRun.value(QStringLiteral("run_id")).toString() == runId) {
        m_selectedRun = QVariantMap();
        emit selectedRunChanged();
    }
    refreshRuns();
}
