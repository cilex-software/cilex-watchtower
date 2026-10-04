#pragma once

#include <QFile>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>
#include <QtQml/qqmlregistration.h>

// Labs tracking: run the temporal tracking engine over a recording the operator
// picked inside Watchtower, review its tracks beside that recording, and run the
// verification checks -- all from the Labs screen.
//
// The analysis itself lives in tools/labs/temporal_tracks_run.py (the existing
// frame_source decoder + labs_foreground_mask detector + the contract engine),
// run as ONE child process so decoding never touches the GUI thread and a
// cancelled run leaves nothing behind. This class owns that process, parses its
// JSONL progress, indexes the run's per-frame evidence ledger, and exposes
// tracks/samples to QML.
//
// HONESTY RULES THIS CLASS KEEPS:
//   * a track sample is a REAL observed instant. samplesAt() returns the most
//     recent observed frame at or before a playback time and reports its own
//     timestamp; nothing is interpolated to fit the player, and no box is
//     invented between observations.
//   * completed / cancelled / no-detections / failed are four different states.
//     A cancelled run keeps its partial evidence, labelled partial.
//   * a missing recording, a missing interpreter or a missing tools directory
//     is reported as the specific prerequisite it is, never as a failed run.
class LabsTracking : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QVariantList recordings READ recordings NOTIFY recordingsChanged)
    Q_PROPERTY(QString exportDir READ exportDir WRITE setExportDir
                   NOTIFY recordingsChanged)

    Q_PROPERTY(QString recording READ recording WRITE setRecording NOTIFY jobChanged)
    Q_PROPERTY(QString recordingName READ recordingName NOTIFY jobChanged)
    Q_PROPERTY(QString cameraId READ cameraId WRITE setCameraId NOTIFY jobChanged)
    Q_PROPERTY(QString unitId READ unitId WRITE setUnitId NOTIFY jobChanged)
    Q_PROPERTY(QString startUtc READ startUtc WRITE setStartUtc NOTIFY jobChanged)
    Q_PROPERTY(QString startSource READ startSource NOTIFY jobChanged)
    Q_PROPERTY(int maxFrames READ maxFrames WRITE setMaxFrames NOTIFY jobChanged)
    Q_PROPERTY(int startOffsetS READ startOffsetS WRITE setStartOffsetS NOTIFY jobChanged)
    Q_PROPERTY(QVariantMap engineConfig READ engineConfig WRITE setEngineConfig
                   NOTIFY jobChanged)
    Q_PROPERTY(QVariantMap probe READ probe NOTIFY jobChanged)

    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY stateChanged)
    Q_PROPERTY(bool running READ running NOTIFY stateChanged)
    Q_PROPERTY(bool partial READ partial NOTIFY stateChanged)
    Q_PROPERTY(bool hasResult READ hasResult NOTIFY stateChanged)
    Q_PROPERTY(double progress READ progress NOTIFY stateChanged)
    Q_PROPERTY(QString errorCode READ errorCode NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap summary READ summary NOTIFY stateChanged)
    Q_PROPERTY(QVariantList tracks READ tracks NOTIFY tracksChanged)
    Q_PROPERTY(QVariantList runs READ runs NOTIFY runsChanged)
    Q_PROPERTY(QString runDir READ runDir NOTIFY stateChanged)

    Q_PROPERTY(QVariantList checks READ checks NOTIFY checksChanged)
    Q_PROPERTY(bool checking READ checking NOTIFY stateChanged)
    Q_PROPERTY(QString checkSummary READ checkSummary NOTIFY checksChanged)
    Q_PROPERTY(QString checkRecording READ checkRecording NOTIFY checksChanged)

public:
    explicit LabsTracking(QObject *parent = nullptr);
    ~LabsTracking() override;

    QVariantList recordings() const { return m_recordings; }
    QString exportDir() const { return m_exportDir; }
    void setExportDir(const QString &dir);

    QString recording() const { return m_recording; }
    void setRecording(const QString &path);
    QString recordingName() const;
    QString cameraId() const { return m_cameraId; }
    void setCameraId(const QString &v);
    QString unitId() const { return m_unitId; }
    void setUnitId(const QString &v);
    QString startUtc() const { return m_startUtc; }
    void setStartUtc(const QString &v);
    QString startSource() const { return m_startSource; }
    int maxFrames() const { return m_maxFrames; }
    void setMaxFrames(int v);
    int startOffsetS() const { return m_startOffsetS; }
    void setStartOffsetS(int v);
    QVariantMap engineConfig() const { return m_engineConfig; }
    void setEngineConfig(const QVariantMap &v);
    QVariantMap probe() const { return m_probe; }

    QString status() const { return m_status; }
    QString statusText() const { return m_statusText; }
    bool running() const { return m_run && m_run->state() != QProcess::NotRunning; }
    bool partial() const { return m_partial; }
    bool hasResult() const { return m_hasResult; }
    double progress() const { return m_progress; }
    QString errorCode() const { return m_errorCode; }
    QString errorText() const { return m_errorText; }
    QVariantMap summary() const { return m_summary; }
    QVariantList tracks() const { return m_tracks; }
    QVariantList runs() const { return m_runs; }
    QString runDir() const { return m_runDir; }

    QVariantList checks() const { return m_checks; }
    bool checking() const { return m_check && m_check->state() != QProcess::NotRunning; }
    QString checkSummary() const { return m_checkSummary; }
    QString checkRecording() const { return m_checkRecording; }

    // The most recent OBSERVED frame at or before `fileMs`, with its own time
    // and an age. found=false before the first observation of the run.
    Q_INVOKABLE QVariantMap samplesAt(qint64 fileMs) const;
    Q_INVOKABLE QVariantList trackSamples(const QString &trackId) const;
    Q_INVOKABLE QVariantList trackObservations(const QString &trackId) const;

    Q_INVOKABLE void refreshRecordings();
    Q_INVOKABLE void probeRecording();
    Q_INVOKABLE void start();
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void refreshRuns();
    Q_INVOKABLE void openRun(const QString &dir);
    Q_INVOKABLE void startChecks(const QString &group);
    Q_INVOKABLE void stopChecks();
    Q_INVOKABLE QString defaultEngineConfigJson() const;

signals:
    void recordingsChanged();
    void jobChanged();
    void stateChanged();
    void tracksChanged();
    void runsChanged();
    void checksChanged();
    void progressChanged();

private slots:
    // Children are stopped while the event loop is still running (aboutToQuit), NOT
    // from the destructor: the destructor runs inside QQmlApplicationEngine's own
    // cleanup, and waiting on a live child there re-enters a half-destroyed engine
    // (measured 2026-10-04: SIGSEGV in QQmlApplicationEnginePrivate::cleanUp when the
    // app was closed during a run).
    void stopChildren();
    void onRunStdout();
    void onRunStderr();
    void onRunFinished(int code, QProcess::ExitStatus status);
    void onCheckStdout();
    void onCheckFinished(int code, QProcess::ExitStatus status);
    void onProbeFinished(int code, QProcess::ExitStatus status);

private:
    void setStatus(const QString &status, const QString &text);
    void fail(const QString &code, const QString &text);
    QString toolsDir() const;
    QString pythonExe() const;
    QString runsRoot() const;
    QString suggestStartFor(const QString &path, QString *source) const;
    void loadResult(const QString &dir);
    void indexLedger(const QString &path);
    void appendCheck(const QVariantMap &row);
    void killProcess(QProcess *&proc);

    QString m_exportDir;
    QVariantList m_recordings;
    QString m_recording;
    QString m_cameraId;
    QString m_unitId = QStringLiteral("labs-tracking");
    QString m_startUtc;
    QString m_startSource = QStringLiteral("operator");
    int m_maxFrames = 900;
    int m_startOffsetS = 0;
    QVariantMap m_engineConfig;
    QVariantMap m_probe;

    QProcess *m_run = nullptr;
    QProcess *m_check = nullptr;
    QProcess *m_probeProc = nullptr;
    QTimer m_killTimer;
    QString m_runDir;
    QString m_status = QStringLiteral("idle");
    QString m_statusText = QStringLiteral("No analysis has been run yet.");
    QString m_errorCode;
    QString m_errorText;
    bool m_partial = false;
    bool m_hasResult = false;
    double m_progress = 0.0;
    QVariantMap m_summary;

    QVariantList m_tracks;
    QVariantList m_runs;
    QVector<qint64> m_sampleTimes;    // observed frame instants, ascending
    QVector<qint64> m_sampleOffsets;  // byte offset of each line in frames.jsonl
    QString m_ledgerPath;
    QFile m_ledger;

    QVariantList m_checks;
    QString m_checkSummary;
    QString m_checkRecording;
    int m_checkIndex = 0;
};
