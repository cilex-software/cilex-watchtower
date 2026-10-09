#pragma once

#include <QColor>
#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QHash>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>
#include <QtQml/qqmlregistration.h>

class QProcess;

// Stage 4 workspace: run the frozen A/B analysers over a recording, apply the V1
// filters to what came back, show the evidence each claim rests on, and keep the
// run's identity visible while doing it.
//
// The filters are implemented here as well as in tools/labs/stage4_filters.py
// because the operator filters interactively and the evaluator scores offline.
// The two are pinned to one shared case file (WT_LABS_STAGE4_FILTER_SELFTEST) so
// a divergence is a test failure rather than a silent difference of opinion.
class LabsStage4 : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantList recordings READ recordings NOTIFY recordingsChanged)
    Q_PROPERTY(QString clipsDir READ clipsDir NOTIFY recordingsChanged)
    Q_PROPERTY(QString runsDir READ runsDir NOTIFY recordingsChanged)

    Q_PROPERTY(QString recording READ recording WRITE setRecording NOTIFY jobChanged)
    Q_PROPERTY(QString recordingName READ recordingName NOTIFY jobChanged)
    Q_PROPERTY(QVariantMap probe READ probe NOTIFY jobChanged)
    Q_PROPERTY(QString approach READ approach WRITE setApproach NOTIFY jobChanged)
    Q_PROPERTY(QVariantList approaches READ approaches NOTIFY jobChanged)
    Q_PROPERTY(QVariantMap modelState READ modelState NOTIFY jobChanged)
    // Which revision of the Stage 4 artifacts this workspace is bound to, and
    // whether its files verified. The registry is the single source of truth the
    // panel, the controls and the evidence all read (tools/labs/stage4_revisions.py).
    Q_PROPERTY(QVariantMap revisionState READ revisionState NOTIFY jobChanged)
    // What a reopened run actually IS: immutable identity, coverage, and whether its
    // evidence/playback resources are still available. A completed historical run
    // whose files were moved is reported as unavailable, not as a failed run.
    Q_PROPERTY(QVariantMap runState READ runState NOTIFY resultChanged)
    Q_PROPERTY(double scoreThreshold READ scoreThreshold WRITE setScoreThreshold
               NOTIFY jobChanged)
    Q_PROPERTY(int decodeWidth READ decodeWidth WRITE setDecodeWidth NOTIFY jobChanged)

    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY stateChanged)
    Q_PROPERTY(bool running READ running NOTIFY stateChanged)
    Q_PROPERTY(bool hasResult READ hasResult NOTIFY stateChanged)
    Q_PROPERTY(QString runDir READ runDir NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap summary READ summary NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap metrics READ metrics NOTIFY stateChanged)
    Q_PROPERTY(QString logTail READ logTail NOTIFY stateChanged)

    // ---- V1 filters -----------------------------------------------------------
    Q_PROPERTY(QStringList filterTypes READ filterTypes WRITE setFilterTypes
               NOTIFY filtersChanged)
    Q_PROPERTY(QStringList filterSizes READ filterSizes WRITE setFilterSizes
               NOTIFY filtersChanged)
    Q_PROPERTY(QString filterLocation READ filterLocation WRITE setFilterLocation
               NOTIFY filtersChanged)
    Q_PROPERTY(QString filterColourHex READ filterColourHex WRITE setFilterColourHex
               NOTIFY filtersChanged)
    Q_PROPERTY(bool filterColourActive READ filterColourActive
               WRITE setFilterColourActive NOTIFY filtersChanged)
    Q_PROPERTY(double filterTolerance READ filterTolerance WRITE setFilterTolerance
               NOTIFY filtersChanged)
    Q_PROPERTY(bool includeUncertain READ includeUncertain WRITE setIncludeUncertain
               NOTIFY filtersChanged)
    // Time and camera/area are METADATA filters: they are satisfied by verified
    // recording metadata, never by visual inference, and a recording without that
    // metadata can never satisfy them (unknown is not "matches anything").
    Q_PROPERTY(QVariantMap recordingMeta READ recordingMeta WRITE setRecordingMeta
               NOTIFY filtersChanged)
    Q_PROPERTY(QString filterTimeFrom READ filterTimeFrom WRITE setFilterTimeFrom
               NOTIFY filtersChanged)
    Q_PROPERTY(QString filterTimeTo READ filterTimeTo WRITE setFilterTimeTo
               NOTIFY filtersChanged)
    Q_PROPERTY(QString filterCamera READ filterCamera WRITE setFilterCamera
               NOTIFY filtersChanged)
    Q_PROPERTY(QString filterArea READ filterArea WRITE setFilterArea
               NOTIFY filtersChanged)
    Q_PROPERTY(QVariantList filtered READ filtered NOTIFY filtersChanged)
    Q_PROPERTY(QVariantMap filterCounts READ filterCounts NOTIFY filtersChanged)

    Q_PROPERTY(QVariantList observations READ observations NOTIFY resultChanged)
    Q_PROPERTY(QVariantList runs READ runs NOTIFY runsChanged)
    Q_PROPERTY(QString selectedObservation READ selectedObservation
               WRITE setSelectedObservation NOTIFY selectionChanged)
    Q_PROPERTY(QVariantMap selectedDetail READ selectedDetail NOTIFY selectionChanged)
    // Playback identity: the recording a loaded run was made from, so selecting an
    // observation can seek the real video instead of only showing numbers.
    Q_PROPERTY(QString videoPath READ videoPath NOTIFY resultChanged)
    Q_PROPERTY(QVariantList checks READ checks NOTIFY checksChanged)
    Q_PROPERTY(bool checking READ checking NOTIFY checksChanged)
    Q_PROPERTY(QString checkSummary READ checkSummary NOTIFY checksChanged)

public:
    explicit LabsStage4(QObject *parent = nullptr);
    ~LabsStage4() override;

    QVariantList recordings() const { return m_recordings; }
    QString clipsDir() const;
    QString runsDir() const;

    QString recording() const { return m_recording; }
    void setRecording(const QString &path);
    QString recordingName() const;
    QVariantMap probe() const { return m_probe; }

    QString approach() const { return m_approach; }
    void setApproach(const QString &a);
    QVariantList approaches() const { return m_approaches; }
    QVariantMap modelState() const;
    QVariantMap revisionState() const { return m_revisionState; }
    QVariantMap runState() const { return m_runState; }
    double scoreThreshold() const { return m_scoreThreshold; }
    void setScoreThreshold(double v);
    int decodeWidth() const { return m_decodeWidth; }
    void setDecodeWidth(int v);

    QString status() const { return m_status; }
    QString statusText() const { return m_statusText; }
    bool running() const { return m_running; }
    bool hasResult() const { return !m_observations.isEmpty(); }
    QString runDir() const { return m_runDir; }
    QString errorText() const { return m_errorText; }
    QVariantMap summary() const { return m_summary; }
    QVariantMap metrics() const { return m_metrics; }
    QString logTail() const { return m_logTail; }

    QStringList filterTypes() const { return m_filterTypes; }
    void setFilterTypes(const QStringList &v);
    QStringList filterSizes() const { return m_filterSizes; }
    void setFilterSizes(const QStringList &v);
    QString filterLocation() const { return m_filterLocation; }
    void setFilterLocation(const QString &v);
    QString filterColourHex() const { return m_filterColourHex; }
    void setFilterColourHex(const QString &v);
    bool filterColourActive() const { return m_filterColourActive; }
    void setFilterColourActive(bool v);
    double filterTolerance() const { return m_filterTolerance; }
    void setFilterTolerance(double v);
    bool includeUncertain() const { return m_includeUncertain; }
    void setIncludeUncertain(bool v);
    QVariantMap recordingMeta() const { return m_recordingMeta; }
    void setRecordingMeta(const QVariantMap &v);
    QString filterTimeFrom() const { return m_filterTimeFrom; }
    void setFilterTimeFrom(const QString &v);
    QString filterTimeTo() const { return m_filterTimeTo; }
    void setFilterTimeTo(const QString &v);
    QString filterCamera() const { return m_filterCamera; }
    void setFilterCamera(const QString &v);
    QString filterArea() const { return m_filterArea; }
    void setFilterArea(const QString &v);
    QVariantList filtered() const;
    QVariantMap filterCounts() const;
    Q_INVOKABLE void clearFilters();
    // Observations at/just before a playback position, for the product overlay.
    Q_INVOKABLE QVariantMap observationsAt(qint64 ptsMs, qint64 toleranceMs = 900) const;

    QVariantList observations() const { return m_observations; }
    QVariantList runs() const { return m_runs; }
    QString selectedObservation() const { return m_selected; }
    void setSelectedObservation(const QString &id);
    QVariantMap selectedDetail() const;
    QString videoPath() const { return m_videoPath; }

    QVariantList checks() const { return m_checks; }
    bool checking() const { return m_checking; }
    QString checkSummary() const { return m_checkSummary; }

    Q_INVOKABLE void refreshRecordings();
    Q_INVOKABLE void refreshRuns();
    Q_INVOKABLE void probeRecording();
    Q_INVOKABLE void start();
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void loadRun(const QString &dir);
    // Re-verify every hash in a reopened run's artifact manifest (bounded by `limit`).
    Q_INVOKABLE QVariantMap verifyRunArtifacts(const QString &dir, int limit = 200);
    // Machine-readable controller state for application self-tests: what input,
    // approach, revision, run and selection the REAL controller holds right now.
    // WT_LABS_STAGE4_STATEDUMP=<path> writes it on exit. Review/test hook only.
    Q_INVOKABLE QVariantMap stateDump() const;
    Q_INVOKABLE void writeStateDump(const QString &path) const;
    Q_INVOKABLE void runChecks(const QString &group);
    Q_INVOKABLE void stopChecks();
    // One observation against the current filter, for the UI and for the selftest.
    Q_INVOKABLE QVariantMap evaluateFilter(const QVariantMap &observation) const;
    // CIEDE2000 for the UI's live delta-E readout (same formula as Python's).
    Q_INVOKABLE double deltaE2000(const QVariantList &lab1, const QVariantList &lab2) const;
    // The Lab of a picked sRGB colour, using the same conversion as the query.
    Q_INVOKABLE QVariantList srgbToLab(const QString &hex) const;

signals:
    void recordingsChanged();
    void jobChanged();
    void stateChanged();
    void resultChanged();
    void filtersChanged();
    void runsChanged();
    void selectionChanged();
    void checksChanged();

private slots:
    void onRunOutput();
    void onRunFinished(int code, int status);

private:
    QString toolsDir() const;
    QString revisionsFile() const;
    QVariantMap registryRevision(const QString &approach) const;
    static QString sha256Of(const QString &path);
    QString pythonExe() const;
    QString checkpointFor(const QString &approach) const;
    void setStatus(const QString &status, const QString &text);
    void ingestRunFile(const QString &path);
    void killProcess(QProcess *&proc);
    void appendLog(const QString &line);
    bool loadResult(const QString &dir, QString *error = nullptr);
    QVariantMap inspectRun(const QString &dir, QString *error) const;

    QVariantList m_recordings;
    QVariantList m_approaches;
    QVariantList m_observations;
    QVariantList m_runs;
    QVariantList m_checks;
    QVariantMap m_probe;
    QVariantMap m_summary;
    QVariantMap m_metrics;
    QString m_recording;
    QString m_approach = QStringLiteral("A");
    QString m_status = QStringLiteral("idle");
    QString m_statusText;
    QString m_runDir;
    QVariantMap m_revisionState;
    QVariantMap m_runState;
    QVariantMap m_lastVerify;
    int m_generation = 0;
    mutable QHash<QString, QVariant> m_hashCache;
    QString m_videoPath;
    QVector<qint64> m_obsPts;
    QString m_errorText;
    QString m_logTail;
    QString m_selected;
    QString m_checkSummary;
    QStringList m_filterTypes;
    QStringList m_filterSizes;
    QString m_filterLocation;
    QString m_filterColourHex = QStringLiteral("#c81e1e");
    bool m_filterColourActive = false;
    bool m_includeUncertain = false;
    QVariantMap m_recordingMeta;
    QString m_filterTimeFrom;
    QString m_filterTimeTo;
    QString m_filterCamera;
    QString m_filterArea;
    double m_filterTolerance = 20.0;
    double m_scoreThreshold = 0.30;
    int m_decodeWidth = 1280;
    bool m_running = false;
    bool m_checking = false;
    QProcess *m_run = nullptr;
    QProcess *m_checksProc = nullptr;
    QTimer m_killTimer;
};
