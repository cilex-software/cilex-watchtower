#include "SnapshotModel.h"

#include <QDir>
#include <QFileInfo>
#include <QDateTime>
#include <QUrl>
#include <QRegularExpression>
#include <algorithm>

SnapshotModel::SnapshotModel(QObject *parent)
    : QObject(parent)
{
}

void SnapshotModel::setDir(const QString &d)
{
    if (d == m_dir)
        return;
    m_dir = d;
    refresh();
}

void SnapshotModel::refresh()
{
    m_items.clear();
    QDir dir(m_dir);
    if (!m_dir.isEmpty() && dir.exists()) {
        // Filenames are "<camId>_<yyyyMMdd>_<HHmmss>.png" (Artifacts::newSnapshotPath).
        static const QRegularExpression re(QStringLiteral("^(.*)_([0-9]{8})_([0-9]{6})$"));
        const auto files = dir.entryInfoList({ "*.png", "*.jpg", "*.jpeg" }, QDir::Files);
        for (const QFileInfo &fi : files) {
            QString cam = fi.completeBaseName();
            QDateTime cap = fi.lastModified();
            const auto m = re.match(fi.completeBaseName());
            if (m.hasMatch()) {
                cam = m.captured(1);
                const QDateTime parsed = QDateTime::fromString(m.captured(2) + m.captured(3),
                                                               QStringLiteral("yyyyMMddHHmmss"));
                if (parsed.isValid())
                    cap = parsed;
            }
            QVariantMap row;
            row["type"] = QStringLiteral("snapshot");
            row["filePath"] = fi.absoluteFilePath();
            row["fileUrl"] = QUrl::fromLocalFile(fi.absoluteFilePath()).toString();
            row["fileName"] = fi.fileName();
            row["camera"] = cam;
            row["title"] = cam.isEmpty() ? fi.fileName() : (QStringLiteral("Snapshot — ") + cam);
            row["capturedIso"] = cap.toString(Qt::ISODate);
            row["bytes"] = static_cast<qlonglong>(fi.size());
            m_items.append(row);
        }
        // newest first
        std::sort(m_items.begin(), m_items.end(), [](const QVariant &a, const QVariant &b) {
            return a.toMap().value("capturedIso").toString() > b.toMap().value("capturedIso").toString();
        });
    }
    emit changed();
}
