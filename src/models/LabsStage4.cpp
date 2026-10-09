#include "LabsStage4.h"

#include "ClipTranscoder.h"

#include <QCryptographicHash>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QUrl>

#include <algorithm>
#include <cmath>

namespace {

const char *kAnalyseScript = "stage4_analyse.py";
const char *kChecksScript = "stage4_checks.py";

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

// ---- CIELAB / CIEDE2000 ------------------------------------------------------
// The same formula tools/labs/stage4_colour.py implements. The shared selftest
// runs both against the published pairs, so a divergence fails a check instead of
// quietly changing what the operator's filter means.

QVector<double> srgbToLab(const QColor &c)
{
    auto linear = [](double v) {
        v /= 255.0;
        return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4);
    };
    const double r = linear(c.red()), g = linear(c.green()), b = linear(c.blue());
    const double x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
    const double y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
    const double z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;
    auto f = [](double t) {
        const double d = 6.0 / 29.0;
        return t > d * d * d ? std::cbrt(t) : t / (3 * d * d) + 4.0 / 29.0;
    };
    const double fx = f(x / 0.95047), fy = f(y / 1.00000), fz = f(z / 1.08883);
    return {116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)};
}

double deltaE2000(const QVector<double> &a, const QVector<double> &b)
{
    const double L1 = a[0], A1 = a[1], B1 = a[2];
    const double L2 = b[0], A2 = b[1], B2 = b[2];
    const double C1 = std::hypot(A1, B1), C2 = std::hypot(A2, B2);
    const double Cbar = (C1 + C2) / 2.0;
    const double c7 = std::pow(Cbar, 7.0);
    const double G = Cbar > 0 ? 0.5 * (1 - std::sqrt(c7 / (c7 + std::pow(25.0, 7.0)))) : 0.5;
    const double A1p = (1 + G) * A1, A2p = (1 + G) * A2;
    const double C1p = std::hypot(A1p, B1), C2p = std::hypot(A2p, B2);
    auto hp = [](double ap, double bp) {
        if (ap == 0.0 && bp == 0.0)
            return 0.0;
        double ang = std::atan2(bp, ap) * 180.0 / M_PI;
        return ang < 0 ? ang + 360.0 : ang;
    };
    const double h1p = hp(A1p, B1), h2p = hp(A2p, B2);
    const double dLp = L2 - L1, dCp = C2p - C1p;
    double dhp = 0.0;
    if (C1p * C2p != 0.0) {
        dhp = h2p - h1p;
        if (dhp > 180.0)
            dhp -= 360.0;
        else if (dhp < -180.0)
            dhp += 360.0;
    }
    const double dHp = 2 * std::sqrt(C1p * C2p) * std::sin(dhp * M_PI / 360.0);
    const double Lbarp = (L1 + L2) / 2.0, Cbarp = (C1p + C2p) / 2.0;
    double hbarp = h1p + h2p;
    if (C1p * C2p != 0.0) {
        const double diff = std::fabs(h1p - h2p);
        if (diff <= 180.0)
            hbarp = (h1p + h2p) / 2.0;
        else if (h1p + h2p < 360.0)
            hbarp = (h1p + h2p + 360.0) / 2.0;
        else
            hbarp = (h1p + h2p - 360.0) / 2.0;
    }
    const double T = 1 - 0.17 * std::cos((hbarp - 30.0) * M_PI / 180.0)
                     + 0.24 * std::cos(2 * hbarp * M_PI / 180.0)
                     + 0.32 * std::cos((3 * hbarp + 6.0) * M_PI / 180.0)
                     - 0.20 * std::cos((4 * hbarp - 63.0) * M_PI / 180.0);
    const double dtheta = 30.0 * std::exp(-std::pow((hbarp - 275.0) / 25.0, 2.0));
    const double c7b = std::pow(Cbarp, 7.0);
    const double Rc = Cbarp > 0 ? 2 * std::sqrt(c7b / (c7b + std::pow(25.0, 7.0))) : 0.0;
    const double Sl = 1 + (0.015 * std::pow(Lbarp - 50.0, 2.0))
                              / std::sqrt(20.0 + std::pow(Lbarp - 50.0, 2.0));
    const double Sc = 1 + 0.045 * Cbarp, Sh = 1 + 0.015 * Cbarp * T;
    const double Rt = -std::sin(2 * dtheta * M_PI / 180.0) * Rc;
    return std::sqrt(std::pow(dLp / Sl, 2.0) + std::pow(dCp / Sc, 2.0)
                     + std::pow(dHp / Sh, 2.0) + Rt * (dCp / Sc) * (dHp / Sh));
}

// The query vocabulary ("upper clothing") and the wire region names
// (`upper_clothing`) are different spellings of one thing.
QStringList regionsForLocation(const QString &location)
{
    const QString l = location.trimmed().toLower();
    if (l.isEmpty())
        return {};
    if (l == "upper" || l == "upper_clothing" || l == "upper clothing")
        return {QStringLiteral("upper_clothing")};
    if (l == "lower" || l == "lower_clothing" || l == "lower clothing")
        return {QStringLiteral("lower_clothing")};
    if (l == "either" || l == "either_clothing" || l == "either clothing")
        return {QStringLiteral("upper_clothing"), QStringLiteral("lower_clothing")};
    if (l == "body" || l == "vehicle_body")
        return {QStringLiteral("vehicle_body")};
    if (l == "coat" || l == "coat/body")
        return {QStringLiteral("coat")};
    return {location};
}

QStringList defaultRegionsForClass(const QString &cls)
{
    if (cls == QLatin1String("human"))
        return {QStringLiteral("upper_clothing"), QStringLiteral("lower_clothing")};
    if (cls == QLatin1String("car"))
        return {QStringLiteral("vehicle_body")};
    if (cls == QLatin1String("animal"))
        return {QStringLiteral("coat")};
    return {};
}

QString checkedDir(const QString &path)
{
    const QFileInfo info(path);
    return info.isDir() ? info.absoluteFilePath() : QString();
}

}  // namespace

LabsStage4::LabsStage4(QObject *parent) : QObject(parent)
{
    connect(qApp, &QCoreApplication::aboutToQuit, this, [this]() {
        killProcess(m_run);
        killProcess(m_checksProc);
    });
    m_killTimer.setSingleShot(true);
    connect(&m_killTimer, &QTimer::timeout, this, [this]() {
        if (m_run && m_run->state() != QProcess::NotRunning)
            m_run->kill();
    });
    m_approaches = QVariantList{
        QVariantMap{{QStringLiteral("id"), QStringLiteral("A")},
                    {QStringLiteral("label"), QStringLiteral("A — trained from scratch")},
                    {QStringLiteral("detail"),
                     QStringLiteral("random initialization, 331k parameters, no "
                                    "pretrained weights anywhere")}},
        QVariantMap{{QStringLiteral("id"), QStringLiteral("B")},
                    {QStringLiteral("label"),
                     QStringLiteral("B — ResNet-18 trunk + trained head")},
                    {QStringLiteral("detail"),
                     QStringLiteral("frozen ImageNet ResNet-18 features (not used in "
                                    "Stage 3, not YOLO); head and laterals trained on "
                                    "the released data")}},
    };
    refreshRecordings();
    refreshRuns();
}

LabsStage4::~LabsStage4()
{
    if (m_run && m_run->state() != QProcess::NotRunning)
        m_run->kill();
    if (m_checksProc && m_checksProc->state() != QProcess::NotRunning)
        m_checksProc->kill();
}

QString LabsStage4::toolsDir() const
{
    const QString appDir = QCoreApplication::applicationDirPath();
    const QStringList candidates{
        appDir + QStringLiteral("/tools/labs"),
        appDir + QStringLiteral("/../tools/labs"),
        appDir + QStringLiteral("/../../tools/labs"),
        QDir::currentPath() + QStringLiteral("/tools/labs"),
    };
    for (const QString &c : candidates) {
        if (QFileInfo::exists(c + QStringLiteral("/stage4_analyse.py")))
            return QFileInfo(c).absoluteFilePath();
    }
    return {};
}

QString LabsStage4::pythonExe() const
{
    const QByteArray env = qgetenv("WT_PYTHON");
    if (!env.isEmpty())
        return QString::fromLocal8Bit(env);
    return QStringLiteral("python3");
}

QString LabsStage4::clipsDir() const
{
    const QByteArray env = qgetenv("WT_STAGE4_CLIPS");
    if (!env.isEmpty())
        return QString::fromLocal8Bit(env);
    QString base = QStandardPaths::writableLocation(QStandardPaths::MoviesLocation);
    if (!base.isEmpty()) {
        const QString candidate = base + QStringLiteral("/Watchtower-Stage4/clips");
        if (QFileInfo::exists(candidate))
            return candidate;
    }
    const QString dev = QStringLiteral("/home/cilex-vision/Videos/Watchtower-Stage4/clips");
    if (QFileInfo::exists(dev))
        return dev;
    return base.isEmpty() ? QString() : base + QStringLiteral("/Watchtower-Stage4/clips");
}

QString LabsStage4::runsDir() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (base.isEmpty())
        base = QDir::homePath() + QStringLiteral("/.local/share/Cilex Vision/Watchtower");
    const QString dir = base + QStringLiteral("/stage4/runs");
    QDir().mkpath(dir);
    return dir;
}

void LabsStage4::refreshRecordings()
{
    QVariantList out;
    const QString dir = clipsDir();
    if (!dir.isEmpty()) {
        const QFileInfoList files = QDir(dir).entryInfoList(
            {QStringLiteral("*.mp4"), QStringLiteral("*.mkv"), QStringLiteral("*.mov")},
            QDir::Files, QDir::Name);
        for (const QFileInfo &fi : files) {
            out.append(QVariantMap{
                {QStringLiteral("path"), fi.absoluteFilePath()},
                {QStringLiteral("name"), fi.fileName()},
                {QStringLiteral("size"), fi.size()},
                {QStringLiteral("modified"),
                 fi.lastModified().toUTC().toString(Qt::ISODate)}});
        }
    }
    m_recordings = out;
    if (m_recording.isEmpty() && !out.isEmpty())
        setRecording(out.first().toMap().value(QStringLiteral("path")).toString());
    emit recordingsChanged();
}

void LabsStage4::setRecording(const QString &path)
{
    if (m_recording == path)
        return;
    m_recording = path;
    m_probe.clear();
    // Switching input must not leave the previous video's objects on screen under
    // the new video's name: the run identity changes, so the result goes with it.
    m_observations.clear();
    m_summary.clear();
    m_metrics.clear();
    m_selected.clear();
    m_errorText.clear();
    m_runDir.clear();
    // ... and neither may the previous video's playback identity, observation
    // timestamps or overlay, or a stale result from a process still running
    // (R2 finding 2: those three survived an input switch in R1).
    m_videoPath.clear();
    m_obsPts.clear();
    m_runState.clear();
    ++m_generation;
    emit jobChanged();
    emit resultChanged();
    emit selectionChanged();
    if (!path.isEmpty())
        probeRecording();
}

QString LabsStage4::recordingName() const
{
    return m_recording.isEmpty() ? QString() : QFileInfo(m_recording).fileName();
}

void LabsStage4::setApproach(const QString &a)
{
    const QString v = a.trimmed().toUpper();
    if (v != QLatin1String("A") && v != QLatin1String("B"))
        return;
    if (m_approach == v)
        return;
    m_approach = v;
    // A different model means a different run: drop rows + crops from the other
    // approach instead of showing them under the new model's name.
    m_observations.clear();
    m_summary.clear();
    m_metrics.clear();
    m_selected.clear();
    m_runDir.clear();
    m_videoPath.clear();
    m_obsPts.clear();
    m_runState.clear();
    m_errorText.clear();
    m_revisionState = registryRevision(m_approach);
    ++m_generation;
    emit jobChanged();
    emit resultChanged();
    emit selectionChanged();
}

QString LabsStage4::revisionsFile() const
{
    const QByteArray env = qgetenv("WT_STAGE4_REVISIONS");
    if (!env.isEmpty())
        return QString::fromLocal8Bit(env);
    const QString appDir = QCoreApplication::applicationDirPath();
    const QStringList candidates{
        appDir + QStringLiteral("/../../build/stage4/revisions.json"),
        appDir + QStringLiteral("/../build/stage4/revisions.json"),
        QDir::currentPath() + QStringLiteral("/build/stage4/revisions.json"),
    };
    for (const QString &c : candidates) {
        if (QFileInfo::exists(c))
            return QFileInfo(c).absoluteFilePath();
    }
    return {};
}

QString LabsStage4::sha256Of(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file))
        return {};
    return QString::fromLatin1(hash.result().toHex());
}

QString LabsStage4::checkpointFor(const QString &approach) const
{
    // The ONE resolver. It reads the registry the tools also read and never
    // substitutes another revision: an R1 selection whose file is missing or whose
    // hash differs is an explicit failure, not a quiet fall back to R0 (R2 finding 1).
    QVariantMap registry = registryRevision(approach);
    if (!registry.value(QStringLiteral("usable")).toBool())
        return {};
    return registry.value(QStringLiteral("checkpoint")).toString();
}

QVariantMap LabsStage4::registryRevision(const QString &approach) const
{
    QVariantMap out{{QStringLiteral("revision"), QString()},
                    {QStringLiteral("label"), QString()},
                    {QStringLiteral("checkpoint"), QString()},
                    {QStringLiteral("checkpoint_sha256"), QString()},
                    {QStringLiteral("verified"), false},
                    {QStringLiteral("usable"), false},
                    {QStringLiteral("registry"), revisionsFile()},
                    {QStringLiteral("message"), QString()}};
    const QString reg = revisionsFile();
    if (reg.isEmpty()) {
        out.insert(QStringLiteral("message"),
                   QStringLiteral("no revisions.json found — the Stage 4 artifact "
                                  "registry is required; nothing is selected by guesswork"));
        return out;
    }
    QFile file(reg);
    if (!file.open(QIODevice::ReadOnly)) {
        out.insert(QStringLiteral("message"),
                   QStringLiteral("revisions.json could not be read at %1").arg(reg));
        return out;
    }
    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    file.close();
    const QByteArray envRev = qgetenv("WT_STAGE4_REVISION");
    const QString selected = envRev.isEmpty()
                                 ? root.value(QStringLiteral("selected")).toString()
                                 : QString::fromLocal8Bit(envRev).toLower();
    const QJsonObject rev = root.value(QStringLiteral("revisions")).toObject()
                                .value(selected).toObject();
    if (rev.isEmpty()) {
        out.insert(QStringLiteral("message"),
                   QStringLiteral("revision %1 is not in the registry").arg(selected));
        out.insert(QStringLiteral("revision"), selected);
        return out;
    }
    const QJsonObject spec = rev.value(QStringLiteral("approaches")).toObject()
                                 .value(approach).toObject();
    out.insert(QStringLiteral("revision"), selected);
    out.insert(QStringLiteral("label"), rev.value(QStringLiteral("label")).toString());
    out.insert(QStringLiteral("architecture"),
               spec.value(QStringLiteral("architecture")).toString());
    out.insert(QStringLiteral("role"), rev.value(QStringLiteral("status")).toString());
    QString path = spec.value(QStringLiteral("checkpoint")).toString();
    QString onnx = spec.value(QStringLiteral("onnx")).toString();
    const QString expected = spec.value(QStringLiteral("checkpoint_sha256")).toString();
    if (path.isEmpty() || !QFileInfo::exists(path)) {
        out.insert(QStringLiteral("message"),
                   QStringLiteral("revision %1 approach %2: checkpoint %3 does not exist — "
                                  "a missing model is a prerequisite failure, never an "
                                  "empty result, and never a fallback to another revision")
                       .arg(selected, approach, path));
        return out;
    }
    const QFileInfo fi(path);
    const QString actual = (m_hashCache.value(path + QLatin1Char('|')
                                              + QString::number(fi.size()) + QLatin1Char('|')
                                              + QString::number(fi.lastModified().toSecsSinceEpoch()))
                            .toString());
    const QString digest = actual.isEmpty() ? sha256Of(path) : actual;
    if (actual.isEmpty())
        m_hashCache.insert(path + QLatin1Char('|') + QString::number(fi.size())
                           + QLatin1Char('|')
                           + QString::number(fi.lastModified().toSecsSinceEpoch()), digest);
    out.insert(QStringLiteral("checkpoint"), fi.absoluteFilePath());
    out.insert(QStringLiteral("checkpoint_sha256"), digest);
    out.insert(QStringLiteral("bytes"), fi.size());
    out.insert(QStringLiteral("onnx"), onnx.isEmpty() || !QFileInfo::exists(onnx)
                                           ? QString() : QFileInfo(onnx).absoluteFilePath());
    const bool verified = !expected.isEmpty() && digest == expected;
    out.insert(QStringLiteral("verified"), verified);
    out.insert(QStringLiteral("expected_sha256"), expected);
    out.insert(QStringLiteral("usable"), verified);
    if (!verified)
        out.insert(QStringLiteral("message"),
                   QStringLiteral("revision %1 approach %2: checkpoint hash %3 does not "
                                  "match the registered %4 — refusing to run")
                       .arg(selected, approach, digest.left(16), expected.left(16)));
    return out;
}

QVariantMap LabsStage4::modelState() const
{
    const QVariantMap reg = registryRevision(m_approach);
    QVariantMap out = reg;
    out.insert(QStringLiteral("approach"), m_approach);
    out.insert(QStringLiteral("path"), reg.value(QStringLiteral("checkpoint")));
    out.insert(QStringLiteral("ready"), reg.value(QStringLiteral("usable")));
    return out;
}

void LabsStage4::setScoreThreshold(double v)
{
    if (qFuzzyCompare(m_scoreThreshold, v))
        return;
    m_scoreThreshold = v;
    emit jobChanged();
}

void LabsStage4::setDecodeWidth(int v)
{
    if (m_decodeWidth == v)
        return;
    m_decodeWidth = v;
    emit jobChanged();
}

void LabsStage4::setStatus(const QString &status, const QString &text)
{
    m_status = status;
    m_statusText = text;
    m_running = status == QLatin1String("running") || status == QLatin1String("decoding")
                || status == QLatin1String("starting");
    emit stateChanged();
}

void LabsStage4::appendLog(const QString &line)
{
    m_logTail += line + QLatin1Char('\n');
    if (m_logTail.size() > 4000)
        m_logTail = m_logTail.right(4000);
}

void LabsStage4::probeRecording()
{
    if (m_recording.isEmpty())
        return;
    const QString tools = toolsDir();
    if (tools.isEmpty()) {
        m_probe.clear();
        return;
    }
    QProcess probe;
    probe.start(pythonExe(), {tools + QStringLiteral("/stage4_analyse.py"),
                              QStringLiteral("--input"), m_recording,
                              QStringLiteral("--approach"), m_approach,
                              QStringLiteral("--probe")});
    if (!probe.waitForFinished(60000)) {
        probe.kill();
        return;
    }
    m_probe = lineObject(probe.readAllStandardOutput().trimmed()).toVariantMap();
    emit jobChanged();
}

void LabsStage4::start()
{
    if (m_running)
        return;
    const QString tools = toolsDir();
    if (tools.isEmpty()) {
        m_errorText = QStringLiteral("the Stage 4 tools directory was not found next to "
                                     "the application; the analyser cannot be started");
        setStatus(QStringLiteral("failed"), m_errorText);
        return;
    }
    if (m_recording.isEmpty() || !QFileInfo::exists(m_recording)) {
        m_errorText = QStringLiteral("no readable recording is selected");
        setStatus(QStringLiteral("failed"), m_errorText);
        return;
    }
    const QVariantMap reg = registryRevision(m_approach);
    const QString checkpoint = reg.value(QStringLiteral("checkpoint")).toString();
    if (checkpoint.isEmpty() || !reg.value(QStringLiteral("usable")).toBool()) {
        m_errorText = reg.value(QStringLiteral("message")).toString().isEmpty()
                          ? QStringLiteral("revision %1 has no usable %2 checkpoint"
                                           ).arg(reg.value(QStringLiteral("revision")).toString(),
                                                 m_approach)
                          : reg.value(QStringLiteral("message")).toString();
        setStatus(QStringLiteral("failed"), m_errorText);
        return;
    }
    m_revisionState = reg;
    const QString stamp = QDateTime::currentDateTimeUtc().toString(QStringLiteral("yyyyMMdd'T'HHmmss'Z'"));
    const QString dir = runsDir() + QLatin1Char('/') + recordingName().section(QLatin1Char('.'), 0, 0)
                        + QLatin1Char('-') + m_approach + QLatin1Char('-') + stamp;
    if (QFileInfo::exists(dir)) {
        m_errorText = QStringLiteral("run directory %1 already exists").arg(dir);
        setStatus(QStringLiteral("failed"), m_errorText);
        return;
    }

    QStringList args{tools + QStringLiteral("/stage4_analyse.py"),
                     QStringLiteral("--input"), m_recording,
                     QStringLiteral("--approach"), m_approach,
                     QStringLiteral("--checkpoint"), checkpoint,
                     QStringLiteral("--output"), dir,
                     QStringLiteral("--score-threshold"), QString::number(m_scoreThreshold),
                     QStringLiteral("--decode-width"), QString::number(m_decodeWidth),
                     QStringLiteral("--threads"), QStringLiteral("2")};
    const QByteArray sched = qgetenv("WT_LABS_STAGE4_SCHEDULE");
    if (!sched.isEmpty())
        args << QStringLiteral("--schedule") << QString::fromLocal8Bit(sched);

    m_observations.clear();
    m_summary.clear();
    m_metrics.clear();
    m_selected.clear();
    m_errorText.clear();
    m_logTail.clear();
    m_runDir = dir;
    emit resultChanged();
    emit selectionChanged();

    m_run = new QProcess(this);
    const int generation = m_generation;
    m_run->setProperty("runDir", dir);
    m_run->setProperty("generation", generation);
    m_run->setProperty("startedUtc", QDateTime::currentDateTimeUtc().toString(Qt::ISODate));
    m_run->setProcessChannelMode(QProcess::SeparateChannels);
    connect(m_run, &QProcess::readyReadStandardOutput, this, &LabsStage4::onRunOutput);
    connect(m_run, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            &LabsStage4::onRunFinished);
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
    setStatus(QStringLiteral("starting"),
              QStringLiteral("starting approach %1 on %2").arg(m_approach, recordingName()));
    m_run->setProgram(pythonExe());
    // The exact artifact identity travels with the run: revision, checkpoint and
    // ONNX hashes are recorded by the analyser from the files it actually loaded.
    args << QStringLiteral("--revision") << reg.value(QStringLiteral("revision")).toString();
    if (!reg.value(QStringLiteral("onnx")).toString().isEmpty())
        args << QStringLiteral("--onnx") << reg.value(QStringLiteral("onnx")).toString();
    m_run->setArguments(args);
    m_run->start();
    if (!m_run->waitForStarted(10000)) {
        m_errorText = QStringLiteral("the analyser process could not be started");
        setStatus(QStringLiteral("failed"), m_errorText);
        killProcess(m_run);
        return;
    }
    m_killTimer.start(3600000);
    setStatus(QStringLiteral("running"),
              QStringLiteral("approach %1 running on %2").arg(m_approach, recordingName()));
}

void LabsStage4::onRunOutput()
{
    // Only the CURRENT process may drive the panel: output from a run whose
    // generation was superseded by a switch is dropped instead of repopulating the
    // new run with the old model's frames (R2 finding 2).
    if (!m_run || sender() != m_run
        || m_run->property("generation").toInt() != m_generation)
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
        if (event == QLatin1String("start")) {
            setStatus(QStringLiteral("running"),
                      QStringLiteral("analysing %1 with approach %2")
                          .arg(recordingName(), m_approach));
        } else if (event == QLatin1String("decoded")) {
            setStatus(QStringLiteral("decoding"),
                      QStringLiteral("%1 frames decoded")
                          .arg(obj.value(QStringLiteral("frames")).toInt()));
        } else if (event == QLatin1String("frame")) {
            const int index = obj.value(QStringLiteral("frame_index")).toInt();
            const int objects = obj.value(QStringLiteral("objects")).toInt();
            setStatus(QStringLiteral("running"),
                      QStringLiteral("frame %1 · %2 object(s)").arg(index).arg(objects));
        } else if (event == QLatin1String("finished")) {
            setStatus(obj.value(QStringLiteral("status")).toString(),
                      QStringLiteral("%1 · %2 observation(s)")
                          .arg(obj.value(QStringLiteral("status")).toString())
                          .arg(obj.value(QStringLiteral("observations")).toInt()));
        }
    }
}

void LabsStage4::onRunFinished(int code, int status)
{
    QProcess *proc = m_run;
    const bool current = proc && sender() == proc
                         && proc->property("generation").toInt() == m_generation;
    if (proc && !current) {
        // A superseded run: report it and discard, never load its result.
        appendLog(QStringLiteral("[stale] a superseded run finished with code %1; its "
                                 "output is not loaded").arg(code));
        proc->disconnect(this);
        proc->deleteLater();
        if (m_run == proc)
            m_run = nullptr;
        return;
    }
    if (proc) {
        appendLog(QString::fromUtf8(proc->readAllStandardError()));
        appendLog(QString::fromUtf8(proc->readAllStandardOutput()));
        m_run = nullptr;
        proc->disconnect(this);
        proc->deleteLater();
    }
    m_killTimer.stop();
    Q_UNUSED(status);
    if (!m_runDir.isEmpty() && QFileInfo::exists(m_runDir + QStringLiteral("/run.json")))
        loadResult(m_runDir, nullptr);
    if (code == 0 && hasResult())
        setStatus(QStringLiteral("completed"),
                  QStringLiteral("completed · %1 observation(s)").arg(m_observations.size()));
    else if (code == 0)
        setStatus(QStringLiteral("completed"),
                  QStringLiteral("completed with no objects in the scheduled frames"));
    else if (m_status == QLatin1String("cancelled"))
        setStatus(QStringLiteral("cancelled"),
                  QStringLiteral("cancelled; partial results kept"));
    else {
        m_errorText = m_errorText.isEmpty()
                          ? QStringLiteral("the analyser exited with code %1").arg(code)
                          : m_errorText;
        setStatus(QStringLiteral("failed"), m_errorText);
    }
    refreshRuns();
}

void LabsStage4::killProcess(QProcess *&proc)
{
    if (!proc)
        return;
    QProcess *local = proc;
    proc = nullptr;
    if (local->state() == QProcess::NotRunning) {
        local->deleteLater();
        return;
    }
    local->disconnect();
    local->terminate();
    if (!local->waitForFinished(4000))
        local->kill();
    local->deleteLater();
}

void LabsStage4::cancel()
{
    if (!m_run)
        return;
    setStatus(QStringLiteral("cancelled"),
              QStringLiteral("cancelling: asking the analyser to stop"));
    m_killTimer.stop();
    killProcess(m_run);
    if (!m_runDir.isEmpty() && QFileInfo::exists(m_runDir + QStringLiteral("/run.json")))
        loadResult(m_runDir, nullptr);
    else
        setStatus(QStringLiteral("cancelled"),
                  QStringLiteral("cancelled before any result was written"));
    refreshRuns();
}

QVariantMap LabsStage4::inspectRun(const QString &dirIn, QString *error) const
{
    // Normalise once: a hook, a QML string or a dialog result may be relative, and a
    // relative path silently failed to open (found by an application self-test).
    const QString dir = QFileInfo(dirIn).absoluteFilePath();
    // Validation happens on LOCALS: a corrupt or incomplete run must leave the
    // currently displayed run untouched rather than half-replacing it (R2 finding 2).
    QVariantMap state;
    auto fail = [&](const QString &why) {
        if (error)
            *error = why;
        return QVariantMap{};
    };
    QFile file(dir + QStringLiteral("/run.json"));
    if (!file.open(QIODevice::ReadOnly))
        return fail(QStringLiteral("run.json could not be read in %1").arg(dir));
    const QByteArray raw = file.readAll();
    file.close();
    QJsonParseError parse{};
    const QJsonDocument doc = QJsonDocument::fromJson(raw, &parse);
    if (!doc.isObject())
        return fail(QStringLiteral("run.json in %1 is not valid JSON (%2 at offset %3)")
                        .arg(dir, parse.errorString()).arg(parse.offset));
    const QJsonObject root = doc.object();
    if (root.isEmpty())
        return fail(QStringLiteral("run.json in %1 is an empty object").arg(dir));

    const QJsonObject input = root.value(QStringLiteral("input")).toObject();
    const QJsonArray coverage = root.value(QStringLiteral("coverage")).toArray();
    const QJsonArray observations = root.value(QStringLiteral("observations")).toArray();
    int analysed = 0, failed = 0;
    for (const QJsonValue &v : coverage) {
        const QString s = v.toObject().value(QStringLiteral("state")).toString();
        if (s == QLatin1String("analysed")) ++analysed;
        else if (s == QLatin1String("failed")) ++failed;
    }
    // Evidence references: what the run claims, and what is still on disk.
    int referenced = 0, present = 0;
    QStringList missing;
    for (const QJsonValue &v : observations) {
        const QJsonObject obs = v.toObject();
        QStringList refs;
        const QString crop = obs.value(QStringLiteral("crop")).toString();
        if (!crop.isEmpty()) refs << crop;
        for (const QJsonValue &cv : obs.value(QStringLiteral("colors")).toArray()) {
            const QJsonObject col = cv.toObject();
            for (const char *key : {"crop", "support_mask"}) {
                const QString r = col.value(QLatin1String(key)).toString();
                if (!r.isEmpty()) refs << r;
            }
        }
        for (const QString &r : refs) {
            ++referenced;
            if (QFileInfo::exists(dir + QLatin1Char('/') + r)) ++present;
            else if (missing.size() < 12) missing << r;
        }
    }
    const QString video = input.value(QStringLiteral("path")).toString();
    const bool videoOk = !video.isEmpty() && QFileInfo::exists(video);
    state.insert(QStringLiteral("dir"), dir);
    state.insert(QStringLiteral("run_id"), root.value(QStringLiteral("run_id")).toString());
    state.insert(QStringLiteral("status"), root.value(QStringLiteral("status")).toString());
    state.insert(QStringLiteral("approach"), root.value(QStringLiteral("approach")).toString());
    state.insert(QStringLiteral("schema_version"),
                 root.value(QStringLiteral("schema_version")).toInt());
    state.insert(QStringLiteral("run_json_sha256"),
                 QString::fromLatin1(QCryptographicHash::hash(raw, QCryptographicHash::Sha256)
                                         .toHex()));
    state.insert(QStringLiteral("input_sha256"), input.value(QStringLiteral("sha256")).toString());
    state.insert(QStringLiteral("scheduled"), coverage.size());
    state.insert(QStringLiteral("analysed"), analysed);
    state.insert(QStringLiteral("failed"), failed);
    state.insert(QStringLiteral("observations"), observations.size());
    state.insert(QStringLiteral("video"), video);
    state.insert(QStringLiteral("video_available"), videoOk);
    state.insert(QStringLiteral("evidence_referenced"), referenced);
    state.insert(QStringLiteral("evidence_present"), present);
    state.insert(QStringLiteral("evidence_missing"), referenced - present);
    state.insert(QStringLiteral("evidence_missing_sample"), missing);
    const QJsonArray models = root.value(QStringLiteral("models")).toArray();
    if (!models.isEmpty()) {
        const QJsonObject m = models.first().toObject();
        state.insert(QStringLiteral("checkpoint"), m.value(QStringLiteral("checkpoint")).toString());
        state.insert(QStringLiteral("checkpoint_sha256"),
                     m.value(QStringLiteral("checkpoint_sha256")).toString());
        state.insert(QStringLiteral("runtime"), m.value(QStringLiteral("runtime")).toString());
    }
    const QJsonObject rev = root.value(QStringLiteral("revision")).toObject();
    if (!rev.isEmpty()) {
        state.insert(QStringLiteral("revision"), rev.value(QStringLiteral("revision")).toString());
        state.insert(QStringLiteral("revision_matches_registry"),
                     rev.value(QStringLiteral("matches_registry")).toBool());
    }
    QStringList problems;
    if (state.value(QStringLiteral("schema_version")).toInt() != 4)
        problems << QStringLiteral("run.json schema_version is not 4");
    if (!videoOk)
        problems << QStringLiteral("the source recording is not available at %1").arg(video);
    if (referenced > present)
        problems << QStringLiteral("%1 of %2 evidence files are missing")
                        .arg(referenced - present).arg(referenced);
    if (failed > 0)
        problems << QStringLiteral("%1 of %2 scheduled frames failed").arg(failed).arg(coverage.size());
    state.insert(QStringLiteral("problems"), problems);
    state.insert(QStringLiteral("playback_unavailable"), !videoOk);
    return state;
}

bool LabsStage4::loadResult(const QString &dirIn, QString *error)
{
    const QString dir = QFileInfo(dirIn).absoluteFilePath();
    QString why;
    const QVariantMap inspected = inspectRun(dir, &why);
    if (inspected.isEmpty()) {
        if (error)
            *error = why;
        return false;
    }
    // Read the file PROPERLY: the first version of this line called readAll() on a
    // QFile that was never opened, so every reopened run showed an empty summary and
    // zero observations while its run_state looked complete (caught by the
    // application state dump, not by any Python check).
    QFile runFile(dir + QStringLiteral("/run.json"));
    if (!runFile.open(QIODevice::ReadOnly)) {
        if (error)
            *error = QStringLiteral("run.json could not be reopened in %1").arg(dir);
        return false;
    }
    const QJsonObject root = QJsonDocument::fromJson(runFile.readAll()).object();
    runFile.close();
    m_runState = inspected;
    m_runDir = dir;
    const int schema = root.value(QStringLiteral("schema_version")).toInt();
    QVariantMap summary;
    summary.insert(QStringLiteral("schema_version"), schema);
    summary.insert(QStringLiteral("schema_ok"), schema == 4);
    summary.insert(QStringLiteral("run_id"), root.value(QStringLiteral("run_id")).toString());
    summary.insert(QStringLiteral("approach"), root.value(QStringLiteral("approach")).toString());
    summary.insert(QStringLiteral("status"), root.value(QStringLiteral("status")).toString());
    summary.insert(QStringLiteral("errors"), toList(root.value(QStringLiteral("errors")).toArray()));
    const QJsonObject input = root.value(QStringLiteral("input")).toObject();
    m_videoPath = input.value(QStringLiteral("path")).toString();
    summary.insert(QStringLiteral("input_sha256"), input.value(QStringLiteral("sha256")).toString());
    summary.insert(QStringLiteral("decoded_frame_count"),
                   input.value(QStringLiteral("decoded_frame_count")).toInt());
    summary.insert(QStringLiteral("source_width"), input.value(QStringLiteral("width")).toInt());
    summary.insert(QStringLiteral("source_height"), input.value(QStringLiteral("height")).toInt());
    const QJsonObject schedule = root.value(QStringLiteral("schedule")).toObject();
    summary.insert(QStringLiteral("sampling"), schedule.value(QStringLiteral("policy")).toString());
    summary.insert(QStringLiteral("scheduled"), schedule.value(QStringLiteral("count")).toInt());
    const QJsonArray coverage = root.value(QStringLiteral("coverage")).toArray();
    int analysed = 0, failed = 0;
    for (const QJsonValue &v : coverage) {
        const QString state = v.toObject().value(QStringLiteral("state")).toString();
        if (state == QLatin1String("analysed"))
            ++analysed;
        else if (state == QLatin1String("failed"))
            ++failed;
    }
    summary.insert(QStringLiteral("covered"), coverage.size());
    summary.insert(QStringLiteral("analysed"), analysed);
    summary.insert(QStringLiteral("failed"), failed);
    const QJsonArray models = root.value(QStringLiteral("models")).toArray();
    if (!models.isEmpty()) {
        const QJsonObject m = models.first().toObject();
        summary.insert(QStringLiteral("model_architecture"),
                       m.value(QStringLiteral("architecture")).toString());
        summary.insert(QStringLiteral("checkpoint_sha256"),
                       m.value(QStringLiteral("checkpoint_sha256")).toString());
        summary.insert(QStringLiteral("checkpoint"), m.value(QStringLiteral("checkpoint")).toString());
        summary.insert(QStringLiteral("pretrained_trunk"),
                       m.value(QStringLiteral("pretrained_trunk")).toVariant());
    }
    m_summary = summary;
    m_metrics = root.value(QStringLiteral("metrics")).toObject().toVariantMap();
    m_observations = toList(root.value(QStringLiteral("observations")).toArray());
    m_obsPts.clear();
    for (const QVariant &v : m_observations) {
        const QVariant pts = v.toMap().value(QStringLiteral("frame_pts_ms"));
        if (pts.isValid() && !pts.isNull())
            m_obsPts.append(static_cast<qint64>(pts.toDouble()));
    }
    std::sort(m_obsPts.begin(), m_obsPts.end());
    const QStringList problems = m_runState.value(QStringLiteral("problems")).toStringList();
    m_errorText = summary.value(QStringLiteral("status")).toString() == QLatin1String("failed")
                      ? summary.value(QStringLiteral("errors")).toStringList().join(QStringLiteral("; "))
                      : problems.join(QStringLiteral("; "));
    // Selection uses the observation's own stable id, never a row position, so a
    // filtered or reopened view selects the same object.
    m_selected = m_observations.isEmpty()
                     ? QString()
                     : m_observations.first().toMap().value(QStringLiteral("observation_id")).toString();
    emit resultChanged();
    emit filtersChanged();
    emit selectionChanged();
    return true;
}

QVariantMap LabsStage4::stateDump() const
{
    QVariantMap out;
    out.insert(QStringLiteral("recording"), m_recording);
    out.insert(QStringLiteral("recording_name"), recordingName());
    out.insert(QStringLiteral("approach"), m_approach);
    out.insert(QStringLiteral("status"), m_status);
    out.insert(QStringLiteral("status_text"), m_statusText);
    out.insert(QStringLiteral("error_text"), m_errorText);
    out.insert(QStringLiteral("running"), m_running);
    out.insert(QStringLiteral("observations"), m_observations.size());
    out.insert(QStringLiteral("selected"), m_selected);
    out.insert(QStringLiteral("video_path"), m_videoPath);
    out.insert(QStringLiteral("run_dir"), m_runDir);
    out.insert(QStringLiteral("generation"), m_generation);
    out.insert(QStringLiteral("filtered"), filtered().size());
    out.insert(QStringLiteral("filter_counts"), filterCounts());
    const QVariantMap model = modelState();
    out.insert(QStringLiteral("model_ready"), model.value(QStringLiteral("ready")));
    out.insert(QStringLiteral("model_verified"), model.value(QStringLiteral("verified")));
    out.insert(QStringLiteral("model_revision"), model.value(QStringLiteral("revision")));
    out.insert(QStringLiteral("model_label"), model.value(QStringLiteral("label")));
    out.insert(QStringLiteral("model_checkpoint"), model.value(QStringLiteral("checkpoint")));
    out.insert(QStringLiteral("model_sha256"), model.value(QStringLiteral("checkpoint_sha256")));
    out.insert(QStringLiteral("model_onnx"), model.value(QStringLiteral("onnx")));
    out.insert(QStringLiteral("model_message"), model.value(QStringLiteral("message")));
    out.insert(QStringLiteral("run_state"), m_runState);
    out.insert(QStringLiteral("shown"), observationsAt(0));
    if (!m_lastVerify.isEmpty())
        out.insert(QStringLiteral("artifact_verify"), m_lastVerify);
    return out;
}

void LabsStage4::writeStateDump(const QString &path) const
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    file.write(QJsonDocument(QJsonObject::fromVariantMap(stateDump()))
                   .toJson(QJsonDocument::Indented));
}

QVariantMap LabsStage4::verifyRunArtifacts(const QString &dirIn, int limit)
{
    const QString dir = QFileInfo(dirIn).absoluteFilePath();
    // Recompute the hashes the run's own artifact manifest recorded. Bounded so the
    // UI stays responsive on a run with thousands of crops; the bound is reported.
    QVariantMap out{{QStringLiteral("dir"), dir}, {QStringLiteral("checked"), 0},
                    {QStringLiteral("matched"), 0}, {QStringLiteral("mismatched"), 0},
                    {QStringLiteral("missing"), 0}, {QStringLiteral("limit"), limit},
                    {QStringLiteral("mismatch_sample"), QStringList()}};
    QFile file(dir + QStringLiteral("/run.json"));
    if (!file.open(QIODevice::ReadOnly))
        return out;
    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    file.close();
    const QJsonArray files = root.value(QStringLiteral("artifact_manifest"))
                                 .toObject().value(QStringLiteral("files")).toArray();
    out.insert(QStringLiteral("listed"), files.size());
    int checked = 0, matched = 0, mismatched = 0, missing = 0;
    QStringList sample;
    for (const QJsonValue &v : files) {
        if (limit > 0 && checked >= limit)
            break;
        const QJsonObject f = v.toObject();
        const QString rel = f.value(QStringLiteral("path")).toString();
        const QString want = f.value(QStringLiteral("sha256")).toString();
        if (rel.isEmpty() || want.isEmpty())
            continue;
        ++checked;
        const QString path = dir + QLatin1Char('/') + rel;
        if (!QFileInfo::exists(path)) {
            ++missing;
            if (sample.size() < 8) sample << rel + QStringLiteral(" (missing)");
            continue;
        }
        const QString got = sha256Of(path);
        if (got == want) ++matched;
        else {
            ++mismatched;
            if (sample.size() < 8) sample << rel + QStringLiteral(" (hash differs)");
        }
    }
    out.insert(QStringLiteral("checked"), checked);
    out.insert(QStringLiteral("matched"), matched);
    out.insert(QStringLiteral("mismatched"), mismatched);
    out.insert(QStringLiteral("missing"), missing);
    out.insert(QStringLiteral("mismatch_sample"), sample);
    out.insert(QStringLiteral("truncated"), limit > 0 && files.size() > checked);
    m_lastVerify = out;
    return out;
}

void LabsStage4::loadRun(const QString &dir)
{
    if (m_running)
        return;
    QString why;
    if (!loadResult(dir, &why)) {
        // The previous run stays on screen; the failure is explicit.
        m_errorText = why;
        setStatus(QStringLiteral("failed"), why);
        return;
    }
    const QString approach = m_summary.value(QStringLiteral("approach")).toString();
    if (!approach.isEmpty() && approach != m_approach) {
        m_approach = approach;
        emit jobChanged();
    }
    setStatus(m_summary.value(QStringLiteral("status")).toString(),
              QStringLiteral("loaded %1").arg(QFileInfo(dir).fileName()));
}

void LabsStage4::refreshRuns()
{
    QVariantList out;
    const QDir dir(runsDir());
    const QFileInfoList entries = dir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot,
                                                    QDir::Time);
    for (const QFileInfo &fi : entries) {
        QFile run(fi.absoluteFilePath() + QStringLiteral("/run.json"));
        if (!run.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject root = QJsonDocument::fromJson(run.readAll()).object();
        run.close();
        out.append(QVariantMap{
            {QStringLiteral("dir"), fi.absoluteFilePath()},
            {QStringLiteral("name"), fi.fileName()},
            {QStringLiteral("approach"), root.value(QStringLiteral("approach")).toString()},
            {QStringLiteral("status"), root.value(QStringLiteral("status")).toString()},
            {QStringLiteral("observations"),
             root.value(QStringLiteral("observations")).toArray().size()},
            {QStringLiteral("modified"),
             fi.lastModified().toUTC().toString(Qt::ISODate)}});
    }
    m_runs = out;
    emit runsChanged();
}

void LabsStage4::setFilterTypes(const QStringList &v)
{
    if (m_filterTypes == v)
        return;
    m_filterTypes = v;
    emit filtersChanged();
}

void LabsStage4::setFilterSizes(const QStringList &v)
{
    if (m_filterSizes == v)
        return;
    m_filterSizes = v;
    emit filtersChanged();
}

void LabsStage4::setFilterLocation(const QString &v)
{
    if (m_filterLocation == v)
        return;
    m_filterLocation = v;
    emit filtersChanged();
}

void LabsStage4::setFilterColourHex(const QString &v)
{
    if (m_filterColourHex == v)
        return;
    m_filterColourHex = v;
    emit filtersChanged();
}

void LabsStage4::setFilterColourActive(bool v)
{
    if (m_filterColourActive == v)
        return;
    m_filterColourActive = v;
    emit filtersChanged();
}

void LabsStage4::setFilterTolerance(double v)
{
    if (qFuzzyCompare(m_filterTolerance, v))
        return;
    m_filterTolerance = v;
    emit filtersChanged();
}

void LabsStage4::setIncludeUncertain(bool v)
{
    if (m_includeUncertain == v)
        return;
    m_includeUncertain = v;
    emit filtersChanged();
}

void LabsStage4::setRecordingMeta(const QVariantMap &v)
{
    if (m_recordingMeta == v)
        return;
    m_recordingMeta = v;
    emit filtersChanged();
}

void LabsStage4::setFilterTimeFrom(const QString &v)
{
    if (m_filterTimeFrom == v)
        return;
    m_filterTimeFrom = v;
    emit filtersChanged();
}

void LabsStage4::setFilterTimeTo(const QString &v)
{
    if (m_filterTimeTo == v)
        return;
    m_filterTimeTo = v;
    emit filtersChanged();
}

void LabsStage4::setFilterCamera(const QString &v)
{
    if (m_filterCamera == v)
        return;
    m_filterCamera = v;
    emit filtersChanged();
}

void LabsStage4::setFilterArea(const QString &v)
{
    if (m_filterArea == v)
        return;
    m_filterArea = v;
    emit filtersChanged();
}

void LabsStage4::clearFilters()
{
    m_filterTypes.clear();
    m_filterSizes.clear();
    m_filterLocation.clear();
    m_filterColourActive = false;
    m_includeUncertain = false;
    m_filterTolerance = 20.0;
    emit filtersChanged();
}

QVariantMap LabsStage4::evaluateFilter(const QVariantMap &observation) const
{
    QVariantMap result{{QStringLiteral("state"), QStringLiteral("no_match")},
                       {QStringLiteral("region"), QString()},
                       {QStringLiteral("delta_e"), QVariant()},
                       {QStringLiteral("reason"), QString()}};
    const QString cls = observation.value(QStringLiteral("class")).toString();
    if (!m_filterTypes.isEmpty() && !m_filterTypes.contains(cls)) {
        result.insert(QStringLiteral("reason"),
                      QStringLiteral("object type %1 is not in the selected list").arg(cls));
        return result;
    }
    const QString size = observation.value(QStringLiteral("apparent_size")).toMap()
                             .value(QStringLiteral("label")).toString();
    if (!m_filterSizes.isEmpty() && !m_filterSizes.contains(size)) {
        result.insert(QStringLiteral("reason"),
                      QStringLiteral("apparent size %1 is not selected").arg(size));
        return result;
    }
    // Metadata filters next: they need no colour and no pixels.
    if (!m_filterTimeFrom.isEmpty() || !m_filterTimeTo.isEmpty()) {
        const QString stamp = m_recordingMeta.value(QStringLiteral("captured_at_utc"))
                                  .toString();
        if (stamp.isEmpty()) {
            result.insert(QStringLiteral("reason"),
                          QStringLiteral("the recording carries no capture time, so a "
                                         "time window cannot be satisfied"));
            return result;
        }
        if ((!m_filterTimeFrom.isEmpty() && stamp < m_filterTimeFrom)
            || (!m_filterTimeTo.isEmpty() && stamp > m_filterTimeTo)) {
            result.insert(QStringLiteral("reason"),
                          QStringLiteral("capture time %1 is outside the window").arg(stamp));
            return result;
        }
    }
    if (!m_filterCamera.isEmpty()
        && m_recordingMeta.value(QStringLiteral("camera_id")).toString() != m_filterCamera) {
        result.insert(QStringLiteral("reason"), QStringLiteral("camera does not match"));
        return result;
    }
    if (!m_filterArea.isEmpty()
        && m_recordingMeta.value(QStringLiteral("area")).toString() != m_filterArea) {
        result.insert(QStringLiteral("reason"), QStringLiteral("area does not match"));
        return result;
    }
    if (!m_filterColourActive) {
        result.insert(QStringLiteral("state"), QStringLiteral("match"));
        return result;
    }
    QStringList wanted = regionsForLocation(m_filterLocation);
    if (wanted.isEmpty())
        wanted = defaultRegionsForClass(cls);
    const QColor query(m_filterColourHex);
    if (!query.isValid()) {
        result.insert(QStringLiteral("reason"),
                      QStringLiteral("the picked colour %1 is not a valid colour")
                          .arg(m_filterColourHex));
        return result;
    }
    const QVector<double> queryLab = ::srgbToLab(query);
    double best = -1.0;
    QString bestRegion, unknownRegion;
    const QVariantList colors = observation.value(QStringLiteral("colors")).toList();
    for (const QVariant &cv : colors) {
        const QVariantMap rec = cv.toMap();
        const QString region = rec.value(QStringLiteral("region")).toString();
        if (!wanted.contains(region))
            continue;
        const QVariantList lab = rec.value(QStringLiteral("lab_d65")).toList();
        if (lab.size() != 3 || rec.value(QStringLiteral("label")).toString()
                                   == QLatin1String("unknown")) {
            if (unknownRegion.isEmpty())
                unknownRegion = region;
            continue;
        }
        QVector<double> observed{lab[0].toDouble(), lab[1].toDouble(), lab[2].toDouble()};
        const double d = ::deltaE2000(queryLab, observed);
        if (best < 0 || d < best) {
            best = d;
            bestRegion = region;
        }
    }
    if (best >= 0 && best <= m_filterTolerance) {
        result.insert(QStringLiteral("state"), QStringLiteral("match"));
        result.insert(QStringLiteral("region"), bestRegion);
        result.insert(QStringLiteral("delta_e"), best);
        return result;
    }
    if (best >= 0) {
        result.insert(QStringLiteral("region"), bestRegion);
        result.insert(QStringLiteral("delta_e"), best);
        result.insert(QStringLiteral("reason"),
                      QStringLiteral("closest %1 is deltaE00 %2, above the tolerance %3")
                          .arg(bestRegion)
                          .arg(best, 0, 'f', 1)
                          .arg(m_filterTolerance, 0, 'f', 1));
        return result;
    }
    result.insert(QStringLiteral("state"), QStringLiteral("uncertain"));
    result.insert(QStringLiteral("region"), unknownRegion);
    result.insert(QStringLiteral("reason"),
                  unknownRegion.isEmpty()
                      ? QStringLiteral("the observation has no colour evidence for the "
                                       "requested location")
                      : QStringLiteral("colour is unknown in %1").arg(unknownRegion));
    return result;
}

QVariantList LabsStage4::filtered() const
{
    QVariantList out;
    for (const QVariant &v : m_observations) {
        QVariantMap obs = v.toMap();
        const QVariantMap verdict = evaluateFilter(obs);
        const QString state = verdict.value(QStringLiteral("state")).toString();
        if (state == QLatin1String("no_match"))
            continue;
        if (state == QLatin1String("uncertain") && !m_includeUncertain)
            continue;
        obs.insert(QStringLiteral("filter_state"), state);
        obs.insert(QStringLiteral("filter_region"), verdict.value(QStringLiteral("region")));
        obs.insert(QStringLiteral("filter_delta_e"), verdict.value(QStringLiteral("delta_e")));
        out.append(obs);
    }
    return out;
}

QVariantMap LabsStage4::filterCounts() const
{
    int matched = 0, uncertain = 0, total = m_observations.size();
    for (const QVariant &v : m_observations) {
        const QString state = evaluateFilter(v.toMap())
                                  .value(QStringLiteral("state")).toString();
        if (state == QLatin1String("match"))
            ++matched;
        else if (state == QLatin1String("uncertain"))
            ++uncertain;
    }
    return QVariantMap{{QStringLiteral("observations"), total},
                       {QStringLiteral("matched"), matched},
                       {QStringLiteral("uncertain"), uncertain},
                       {QStringLiteral("uncertain_shown"), m_includeUncertain}};
}

QVariantMap LabsStage4::observationsAt(qint64 ptsMs, qint64 toleranceMs) const
{
    // The overlay must show what belongs to the frame under the playhead, and say
    // when the playhead is NOT on an observed frame rather than leaving stale boxes
    // up. Same rule as the Stage 3 panel: nearest observation at or before the
    // playhead, drawn only while it is within the tolerance.
    QVariantMap out;
    out.insert(QStringLiteral("found"), false);
    out.insert(QStringLiteral("observations"), QVariantList());
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
        out.insert(QStringLiteral("first_pts_ms"), double(m_obsPts.first()));
        return out;
    }
    const qint64 t = m_obsPts[best];
    out.insert(QStringLiteral("pts_ms"), double(t));
    out.insert(QStringLiteral("age_ms"), double(ptsMs - t));
    if (ptsMs - t > toleranceMs)
        return out;
    QVariantList rows;
    for (const QVariant &v : m_observations) {
        const QVariantMap obs = v.toMap();
        const QVariant pts = obs.value(QStringLiteral("frame_pts_ms"));
        if (!pts.isValid() || pts.isNull()
            || static_cast<qint64>(pts.toDouble()) != t)
            continue;
        rows.append(obs);
    }
    out.insert(QStringLiteral("found"), !rows.isEmpty());
    out.insert(QStringLiteral("observations"), rows);
    out.insert(QStringLiteral("count"), rows.size());
    return out;
}

void LabsStage4::setSelectedObservation(const QString &id)
{
    if (m_selected == id)
        return;
    m_selected = id;
    emit selectionChanged();
}

QVariantMap LabsStage4::selectedDetail() const
{
    for (const QVariant &v : m_observations) {
        const QVariantMap obs = v.toMap();
        if (obs.value(QStringLiteral("observation_id")).toString() != m_selected)
            continue;
        QVariantMap out = obs;
        const QVariantMap verdict = evaluateFilter(obs);
        out.insert(QStringLiteral("filter_state"), verdict.value(QStringLiteral("state")));
        out.insert(QStringLiteral("filter_region"), verdict.value(QStringLiteral("region")));
        out.insert(QStringLiteral("filter_delta_e"), verdict.value(QStringLiteral("delta_e")));
        out.insert(QStringLiteral("filter_reason"), verdict.value(QStringLiteral("reason")));
        return out;
    }
    return {};
}

QVariantList LabsStage4::srgbToLab(const QString &hex) const
{
    const QColor c(hex);
    if (!c.isValid())
        return {};
    const QVector<double> lab = ::srgbToLab(c);
    return QVariantList{lab[0], lab[1], lab[2]};
}

double LabsStage4::deltaE2000(const QVariantList &lab1, const QVariantList &lab2) const
{
    if (lab1.size() != 3 || lab2.size() != 3)
        return -1.0;
    return ::deltaE2000({lab1[0].toDouble(), lab1[1].toDouble(), lab1[2].toDouble()},
                        {lab2[0].toDouble(), lab2[1].toDouble(), lab2[2].toDouble()});
}

void LabsStage4::runChecks(const QString &group)
{
    if (m_checking)
        return;
    const QString tools = toolsDir();
    if (tools.isEmpty()) {
        m_checkSummary = QStringLiteral("the Stage 4 tools directory was not found next "
                                        "to the application");
        emit checksChanged();
        return;
    }
    m_checks.clear();
    m_checkSummary.clear();
    m_checking = true;
    emit checksChanged();

    m_checksProc = new QProcess(this);
    connect(m_checksProc, &QProcess::readyReadStandardOutput, this, [this]() {
        if (!m_checksProc)
            return;
        const QList<QByteArray> lines = m_checksProc->readAllStandardOutput().split('\n');
        for (const QByteArray &raw : lines) {
            const QByteArray line = raw.trimmed();
            if (line.isEmpty())
                continue;
            const QJsonObject obj = lineObject(line);
            if (obj.isEmpty())
                continue;
            const QString event = obj.value(QStringLiteral("event")).toString();
            if (event != QLatin1String("check") && event != QLatin1String("group")
                && event != QLatin1String("done"))
                continue;
            m_checks.append(obj.toVariantMap());
            if (event == QLatin1String("done")) {
                m_checkSummary = QStringLiteral("%1 passed, %2 failed, %3 skipped, "
                                               "%4 deliberate control")
                                     .arg(obj.value(QStringLiteral("passed")).toInt())
                                     .arg(obj.value(QStringLiteral("failed")).toInt())
                                     .arg(obj.value(QStringLiteral("skipped")).toInt())
                                     .arg(obj.value(QStringLiteral("control_failed")).toInt());
            }
            emit checksChanged();
        }
    });
    connect(m_checksProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this](int code, QProcess::ExitStatus) {
                m_checking = false;
                if (m_checkSummary.isEmpty())
                    m_checkSummary = QStringLiteral("the check runner exited with code %1 "
                                                    "before reporting a summary")
                                         .arg(code);
                emit checksChanged();
            });
    connect(m_checksProc, &QProcess::readyReadStandardError, this, [this]() {
        if (m_checksProc)
            appendLog(QString::fromUtf8(m_checksProc->readAllStandardError()));
    });
    m_checksProc->setProgram(pythonExe());
    m_checksProc->setArguments({tools + QStringLiteral("/stage4_checks.py"),
                            QStringLiteral("--group"),
                            group.isEmpty() ? QStringLiteral("all") : group});
    m_checksProc->start();
}

void LabsStage4::stopChecks()
{
    if (!m_checksProc)
        return;
    killProcess(m_checksProc);
    m_checking = false;
    emit checksChanged();
}
