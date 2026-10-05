#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

// Stage-3 semantic analysis controller for the Labs screen.
//
// It drives TWO product-owned Python helpers as child processes and nothing
// else: tools/labs/semantic_objects.py (decode + detect + colour, the same
// code the terminal and the tests use) and tools/labs/stage3_checklist.py (the
// only reader of the public target manifest, plus reviewer decisions). Keeping
// the work in a child means a decoder or model fault can never take the UI down,
// cancellation is a signal, and the GUI thread only parses JSON lines.
//
// States are distinct on purpose: "missing" = weights/runtime absent (a
// prerequisite failure, never a no-detection success), "failed" = the run
// refused its input or crashed, "cancelled" = the operator stopped it,
// "completed" = the whole requested window was analysed, "empty" = completed
// with zero observations. A run document is only exposed through `runDoc` for
// THIS controller's own latest run, so one clip's evidence can never appear
// under another clip's name.
class LabsSemanticJob : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    Q_PROPERTY(int percent READ percent NOTIFY progressChanged)
    Q_PROPERTY(QString statusLine READ statusLine NOTIFY progressChanged)
    Q_PROPERTY(int decoded READ decoded NOTIFY progressChanged)
    Q_PROPERTY(int inferred READ inferred NOTIFY progressChanged)
    Q_PROPERTY(int observations READ observations NOTIFY progressChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(QString runId READ runId NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap runDoc READ runDoc NOTIFY resultChanged)
    Q_PROPERTY(QString runPath READ runPath NOTIFY resultChanged)
    Q_PROPERTY(QVariantMap manifest READ manifest NOTIFY manifestChanged)
    Q_PROPERTY(bool modelsAvailable READ modelsAvailable NOTIFY manifestChanged)
    Q_PROPERTY(QString toolsDir READ toolsDir CONSTANT)
    Q_PROPERTY(QString stage3Dir READ stage3Dir WRITE setStage3Dir NOTIFY stage3DirChanged)
public:
    explicit LabsSemanticJob(QObject *parent = nullptr);
    ~LabsSemanticJob() override;

    QString state() const { return m_state; }
    int percent() const { return m_percent; }
    QString statusLine() const { return m_statusLine; }
    int decoded() const { return m_decoded; }
    int inferred() const { return m_inferred; }
    int observations() const { return m_obs; }
    bool busy() const { return m_proc != nullptr; }
    QString errorText() const { return m_error; }
    QString runId() const { return m_runId; }
    QVariantMap runDoc() const { return m_runDoc; }
    QString runPath() const { return m_runPath; }
    // CASES.md S3-C02: same bytes under another neutral name. The copy is
    // made by the product so the equivalence control uses the real analyser
    // on real bytes, never a canned comparison.
    Q_INVOKABLE QString copyForVerification(const QString &path);
    QVariantMap manifest() const { return m_manifest; }
    bool modelsAvailable() const;
    QString toolsDir() const { return m_toolsDir; }
    QString stage3Dir() const;
    void setStage3Dir(const QString &d);

    // opts: clipId, schedule, sampleFps, conf, imgsz, decodeWidth, maxFrames,
    // crops, tracks, classes, cameraId, unitId.
    Q_INVOKABLE void startRun(const QString &path, const QVariantMap &opts);
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void loadManifest();

    // Checklist operations. Each spawns the checklist helper, waits (bounded)
    // and returns its parsed document; an empty map plus `error` means the
    // helper refused or timed out. These are synchronous on purpose: they are
    // JSON-only and take milliseconds, unlike a decode.
    Q_INVOKABLE QVariantMap evaluate(const QString &runPath, const QString &clipId);
    Q_INVOKABLE QVariantMap recordReview(const QString &runPath, const QString &clipId,
                                         const QString &reviewer, const QVariantList &decisions);
    Q_INVOKABLE QVariantMap controlInvalid(const QString &runPath, const QString &clipId);
    // Re-evaluate a run together with a stored review, so the checklist
    // shows the reviewer's decisions rather than only candidates.
    Q_INVOKABLE QVariantMap statusOf(const QString &runPath, const QString &reviewPath,
                                     const QString &clipId);

signals:
    void stateChanged();
    void progressChanged();
    void resultChanged();
    void manifestChanged();
    void stage3DirChanged();

private:
    void setState(const QString &s);
    void onStdout();
    void handleLine(const QByteArray &line);
    void finishProcess(int code, int exitStatus);
    QVariantMap runHelper(const QStringList &args, int timeoutMs, QString *err);

    QProcess *m_proc = nullptr;
    QByteArray m_buf;
    QString m_state = QStringLiteral("idle");
    QString m_statusLine;
    QString m_error;
    QString m_runId;
    QString m_runPath;
    QString m_toolsDir;
    QString m_tail;
    QVariantMap m_runDoc;
    QVariantMap m_manifest;
    int m_percent = 0;
    int m_decoded = 0;
    int m_inferred = 0;
    int m_obs = 0;
    bool m_cancelAsked = false;
};
