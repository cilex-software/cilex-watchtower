#include "Artifacts.h"

#include <QDateTime>
#include <QDir>
#include <QRegularExpression>
#include <QStandardPaths>

Artifacts::Artifacts(QObject *parent)
    : QObject(parent)
{
}

QString Artifacts::snapshotDir() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
    if (base.isEmpty())
        base = QDir::homePath();
    const QString dir = base + QStringLiteral("/Watchtower");
    QDir().mkpath(dir);
    return dir;
}

QString Artifacts::newSnapshotPath(const QString &camId) const
{
    QString safeId = camId;
    safeId.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    const QString stamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
    return snapshotDir() + QStringLiteral("/%1_%2.png").arg(safeId, stamp);
}
