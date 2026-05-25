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
