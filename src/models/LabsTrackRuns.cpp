#include "LabsTrackRuns.h"

#include <algorithm>

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStandardPaths>

namespace {
constexpr int kMaxListedInputs = 200;
const QStringList kVideoGlobs{ QStringLiteral("*.mp4"), QStringLiteral("*.mkv"),
                               QStringLiteral("*.mov"), QStringLiteral("*.m4v"),
                               QStringLiteral("*.webm"), QStringLiteral("*.ts") };
}

LabsTrackRuns::LabsTrackRuns(QObject *parent) : QObject(parent)
{
    m_dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
            + QStringLiteral("/labs-tracks");
    QDir().mkpath(m_dir);
}

bool LabsTrackRuns::validRunId(const QString &id)
{
    static const QRegularExpression re(QStringLiteral("\\A[A-Za-z0-9_-]{1,40}\\z"));
    return re.match(id).hasMatch();
}

QVariantList LabsTrackRuns::listInputs(const QString &dir) const
{
    QVariantList out;
    if (dir.isEmpty())
        return out;
    QDir d(dir);
    if (!d.exists())
        return out;
    const QFileInfoList files = d.entryInfoList(kVideoGlobs, QDir::Files, QDir::Size);
    // Newest first: the clip an operator exported a moment ago is the one they
    // mean. Size order would bury it under last year's hour-long export.
    QList<QFileInfo> sorted = files;
    std::sort(sorted.begin(), sorted.end(), [](const QFileInfo &a, const QFileInfo &b) {
        return a.lastModified() > b.lastModified();
    });
    for (const QFileInfo &fi : sorted) {
        if (out.size() >= kMaxListedInputs)
            break;
        QVariantMap m;
        m[QStringLiteral("path")] = fi.absoluteFilePath();
        m[QStringLiteral("name")] = fi.fileName();
        m[QStringLiteral("size")] = double(fi.size());
        m[QStringLiteral("mtimeMs")] = double(fi.lastModified().toMSecsSinceEpoch());
        out.append(m);
    }
    return out;
}

QString LabsTrackRuns::saveRun(const QVariantMap &doc)
{
    const QString id = doc.value(QStringLiteral("run_id")).toString();
    if (!validRunId(id))
        return QString();
    QVariantMap withSaved = doc;
    withSaved[QStringLiteral("saved_at")] =
        QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
    const QString path = m_dir + QLatin1Char('/') + id + QStringLiteral(".json");
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return QString();
    f.write(QJsonDocument(QJsonObject::fromVariantMap(withSaved)).toJson(QJsonDocument::Indented));
    f.close();
    return path;
}

QVariantList LabsTrackRuns::listRuns() const
{
    QVariantList out;
    const QFileInfoList files = QDir(m_dir).entryInfoList({ QStringLiteral("*.json") }, QDir::Files);
    QList<QFileInfo> sorted = files;
    std::sort(sorted.begin(), sorted.end(), [](const QFileInfo &a, const QFileInfo &b) {
        return a.lastModified() > b.lastModified();
    });
    for (const QFileInfo &fi : sorted) {
        QFile f(fi.absoluteFilePath());
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonDocument doc = QJsonDocument::fromJson(f.read(1 << 20));
        f.close();
        if (!doc.isObject())
            continue;
        const QVariantMap d = doc.object().toVariantMap();
        const QVariantMap in = d.value(QStringLiteral("input")).toMap();
        const QVariantMap counts = d.value(QStringLiteral("counts")).toMap();
        const QVariantMap scope = d.value(QStringLiteral("scope")).toMap();
        QVariantMap m;
        m[QStringLiteral("runId")] = d.value(QStringLiteral("run_id"));
        m[QStringLiteral("startedAt")] = d.value(QStringLiteral("started_at"));
        m[QStringLiteral("status")] = d.value(QStringLiteral("status"));
        m[QStringLiteral("inputName")] = QFileInfo(in.value(QStringLiteral("path")).toString()).fileName();
        m[QStringLiteral("inputPath")] = in.value(QStringLiteral("path"));
        m[QStringLiteral("inputSha")] = in.value(QStringLiteral("sha256"));
        m[QStringLiteral("timeBasis")] = scope.value(QStringLiteral("time_basis"));
        m[QStringLiteral("cameraId")] = scope.value(QStringLiteral("camera_id"));
        m[QStringLiteral("tracks")] = counts.value(QStringLiteral("tracks"));
        m[QStringLiteral("detections")] = counts.value(QStringLiteral("detections"));
        m[QStringLiteral("ambiguous")] = counts.value(QStringLiteral("ambiguous"));
        m[QStringLiteral("elapsedS")] = d.value(QStringLiteral("elapsed_s"));
        m[QStringLiteral("savedPath")] = fi.absoluteFilePath();
        out.append(m);
    }
    return out;
}

QVariantMap LabsTrackRuns::loadRun(const QString &runId) const
{
    if (!validRunId(runId))
        return QVariantMap();
    QFile f(m_dir + QLatin1Char('/') + runId + QStringLiteral(".json"));
    if (!f.open(QIODevice::ReadOnly))
        return QVariantMap();
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    f.close();
    return doc.isObject() ? doc.object().toVariantMap() : QVariantMap();
}

bool LabsTrackRuns::removeRun(const QString &runId)
{
    if (!validRunId(runId))
        return false;
    return QFile::remove(m_dir + QLatin1Char('/') + runId + QStringLiteral(".json"));
}
