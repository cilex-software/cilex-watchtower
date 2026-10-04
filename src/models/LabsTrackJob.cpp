#include "LabsTrackJob.h"

#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QUuid>
#include <QTimer>

namespace {
// The job's own protocol, mirrored from tools/labs/temporal_tracks_clip.py.
constexpr int kChildCancelGraceMs = 3000;
}

LabsTrackJob::LabsTrackJob(QObject *parent) : QObject(parent)
{
    // The tools tree ships in the source repository, not inside an installed
    // bundle, so resolve it from the binary's location and say plainly when it
    // is not there: an analysis that cannot find its engine is a missing
    // prerequisite, not a failure of the footage.
    const QString override = qEnvironmentVariable("WT_LABS_TOOLS");
    QStringList candidates;
    if (!override.isEmpty())
        candidates << override;
    const QString app = QCoreApplication::applicationDirPath();
    candidates << app + QStringLiteral("/../tools/labs")
               << app + QStringLiteral("/../../tools/labs");
    for (const QString &c : candidates) {
        const QString d = QFileInfo(c).absoluteFilePath();
        if (QFile::exists(d + QStringLiteral("/temporal_tracks_clip.py"))) {
            m_toolsDir = d;
            break;
        }
    }
}

LabsTrackJob::~LabsTrackJob()
{
    // Application shutdown must not orphan a decode: the child is ours alone.
    if (m_proc) {
        m_proc->kill();
        m_proc->waitForFinished(2000);
    }
}

bool LabsTrackJob::toolsAvailable() const
{
    return !m_toolsDir.isEmpty()
           && !QStandardPaths::findExecutable(QStringLiteral("python3")).isEmpty();
}

void LabsTrackJob::setState(const QString &s)
{
    if (m_state == s)
        return;
    qInfo("[TRACK] state %s -> %s (run %s)", qUtf8Printable(m_state), qUtf8Printable(s),
          qUtf8Printable(m_runId));
    m_state = s;
    emit stateChanged();
}

void LabsTrackJob::startRun(const QString &path, const QString &cameraId,
                            const QString &unitId, const QString &label,
                            double originEpochMs, const QString &configJson,
                            double maxSeconds, int maxFrames)
{
    if (m_proc) {
        m_error = tr("A tracking run is already in progress.");
        setState(QStringLiteral("failed"));
        return;
    }
    m_result = QVariantMap();
    m_error.clear();
    m_percent = 0;
    m_frames = 0;
    m_obs = 0;
    m_eps = 0;
    m_tail.clear();
    m_buf.clear();
    m_cancelAsked = false;
    m_started = false;
    m_input = path;
    m_runId = QUuid::createUuid().toString(QUuid::Id128).left(12);

    if (!toolsAvailable()) {
        m_error = m_toolsDir.isEmpty()
                      ? tr("The Labs tracking tools tree (tools/labs/temporal_tracks_clip.py) "
                           "is not beside this application binary. Run from a repository "
                           "build, or set WT_LABS_TOOLS.")
                      : tr("python3 was not found on this machine's PATH.");
        setState(QStringLiteral("missing"));
        emit progressChanged();
        return;
    }
    if (!QFileInfo::exists(path)) {
        m_error = tr("The selected recording no longer exists: %1").arg(path);
        setState(QStringLiteral("failed"));
        return;
    }

    QStringList args{ QStringLiteral("-u"),
                      m_toolsDir + QStringLiteral("/temporal_tracks_clip.py"),
                      QStringLiteral("analyze"),
                      QStringLiteral("--input"), path,
                      QStringLiteral("--run-id"), m_runId,
                      QStringLiteral("--camera-id"), cameraId.isEmpty() ? QStringLiteral("local-clip") : cameraId,
                      QStringLiteral("--unit-id"), unitId.isEmpty() ? QStringLiteral("watchtower-labs") : unitId,
                      QStringLiteral("--revision"),
#ifdef WT_GIT_SHA
                      qEnvironmentVariable("WT_LABS_REVISION", QStringLiteral(WT_GIT_SHA))
#else
                      qEnvironmentVariable("WT_LABS_REVISION", QStringLiteral("unknown"))
#endif
    };
    if (!label.isEmpty())
        args << QStringLiteral("--label") << label;
    if (originEpochMs >= 0)
        args << QStringLiteral("--origin-epoch-ms") << QString::number(qint64(originEpochMs));
    if (!configJson.isEmpty())
        args << QStringLiteral("--config") << configJson;
    if (maxSeconds > 0)
        args << QStringLiteral("--max-seconds") << QString::number(maxSeconds, 'f', 3);
    if (maxFrames > 0)
        args << QStringLiteral("--max-frames") << QString::number(maxFrames);

    m_proc = new QProcess(this);
    m_proc->setProcessChannelMode(QProcess::SeparateChannels);
    connect(m_proc, &QProcess::readyReadStandardOutput, this, [this]() { onStdout(); });
    connect(m_proc, &QProcess::readyReadStandardError, this, [this]() {
        m_tail = (m_tail + m_proc->readAllStandardError()).right(1200);
    });
    connect(m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        if (!m_proc)
            return;
        m_error = m_proc->errorString();
        const QString tail = m_tail;
        auto *p = m_proc;
        m_proc = nullptr;
        p->deleteLater();
        if (m_cancelAsked)
            setState(QStringLiteral("cancelled"));
        else {
            if (!tail.trimmed().isEmpty())
                m_error = tail.trimmed().section(QLatin1Char('\n'), -1);
            setState(QStringLiteral("failed"));
        }
    });
    connect(m_proc, &QProcess::finished, this, [this](int code, QProcess::ExitStatus st) {
        onStdout();                       // drain whatever arrived with the exit
        finishProcess(code, int(st));
    });

    setState(QStringLiteral("running"));
    m_statusLine = tr("Starting the tracking run…");
    emit progressChanged();
    m_proc->start(QStandardPaths::findExecutable(QStringLiteral("python3")), args);
}

void LabsTrackJob::cancel()
{
    qInfo("[TRACK] cancel asked (child %s)", m_proc ? "running" : "absent");
    if (!m_proc)
        return;
    m_cancelAsked = true;
    m_statusLine = tr("Cancelling…");
    emit progressChanged();
    QProcess *const doomed = m_proc;
    doomed->terminate();                  // the job reports status "cancelled" itself
    QTimer::singleShot(kChildCancelGraceMs, this, [this, doomed]() {
        // Only THIS child: a grace timer outliving its run must never kill the
        // next one (measured: it did, and the next run reported "failed").
        if (m_proc == doomed && doomed->state() != QProcess::NotRunning)
            doomed->kill();               // a decode stuck in priming still dies
    });
}

void LabsTrackJob::onStdout()
{
    if (!m_proc)
        return;
    m_buf += m_proc->readAllStandardOutput();
    int nl = 0;
    while ((nl = m_buf.indexOf('\n')) >= 0) {
        const QByteArray line = m_buf.left(nl);
        m_buf.remove(0, nl + 1);
        if (!line.trimmed().isEmpty())
            handleLine(line);
    }
}

void LabsTrackJob::handleLine(const QByteArray &line)
{
    const QJsonDocument doc = QJsonDocument::fromJson(line);
    if (!doc.isObject())
        return;                           // a stray non-JSON line is noise, not a result
    const QJsonObject o = doc.object();
    const QString kind = o.value(QStringLiteral("kind")).toString();
    if (kind == QLatin1String("progress")) {
        m_percent = o.value(QStringLiteral("percent")).toInt();
        m_frames = o.value(QStringLiteral("frame")).toInt();
        m_statusLine = tr("Frame %1 · %2 detections · %3 live tracks")
                           .arg(m_frames)
                           .arg(o.value(QStringLiteral("detections")).toInt())
                           .arg(o.value(QStringLiteral("live_tracks")).toInt());
        emit progressChanged();
    } else if (kind == QLatin1String("meta")) {
        m_started = true;
        emit stateChanged();
    } else if (kind == QLatin1String("obs")) {
        ++m_obs;
        emit progressChanged();
    } else if (kind == QLatin1String("closed")) {
        ++m_eps;
        m_statusLine = tr("Track %1 closed (%2)").arg(m_eps).arg(m_frames);
        emit progressChanged();
    } else if (kind == QLatin1String("error")) {
        m_error = o.value(QStringLiteral("message")).toString();
    } else if (kind == QLatin1String("result")) {
        m_result = o.toVariantMap();
        qInfo("[TRACK] result status=%s", qUtf8Printable(o.value(QStringLiteral("status")).toString()));
        const QString status = o.value(QStringLiteral("status")).toString();
        const int detections = o.value(QStringLiteral("counts")).toObject()
                                   .toVariantMap().value(QStringLiteral("detections")).toInt();
        if (status == QLatin1String("cancelled"))
            setState(QStringLiteral("cancelled"));
        else if (status == QLatin1String("failed")) {
            const QVariantMap e = o.value(QStringLiteral("error")).toObject().toVariantMap();
            m_error = e.value(QStringLiteral("message")).toString();
            setState(QStringLiteral("failed"));
        } else if (detections == 0)
            setState(QStringLiteral("empty"));
        else
            setState(QStringLiteral("completed"));
        emit resultChanged();
    }
}

void LabsTrackJob::finishProcess(int code, int exitStatus)
{
    qInfo("[TRACK] child finished code=%d exitStatus=%d cancelAsked=%d result=%d",
          code, exitStatus, int(m_cancelAsked), int(!m_result.isEmpty()));
    const QString tail = m_tail;
    if (m_proc) {
        m_proc->deleteLater();
        m_proc = nullptr;
        // `busy` is derived from the child's existence: re-notify even when the
        // state string did not change (the result line usually sets it first),
        // or the Run button would keep saying Cancel after the run ended.
        emit stateChanged();
    }
    if (!m_result.isEmpty()) {            // the job reported its own outcome
        if (m_state == QLatin1String("running"))
            setState(m_cancelAsked ? QStringLiteral("cancelled") : QStringLiteral("completed"));
        return;
    }
    if (m_cancelAsked) {                    // killed before it could report: still a cancel
        setState(QStringLiteral("cancelled"));
        return;
    }
    if (exitStatus != 0 || (code != 0 && code != 130)) {
        if (m_error.isEmpty())
            m_error = tail.trimmed().isEmpty()
                          ? tr("The tracking helper exited with code %1.").arg(code)
                          : tail.trimmed().section(QLatin1Char('\n'), -1);
        setState(QStringLiteral("failed"));
        return;
    }
    if (code == 130)
        setState(QStringLiteral("cancelled"));
    else
        setState(QStringLiteral("completed"));
}
