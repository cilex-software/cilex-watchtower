#include "LabsSemanticJob.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QStandardPaths>
#include <QUuid>
#include <QTimer>

namespace {
constexpr int kChildCancelGraceMs = 3000;
constexpr int kHelperTimeoutMs = 60000;
}

LabsSemanticJob::LabsSemanticJob(QObject *parent) : QObject(parent)
{
    const QString override = qEnvironmentVariable("WT_LABS_TOOLS");
    QStringList candidates;
    if (!override.isEmpty())
        candidates << override;
    const QString app = QCoreApplication::applicationDirPath();
    candidates << app + QStringLiteral("/../tools/labs")
               << app + QStringLiteral("/../../tools/labs");
    for (const QString &c : candidates) {
        const QString d = QFileInfo(c).absoluteFilePath();
        if (QFile::exists(d + QStringLiteral("/semantic_objects.py"))) {
            m_toolsDir = d;
            break;
        }
    }
    // The manifest imports the detector runtime; ask for it lazily and with a
    // generous timeout instead of blocking construction (and the first paint).
}

LabsSemanticJob::~LabsSemanticJob()
{
    if (m_proc) {
        m_proc->kill();
        m_proc->waitForFinished(2000);
    }
}

bool LabsSemanticJob::modelsAvailable() const
{
    // A direct file check, not the manifest: importing the detector runtime on a
    // cold cache takes longer than a UI-facing probe may wait, and "weights are
    // not on disk" must be answerable instantly. A weights-present-but-runtime-
    // broken box still fails honestly when a run starts (model_runtime_missing).
    const QString dir = qEnvironmentVariable("WT_LABS_MODEL_DIR",
        QStandardPaths::writableLocation(QStandardPaths::CacheLocation).isEmpty()
            ? QStringLiteral("/nonexistent")
            : QDir(QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation))
                  .filePath(QStringLiteral("watchtower-labs-models")));
    const QString xdg = QString::fromLocal8Bit(qgetenv("XDG_CACHE_HOME"));
    const QStringList dirs = { dir,
                               (xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.cache")
                                              : xdg) + QStringLiteral("/watchtower-labs-models"),
                               QDir::homePath() + QStringLiteral("/.cache/watchtower-labs-models") };
    const QStringList files = { QStringLiteral("yolo11n.pt"), QStringLiteral("yolo11s.pt") };
    for (const QString &d : dirs)
        for (const QString &f : files)
            if (QFile::exists(d + QLatin1Char('/') + f))
                return true;
    return false;
}

void LabsSemanticJob::setState(const QString &s)
{
    if (m_state == s)
        return;
    qInfo("[SEM] state %s -> %s (run %s)", qUtf8Printable(m_state), qUtf8Printable(s),
          qUtf8Printable(m_runId));
    m_state = s;
    emit stateChanged();
}

QVariantMap LabsSemanticJob::runHelper(const QStringList &args, int timeoutMs, QString *err)
{
    const QString py = QStandardPaths::findExecutable(QStringLiteral("python3"));
    if (py.isEmpty() || m_toolsDir.isEmpty()) {
        if (err) *err = tr("python3 or the Labs tools tree is not available on this machine");
        return QVariantMap();
    }
    QProcess p;
    p.setProcessChannelMode(QProcess::SeparateChannels);
    p.start(py, args);
    if (!p.waitForStarted(5000) || !p.waitForFinished(timeoutMs)) {
        p.kill();
        if (err) *err = tr("the helper did not answer within %1 s").arg(timeoutMs / 1000);
        return QVariantMap();
    }
    const QByteArray out = p.readAllStandardOutput();
    if (p.exitCode() != 0) {
        if (err) *err = QString::fromUtf8(p.readAllStandardError()).trimmed()
                            .section(QLatin1Char('\n'), -1);
        if (err && err->isEmpty())
            *err = tr("helper exited %1").arg(p.exitCode());
        return QVariantMap();
    }
    const QJsonDocument doc = QJsonDocument::fromJson(out);
    if (!doc.isObject()) {
        if (err) *err = tr("helper output was not a JSON object");
        return QVariantMap();
    }
    return doc.object().toVariantMap();
}

QString LabsSemanticJob::stage3Dir() const
{
    // The supplied neutral recordings live outside the product's own artifact
    // directories, so the location is a setting with a conventional default,
    // exactly like Artifacts' snapshot/export directories.
    QSettings st;
    const QString def = QStandardPaths::writableLocation(QStandardPaths::MoviesLocation)
                        + QStringLiteral("/Watchtower-Stage3");
    return st.value(QStringLiteral("labs/stage3dir"), def).toString();
}

void LabsSemanticJob::setStage3Dir(const QString &d)
{
    if (d.isEmpty() || d == stage3Dir())
        return;
    QSettings st;
    st.setValue(QStringLiteral("labs/stage3dir"), d);
    emit stage3DirChanged();
}

QString LabsSemanticJob::copyForVerification(const QString &path)
{
    const QFileInfo fi(path);
    if (!fi.exists())
        return QString();
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                        + QStringLiteral("/labs-semantic/verification");
    QDir().mkpath(dir);
    const QString dest = dir + QStringLiteral("/renamed-") + fi.fileName();
    QFile::remove(dest);
    return QFile::copy(path, dest) ? dest : QString();
}

void LabsSemanticJob::loadManifest()
{
    QString err;
    const QVariantMap m = runHelper({ m_toolsDir + QStringLiteral("/semantic_objects.py"),
                                      QStringLiteral("manifest") }, 180000, &err);
    if (m.isEmpty()) {
        m_manifest = QVariantMap{ { QStringLiteral("error"), err } };
    } else {
        m_manifest = m.value(QStringLiteral("manifest")).toMap().isEmpty() ? m : m_manifest;
        m_manifest = m;   // the manifest subcommand prints {"kind":"manifest", ...}
    }
    emit manifestChanged();
}

void LabsSemanticJob::startRun(const QString &path, const QVariantMap &opts)
{
    if (m_proc) {
        m_error = tr("An analysis is already running.");
        setState(QStringLiteral("failed"));
        return;
    }
    m_runDoc = QVariantMap();
    m_error.clear();
    m_percent = m_decoded = m_inferred = m_obs = 0;
    m_cancelAsked = false;
    m_buf.clear();
    m_tail.clear();
    m_runId = QUuid::createUuid().toString(QUuid::Id128).left(12);

    if (m_toolsDir.isEmpty() || QStandardPaths::findExecutable(QStringLiteral("python3")).isEmpty()) {
        m_error = tr("The Labs tools tree or python3 is not beside this application binary.");
        setState(QStringLiteral("missing"));
        return;
    }
    if (!modelsAvailable()) {
        m_error = tr("No local detector weights are installed. Expected them in %1 "
                     "(see the analyser manifest for the exact file, source, SHA-256 and licence). "
                     "A missing model is a prerequisite failure, not a no-detection result.")
                      .arg(m_manifest.value(QStringLiteral("model_dir")).toString());
        setState(QStringLiteral("missing"));
        return;
    }
    if (!QFileInfo::exists(path)) {
        m_error = tr("The selected recording no longer exists: %1").arg(path);
        setState(QStringLiteral("failed"));
        return;
    }

    const QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                         + QStringLiteral("/labs-semantic");
    QDir().mkpath(base + QStringLiteral("/runs"));
    QDir().mkpath(base + QStringLiteral("/crops/") + m_runId);
    m_runPath = base + QStringLiteral("/runs/") + m_runId + QStringLiteral(".json");

    QStringList args{ QStringLiteral("-u"),
                      m_toolsDir + QStringLiteral("/semantic_objects.py"),
                      QStringLiteral("analyze"),
                      QStringLiteral("--input"), path,
                      QStringLiteral("--clip-id"), opts.value(QStringLiteral("clipId")).toString(),
                      QStringLiteral("--run-id"), m_runId,
                      QStringLiteral("--out-run"), m_runPath,
                      QStringLiteral("--evidence-dir"), base + QStringLiteral("/crops/") + m_runId,
                      QStringLiteral("--source-revision"),
#ifdef WT_GIT_SHA
                      QStringLiteral(WT_GIT_SHA)
#else
                      QStringLiteral("unknown")
#endif
                      ,
                      QStringLiteral("--schedule"),
                      opts.value(QStringLiteral("schedule"), QStringLiteral("adaptive")).toString(),
                      QStringLiteral("--sample-fps"),
                      QString::number(opts.value(QStringLiteral("sampleFps"), 2.0).toDouble(), 'f', 2),
                      QStringLiteral("--conf"),
                      QString::number(opts.value(QStringLiteral("conf"), 0.35).toDouble(), 'f', 3),
                      QStringLiteral("--imgsz"),
                      QString::number(opts.value(QStringLiteral("imgsz"), 640).toInt()),
                      QStringLiteral("--decode-width"),
                      QString::number(opts.value(QStringLiteral("decodeWidth"), 1280).toInt()),
                      QStringLiteral("--max-frames"),
                      QString::number(opts.value(QStringLiteral("maxFrames"), 400).toInt()) };
    if (opts.value(QStringLiteral("crops"), true).toBool())
        args << QStringLiteral("--crops");
    if (!opts.value(QStringLiteral("tracks"), true).toBool())
        args << QStringLiteral("--no-tracks");
    const QString classes = opts.value(QStringLiteral("classes")).toString();
    if (!classes.isEmpty())
        args << QStringLiteral("--classes") << classes;
    const QString cam = opts.value(QStringLiteral("cameraId")).toString();
    if (!cam.isEmpty())
        args << QStringLiteral("--camera-id") << cam;
    const QString unit = opts.value(QStringLiteral("unitId")).toString();
    if (!unit.isEmpty())
        args << QStringLiteral("--unit-id") << unit;

    m_proc = new QProcess(this);
    m_proc->setProcessChannelMode(QProcess::SeparateChannels);
    connect(m_proc, &QProcess::readyReadStandardOutput, this, [this]() { onStdout(); });
    connect(m_proc, &QProcess::readyReadStandardError, this, [this]() {
        m_tail = (m_tail + m_proc->readAllStandardError()).right(1500);
    });
    connect(m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        if (!m_proc)
            return;
        m_error = m_proc->errorString();
        const QString tail = m_tail;
        auto *p = m_proc;
        m_proc = nullptr;
        p->deleteLater();
        if (!m_cancelAsked && !tail.trimmed().isEmpty())
            m_error = tail.trimmed().section(QLatin1Char('\n'), -1);
        setState(m_cancelAsked ? QStringLiteral("cancelled") : QStringLiteral("failed"));
        emit stateChanged();
    });
    connect(m_proc, &QProcess::finished, this,
            [this](int code, QProcess::ExitStatus st) { onStdout(); finishProcess(code, int(st)); });

    setState(QStringLiteral("running"));
    m_statusLine = tr("Decoding and analysing…");
    emit progressChanged();
    m_proc->start(QStandardPaths::findExecutable(QStringLiteral("python3")), args);
}

void LabsSemanticJob::cancel()
{
    qInfo("[SEM] cancel asked (child %s)", m_proc ? "running" : "absent");
    if (!m_proc)
        return;
    m_cancelAsked = true;
    m_statusLine = tr("Cancelling…");
    emit progressChanged();
    QProcess *const doomed = m_proc;
    doomed->terminate();
    QTimer::singleShot(kChildCancelGraceMs, this, [this, doomed]() {
        if (m_proc == doomed && doomed->state() != QProcess::NotRunning)
            doomed->kill();
    });
}

void LabsSemanticJob::onStdout()
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

void LabsSemanticJob::handleLine(const QByteArray &line)
{
    const QJsonDocument doc = QJsonDocument::fromJson(line);
    if (!doc.isObject())
        return;
    const QJsonObject o = doc.object();
    const QString kind = o.value(QStringLiteral("kind")).toString();
    if (kind == QLatin1String("progress")) {
        m_decoded = o.value(QStringLiteral("decoded")).toInt();
        m_inferred = o.value(QStringLiteral("inferred")).toInt();
        m_obs = o.value(QStringLiteral("observations")).toInt();
        m_percent = o.value(QStringLiteral("percent")).toInt();
        m_statusLine = tr("decoded %1 · analysed %2 · %3 objects")
                           .arg(m_decoded).arg(m_inferred).arg(m_obs);
        emit progressChanged();
    } else if (kind == QLatin1String("error")) {
        m_error = o.value(QStringLiteral("message")).toString();
    } else if (kind == QLatin1String("result")) {
        m_runPath = o.value(QStringLiteral("run_path")).toString();
        QFile f(m_runPath);
        if (f.open(QIODevice::ReadOnly)) {
            m_runDoc = QJsonDocument::fromJson(f.readAll()).object().toVariantMap();
            f.close();
        }
        const QString status = o.value(QStringLiteral("status")).toString();
        const int n = o.value(QStringLiteral("counts")).toObject()
                          .toVariantMap().value(QStringLiteral("observations")).toInt();
        if (status == QLatin1String("cancelled"))
            setState(QStringLiteral("cancelled"));
        else if (n == 0)
            setState(QStringLiteral("empty"));
        else
            setState(QStringLiteral("completed"));
        emit resultChanged();
    }
}

void LabsSemanticJob::finishProcess(int code, int exitStatus)
{
    qInfo("[SEM] child finished code=%d exitStatus=%d cancelAsked=%d haveDoc=%d",
          code, exitStatus, int(m_cancelAsked), int(!m_runDoc.isEmpty()));
    const QString tail = m_tail;
    if (m_proc) {
        m_proc->deleteLater();
        m_proc = nullptr;
        emit stateChanged();          // `busy` is derived from the child's existence
    }
    if (!m_runDoc.isEmpty()) {
        if (m_state == QLatin1String("running"))
            setState(m_cancelAsked ? QStringLiteral("cancelled") : QStringLiteral("completed"));
        return;
    }
    if (m_cancelAsked) {
        setState(QStringLiteral("cancelled"));
        return;
    }
    if (exitStatus != 0 || (code != 0 && code != 130)) {
        if (m_error.isEmpty())
            m_error = tail.trimmed().isEmpty()
                          ? tr("The analyser helper exited with code %1.").arg(code)
                          : tail.trimmed().section(QLatin1Char('\n'), -1);
        setState(QStringLiteral("failed"));
        return;
    }
    setState(QStringLiteral("completed"));
}

QVariantMap LabsSemanticJob::evaluate(const QString &runPath, const QString &clipId)
{
    QString err;
    QVariantMap m = runHelper({ m_toolsDir + QStringLiteral("/stage3_checklist.py"),
                                QStringLiteral("evaluate"),
                                QStringLiteral("--run"), runPath,
                                QStringLiteral("--clip-id"), clipId },
                              kHelperTimeoutMs, &err);
    if (m.isEmpty())
        m = QVariantMap{ { QStringLiteral("error"), err } };
    return m;
}

QVariantMap LabsSemanticJob::recordReview(const QString &runPath, const QString &clipId,
                                          const QString &reviewer, const QVariantList &decisions)
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                         + QStringLiteral("/labs-semantic/reviews");
    QDir().mkpath(base);
    const QFileInfo fi(runPath);
    const QString out = base + QStringLiteral("/") + fi.completeBaseName()
                        + QStringLiteral(".review.json");
    QString err;
    QVariantMap m = runHelper({ m_toolsDir + QStringLiteral("/stage3_checklist.py"),
                                QStringLiteral("review"),
                                QStringLiteral("--run"), runPath,
                                QStringLiteral("--clip-id"), clipId,
                                QStringLiteral("--reviewer"), reviewer,
                                QStringLiteral("--decisions"),
                                QString::fromUtf8(QJsonDocument(QJsonArray::fromVariantList(decisions))
                                                      .toJson(QJsonDocument::Compact)),
                                QStringLiteral("--out"), out },
                              kHelperTimeoutMs, &err);
    if (m.isEmpty())
        m = QVariantMap{ { QStringLiteral("error"), err } };
    m.insert(QStringLiteral("review_path"), out);
    return m;
}

QVariantMap LabsSemanticJob::statusOf(const QString &runPath, const QString &reviewPath,
                                      const QString &clipId)
{
    QString err;
    QVariantMap m = runHelper({ m_toolsDir + QStringLiteral("/stage3_checklist.py"),
                                QStringLiteral("status"),
                                QStringLiteral("--run"), runPath,
                                QStringLiteral("--review"), reviewPath,
                                QStringLiteral("--clip-id"), clipId },
                              kHelperTimeoutMs, &err);
    if (m.isEmpty())
        m = QVariantMap{ { QStringLiteral("error"), err } };
    return m;
}

QVariantMap LabsSemanticJob::controlInvalid(const QString &runPath, const QString &clipId)
{
    QString err;
    QVariantMap m = runHelper({ m_toolsDir + QStringLiteral("/stage3_checklist.py"),
                                QStringLiteral("control-invalid"),
                                QStringLiteral("--run"), runPath,
                                QStringLiteral("--clip-id"), clipId },
                              kHelperTimeoutMs, &err);
    if (m.isEmpty())
        m = QVariantMap{ { QStringLiteral("error"), err } };
    return m;
}
