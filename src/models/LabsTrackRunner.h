#pragma once

#include <QObject>
#include <QByteArray>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// LabsTrackRunner — the C++ side of the Labs "Tracking" view: it runs the
// product-owned Python helper (tools/labs/track_run.py) as a child process,
// never on the UI thread, for three jobs:
//
//   * probe   — identity of one local recording (size, sha256, real codec/rate,
//               suggested scope/time mapping parsed from a Watchtower export name);
//   * run     — decode + foreground detections + the temporal tracking engine,
//               producing one atomic evidence JSON per run;
//   * verify  — the in-app check suites (contract cases, Labs regressions, the
//               streaming workload, integration checks incl. an optional
//               deliberate failure control), streamed as JSONL check results.
//
// Evidence lives under wtlabs::stateDir()/track-runs/, so runs can be reopened
// after a restart. Cancellation kills the child and records the run as
// cancelled — never as completed; a killed run leaves no completed evidence
// behind. A missing helper/python/OpenCV is reported as an explicit failure,
// not as a pass.
class LabsTrackRunner : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    // "idle" | "probing" | "running" | "verifying"; the terminal states live on
    // the finished run/verification, so the control itself returns to idle.
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    Q_PROPERTY(double progress READ progress NOTIFY progressChanged)        // 0..1, -1 indeterminate
    Q_PROPERTY(QString progressDetail READ progressDetail NOTIFY progressChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    Q_PROPERTY(QVariantList runs READ runs NOTIFY runsChanged)              // run summaries, newest first
    Q_PROPERTY(QVariantMap selectedRun READ selectedRun NOTIFY selectedRunChanged)
    Q_PROPERTY(QVariantList checks READ checks NOTIFY checksChanged)        // live verification rows
    Q_PROPERTY(QVariantMap verifySummary READ verifySummary NOTIFY verifySummaryChanged)
    Q_PROPERTY(QString verifySuite READ verifySuite NOTIFY verifySummaryChanged)
    Q_PROPERTY(bool helperAvailable READ helperAvailable NOTIFY helperChanged)
    Q_PROPERTY(QString helperProblem READ helperProblem NOTIFY helperChanged)
    Q_PROPERTY(QString evidenceDir READ evidenceDir CONSTANT)

public:
    explicit LabsTrackRunner(QObject *parent = nullptr);
    ~LabsTrackRunner() override;

    QString state() const { return m_state; }
    double progress() const { return m_progress; }
    QString progressDetail() const { return m_progressDetail; }
    QString lastError() const { return m_lastError; }
    QVariantList runs() const { return m_runs; }
    QVariantMap selectedRun() const { return m_selectedRun; }
    QVariantList checks() const { return m_checks; }
    QVariantMap verifySummary() const { return m_verifySummary; }
    QString verifySuite() const { return m_verifySuite; }
    bool helperAvailable() const { return m_helperOk; }
    QString helperProblem() const { return m_helperProblem; }
    QString evidenceDir() const;

    Q_INVOKABLE void probeFile(const QString &path);
    Q_INVOKABLE void startRun(const QString &path, const QString &cameraId,
                              const QString &startIso, const QString &origin,
                              const QString &configJson, bool synthetic);
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void refreshRuns();
    Q_INVOKABLE void openRun(const QString &runId);
    Q_INVOKABLE void deleteRun(const QString &runId);
    Q_INVOKABLE void verify(const QString &suite, bool failureControl);
    Q_INVOKABLE void cancelVerify();
    Q_INVOKABLE void clearError() { setLastError(QString()); }

signals:
    void stateChanged();
    void progressChanged();
    void lastErrorChanged();
    void runsChanged();
    void selectedRunChanged();
    void checksChanged();
    void verifySummaryChanged();
    void helperChanged();
    void probeReady(const QVariantMap &info);
    void probeFailed(const QString &message);
    void runFinished(const QString &runId, const QString &status);
    void verifyFinished(const QString &suite, int failed);

private:
    enum class Job { None, Probe, Run, Verify };

    void probeHelper();                     // fill m_helperOk/m_helperProblem
    QString helperScript() const;
    QString pythonExe() const;
    void startJob(Job job, const QStringList &args);
    void killJob();
    void setState(const QString &s);
    void setProgress(double p, const QString &detail);
    void setLastError(const QString &e);
    void finishRun(int code, QProcess::ExitStatus st);
    void finishVerify(int code, QProcess::ExitStatus st);
    void finishProbe(int code, QProcess::ExitStatus st);
    static QVariantMap runSummary(const QVariantMap &ev);

    QProcess *m_proc = nullptr;
    Job m_job = Job::None;
    QString m_state = QStringLiteral("idle");
    double m_progress = -1.0;
    QString m_progressDetail;
    QString m_lastError;
    QString m_stderrTail;
    QByteArray m_stdoutBuf;
    QVariantList m_runs;
    QVariantMap m_selectedRun;
    QVariantList m_checks;
    QVariantMap m_verifySummary;
    QString m_verifySuite;
    bool m_helperOk = false;
    QString m_helperProblem;
    // what an in-flight run was started with (for the cancelled stub record)
    QVariantMap m_pending;
    QString m_pendingOut;
    bool m_cancelled = false;
};
