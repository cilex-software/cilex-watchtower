#include "LabsTrackingController.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QDebug>

namespace {
QString findRepoRoot()
{
    QString appDir = QCoreApplication::applicationDirPath();
    QDir d(appDir);
    // If running in build/, repo root is ..
    if (QFile::exists(d.filePath(QStringLiteral("../tools/labs/run_tracking_verification.py")))) {
        return QDir(d.filePath(QStringLiteral(".."))).canonicalPath();
    }
    // Check current working directory
    if (QFile::exists(QStringLiteral("tools/labs/run_tracking_verification.py"))) {
        return QDir::currentPath();
    }
    // Fallback to project root directory
    return QStringLiteral("/home/cilex-vision/projects/cilex-watchtower-gemini");
}
}

LabsTrackingController::LabsTrackingController(QObject *parent)
    : QObject(parent)
{
    refreshSavedRuns();
}

LabsTrackingController::~LabsTrackingController()
{
    if (m_process) {
        m_process->disconnect();
        if (m_process->state() != QProcess::NotRunning) {
            m_process->terminate();
            if (!m_process->waitForFinished(500)) {
                m_process->kill();
                m_process->waitForFinished(500);
            }
        }
        delete m_process;
        m_process = nullptr;
    }
}

void LabsTrackingController::setDeliberateFailure(bool v)
{
    if (m_deliberateFailure != v) {
        m_deliberateFailure = v;
        emit deliberateFailureChanged();
    }
}

void LabsTrackingController::setRunWorkload(bool v)
{
    if (m_runWorkload != v) {
        m_runWorkload = v;
        emit runWorkloadChanged();
    }
}

void LabsTrackingController::setRecordingPath(const QString &p)
{
    if (m_recordingPath != p) {
        m_recordingPath = p;
        emit recordingPathChanged();
    }
}

QString LabsTrackingController::evidenceDirectory() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QString dir = base + QStringLiteral("/labs_tracking_evidence");
    QDir().mkpath(dir);
    return dir;
}

void LabsTrackingController::startVerification()
{
    if (m_process && m_process->state() != QProcess::NotRunning) {
        return;
    }

    m_isAnalysisMode = false;
    m_state = QStringLiteral("running");
    m_progress = 0.0;
    m_statusMessage = QStringLiteral("Running in-app temporal tracking verification…");
    m_testCases.clear();
    m_summary.clear();
    m_tracks.clear();
    m_selectedTrackIndex = -1;
    m_selectedTrack.clear();
    m_buffer.clear();

    emit stateChanged();
    emit progressChanged();
    emit statusMessageChanged();
    emit testCasesChanged();
    emit summaryChanged();
    emit tracksChanged();
    emit selectedTrackIndexChanged();
    emit selectedTrackChanged();

    if (!m_process) {
        m_process = new QProcess(this);
        connect(m_process, &QProcess::readyReadStandardOutput, this, &LabsTrackingController::onProcessReadyRead);
        connect(m_process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this, &LabsTrackingController::onProcessFinished);
        connect(m_process, &QProcess::errorOccurred, this, &LabsTrackingController::onProcessErrorOccurred);
    }

    QString repo = findRepoRoot();
    QString script = repo + QStringLiteral("/tools/labs/run_tracking_verification.py");

    QStringList args;
    args << script;
    if (m_deliberateFailure) {
        args << QStringLiteral("--failure-control");
    }
    if (!m_runWorkload) {
        args << QStringLiteral("--skip-workload");
    }

    m_process->setWorkingDirectory(repo);
    m_process->start(QStringLiteral("python3"), args);
}

void LabsTrackingController::startRecordingAnalysis(const QString &path, const QString &cameraId, const QString &unitId)
{
    if (m_process && m_process->state() != QProcess::NotRunning) {
        return;
    }

    QString targetPath = path.isEmpty() ? m_recordingPath : path;
    if (targetPath.isEmpty()) {
        m_recordingStatus = QStringLiteral("not_verified");
        m_recordingStatusNote = QStringLiteral("No recording file selected. Real-footage acceptance is NOT VERIFIED.");
        emit recordingStatusChanged();
        emit recordingStatusNoteChanged();
        return;
    }

    m_isAnalysisMode = true;
    m_state = QStringLiteral("running");
    m_progress = 0.0;
    m_recordingPath = targetPath;
    m_recordingHash.clear();
    m_recordingStatus = QStringLiteral("in_progress");
    m_recordingStatusNote = QStringLiteral("Analyzing recording…");
    m_tracks.clear();
    m_selectedTrackIndex = -1;
    m_selectedTrack.clear();
    m_buffer.clear();

    emit stateChanged();
    emit progressChanged();
    emit recordingPathChanged();
    emit recordingHashChanged();
    emit recordingStatusChanged();
    emit recordingStatusNoteChanged();
    emit tracksChanged();
    emit selectedTrackIndexChanged();
    emit selectedTrackChanged();

    if (!m_process) {
        m_process = new QProcess(this);
        connect(m_process, &QProcess::readyReadStandardOutput, this, &LabsTrackingController::onProcessReadyRead);
        connect(m_process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this, &LabsTrackingController::onProcessFinished);
        connect(m_process, &QProcess::errorOccurred, this, &LabsTrackingController::onProcessErrorOccurred);
    }

    QString repo = findRepoRoot();
    QString script = repo + QStringLiteral("/tools/labs/run_tracking_analysis.py");

    QStringList args;
    args << script << QStringLiteral("--input") << targetPath
         << QStringLiteral("--camera-id") << cameraId
         << QStringLiteral("--unit-id") << unitId;

    m_process->setWorkingDirectory(repo);
    m_process->start(QStringLiteral("python3"), args);
}

void LabsTrackingController::cancel()
{
    if (m_process && m_process->state() != QProcess::NotRunning) {
        m_process->terminate();
        if (!m_process->waitForFinished(400)) {
            m_process->kill();
            m_process->waitForFinished(400);
        }
    }
    m_state = QStringLiteral("cancelled");
    m_statusMessage = QStringLiteral("Verification cancelled by operator.");
    emit stateChanged();
    emit statusMessageChanged();
}

void LabsTrackingController::onProcessReadyRead()
{
    if (!m_process) return;
    m_buffer.append(m_process->readAllStandardOutput());

    while (true) {
        int idx = m_buffer.indexOf('\n');
        if (idx < 0) break;
        QByteArray line = m_buffer.left(idx).trimmed();
        m_buffer.remove(0, idx + 1);
        if (!line.isEmpty()) {
            parseEventLine(line);
        }
    }
}

void LabsTrackingController::parseEventLine(const QByteArray &line)
{
    QJsonParseError err;
    QJsonDocument doc = QJsonDocument::fromJson(line, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        return;
    }

    QJsonObject obj = doc.object();
    QString ev = obj.value(QStringLiteral("event")).toString();

    if (ev == QStringLiteral("test_start")) {
        QString name = obj.value(QStringLiteral("name")).toString();
        QString fam = obj.value(QStringLiteral("family")).toString();
        QVariantMap tc;
        tc[QStringLiteral("name")] = name;
        tc[QStringLiteral("family")] = fam;
        tc[QStringLiteral("status")] = QStringLiteral("running");
        tc[QStringLiteral("durationMs")] = 0;
        tc[QStringLiteral("details")] = QString();
        tc[QStringLiteral("error")] = QString();
        m_testCases.append(tc);
        emit testCasesChanged();
    } else if (ev == QStringLiteral("test_pass")) {
        QString name = obj.value(QStringLiteral("name")).toString();
        int dur = obj.value(QStringLiteral("duration_ms")).toInt();
        QString details = obj.value(QStringLiteral("details")).toString();
        for (int i = 0; i < m_testCases.size(); ++i) {
            QVariantMap tc = m_testCases[i].toMap();
            if (tc.value(QStringLiteral("name")).toString() == name) {
                tc[QStringLiteral("status")] = QStringLiteral("pass");
                tc[QStringLiteral("durationMs")] = dur;
                tc[QStringLiteral("details")] = details;
                m_testCases[i] = tc;
                break;
            }
        }
        emit testCasesChanged();
    } else if (ev == QStringLiteral("test_fail")) {
        QString name = obj.value(QStringLiteral("name")).toString();
        int dur = obj.value(QStringLiteral("duration_ms")).toInt();
        QString error = obj.value(QStringLiteral("error")).toString();
        for (int i = 0; i < m_testCases.size(); ++i) {
            QVariantMap tc = m_testCases[i].toMap();
            if (tc.value(QStringLiteral("name")).toString() == name) {
                tc[QStringLiteral("status")] = QStringLiteral("fail");
                tc[QStringLiteral("durationMs")] = dur;
                tc[QStringLiteral("error")] = error;
                m_testCases[i] = tc;
                break;
            }
        }
        emit testCasesChanged();
    } else if (ev == QStringLiteral("summary")) {
        m_summary = obj.toVariantMap();
        emit summaryChanged();
    } else if (ev == QStringLiteral("tracks_sample")) {
        m_tracks = obj.value(QStringLiteral("tracks")).toArray().toVariantList();
        if (!m_tracks.isEmpty()) {
            selectTrack(0);
        }
        emit tracksChanged();
    } else if (ev == QStringLiteral("start")) {
        m_recordingHash = obj.value(QStringLiteral("file_hash")).toString();
        emit recordingHashChanged();
    } else if (ev == QStringLiteral("status")) {
        m_recordingStatus = obj.value(QStringLiteral("status")).toString();
        m_recordingStatusNote = obj.value(QStringLiteral("error")).toString();
        emit recordingStatusChanged();
        emit recordingStatusNoteChanged();
    } else if (ev == QStringLiteral("progress")) {
        int fr = obj.value(QStringLiteral("frame")).toInt();
        int tot = obj.value(QStringLiteral("total_frames")).toInt();
        if (tot > 0) {
            m_progress = qreal(fr) / qreal(tot);
            emit progressChanged();
        }
    } else if (ev == QStringLiteral("complete")) {
        m_recordingStatus = obj.value(QStringLiteral("status")).toString();
        m_tracks = obj.value(QStringLiteral("tracks")).toArray().toVariantList();
        m_recordingStatusNote = QStringLiteral("Analysis complete: %1 tracks found.").arg(m_tracks.size());
        if (!m_tracks.isEmpty()) {
            selectTrack(0);
        }
        emit recordingStatusChanged();
        emit recordingStatusNoteChanged();
        emit tracksChanged();
    }
}

void LabsTrackingController::onProcessFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    Q_UNUSED(exitCode);
    if (m_state != QStringLiteral("cancelled")) {
        if (exitStatus == QProcess::NormalExit) {
            m_state = QStringLiteral("completed");
            m_statusMessage = m_isAnalysisMode
                ? QStringLiteral("Recording analysis finished.")
                : QStringLiteral("In-app verification completed.");
        } else {
            m_state = QStringLiteral("failed");
            m_statusMessage = QStringLiteral("Process terminated unexpectedly.");
        }
        m_progress = 1.0;
        emit stateChanged();
        emit progressChanged();
        emit statusMessageChanged();
    }
}

void LabsTrackingController::onProcessErrorOccurred(QProcess::ProcessError error)
{
    if (error == QProcess::FailedToStart) {
        m_state = QStringLiteral("failed");
        m_statusMessage = QStringLiteral("Failed to launch python3 helper process.");
        emit stateChanged();
        emit statusMessageChanged();
    }
}

void LabsTrackingController::selectTrack(int index)
{
    if (index >= 0 && index < m_tracks.size()) {
        m_selectedTrackIndex = index;
        m_selectedTrack = m_tracks[index].toMap();
    } else {
        m_selectedTrackIndex = -1;
        m_selectedTrack.clear();
    }
    emit selectedTrackIndexChanged();
    emit selectedTrackChanged();
}

void LabsTrackingController::saveEvidence(const QString &label)
{
    QString dir = evidenceDirectory();
    QString tag = label.trimmed().isEmpty() ? QStringLiteral("run") : label.trimmed();
    QString filename = QStringLiteral("%1_%2.json").arg(QDateTime::currentDateTimeUtc().toString(QStringLiteral("yyyyMMdd_hhmmss"))).arg(tag);
    QString path = dir + QStringLiteral("/") + filename;

    QJsonObject root;
    root[QStringLiteral("saved_at")] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    root[QStringLiteral("label")] = tag;
    root[QStringLiteral("state")] = m_state;
    root[QStringLiteral("summary")] = QJsonObject::fromVariantMap(m_summary);
    root[QStringLiteral("test_cases")] = QJsonArray::fromVariantList(m_testCases);
    root[QStringLiteral("tracks")] = QJsonArray::fromVariantList(m_tracks);
    root[QStringLiteral("recording_path")] = m_recordingPath;
    root[QStringLiteral("recording_hash")] = m_recordingHash;
    root[QStringLiteral("recording_status")] = m_recordingStatus;
    root[QStringLiteral("recording_status_note")] = m_recordingStatusNote;

    QFile file(path);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
        file.close();
        m_evidencePath = path;
        emit evidencePathChanged();
        refreshSavedRuns();
    }
}

void LabsTrackingController::loadEvidence(const QString &filePath)
{
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) {
        return;
    }

    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    file.close();

    if (!doc.isObject()) return;
    QJsonObject root = doc.object();

    m_summary = root.value(QStringLiteral("summary")).toObject().toVariantMap();
    m_testCases = root.value(QStringLiteral("test_cases")).toArray().toVariantList();
    m_tracks = root.value(QStringLiteral("tracks")).toArray().toVariantList();
    m_recordingPath = root.value(QStringLiteral("recording_path")).toString();
    m_recordingHash = root.value(QStringLiteral("recording_hash")).toString();
    m_recordingStatus = root.value(QStringLiteral("recording_status")).toString();
    m_recordingStatusNote = root.value(QStringLiteral("recording_status_note")).toString();
    m_state = QStringLiteral("completed");
    m_statusMessage = QStringLiteral("Loaded saved evidence from %1").arg(QFileInfo(filePath).fileName());
    m_evidencePath = filePath;

    if (!m_tracks.isEmpty()) {
        selectTrack(0);
    } else {
        selectTrack(-1);
    }

    emit summaryChanged();
    emit testCasesChanged();
    emit tracksChanged();
    emit recordingPathChanged();
    emit recordingHashChanged();
    emit recordingStatusChanged();
    emit recordingStatusNoteChanged();
    emit stateChanged();
    emit statusMessageChanged();
    emit evidencePathChanged();
}

void LabsTrackingController::refreshSavedRuns()
{
    QString dir = evidenceDirectory();
    QDir d(dir);
    QStringList files = d.entryList(QStringList() << QStringLiteral("*.json"), QDir::Files, QDir::Time);

    QVariantList list;
    for (const QString &f : files) {
        QVariantMap m;
        m[QStringLiteral("fileName")] = f;
        m[QStringLiteral("filePath")] = d.filePath(f);
        m[QStringLiteral("sizeBytes")] = QFileInfo(d.filePath(f)).size();
        list.append(m);
    }

    m_savedRuns = list;
    emit savedRunsChanged();
}
