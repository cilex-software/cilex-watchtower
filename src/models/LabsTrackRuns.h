#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

// Local run evidence for the Labs temporal-tracks view: what ran, on which
// bytes, with which configuration, and what it found. Runs are saved under the
// application's own data location (isolated per instance), listed and reopened
// inside Watchtower, and never leave the machine. A saved document carries the
// input identity (path, size, mtime, sha256), the engine revision and module
// digests, the scope and time basis, the counts, the tracks and the problems,
// which is exactly what a later reader needs to reproduce or distrust the run.
//
// runId is validated before it touches a path: it becomes a file name.
class LabsTrackRuns : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString runsDir READ runsDir CONSTANT)
public:
    explicit LabsTrackRuns(QObject *parent = nullptr);

    QString runsDir() const { return m_dir; }

    // Candidate local recordings in `dir` (the product's export directory, or
    // any directory the operator points at): name, size, mtime -- nothing
    // probed or guessed. Newest first, capped, so a full export folder cannot
    // stall the picker.
    Q_INVOKABLE QVariantList listInputs(const QString &dir) const;

    Q_INVOKABLE QString saveRun(const QVariantMap &doc);
    Q_INVOKABLE QVariantList listRuns(const QString &analyserFilter = QString()) const;
    Q_INVOKABLE QVariantMap loadRun(const QString &runId) const;
    Q_INVOKABLE bool removeRun(const QString &runId);

    static bool validRunId(const QString &id);

private:
    QString m_dir;
};
