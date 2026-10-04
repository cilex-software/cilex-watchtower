#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QVariantMap>

// One temporal-tracks analysis of one local recording, driven from the Labs
// screen. The work itself lives in tools/labs/temporal_tracks_clip.py -- the same
// engine, adapter and decode pass the offline suite tests -- run as a CHILD
// PROCESS so a decode or a NumPy fault can never take the UI down, and so
// cancellation is a signal rather than a flag poll. This class owns exactly the
// product half: resolving the tools tree and the interpreter, launching, parsing
// the JSON line protocol, reporting progress, cancelling, and handing the
// finished run document to LabsTrackRuns.
//
// States are deliberately distinct because the operator must never read one for
// another: "missing" = the tools tree or python3 is not beside this binary;
// "failed" = the run refused its input or crashed; "cancelled" = the operator
// stopped it (its partial evidence is still labelled cancelled); "completed" =
// the whole bounded window was analysed; "empty" = completed with no detections.
// A stale result is never shown as current: `result` is only ever the document
// of THIS object's own latest run, and `runId` names it.
class LabsTrackJob : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    Q_PROPERTY(int percent READ percent NOTIFY progressChanged)
    Q_PROPERTY(QString statusLine READ statusLine NOTIFY progressChanged)
    Q_PROPERTY(int framesDecoded READ framesDecoded NOTIFY progressChanged)
    Q_PROPERTY(int observationsSeen READ observationsSeen NOTIFY progressChanged)
    Q_PROPERTY(int episodesClosed READ episodesClosed NOTIFY progressChanged)
    Q_PROPERTY(QVariantMap result READ result NOTIFY resultChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(QString runId READ runId NOTIFY stateChanged)
    Q_PROPERTY(QString inputPath READ inputPath NOTIFY stateChanged)
    Q_PROPERTY(bool toolsAvailable READ toolsAvailable NOTIFY stateChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY stateChanged)
    Q_PROPERTY(bool started READ started NOTIFY stateChanged)
    Q_PROPERTY(QString toolsDir READ toolsDir CONSTANT)
public:
    explicit LabsTrackJob(QObject *parent = nullptr);
    ~LabsTrackJob() override;

    QString state() const { return m_state; }
    int percent() const { return m_percent; }
    QString statusLine() const { return m_statusLine; }
    int framesDecoded() const { return m_frames; }
    int observationsSeen() const { return m_obs; }
    int episodesClosed() const { return m_eps; }
    QVariantMap result() const { return m_result; }
    QString errorText() const { return m_error; }
    QString runId() const { return m_runId; }
    QString inputPath() const { return m_input; }
    bool toolsAvailable() const;
    QString toolsDir() const { return m_toolsDir; }
    bool busy() const { return m_proc != nullptr; }
    bool started() const { return m_started; }

    // originEpochMs < 0 means "the footage's wall-clock origin is not known":
    // the flag is then not passed at all and every time in the document stays
    // clip-relative, which the document and the UI both say out loud.
    Q_INVOKABLE void startRun(const QString &path, const QString &cameraId,
                              const QString &unitId, const QString &label,
                              double originEpochMs, const QString &configJson,
                              double maxSeconds, int maxFrames);
    Q_INVOKABLE void cancel();

signals:
    void stateChanged();
    void progressChanged();
    void resultChanged();

private:
    void setState(const QString &s);
    void onStdout();
    void handleLine(const QByteArray &line);
    void finishProcess(int code, int exitStatus);

    QProcess *m_proc = nullptr;
    QByteArray m_buf;
    QString m_state = QStringLiteral("idle");
    QString m_statusLine;
    QString m_error;
    QString m_runId;
    QString m_input;
    QString m_toolsDir;
    QString m_tail;
    QVariantMap m_result;
    int m_percent = 0;
    int m_frames = 0;
    int m_obs = 0;
    int m_eps = 0;
    bool m_cancelAsked = false;
    bool m_started = false;
};
