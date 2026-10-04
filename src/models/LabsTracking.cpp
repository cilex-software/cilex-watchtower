#include "LabsTracking.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>

namespace {

const char *kRunScript = "temporal_tracks_run.py";
const char *kCheckScript = "temporal_tracks_checks.py";

QString human(int n) { return QString::number(n); }

QVariantList toList(const QJsonArray &array)
{
    QVariantList out;
    out.reserve(array.size());
    for (const QJsonValue &v : array)
        out.append(v.toVariant());
    return out;
}

// One JSONL line from a child's stdout; empty when the line is not an object.
QJsonObject lineObject(const QByteArray &line)
{
    const QJsonDocument doc = QJsonDocument::fromJson(line);
    return doc.isObject() ? doc.object() : QJsonObject();
}

}  // namespace

LabsTracking::LabsTracking(QObject *parent)
    : QObject(parent)
{
    connect(qApp, &QCoreApplication::aboutToQuit, this, &LabsTracking::stopChildren,
            Qt::UniqueConnection);
    m_killTimer.setSingleShot(true);
    connect(&m_killTimer, &QTimer::timeout, this, [this]() {
        if (m_run && m_run->state() != QProcess::NotRunning) {
            m_run->kill();
        }
    });
    refreshRuns();
}

LabsTracking::~LabsTracking()
{
    // No waiting here: by now aboutToQuit has already stopped the children. Anything
    // still alive gets SIGKILL, which needs no event loop.
    for (QProcess *p : {m_run, m_check, m_probeProc}) {
        if (p && p->state() != QProcess::NotRunning)
            p->kill();
    }
}

void LabsTracking::stopChildren()
{
    // Called with the event loop up: a cancelled analysis finalises its partial
    // evidence (SIGTERM), and anything that does not stop is killed.
    killProcess(m_run);
    killProcess(m_check);
    killProcess(m_probeProc);
    m_killTimer.stop();
}

void LabsTracking::killProcess(QProcess *&slot)
{
    // DETACH FIRST, and disconnect before waiting. `slot` aliases the member, and a
    // finished-handler (onRunFinished) sets that member to nullptr -- so waiting while
    // still holding the member would dereference null the moment the child dies inside
    // waitForFinished. Measured 2026-10-04: SIGSEGV in QProcess::waitForFinished when
    // the app was closed during a run.
    QProcess *proc = slot;
    if (!proc)
        return;
    slot = nullptr;
    disconnect(proc, nullptr, this, nullptr);
    if (proc->state() != QProcess::NotRunning) {
        proc->terminate();
        if (!proc->waitForFinished(3000)) {
            proc->kill();
            proc->waitForFinished(1000);
        }
    }
    proc->deleteLater();
}

// ----------------------------------------------------------------------------------
// Where the tools and the interpreter are. Reported when missing, never guessed.
// ----------------------------------------------------------------------------------
QString LabsTracking::toolsDir() const
{
    QStringList candidates;
    const QByteArray env = qgetenv("WT_LABS_TRACKING_TOOLS");
    if (!env.isEmpty())
        candidates << QString::fromLocal8Bit(env);
    const QString appDir = QCoreApplication::applicationDirPath();
    candidates << appDir + QStringLiteral("/../tools/labs")
               << appDir + QStringLiteral("/../../tools/labs")
               << QDir::currentPath() + QStringLiteral("/tools/labs");
    for (const QString &dir : candidates) {
        const QString path = QDir::cleanPath(dir);
        if (QFileInfo::exists(path + QLatin1Char('/') + QLatin1String(kRunScript)))
            return path;
    }
    return QString();
}

QString LabsTracking::pythonExe() const
{
    const QByteArray env = qgetenv("WT_PYTHON");
    if (!env.isEmpty())
        return QString::fromLocal8Bit(env);
    const QString found = QStandardPaths::findExecutable(QStringLiteral("python3"));
    return found.isEmpty() ? QStringLiteral("python3") : found;
}

QString LabsTracking::runsRoot() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (base.isEmpty())
        base = QDir::homePath() + QStringLiteral("/.local/share/Watchtower");
    const QString dir = base + QStringLiteral("/labs-tracking/runs");
    QDir().mkpath(dir);
    return dir;
}

// ----------------------------------------------------------------------------------
// Recordings: the product's own export directory, and any file the operator picks.
// ----------------------------------------------------------------------------------
void LabsTracking::setExportDir(const QString &dir)
{
    QString d = dir;
    if (d.startsWith(QLatin1String("file:")))
        d = QUrl(d).toLocalFile();
    if (d == m_exportDir)
        return;
    m_exportDir = d;
    refreshRecordings();
}

void LabsTracking::refreshRecordings()
{
    QVariantList out;
    const QString dir = exportDir();
    if (!dir.isEmpty()) {
        QDir d(dir);
        const QStringList filters{QStringLiteral("*.mp4"), QStringLiteral("*.mkv"),
                                  QStringLiteral("*.mov"), QStringLiteral("*.ts"),
                                  QStringLiteral("*.m4v")};
        const QFileInfoList files = d.entryInfoList(filters, QDir::Files,
                                                    QDir::Time);
        for (const QFileInfo &fi : files) {
            QVariantMap row;
            row[QStringLiteral("path")] = fi.absoluteFilePath();
            row[QStringLiteral("name")] = fi.fileName();
            row[QStringLiteral("bytes")] = double(fi.size());
            row[QStringLiteral("modified")] =
                fi.lastModified().toString(QStringLiteral("yyyy-MM-dd HH:mm"));
            row[QStringLiteral("startUtc")] = suggestStartFor(fi.absoluteFilePath(),
                                                             nullptr);
            out.append(row);
        }
    }
    m_recordings = out;
    emit recordingsChanged();
}

QString LabsTracking::suggestStartFor(const QString &path, QString *source) const
{
    // The product writes export names with QDateTime::currentDateTime(), which is
    // LOCAL time -- so the parsed stamp is local, and the source says so. Nothing
    // here claims a timezone the name does not carry.
    static const QRegularExpression stamp(
        QStringLiteral("(\\d{8})[_-](\\d{6})"));
    const QRegularExpressionMatch m = stamp.match(QFileInfo(path).fileName());
    if (!m.hasMatch())
        return QString();
    const QDateTime local = QDateTime::fromString(m.captured(1) + m.captured(2),
                                                  QStringLiteral("yyyyMMddHHmmss"));
    if (!local.isValid())
        return QString();
    if (source)
        *source = QStringLiteral("filename (local time)");
    return local.toUTC().toString(Qt::ISODate);
}

void LabsTracking::setRecording(const QString &path)
{
    QString p = path;
    if (p.startsWith(QLatin1String("file:")))
        p = QUrl(p).toLocalFile();
    if (p == m_recording)
        return;
    m_recording = p;
    m_probe.clear();
    m_errorCode.clear();
    m_errorText.clear();
    m_startSource = QStringLiteral("operator");
    if (!p.isEmpty()) {
        QString source;
        const QString suggested = suggestStartFor(p, &source);
        if (!suggested.isEmpty()) {
            m_startUtc = suggested;
            m_startSource = source;
        }
        if (m_cameraId.isEmpty() || m_cameraId == QLatin1String("recording")) {
            QString stem = QFileInfo(p).completeBaseName();
            stem.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9_.:-]")),
                         QStringLiteral("_"));
            m_cameraId = stem.left(64);
        }
    }
    emit jobChanged();
    if (!p.isEmpty())
        probeRecording();
}

QString LabsTracking::recordingName() const
{
    return m_recording.isEmpty() ? QString() : QFileInfo(m_recording).fileName();
}

void LabsTracking::setCameraId(const QString &v)
{
    if (v == m_cameraId)
        return;
    m_cameraId = v;
    emit jobChanged();
}

void LabsTracking::setUnitId(const QString &v)
{
    if (v == m_unitId)
        return;
    m_unitId = v;
    emit jobChanged();
}

void LabsTracking::setStartUtc(const QString &v)
{
    if (v == m_startUtc)
        return;
    m_startUtc = v;
    m_startSource = QStringLiteral("operator");
    emit jobChanged();
}

void LabsTracking::setMaxFrames(int v)
{
    v = qBound(10, v, 20000);
    if (v == m_maxFrames)
        return;
    m_maxFrames = v;
    emit jobChanged();
}

void LabsTracking::setStartOffsetS(int v)
{
    v = qMax(0, v);
    if (v == m_startOffsetS)
        return;
    m_startOffsetS = v;
    emit jobChanged();
}

void LabsTracking::setEngineConfig(const QVariantMap &v)
{
    if (v == m_engineConfig)
        return;
    m_engineConfig = v;
    emit jobChanged();
}

QString LabsTracking::defaultEngineConfigJson() const
{
    return QStringLiteral("{}");
}

// ----------------------------------------------------------------------------------
// Probe: the recording's own container facts (codec, size, fps). No invention.
// ----------------------------------------------------------------------------------
void LabsTracking::probeRecording()
{
    if (m_recording.isEmpty())
        return;
    const QString tools = toolsDir();
    if (tools.isEmpty()) {
        m_probe.clear();
        m_probe[QStringLiteral("ok")] = false;
        m_probe[QStringLiteral("error")] =
            QStringLiteral("tracking tools not found next to this build "
                           "(set WT_LABS_TRACKING_TOOLS)");
        emit jobChanged();
        return;
    }
    killProcess(m_probeProc);
    m_probeProc = new QProcess(this);
    connect(m_probeProc, &QProcess::finished, this,
            [this](int, QProcess::ExitStatus) { onProbeFinished(0, QProcess::NormalExit); });
    m_probeProc->setProgram(pythonExe());
    m_probeProc->setArguments({tools + QLatin1Char('/') + QLatin1String(kRunScript),
                               QStringLiteral("--probe"),
                               QStringLiteral("--recording"), m_recording,
                               QStringLiteral("--out"), runsRoot()});
    m_probeProc->start();
}

void LabsTracking::onProbeFinished(int, QProcess::ExitStatus)
{
    if (!m_probeProc)
        return;
    const QByteArray out = m_probeProc->readAllStandardOutput();
    const QJsonObject obj = QJsonDocument::fromJson(out).object();
    m_probe = obj.toVariantMap();
    if (obj.contains(QStringLiteral("suggested_start_utc")) && m_startUtc.isEmpty()) {
        m_startUtc = obj.value(QStringLiteral("suggested_start_utc")).toString();
        m_startSource = obj.value(QStringLiteral("suggested_start_source")).toString();
    }
    // The container's own metadata wins over the file name when it exists.
    const QJsonObject pr = obj.value(QStringLiteral("probe")).toObject();
    if (pr.contains(QStringLiteral("creation_time"))) {
        m_startUtc = pr.value(QStringLiteral("creation_time")).toString();
        m_startSource = QStringLiteral("file metadata");
    }
    m_probeProc->deleteLater();
    m_probeProc = nullptr;
    emit jobChanged();
}

// ----------------------------------------------------------------------------------
// The run
// ----------------------------------------------------------------------------------
void LabsTracking::setStatus(const QString &status, const QString &text)
{
    m_status = status;
    if (!text.isNull())
        m_statusText = text;
    emit stateChanged();
}

void LabsTracking::fail(const QString &code, const QString &text)
{
    m_errorCode = code;
    m_errorText = text;
    setStatus(QStringLiteral("failed"), text);
}

void LabsTracking::start()
{
    if (running())
        return;
    // A new run REPLACES the previous result: no stale tracks survive it.
    m_tracks.clear();
    m_summary.clear();
    m_sampleTimes.clear();
    m_sampleOffsets.clear();
    m_ledgerPath.clear();
    if (m_ledger.isOpen())
        m_ledger.close();
    m_hasResult = false;
    m_partial = false;
    m_errorCode.clear();
    m_errorText.clear();
    m_progress = 0.0;
    emit tracksChanged();
    emit stateChanged();

    if (m_recording.isEmpty() || !QFileInfo::exists(m_recording)) {
        fail(QStringLiteral("missing_recording"),
             m_recording.isEmpty()
                 ? QStringLiteral("Choose a recording first.")
                 : QStringLiteral("The recording is not readable: %1").arg(m_recording));
        return;
    }
    const QString tools = toolsDir();
    if (tools.isEmpty()) {
        fail(QStringLiteral("missing_tools"),
             QStringLiteral("The tracking tools are not next to this build. "
                            "Expected tools/labs/%1 (set WT_LABS_TRACKING_TOOLS).")
                 .arg(QLatin1String(kRunScript)));
        return;
    }
    const QString python = pythonExe();
    if (python.isEmpty() || (python != QLatin1String("python3")
                             && !QFileInfo::exists(python))) {
        fail(QStringLiteral("missing_python"),
             QStringLiteral("No python3 interpreter found."));
        return;
    }

    const QString stamp = QDateTime::currentDateTimeUtc()
                              .toString(QStringLiteral("yyyyMMdd-HHmmss"));
    m_runDir = runsRoot() + QLatin1Char('/') + stamp;
    QDir().mkpath(m_runDir);

    QVariantMap job;
    job[QStringLiteral("recording")] = m_recording;
    job[QStringLiteral("camera_id")] = m_cameraId.isEmpty()
        ? QStringLiteral("recording") : m_cameraId;
    job[QStringLiteral("unit_id")] = m_unitId;
    job[QStringLiteral("max_frames")] = m_maxFrames;
    job[QStringLiteral("start_offset_s")] = m_startOffsetS;
    job[QStringLiteral("recording_start_utc")] = m_startUtc;
    job[QStringLiteral("time_mapping_source")] = m_startSource;
    job[QStringLiteral("config")] = m_engineConfig;
    QFile jobFile(m_runDir + QStringLiteral("/job.json"));
    if (!jobFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        fail(QStringLiteral("run_dir"),
             QStringLiteral("Cannot write the run directory: %1").arg(m_runDir));
        return;
    }
    jobFile.write(QJsonDocument(QJsonObject::fromVariantMap(job))
                      .toJson(QJsonDocument::Indented));
    jobFile.close();

    m_run = new QProcess(this);
    m_run->setProgram(python);
    m_run->setArguments({tools + QLatin1Char('/') + QLatin1String(kRunScript),
                         QStringLiteral("--job"), m_runDir + QStringLiteral("/job.json"),
                         QStringLiteral("--out"), m_runDir});
    m_run->setProcessChannelMode(QProcess::SeparateChannels);
    connect(m_run, &QProcess::readyReadStandardOutput, this,
            &LabsTracking::onRunStdout);
    connect(m_run, &QProcess::readyReadStandardError, this,
            &LabsTracking::onRunStderr);
    connect(m_run, &QProcess::finished, this, &LabsTracking::onRunFinished);
    m_run->start();
    setStatus(QStringLiteral("running"),
              QStringLiteral("Analysing %1 — decoding with the Labs pipeline, "
                             "tracking on the contract engine.")
                  .arg(recordingName()));
    emit stateChanged();
}

void LabsTracking::onRunStdout()
{
    if (!m_run)
        return;
    const QList<QByteArray> lines = m_run->readAllStandardOutput().split('\n');
    for (const QByteArray &raw : lines) {
        const QByteArray line = raw.trimmed();
        if (line.isEmpty())
            continue;
        const QJsonObject obj = lineObject(line);
        if (obj.isEmpty())
            continue;
        const QString event = obj.value(QStringLiteral("event")).toString();
        if (event == QLatin1String("started")) {
            m_summary[QStringLiteral("recording_sha256")] =
                obj.value(QStringLiteral("sha256")).toString();
            m_summary[QStringLiteral("recording_bytes")] =
                obj.value(QStringLiteral("bytes")).toVariant();
        } else if (event == QLatin1String("progress")) {
            const int batches = obj.value(QStringLiteral("batches")).toInt();
            m_progress = m_maxFrames > 0
                ? qBound(0.0, double(batches) / double(m_maxFrames), 1.0) : 0.0;
            m_statusText = QStringLiteral("Analysing %1 — %2 frames, %3 detections, "
                                          "%4 tracks closed")
                               .arg(recordingName())
                               .arg(batches)
                               .arg(obj.value(QStringLiteral("detections")).toInt())
                               .arg(obj.value(QStringLiteral("tracks_closed")).toInt());
            emit stateChanged();
        } else if (event == QLatin1String("failed")) {
            m_errorCode = obj.value(QStringLiteral("code")).toString();
            m_errorText = obj.value(QStringLiteral("message")).toString();
        }
    }
}

void LabsTracking::onRunStderr()
{
    if (m_run)
        m_run->readAllStandardError();   // drained; failures arrive as JSON events
}

void LabsTracking::onRunFinished(int code, QProcess::ExitStatus exitStatus)
{
    if (exitStatus == QProcess::CrashExit && m_status == QLatin1String("running"))
        m_errorCode = QStringLiteral("crashed");
    const QString dir = m_runDir;
    if (m_run) {
        m_run->deleteLater();
        m_run = nullptr;
    }
    m_killTimer.stop();
    if (!dir.isEmpty())
        loadResult(dir);
    if (code == 0 && m_errorCode.isEmpty()) {
        // The summary, not the last progress line: a completed run reports what it
        // actually did, including the input's identity.
        if (!m_summary.value(QStringLiteral("empty")).toBool()) {
            const QString sha = m_summary.value(QStringLiteral("recording_sha256"))
                                    .toString();
            setStatus(QStringLiteral("completed"),
                      QStringLiteral("Analysed %1 frames of %2 — %3 detections, "
                                     "%4 tracks, %5 s. Input sha256 %6%7")
                          .arg(m_summary.value(QStringLiteral("frames")).toInt())
                          .arg(recordingName())
                          .arg(m_summary.value(QStringLiteral("detections")).toInt())
                          .arg(m_summary.value(QStringLiteral("tracks")).toInt())
                          .arg(m_summary.value(QStringLiteral("elapsed_s")).toDouble(),
                               0, 'f', 1)
                          .arg(sha.left(12))
                          .arg(m_summary.value(QStringLiteral("model_runs")).toInt() > 1
                                   ? QStringLiteral(" · the mask model was rebuilt %1×, "
                                                    "each rebuild resets tracks")
                                         .arg(m_summary.value(QStringLiteral("model_runs"))
                                                  .toInt() - 1)
                                   : QString()));
        }
    } else if (code == 3) {
        m_partial = true;
        setStatus(QStringLiteral("cancelled"),
                  QStringLiteral("Cancelled — the evidence kept so far is partial "
                                 "and is not a completed analysis."));
    } else {
        if (m_errorCode.isEmpty())
            m_errorCode = QStringLiteral("runner_exit_%1").arg(code);
        if (m_errorText.isEmpty())
            m_errorText = QStringLiteral("The analysis process exited with status %1.")
                              .arg(code);
        setStatus(QStringLiteral("failed"), m_errorText);
    }
}

void LabsTracking::cancel()
{
    if (!running())
        return;
    setStatus(QStringLiteral("cancelling"),
              QStringLiteral("Stopping the analysis…"));
    m_killTimer.start(4000);
    m_run->terminate();                 // SIGTERM: the runner finalises partial evidence
}

void LabsTracking::loadResult(const QString &dir)
{
    m_runDir = dir;
    const QFileInfo runJson(dir + QStringLiteral("/run.json"));
    if (!runJson.exists())
        return;
    QFile f(runJson.absoluteFilePath());
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonObject meta = QJsonDocument::fromJson(f.readAll()).object();
    f.close();
    m_summary = meta.toVariantMap();
    const QString status = meta.value(QStringLiteral("status")).toString();
    if (status == QLatin1String("failed")) {
        const QJsonObject err = meta.value(QStringLiteral("error")).toObject();
        m_errorCode = err.value(QStringLiteral("code")).toString();
        m_errorText = err.value(QStringLiteral("message")).toString();
    }
    if (meta.contains(QStringLiteral("recording_sha256")))
        m_summary[QStringLiteral("recording_sha256")] =
            meta.value(QStringLiteral("recording_sha256")).toString();

    m_tracks.clear();
    QFile tf(dir + QStringLiteral("/tracks.json"));
    if (tf.open(QIODevice::ReadOnly)) {
        const QJsonArray arr = QJsonDocument::fromJson(tf.readAll()).array();
        for (const QJsonValue &v : arr) {
            QVariantMap ep = v.toObject().toVariantMap();
            ep[QStringLiteral("uncertain")] =
                ep.value(QStringLiteral("ambiguous_batches")).toInt() > 0;
            const int obs = ep.value(QStringLiteral("observations")).toInt();
            const int amb = ep.value(QStringLiteral("ambiguous_batches")).toInt();
            ep[QStringLiteral("timing")] = QStringLiteral("%1 → %2 (%3 s)")
                .arg(QDateTime::fromMSecsSinceEpoch(
                         ep.value(QStringLiteral("start_ms")).toLongLong(), Qt::UTC)
                         .toString(QStringLiteral("HH:mm:ss.zzz")))
                .arg(QDateTime::fromMSecsSinceEpoch(
                         ep.value(QStringLiteral("end_ms")).toLongLong(), Qt::UTC)
                         .toString(QStringLiteral("HH:mm:ss.zzz")))
                .arg(double(ep.value(QStringLiteral("end_ms")).toLongLong()
                            - ep.value(QStringLiteral("start_ms")).toLongLong())
                     / 1000.0, 0, 'f', 2);
            ep[QStringLiteral("counts")] = QStringLiteral("%1 observed, %2 uncertain")
                                               .arg(obs).arg(amb);
            m_tracks.append(ep);
        }
        tf.close();
    }
    indexLedger(dir + QStringLiteral("/frames.jsonl"));
    m_hasResult = true;
    const int detections = meta.value(QStringLiteral("detections")).toInt();
    if (status == QLatin1String("completed") && detections == 0) {
        setStatus(QStringLiteral("completed"),
                  QStringLiteral("Completed — the selected stretch produced no "
                                 "detections, so there is nothing to track. That is "
                                 "a result, not a failure."));
        m_summary[QStringLiteral("empty")] = true;
    }
    emit tracksChanged();
    emit stateChanged();
}

void LabsTracking::indexLedger(const QString &path)
{
    m_sampleTimes.clear();
    m_sampleOffsets.clear();
    m_ledgerPath = path;
    if (m_ledger.isOpen())
        m_ledger.close();
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return;
    qint64 offset = 0;
    while (!f.atEnd()) {
        const QByteArray line = f.readLine();
        const qint64 here = offset;
        offset += line.size();
        const QByteArray trimmed = line.trimmed();
        if (trimmed.isEmpty())
            continue;
        const QJsonObject obj = lineObject(trimmed);
        if (obj.isEmpty())
            continue;
        m_sampleTimes.append(qint64(obj.value(QStringLiteral("t_ms")).toDouble()));
        m_sampleOffsets.append(here);
    }
    f.close();
    m_ledger.setFileName(path);
    m_ledger.open(QIODevice::ReadOnly);
}

QVariantMap LabsTracking::samplesAt(qint64 fileMs) const
{
    QVariantMap out;
    if (m_sampleTimes.isEmpty() || !m_ledger.isOpen()) {
        out[QStringLiteral("found")] = false;
        return out;
    }
    int lo = 0, hi = m_sampleTimes.size() - 1, best = -1;
    while (lo <= hi) {
        const int mid = (lo + hi) / 2;
        if (m_sampleTimes[mid] <= fileMs) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    if (best < 0) {
        out[QStringLiteral("found")] = false;
        out[QStringLiteral("firstMs")] = double(m_sampleTimes.first());
        return out;
    }
    QFile f(m_ledgerPath);
    if (!f.open(QIODevice::ReadOnly)) {
        out[QStringLiteral("found")] = false;
        return out;
    }
    f.seek(m_sampleOffsets[best]);
    const QJsonObject obj = lineObject(f.readLine().trimmed());
    f.close();
    out[QStringLiteral("found")] = true;
    out[QStringLiteral("t_ms")] = double(m_sampleTimes[best]);
    out[QStringLiteral("age_ms")] = double(fileMs - m_sampleTimes[best]);
    out[QStringLiteral("run")] = obj.value(QStringLiteral("run")).toInt();
    out[QStringLiteral("scored")] = obj.value(QStringLiteral("scored")).toBool();
    out[QStringLiteral("detections")] =
        toList(obj.value(QStringLiteral("detections")).toArray());
    return out;
}

QVariantList LabsTracking::trackSamples(const QString &trackId) const
{
    for (const QVariant &v : m_tracks) {
        const QVariantMap ep = v.toMap();
        if (ep.value(QStringLiteral("track_id")).toString() == trackId)
            return ep.value(QStringLiteral("path")).toList();
    }
    return {};
}

QVariantList LabsTracking::trackObservations(const QString &trackId) const
{
    // Every observed instant of one track, from the run's own ledger. This is
    // the full evidence; the episode's `path` is the contract's bounded sample.
    QVariantList out;
    QFile f(m_ledgerPath);
    if (!f.open(QIODevice::ReadOnly))
        return out;
    while (!f.atEnd()) {
        const QJsonObject row = lineObject(f.readLine().trimmed());
        if (row.isEmpty())
            continue;
        const double t = row.value(QStringLiteral("t_ms")).toDouble();
        const QJsonArray dets = row.value(QStringLiteral("detections")).toArray();
        for (const QJsonValue &d : dets) {
            const QJsonObject o = d.toObject();
            if (o.value(QStringLiteral("track_id")).toString() != trackId)
                continue;
            QVariantMap rec = o.toVariantMap();
            rec[QStringLiteral("t_ms")] = t;
            out.append(rec);
        }
    }
    return out;
}

// ----------------------------------------------------------------------------------
// Saved runs
// ----------------------------------------------------------------------------------
void LabsTracking::refreshRuns()
{
    QVariantList out;
    QDir root(runsRoot());
    const QFileInfoList dirs = root.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot,
                                                  QDir::Name | QDir::Reversed);
    for (const QFileInfo &dir : dirs) {
        QFile f(dir.absoluteFilePath() + QStringLiteral("/run.json"));
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject meta = QJsonDocument::fromJson(f.readAll()).object();
        f.close();
        QVariantMap row;
        row[QStringLiteral("dir")] = dir.absoluteFilePath();
        row[QStringLiteral("id")] = dir.fileName();
        row[QStringLiteral("status")] = meta.value(QStringLiteral("status")).toString();
        row[QStringLiteral("recording")] =
            meta.value(QStringLiteral("recording_name")).toString(
                meta.value(QStringLiteral("source_run")).toString());
        row[QStringLiteral("frames")] = meta.value(QStringLiteral("frames")).toInt();
        row[QStringLiteral("detections")] =
            meta.value(QStringLiteral("detections")).toInt();
        row[QStringLiteral("tracks")] = meta.value(QStringLiteral("tracks")).toInt();
        row[QStringLiteral("elapsed_s")] =
            meta.value(QStringLiteral("elapsed_s")).toDouble();
        row[QStringLiteral("sha256")] =
            meta.value(QStringLiteral("recording_sha256")).toString(
                meta.value(QStringLiteral("source_sha256")).toString());
        row[QStringLiteral("utc")] = meta.value(QStringLiteral("started_utc")).toString();
        out.append(row);
    }
    m_runs = out;
    emit runsChanged();
}

void LabsTracking::openRun(const QString &dir)
{
    if (running())
        return;
    loadResult(dir);
    const QVariantMap meta = m_summary;
    const QString status = meta.value(QStringLiteral("status")).toString();
    m_partial = status == QLatin1String("cancelled");
    if (status == QLatin1String("failed")) {
        setStatus(QStringLiteral("failed"),
                  meta.value(QStringLiteral("error")).toMap()
                      .value(QStringLiteral("message")).toString());
    } else if (status == QLatin1String("cancelled")) {
        setStatus(QStringLiteral("cancelled"),
                  QStringLiteral("Saved run %1 was cancelled: partial evidence, "
                                 "not a completed analysis.")
                      .arg(QFileInfo(dir).fileName()));
    } else {
        setStatus(QStringLiteral("completed"),
                  QStringLiteral("Saved run %1 reopened. Input %2…")
                      .arg(QFileInfo(dir).fileName(),
                           meta.value(QStringLiteral("recording_sha256")).toString()
                               .left(12)));
    }
    emit runsChanged();
}

// ----------------------------------------------------------------------------------
// Verification checks: the real suites, in their own process
// ----------------------------------------------------------------------------------
void LabsTracking::startChecks(const QString &group)
{
    if (checking())
        return;
    const QString tools = toolsDir();
    if (tools.isEmpty()) {
        m_checkSummary = QStringLiteral("tracking tools not found next to this build");
        emit checksChanged();
        return;
    }
    m_checks.clear();
    m_checkIndex = 0;
    m_checkSummary = QStringLiteral("running…");
    m_checkRecording = m_recording;
    emit checksChanged();
    emit stateChanged();

    const QString workdir = runsRoot() + QStringLiteral("/../checks");
    QDir().mkpath(workdir);
    m_check = new QProcess(this);
    m_check->setProgram(pythonExe());
    m_check->setArguments({tools + QLatin1Char('/') + QLatin1String(kCheckScript),
                           QStringLiteral("--group"), group,
                           QStringLiteral("--workdir"), workdir,
                           QStringLiteral("--recording"), m_recording});
    connect(m_check, &QProcess::readyReadStandardOutput, this,
            &LabsTracking::onCheckStdout);
    connect(m_check, &QProcess::finished, this, &LabsTracking::onCheckFinished);
    m_check->start();
}

void LabsTracking::onCheckStdout()
{
    if (!m_check)
        return;
    const QList<QByteArray> lines = m_check->readAllStandardOutput().split('\n');
    for (const QByteArray &raw : lines) {
        const QByteArray line = raw.trimmed();
        if (line.isEmpty())
            continue;
        const QJsonObject obj = lineObject(line);
        if (obj.isEmpty())
            continue;
        const QString event = obj.value(QStringLiteral("event")).toString();
        if (event == QLatin1String("check")) {
            QVariantMap row = obj.toVariantMap();
            row[QStringLiteral("index")] = ++m_checkIndex;
            appendCheck(row);
        } else if (event == QLatin1String("done")) {
            const int passed = obj.value(QStringLiteral("passed")).toInt();
            const int failed = obj.value(QStringLiteral("failed")).toInt();
            const int skipped = obj.value(QStringLiteral("skipped")).toInt();
            const int control = obj.value(QStringLiteral("control_failed")).toInt();
            m_checkSummary = QStringLiteral("%1 passed, %2 failed (%3 of them the "
                                            "deliberate control), %4 skipped")
                                 .arg(passed)
                                 .arg(failed - control)
                                 .arg(control)
                                 .arg(skipped);
        }
    }
}

void LabsTracking::appendCheck(const QVariantMap &row)
{
    m_checks.append(row);
    emit checksChanged();
}

void LabsTracking::onCheckFinished(int code, QProcess::ExitStatus)
{
    if (m_check) {
        m_check->deleteLater();
        m_check = nullptr;
    }
    if (m_checkSummary == QLatin1String("running…"))
        m_checkSummary = code == 0
            ? QStringLiteral("finished")
            : QStringLiteral("the check process exited with status %1").arg(code);
    emit checksChanged();
    emit stateChanged();
}

void LabsTracking::stopChecks()
{
    killProcess(m_check);
    m_checkSummary = QStringLiteral("stopped by the operator");
    emit checksChanged();
    emit stateChanged();
}
