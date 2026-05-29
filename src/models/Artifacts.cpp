#include "Artifacts.h"

#include <QDateTime>
#include <QDir>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>

Artifacts::Artifacts(QObject *parent)
    : QObject(parent)
{
}

QString Artifacts::defaultSnapshotDir() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
    if (base.isEmpty())
        base = QDir::homePath();
    return base + QStringLiteral("/Watchtower");
}

QString Artifacts::snapshotDir() const
{
    QString dir = m_settings.value(QStringLiteral("snapshots/dir")).toString();
    if (dir.isEmpty())
        dir = defaultSnapshotDir();
    QDir().mkpath(dir);
    return dir;
}

void Artifacts::setSnapshotDir(const QString &dir)
{
    QString d = dir;
    if (d.startsWith(QLatin1String("file:")))   // from the QML FolderDialog
        d = QUrl(d).toLocalFile();
    if (d == m_settings.value(QStringLiteral("snapshots/dir")).toString())
        return;
    m_settings.setValue(QStringLiteral("snapshots/dir"), d);
    if (!d.isEmpty())
        QDir().mkpath(d);
    emit snapshotDirChanged();
}

QString Artifacts::newSnapshotPath(const QString &camId) const
{
    QString safeId = camId;
    safeId.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    const QString stamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
    return snapshotDir() + QStringLiteral("/%1_%2.png").arg(safeId, stamp);
}

QString Artifacts::defaultExportDir() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::MoviesLocation);
    if (base.isEmpty())
        base = QDir::homePath();
    return base + QStringLiteral("/Watchtower");
}

QString Artifacts::exportDir() const
{
    QString dir = m_settings.value(QStringLiteral("exports/dir")).toString();
    if (dir.isEmpty())
        dir = defaultExportDir();
    QDir().mkpath(dir);
    return dir;
}

void Artifacts::setExportDir(const QString &dir)
{
    QString d = dir;
    if (d.startsWith(QLatin1String("file:")))   // from the QML FolderDialog
        d = QUrl(d).toLocalFile();
    if (d == m_settings.value(QStringLiteral("exports/dir")).toString())
        return;
    m_settings.setValue(QStringLiteral("exports/dir"), d);
    if (!d.isEmpty())
        QDir().mkpath(d);
    emit exportDirChanged();
}

QString Artifacts::newExportPath(const QString &camId, const QString &ext) const
{
    QString safeId = camId;
    safeId.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    if (safeId.isEmpty())
        safeId = QStringLiteral("clip");
    const QString stamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
    return exportDir() + QStringLiteral("/%1_%2.%3").arg(safeId, stamp, ext);
}
