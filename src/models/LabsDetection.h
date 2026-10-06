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

// Labs — the Stage 3 semantic analysers (objects + object-linked colours), as a
// second, separately identifiable analyser workspace beside the temporal tracker.
//
// The inference itself lives in tools/labs/stage3_detect.py (one ffmpeg decode
// pass, torchvision COCO detector, colour sampling) and runs as ONE child process
// so nothing blocks the GUI thread and a cancelled run can be stopped cleanly.
// This class owns that process, parses its JSONL progress, indexes the run's
// observations, asks the evaluator (tools/labs/stage3_evaluate.py) to validate the
// result and to find per-target candidates, and writes the reviewer's decisions.
//
// SEPARATION THAT MATTERS: expected targets come from the evaluator, never from
// the detector; this class never merges them into the run the detector produced.
// A candidate is `review_required` until a named reviewer decides, and the review
// is stored beside — not inside — the immutable analyser output.
class LabsDetection : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QVariantList recordings READ recordings NOTIFY recordingsChanged)
    Q_PROPERTY(QString exportDir READ exportDir WRITE setExportDir NOTIFY recordingsChanged)
    Q_PROPERTY(QString stage3Dir READ stage3Dir NOTIFY recordingsChanged)

    Q_PROPERTY(QString recording READ recording WRITE setRecording NOTIFY jobChanged)
    Q_PROPERTY(QString recordingName READ recordingName NOTIFY jobChanged)
    Q_PROPERTY(QString clipId READ clipId WRITE setClipId NOTIFY jobChanged)
    Q_PROPERTY(QString backend READ backend WRITE setBackend NOTIFY jobChanged)
    Q_PROPERTY(double sampleFps READ sampleFps WRITE setSampleFps NOTIFY jobChanged)
    Q_PROPERTY(double scoreThreshold READ scoreThreshold WRITE setScoreThreshold
                   NOTIFY jobChanged)
    Q_PROPERTY(QVariantMap probe READ probe NOTIFY jobChanged)
    Q_PROPERTY(QVariantMap modelState READ modelState NOTIFY jobChanged)
    Q_PROPERTY(QVariantList backends READ backends NOTIFY jobChanged)

    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY stateChanged)
    Q_PROPERTY(bool running READ running NOTIFY stateChanged)
    Q_PROPERTY(bool partial READ partial NOTIFY stateChanged)
    Q_PROPERTY(bool hasResult READ hasResult NOTIFY stateChanged)
    Q_PROPERTY(double progress READ progress NOTIFY stateChanged)
    Q_PROPERTY(QString errorCode READ errorCode NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap summary READ summary NOTIFY stateChanged)
    Q_PROPERTY(QString runDir READ runDir NOTIFY stateChanged)

    Q_PROPERTY(QVariantList observations READ observations NOTIFY observationsChanged)
    Q_PROPERTY(QVariantList targets READ targets NOTIFY targetsChanged)
    Q_PROPERTY(QVariantMap targetInfo READ targetInfo NOTIFY targetsChanged)
    Q_PROPERTY(QVariantMap evaluation READ evaluation NOTIFY targetsChanged)
    Q_PROPERTY(QVariantList decisions READ decisions NOTIFY targetsChanged)
    Q_PROPERTY(QString reviewPath READ reviewPath NOTIFY targetsChanged)
    Q_PROPERTY(QString selectedObservation READ selectedObservation NOTIFY selectionChanged)
    Q_PROPERTY(QVariantMap selectedDetail READ selectedDetail NOTIFY selectionChanged)

    Q_PROPERTY(QVariantList runs READ runs NOTIFY runsChanged)
    Q_PROPERTY(QVariantList checks READ checks NOTIFY checksChanged)
    Q_PROPERTY(bool checking READ checking NOTIFY stateChanged)
    Q_PROPERTY(QString checkSummary READ checkSummary NOTIFY checksChanged)

public:
    explicit LabsDetection(QObject *parent = nullptr);
    ~LabsDetection() override;

    QVariantList recordings() const { return m_recordings; }
    QString exportDir() const { return m_exportDir; }
    void setExportDir(const QString &dir);
    QString stage3Dir() const;

    QString recording() const { return m_recording; }
    void setRecording(const QString &path);
    QString recordingName() const;
    QString clipId() const { return m_clipId; }
    void setClipId(const QString &v);
    QString backend() const { return m_backend; }
    void setBackend(const QString &v);
    double sampleFps() const { return m_sampleFps; }
    void setSampleFps(double v);
    double scoreThreshold() const { return m_scoreThreshold; }
    void setScoreThreshold(double v);
    QVariantMap probe() const { return m_probe; }
    QVariantMap modelState() const { return m_modelState; }
    QVariantList backends() const;

    QString status() const { return m_status; }
    QString statusText() const { return m_statusText; }
    bool running() const;
    bool partial() const { return m_partial; }
    bool hasResult() const { return m_hasResult; }
    double progress() const { return m_progress; }
    QString errorCode() const { return m_errorCode; }
    QString errorText() const { return m_errorText; }
    QVariantMap summary() const { return m_summary; }
    QString runDir() const { return m_runDir; }

    QVariantList observations() const { return m_observations; }
    QVariantList targets() const { return m_targets; }
    QVariantMap targetInfo() const { return m_targetInfo; }
    QVariantMap evaluation() const { return m_evaluation; }
    QVariantList decisions() const { return m_decisions; }
    QString reviewPath() const { return m_reviewPath; }
    QString selectedObservation() const { return m_selected; }
    QVariantMap selectedDetail() const;
    QVariantList runs() const { return m_runs; }
    QVariantList checks() const { return m_checks; }
    bool checking() const;
    QString checkSummary() const { return m_checkSummary; }

    // The observations whose decoded PTS is at or before `ptsMs` and within
    // `toleranceMs` of it: what the picture should show, with the frame's own time.
    Q_INVOKABLE QVariantMap observationsAt(qint64 ptsMs, qint64 toleranceMs = 900) const;
    Q_INVOKABLE void selectObservation(const QString &id);
    Q_INVOKABLE QVariantList observationsFor(const QString &targetId) const;

    Q_INVOKABLE void refreshRecordings();
    Q_INVOKABLE void probeRecording();
    Q_INVOKABLE void probeModel();
    Q_INVOKABLE void start();
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void refreshRuns();
    Q_INVOKABLE void openRun(const QString &dir);
    Q_INVOKABLE void evaluateRun();
    Q_INVOKABLE void decide(const QString &targetId, const QString &decision,
                            const QVariantList &observationIds, const QString &note);
    Q_INVOKABLE void clearDecisions();
    Q_INVOKABLE void runChecks(const QString &group);
    Q_INVOKABLE void stopChecks();
    Q_INVOKABLE QString toolsDir() const;

signals:
    void recordingsChanged();
    void jobChanged();
    void stateChanged();
    void observationsChanged();
    void targetsChanged();
    void selectionChanged();
    void runsChanged();
    void checksChanged();

private slots:
    void stopChildren();
    void onRunStdout();
    void onRunFinished(int code, QProcess::ExitStatus status);
    void onEvalFinished(int code, QProcess::ExitStatus status);
    void onProbeFinished(int code, QProcess::ExitStatus status);
    void onModelProbeFinished(int code, QProcess::ExitStatus status);
    void onTargetsFinished(int code, QProcess::ExitStatus status);
    void requestTargetInfo();
    void onCheckStdout();
    void onCheckFinished(int code, QProcess::ExitStatus status);
    void refreshModelState();

private:
    void setStatus(const QString &status, const QString &text);
    void fail(const QString &code, const QString &text);
    void loadRun(const QString &dir);
    void indexObservations(const QString &path);
    void writeReviewFile();
    QString runsRoot() const;
    static void killProcess(QProcess *&slot);

    QString m_exportDir;
    QVariantList m_recordings;
    QString m_recording;
    QString m_clipId;
    QString m_backend = QStringLiteral("fasterrcnn-mobilenet320");
    double m_sampleFps = 2.5;
    double m_scoreThreshold = 0.55;
    QVariantMap m_probe;
    QVariantMap m_modelState;

    QProcess *m_run = nullptr;
    QProcess *m_eval = nullptr;
    QProcess *m_probeProc = nullptr;
    QProcess *m_modelProc = nullptr;
    QProcess *m_targetsProc = nullptr;
    QProcess *m_check = nullptr;
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

    QVariantList m_observations;
    QVariantList m_targets;          // target rows from the evaluator (annotations)
    QVariantMap m_targetInfo;        // target_id -> description/required colours
    QVariantMap m_evaluation;        // last evaluator result
    QVariantList m_decisions;        // reviewer decisions, kept outside the run
    QString m_reviewPath;
    QString m_selected;
    QVector<qint64> m_obsPts;        // ascending PTS of the indexed observations
    QVector<int> m_obsRow;           // observation row for each PTS entry

    QVariantList m_runs;
    QVariantList m_checks;
    QString m_checkSummary;
    int m_checkIndex = 0;
};
