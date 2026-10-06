#include "LabsDetection.h"
#include "ClipTranscoder.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>

namespace {

const char *kDetectScript = "stage3_detect.py";
const char *kEvalScript = "stage3_evaluate.py";
const char *kChecksScript = "stage3_checks.py";

QJsonObject lineObject(const QByteArray &line)
{
    const QJsonDocument doc = QJsonDocument::fromJson(line);
    return doc.isObject() ? doc.object() : QJsonObject();
}

QVariantList toList(const QJsonArray &array)
{
    QVariantList out;
    for (const QJsonValue &v : array)
        out.append(v.toVariant());
    return out;
}

}  // namespace

LabsDetection::LabsDetection(QObject *parent) : QObject(parent)
{
    connect(qApp, &QCoreApplication::aboutToQuit, this, &LabsDetection::stopChildren,
            Qt::UniqueConnection);
    m_killTimer.setSingleShot(true);
    connect(&m_killTimer, &QTimer::timeout, this, [this]() {
        if (m_run && m_run->state() != QProcess::NotRunning)
            m_run->kill();
    });
    refreshRuns();
    probeModel();
}

LabsDetection::~LabsDetection()
{
    for (QProcess *p : {m_run, m_eval, m_probeProc, m_modelProc, m_targetsProc, m_check}) {
        if (p && p->state() != QProcess::NotRunning)
            p->kill();
    }
}

void LabsDetection::killProcess(QProcess *&slot)
{
    // (No `this` use before the first disconnect: the slot is a member reference.)
    // Detach before waiting: a finished handler nulls the member, and holding the
    // member across waitForFinished is how the tracking panel crashed at shutdown
    // (fixed 2026-10-04). Same rule here.
    QProcess *proc = slot;
    if (!proc)
        return;
    slot = nullptr;
    QObject::disconnect(proc, nullptr, nullptr, nullptr);
    if (proc->state() != QProcess::NotRunning) {
        proc->terminate();
        if (!proc->waitForFinished(3000)) {
            proc->kill();
            proc->waitForFinished(1000);
        }
    }
    proc->deleteLater();
}

void LabsDetection::stopChildren()
{
    killProcess(m_run);
    killProcess(m_eval);
    killProcess(m_probeProc);
    killProcess(m_modelProc);
    killProcess(m_targetsProc);
    killProcess(m_check);
    m_killTimer.stop();
}

QString LabsDetection::toolsDir() const
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
        if (QFileInfo::exists(path + QLatin1Char('/') + QLatin1String(kDetectScript)))
            return path;
    }
    return QString();
}

QString LabsDetection::runsRoot() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (base.isEmpty())
        base = QDir::homePath() + QStringLiteral("/.local/share/Watchtower");
    const QString dir = base + QStringLiteral("/stage3/runs");
    QDir().mkpath(dir);
    return dir;
}

QString LabsDetection::stage3Dir() const
{
    // The supplied Stage 3 clips. WT_STAGE3_CLIPS first (how the coordinator
    // points any machine at the pack), then this platform's Movies directory --
    // /home/cilex-vision/... is a Linux dev box convention and does not exist on
    // a Mac, so it is only a last resort when it happens to be there.
    const QByteArray env = qgetenv("WT_STAGE3_CLIPS");
    if (!env.isEmpty())
        return QString::fromLocal8Bit(env);
    QString base = QStandardPaths::writableLocation(QStandardPaths::MoviesLocation);
    if (!base.isEmpty()) {
        const QString candidate = base + QStringLiteral("/Watchtower-Stage3");
        if (QFileInfo::exists(candidate))
            return candidate;
    }
    const QString dev = QStringLiteral("/home/cilex-vision/Videos/Watchtower-Stage3");
    return QFileInfo::exists(dev) ? dev : (base.isEmpty()
                                           ? QString()
                                           : base + QStringLiteral("/Watchtower-Stage3"));
}

bool LabsDetection::running() const
{
    return m_run && m_run->state() != QProcess::NotRunning;
}

bool LabsDetection::checking() const
{
    return m_check && m_check->state() != QProcess::NotRunning;
}

QVariantList LabsDetection::backends() const
{
    return QVariantList{
        QVariantMap{{QStringLiteral("key"), QStringLiteral("fasterrcnn-mobilenet320")},
                    {QStringLiteral("label"), QStringLiteral("Faster R-CNN MobileNetV3 320 (COCO, BSD-3)")}},
        QVariantMap{{QStringLiteral("key"), QStringLiteral("fasterrcnn-mobilenet800")},
                    {QStringLiteral("label"), QStringLiteral("Faster R-CNN MobileNetV3 800 (COCO, BSD-3, slower)")}},
        QVariantMap{{QStringLiteral("key"), QStringLiteral("ssdlite320")},
                    {QStringLiteral("label"), QStringLiteral("SSDLite MobileNetV3 320 (COCO, BSD-3, fastest)")}}};
}

// ----------------------------------------------------------------------------------
// recordings: the Stage 3 clips, the product's export folder, or any local file
// ----------------------------------------------------------------------------------
void LabsDetection::setExportDir(const QString &dir)
{
    QString d = dir;
    if (d.startsWith(QLatin1String("file:")))
        d = QUrl(d).toLocalFile();
    if (d == m_exportDir)
        return;
    m_exportDir = d;
    refreshRecordings();
}

void LabsDetection::refreshRecordings()
{
    QVariantList out;
    const QStringList dirs{m_exportDir, stage3Dir()};
    const QStringList filters{QStringLiteral("*.mp4"), QStringLiteral("*.mkv"),
                              QStringLiteral("*.mov"), QStringLiteral("*.ts")};
    for (const QString &dir : dirs) {
        if (dir.isEmpty())
            continue;
        const QFileInfoList files = QDir(dir).entryInfoList(filters, QDir::Files,
                                                            QDir::Name);
        for (const QFileInfo &fi : files) {
            QVariantMap row;
            row[QStringLiteral("path")] = fi.absoluteFilePath();
            row[QStringLiteral("name")] = fi.fileName();
            row[QStringLiteral("bytes")] = double(fi.size());
            row[QStringLiteral("modified")] =
                fi.lastModified().toString(QStringLiteral("yyyy-MM-dd HH:mm"));
            row[QStringLiteral("stage3")] = fi.absolutePath() == stage3Dir();
            out.append(row);
        }
    }
    m_recordings = out;
    emit recordingsChanged();
}

QString LabsDetection::recordingName() const
{
    return m_recording.isEmpty() ? QString() : QFileInfo(m_recording).fileName();
}

void LabsDetection::setRecording(const QString &path)
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
    // Selecting another clip CLEARS the findings on screen. S3-C05's rule is that
    // one clip's evidence is never silently shown as another's; a saved run stays
    // reachable in the Saved runs list, which is where a previous clip belongs.
    m_observations.clear();
    m_targets.clear();
    m_targetInfo.clear();
    m_evaluation.clear();
    m_decisions.clear();
    m_selected.clear();
    m_hasResult = false;
    m_partial = false;
    m_summary.clear();
    m_obsPts.clear();
    m_obsRow.clear();
    m_runDir.clear();
    emit observationsChanged();
    emit targetsChanged();
    emit selectionChanged();
    // The clip ID is IDENTITY plumbing (which annotations apply to these bytes),
    // never a detection input: the neutral names map to the supplied case IDs, and
    // any other recording gets its own stem as ID.
    static const QRegularExpression neutral(QStringLiteral("^clip-(\\d{3})$"));
    const QString stem = QFileInfo(p).completeBaseName();
    const QRegularExpressionMatch m = neutral.match(stem);
    if (m.hasMatch())
        m_clipId = QStringLiteral("WT3-") + m.captured(1);
    else if (!stem.isEmpty())
        m_clipId = stem.left(64);
    emit jobChanged();
    if (!p.isEmpty())
        probeRecording();
}

void LabsDetection::setClipId(const QString &v)
{
    if (v == m_clipId)
        return;
    m_clipId = v;
    emit jobChanged();
}

void LabsDetection::setBackend(const QString &v)
{
    if (v == m_backend)
        return;
    m_backend = v;
    emit jobChanged();
    probeModel();
}

void LabsDetection::setSampleFps(double v)
{
    v = qBound(0.1, v, 15.0);
    if (qFuzzyCompare(v, m_sampleFps))
        return;
    m_sampleFps = v;
    emit jobChanged();
}

void LabsDetection::setScoreThreshold(double v)
{
    v = qBound(0.05, v, 0.95);
    if (qFuzzyCompare(v, m_scoreThreshold))
        return;
    m_scoreThreshold = v;
    emit jobChanged();
}

void LabsDetection::probeRecording()
{
    if (m_recording.isEmpty())
        return;
    const QString tools = toolsDir();
    if (tools.isEmpty()) {
        m_probe = QVariantMap{{QStringLiteral("ok"), false},
                              {QStringLiteral("error"),
                               QStringLiteral("Stage 3 tools not found next to this build")}};
        emit jobChanged();
        return;
    }
    killProcess(m_probeProc);
    m_probeProc = new QProcess(this);
    connect(m_probeProc, &QProcess::finished, this, &LabsDetection::onProbeFinished);
    m_probeProc->setProgram(QStringLiteral("python3"));
    m_probeProc->setArguments({tools + QLatin1Char('/') + QLatin1String(kDetectScript),
                               QStringLiteral("--probe"),
                               QStringLiteral("--recording"), m_recording});
    m_probeProc->start();
}

void LabsDetection::onProbeFinished(int, QProcess::ExitStatus)
{
    if (!m_probeProc)
        return;
    const QJsonObject obj = QJsonDocument::fromJson(
        m_probeProc->readAllStandardOutput()).object();
    m_probe = obj.toVariantMap();
    m_probeProc->deleteLater();
    m_probeProc = nullptr;
    emit jobChanged();
}

void LabsDetection::probeModel()
{
    const QString tools = toolsDir();
    if (tools.isEmpty())
        return;
    killProcess(m_modelProc);
    m_modelProc = new QProcess(this);
    connect(m_modelProc, &QProcess::finished, this,
            &LabsDetection::onModelProbeFinished);
    m_modelProc->setProgram(QStringLiteral("python3"));
    m_modelProc->setArguments({tools + QLatin1Char('/') + QLatin1String(kDetectScript),
                               QStringLiteral("--check-model"),
                               QStringLiteral("--backend"), m_backend});
    m_modelProc->start();
}

void LabsDetection::onModelProbeFinished(int code, QProcess::ExitStatus)
{
    if (!m_modelProc)
        return;
    const QJsonObject obj = QJsonDocument::fromJson(
        m_modelProc->readAllStandardOutput()).object();
    m_modelState = obj.toVariantMap();
    m_modelState[QStringLiteral("ready")] = (code == 0);
    m_modelProc->deleteLater();
    m_modelProc = nullptr;
    emit jobChanged();
}

void LabsDetection::refreshModelState()
{
    probeModel();
}

// ----------------------------------------------------------------------------------
// the analysis run
// ----------------------------------------------------------------------------------
void LabsDetection::setStatus(const QString &status, const QString &text)
{
    m_status = status;
    if (!text.isNull())
        m_statusText = text;
    emit stateChanged();
}

void LabsDetection::fail(const QString &code, const QString &text)
{
    m_errorCode = code;
    m_errorText = text;
    setStatus(QStringLiteral("failed"), text);
}

void LabsDetection::start()
{
    if (running())
        return;
    // A new run REPLACES the old one: findings, targets, decisions and the review
    // binding never survive into another clip's analysis.
    m_observations.clear();
    m_targets.clear();
    m_targetInfo.clear();
    m_evaluation.clear();
    m_decisions.clear();
    m_reviewPath.clear();
    m_selected.clear();
    m_summary.clear();
    m_obsPts.clear();
    m_obsRow.clear();
    m_hasResult = false;
    m_partial = false;
    m_errorCode.clear();
    m_errorText.clear();
    m_progress = 0.0;
    emit observationsChanged();
    emit targetsChanged();
    emit selectionChanged();
    emit stateChanged();

    if (m_recording.isEmpty() || !QFileInfo::exists(m_recording)) {
        fail(QStringLiteral("missing_recording"),
             m_recording.isEmpty() ? QStringLiteral("Choose a recording first.")
                                   : QStringLiteral("The recording is not readable: %1")
                                         .arg(m_recording));
        return;
    }
    const QString tools = toolsDir();
    if (tools.isEmpty()) {
        fail(QStringLiteral("missing_tools"),
             QStringLiteral("The Stage 3 analyser tools are not next to this build."));
        return;
    }
    if (m_modelState.contains(QStringLiteral("weights_present"))
            && !m_modelState.value(QStringLiteral("weights_present")).toBool()) {
        fail(QStringLiteral("missing_model"),
             QStringLiteral("The detector weights are not present at %1. Expected "
                            "source: %2")
                 .arg(m_modelState.value(QStringLiteral("weights_path")).toString(),
                      m_modelState.value(QStringLiteral("source")).toString()));
        return;
    }

    const QString stamp = QDateTime::currentDateTimeUtc()
                              .toString(QStringLiteral("yyyyMMddTHHmmssZ"));
    m_runDir = runsRoot() + QLatin1Char('/') + m_clipId + QLatin1Char('-') + stamp;
    QDir().mkpath(m_runDir);

    QVariantMap job;
    job[QStringLiteral("recording")] = m_recording;
    job[QStringLiteral("clip_id")] = m_clipId;
    job[QStringLiteral("backend")] = m_backend;
    job[QStringLiteral("sample_fps")] = m_sampleFps;
    job[QStringLiteral("score_threshold")] = m_scoreThreshold;
    job[QStringLiteral("run_id")] = m_clipId + QLatin1Char('-') + stamp;
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
    m_run->setProgram(QStringLiteral("python3"));
    m_run->setArguments({tools + QLatin1Char('/') + QLatin1String(kDetectScript),
                         QStringLiteral("--job"), m_runDir + QStringLiteral("/job.json"),
                         QStringLiteral("--out"), m_runDir});
    // macOS ships no ffmpeg on PATH: the packaged app carries its own (LGPL,
    // built by packaging/macos/build-local.sh). Hand the analyser the very
    // binary the rest of the product uses, so the two cannot diverge, and let
    // Linux fall back to PATH when this is empty.
    const QString ffmpeg = ClipTranscoder::ffmpegProgram();
    if (!ffmpeg.isEmpty()) {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("WT_FFMPEG"), ffmpeg);
        const QFileInfo fi(ffmpeg);
        const QString probe = fi.absolutePath() + QStringLiteral("/ffprobe");
        if (QFileInfo::exists(probe))
            env.insert(QStringLiteral("WT_FFPROBE"), probe);
        m_run->setProcessEnvironment(env);
    }
    connect(m_run, &QProcess::readyReadStandardOutput, this, &LabsDetection::onRunStdout);
    connect(m_run, &QProcess::finished, this, &LabsDetection::onRunFinished);
    m_run->start();
    setStatus(QStringLiteral("running"),
              QStringLiteral("Analysing %1 with %2 — decoding with PTS, detecting "
                             "objects, sampling colours.")
                  .arg(recordingName(),
                       m_modelState.value(QStringLiteral("name")).toString()));
}

void LabsDetection::onRunStdout()
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
        if (event == QLatin1String("progress")) {
            const int decoded = obj.value(QStringLiteral("frames_decoded")).toInt();
            const int total = m_probe.value(QStringLiteral("nb_frames")).toInt();
            m_progress = total > 0 ? qBound(0.0, double(decoded) / double(total), 1.0)
                                   : 0.0;
            m_statusText = QStringLiteral("Analysing %1 — %2 frames decoded, %3 "
                                          "analysed, %4 observations")
                               .arg(recordingName())
                               .arg(decoded)
                               .arg(obj.value(QStringLiteral("inference_frames")).toInt())
                               .arg(obj.value(QStringLiteral("observations")).toInt());
            emit stateChanged();
        } else if (event == QLatin1String("observation")) {
            // Live rows while it runs: the object list fills in as frames are
            // analysed, so a long clip is reviewable before it ends.
            QVariantMap row = obj.toVariantMap();
            row[QStringLiteral("live")] = true;
            m_observations.append(row);
            emit observationsChanged();
        } else if (event == QLatin1String("failed")) {
            m_errorCode = obj.value(QStringLiteral("code")).toString();
            m_errorText = obj.value(QStringLiteral("message")).toString();
        }
    }
}

void LabsDetection::onRunFinished(int code, QProcess::ExitStatus exitStatus)
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
        loadRun(dir);
    if (code == 0 && m_errorCode.isEmpty()) {
        setStatus(QStringLiteral("completed"), QString());
    } else if (code == 3) {
        m_partial = true;
        setStatus(QStringLiteral("cancelled"),
                  QStringLiteral("Cancelled — the observations kept so far are partial "
                                 "and are not a completed analysis."));
    } else {
        if (m_errorCode.isEmpty())
            m_errorCode = QStringLiteral("analyser_exit_%1").arg(code);
        if (m_errorText.isEmpty())
            m_errorText = QStringLiteral("The analyser process exited with status %1.")
                              .arg(code);
        setStatus(QStringLiteral("failed"), m_errorText);
    }
    if (m_hasResult && m_status == QLatin1String("completed"))
        evaluateRun();
}

void LabsDetection::cancel()
{
    if (!running())
        return;
    setStatus(QStringLiteral("cancelling"), QStringLiteral("Stopping the analysis…"));
    m_killTimer.start(4000);
    m_run->terminate();
}

void LabsDetection::loadRun(const QString &dir)
{
    m_runDir = dir;
    QFile f(dir + QStringLiteral("/run.json"));
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
    indexObservations(dir + QStringLiteral("/observations.jsonl"));
    m_hasResult = true;
    emit observationsChanged();
    emit stateChanged();
}

void LabsDetection::indexObservations(const QString &path)
{
    m_observations.clear();
    m_obsPts.clear();
    m_obsRow.clear();
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return;
    while (!f.atEnd()) {
        const QByteArray line = f.readLine().trimmed();
        if (line.isEmpty())
            continue;
        const QJsonObject obj = lineObject(line);
        if (obj.isEmpty())
            continue;
        QVariantMap row = obj.toVariantMap();
        row[QStringLiteral("bbox_text")] =
            QStringLiteral("[%1, %2, %3, %4]")
                .arg(obj.value(QStringLiteral("bbox_xywh")).toArray().at(0).toDouble(), 0, 'f', 3)
                .arg(obj.value(QStringLiteral("bbox_xywh")).toArray().at(1).toDouble(), 0, 'f', 3)
                .arg(obj.value(QStringLiteral("bbox_xywh")).toArray().at(2).toDouble(), 0, 'f', 3)
                .arg(obj.value(QStringLiteral("bbox_xywh")).toArray().at(3).toDouble(), 0, 'f', 3);
        const qint64 pts = qint64(obj.value(QStringLiteral("frame_pts_ms")).toDouble());
        m_obsPts.append(pts);
        m_obsRow.append(m_observations.size());
        m_observations.append(row);
    }
}

QVariantMap LabsDetection::observationsAt(qint64 ptsMs, qint64 toleranceMs) const
{
    QVariantMap out;
    out[QStringLiteral("found")] = false;
    out[QStringLiteral("observations")] = QVariantList();
    if (m_obsPts.isEmpty())
        return out;
    int best = -1;
    for (int i = 0; i < m_obsPts.size(); ++i) {
        if (m_obsPts[i] <= ptsMs)
            best = i;
        else
            break;
    }
    if (best < 0) {
        out[QStringLiteral("first_pts_ms")] = double(m_obsPts.first());
        return out;
    }
    const qint64 t = m_obsPts[best];
    out[QStringLiteral("pts_ms")] = double(t);
    out[QStringLiteral("age_ms")] = double(ptsMs - t);
    if (ptsMs - t > toleranceMs)
        return out;                    // no observation this close: draw nothing
    QVariantList rows;
    for (int i = 0; i < m_obsPts.size(); ++i) {
        if (m_obsPts[i] != t)
            continue;
        QVariantMap row = m_observations[m_obsRow[i]].toMap();
        row[QStringLiteral("selected")] =
            row.value(QStringLiteral("id")).toString() == m_selected;
        rows.append(row);
    }
    out[QStringLiteral("found")] = true;
    out[QStringLiteral("observations")] = rows;
    return out;
}

void LabsDetection::selectObservation(const QString &id)
{
    m_selected = id;
    emit selectionChanged();
}

QVariantMap LabsDetection::selectedDetail() const
{
    for (const QVariant &v : m_observations) {
        const QVariantMap row = v.toMap();
        if (row.value(QStringLiteral("id")).toString() == m_selected) {
            QVariantMap detail = row;
            const QString crop = row.value(QStringLiteral("evidence")).toMap()
                                     .value(QStringLiteral("object_crop")).toString();
            detail[QStringLiteral("crop_path")] =
                crop.isEmpty() ? QString() : m_runDir + QLatin1Char('/') + crop;
            QVariantList regions;
            for (const QVariant &c : row.value(QStringLiteral("colors")).toList()) {
                QVariantMap region = c.toMap();
                const QString ref = region.value(QStringLiteral("evidence")).toMap()
                                        .value(QStringLiteral("region_crop")).toString();
                region[QStringLiteral("crop_path")] =
                    ref.isEmpty() ? QString() : m_runDir + QLatin1Char('/') + ref;
                regions.append(region);
            }
            detail[QStringLiteral("regions")] = regions;
            return detail;
        }
    }
    return {};
}

QVariantList LabsDetection::observationsFor(const QString &targetId) const
{
    QVariantList out;
    for (const QVariant &v : m_evaluation.value(QStringLiteral("targets")).toList()) {
        const QVariantMap row = v.toMap();
        if (row.value(QStringLiteral("target_id")).toString() != targetId)
            continue;
        const QStringList ids = [&]() {
            QStringList list;
            for (const QVariant &id : row.value(QStringLiteral("class_observation_ids")).toList())
                list << id.toString();
            return list;
        }();
        const QStringList qualifying = [&]() {
            QStringList list;
            for (const QVariant &id : row.value(QStringLiteral("qualifying_observation_ids")).toList())
                list << id.toString();
            return list;
        }();
        for (const QVariant &v2 : m_observations) {
            const QVariantMap ob = v2.toMap();
            const QString id = ob.value(QStringLiteral("id")).toString();
            if (!ids.contains(id))
                continue;
            QVariantMap item = ob;
            item[QStringLiteral("qualifying")] = qualifying.contains(id);
            out.append(item);
        }
    }
    return out;
}

// ----------------------------------------------------------------------------------
// evaluator: annotations, candidates and the reviewer's decisions
// ----------------------------------------------------------------------------------
void LabsDetection::evaluateRun()
{
    if (m_runDir.isEmpty())
        return;
    const QString tools = toolsDir();
    if (tools.isEmpty())
        return;
    killProcess(m_eval);
    const QString reviewFile = m_runDir + QStringLiteral("/review.json");
    m_reviewPath = QFileInfo::exists(reviewFile) ? reviewFile : QString();
    m_eval = new QProcess(this);
    connect(m_eval, &QProcess::finished, this, &LabsDetection::onEvalFinished);
    QStringList args{tools + QLatin1Char('/') + QLatin1String(kEvalScript),
                     QStringLiteral("--run"), m_runDir,
                     QStringLiteral("--clip-id"), m_clipId};
    if (!m_reviewPath.isEmpty())
        args << QStringLiteral("--review") << m_reviewPath;
    m_eval->setProgram(QStringLiteral("python3"));
    m_eval->setArguments(args);
    m_eval->start();
    requestTargetInfo();
}

void LabsDetection::requestTargetInfo()
{
    // Target DESCRIPTIONS come from the evaluator's annotation view, never from the
    // detector: this is the same separation the run/evaluate split enforces.
    const QString tools = toolsDir();
    if (tools.isEmpty() || m_clipId.isEmpty())
        return;
    killProcess(m_targetsProc);
    m_targetsProc = new QProcess(this);
    connect(m_targetsProc, &QProcess::finished, this, &LabsDetection::onTargetsFinished);
    m_targetsProc->setProgram(QStringLiteral("python3"));
    m_targetsProc->setArguments({tools + QLatin1Char('/') + QLatin1String(kEvalScript),
                                 QStringLiteral("--list-targets"),
                                 QStringLiteral("--clip-id"), m_clipId});
    m_targetsProc->start();
}

void LabsDetection::onTargetsFinished(int, QProcess::ExitStatus)
{
    if (!m_targetsProc)
        return;
    const QJsonObject obj = QJsonDocument::fromJson(
        m_targetsProc->readAllStandardOutput()).object();
    m_targetsProc->deleteLater();
    m_targetsProc = nullptr;
    QVariantMap info;
    for (const QJsonValue &v : obj.value(QStringLiteral("targets")).toArray()) {
        const QJsonObject t = v.toObject();
        const QString id = t.value(QStringLiteral("target_id")).toString();
        if (!id.isEmpty())
            info[id] = t.toVariantMap();
    }
    const bool changed = info != m_targetInfo;
    m_targetInfo = info;
    if (changed)
        emit targetsChanged();
}

void LabsDetection::onEvalFinished(int, QProcess::ExitStatus)
{
    if (!m_eval)
        return;
    const QByteArray out = m_eval->readAllStandardOutput();
    m_eval->deleteLater();
    m_eval = nullptr;
    QJsonParseError err{};
    const QJsonObject obj = QJsonDocument::fromJson(out, &err).object();
    if (err.error != QJsonParseError::NoError || obj.isEmpty()) {
        m_evaluation = QVariantMap{{QStringLiteral("valid"), false},
                                   {QStringLiteral("errors"),
                                    QStringList{QStringLiteral("evaluator produced no JSON")}}};
        m_targets.clear();
        emit targetsChanged();
        return;
    }
    m_evaluation = obj.toVariantMap();
    QVariantList rows;
    for (const QVariant &v : m_evaluation.value(QStringLiteral("targets")).toList()) {
        QVariantMap row = v.toMap();
        row[QStringLiteral("reviewed")] =
            row.value(QStringLiteral("status")).toString() == QLatin1String("accepted")
            || row.value(QStringLiteral("status")).toString() == QLatin1String("rejected")
            || row.value(QStringLiteral("status")).toString() == QLatin1String("unreviewable");
        rows.append(row);
    }
    m_targets = rows;
    emit targetsChanged();
}

void LabsDetection::decide(const QString &targetId, const QString &decision,
                           const QVariantList &observationIds, const QString &note)
{
    QVariantList kept;
    for (const QVariant &v : m_decisions) {
        const QVariantMap row = v.toMap();
        if (row.value(QStringLiteral("target_id")).toString() != targetId)
            kept.append(row);
    }
    QVariantMap entry;
    entry[QStringLiteral("target_id")] = targetId;
    entry[QStringLiteral("decision")] = decision;
    entry[QStringLiteral("observation_ids")] = observationIds;
    entry[QStringLiteral("note")] = note;
    kept.append(entry);
    m_decisions = kept;
    writeReviewFile();
}

void LabsDetection::clearDecisions()
{
    m_decisions.clear();
    writeReviewFile();
}

void LabsDetection::writeReviewFile()
{
    if (m_runDir.isEmpty())
        return;
    const QString reviewer = qEnvironmentVariable("WT_STAGE3_REVIEWER",
                                                   "operator (in-app reviewer)");
    QVariantMap review;
    review[QStringLiteral("run_id")] = m_summary.value(QStringLiteral("run_id"));
    review[QStringLiteral("input_sha256")] = m_summary.value(QStringLiteral("input_sha256"));
    review[QStringLiteral("run_sha256")] = m_evaluation.value(QStringLiteral("run_sha256"));
    review[QStringLiteral("reviewer")] = reviewer;
    review[QStringLiteral("targets")] = m_decisions;
    review[QStringLiteral("decided_utc")] =
        QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    QFile f(m_runDir + QStringLiteral("/review.json"));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    f.write(QJsonDocument(QJsonObject::fromVariantMap(review))
                .toJson(QJsonDocument::Indented));
    f.close();
    m_reviewPath = f.fileName();
    // The helper re-validates the review against the run hash: a decision that does
    // not bind to this evidence comes back as an explicit error, not a silent save.
    evaluateRun();
}

// ----------------------------------------------------------------------------------
// saved runs and the product checks
// ----------------------------------------------------------------------------------
void LabsDetection::refreshRuns()
{
    QVariantList out;
    const QFileInfoList dirs = QDir(runsRoot()).entryInfoList(
        QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name | QDir::Reversed);
    for (const QFileInfo &dir : dirs) {
        QFile f(dir.absoluteFilePath() + QStringLiteral("/run.json"));
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject meta = QJsonDocument::fromJson(f.readAll()).object();
        f.close();
        QVariantMap row;
        row[QStringLiteral("dir")] = dir.absoluteFilePath();
        row[QStringLiteral("id")] = dir.fileName();
        row[QStringLiteral("clip_id")] = meta.value(QStringLiteral("clip_id")).toString();
        row[QStringLiteral("status")] = meta.value(QStringLiteral("status")).toString();
        row[QStringLiteral("observations")] =
            meta.value(QStringLiteral("observations")).toArray().size();
        row[QStringLiteral("run_id")] = meta.value(QStringLiteral("run_id")).toString();
        row[QStringLiteral("sha256")] = meta.value(QStringLiteral("input_sha256")).toString();
        row[QStringLiteral("reviewed")] =
            QFileInfo::exists(dir.absoluteFilePath() + QStringLiteral("/review.json"));
        row[QStringLiteral("utc")] =
            meta.value(QStringLiteral("run_id")).toString().section('-', -1);
        out.append(row);
    }
    m_runs = out;
    emit runsChanged();
}

void LabsDetection::openRun(const QString &dir)
{
    if (running())
        return;
    m_decisions.clear();
    m_selected.clear();
    m_targets.clear();
    m_targetInfo.clear();
    m_evaluation.clear();
    loadRun(dir);
    const QVariantMap meta = m_summary;
    const QString clip = meta.value(QStringLiteral("clip_id")).toString();
    if (!clip.isEmpty())
        m_clipId = clip;
    const QString status = meta.value(QStringLiteral("status")).toString();
    m_partial = status == QLatin1String("cancelled");
    const QString digest = meta.value(QStringLiteral("input_sha256")).toString();
    if (status == QLatin1String("completed")) {
        setStatus(QStringLiteral("completed"),
                  QStringLiteral("Saved run %1 reopened — clip %2, input %3…")
                      .arg(QFileInfo(dir).fileName(), clip, digest.left(12)));
    } else if (status == QLatin1String("cancelled")) {
        setStatus(QStringLiteral("cancelled"),
                  QStringLiteral("Saved run %1 was cancelled: partial observations, "
                                 "not a completed analysis.").arg(QFileInfo(dir).fileName()));
    } else {
        setStatus(QStringLiteral("failed"),
                  QStringLiteral("Saved run %1 failed.").arg(QFileInfo(dir).fileName()));
    }
    // Reopening re-reads the reviewer's own decisions from disk and re-binds them
    // to the run hash; nothing is inherited from whatever was open before.
    QFile rf(dir + QStringLiteral("/review.json"));
    if (rf.open(QIODevice::ReadOnly)) {
        const QJsonObject review = QJsonDocument::fromJson(rf.readAll()).object();
        m_decisions = toList(review.value(QStringLiteral("targets")).toArray());
        m_reviewPath = rf.fileName();
        rf.close();
    }
    emit jobChanged();
    evaluateRun();
    emit runsChanged();
}

void LabsDetection::runChecks(const QString &group)
{
    if (checking())
        return;
    const QString tools = toolsDir();
    if (tools.isEmpty())
        return;
    m_checks.clear();
    m_checkIndex = 0;
    m_checkSummary = QStringLiteral("running…");
    emit checksChanged();
    emit stateChanged();
    const QString workdir = runsRoot() + QStringLiteral("/../checks");
    QDir().mkpath(workdir);
    m_check = new QProcess(this);
    connect(m_check, &QProcess::readyReadStandardOutput, this, &LabsDetection::onCheckStdout);
    connect(m_check, &QProcess::finished, this, &LabsDetection::onCheckFinished);
    QStringList args{tools + QLatin1Char('/') + QLatin1String(kChecksScript),
                     QStringLiteral("--group"), group,
                     QStringLiteral("--runs-dir"), runsRoot(),
                     QStringLiteral("--recordings"), stage3Dir(),
                     QStringLiteral("--workdir"), workdir};
    if (!m_recording.isEmpty())
        args << QStringLiteral("--recording") << m_recording;
    if (!m_clipId.isEmpty())
        args << QStringLiteral("--clip-id") << m_clipId;
    m_check->setProgram(QStringLiteral("python3"));
    m_check->setArguments(args);
    m_check->start();
}

void LabsDetection::onCheckStdout()
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
            m_checks.append(row);
            emit checksChanged();
        } else if (event == QLatin1String("done")) {
            const int passed = obj.value(QStringLiteral("passed")).toInt();
            const int failed = obj.value(QStringLiteral("failed")).toInt();
            const int skipped = obj.value(QStringLiteral("skipped")).toInt();
            const int control = obj.value(QStringLiteral("control_failed")).toInt();
            m_checkSummary = QStringLiteral("%1 passed, %2 failed (%3 deliberate "
                                            "control), %4 skipped")
                                 .arg(passed).arg(failed - control).arg(control)
                                 .arg(skipped);
        }
    }
}

void LabsDetection::onCheckFinished(int code, QProcess::ExitStatus)
{
    if (m_check) {
        m_check->deleteLater();
        m_check = nullptr;
    }
    if (m_checkSummary == QLatin1String("running…"))
        m_checkSummary = code == 0 ? QStringLiteral("finished")
                                   : QStringLiteral("checks exited %1").arg(code);
    emit checksChanged();
    emit stateChanged();
}

void LabsDetection::stopChecks()
{
    killProcess(m_check);
    m_checkSummary = QStringLiteral("stopped by the operator");
    emit checksChanged();
    emit stateChanged();
}
