#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class LabsTrackingController : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    Q_PROPERTY(qreal progress READ progress NOTIFY progressChanged)
    Q_PROPERTY(QString statusMessage READ statusMessage NOTIFY statusMessageChanged)
    Q_PROPERTY(QVariantList testCases READ testCases NOTIFY testCasesChanged)
    Q_PROPERTY(QVariantMap summary READ summary NOTIFY summaryChanged)
    Q_PROPERTY(bool deliberateFailure READ deliberateFailure WRITE setDeliberateFailure NOTIFY deliberateFailureChanged)
    Q_PROPERTY(bool runWorkload READ runWorkload WRITE setRunWorkload NOTIFY runWorkloadChanged)
    Q_PROPERTY(QVariantList tracks READ tracks NOTIFY tracksChanged)
    Q_PROPERTY(int selectedTrackIndex READ selectedTrackIndex NOTIFY selectedTrackIndexChanged)
    Q_PROPERTY(QVariantMap selectedTrack READ selectedTrack NOTIFY selectedTrackChanged)
    Q_PROPERTY(QString recordingPath READ recordingPath WRITE setRecordingPath NOTIFY recordingPathChanged)
    Q_PROPERTY(QString recordingHash READ recordingHash NOTIFY recordingHashChanged)
    Q_PROPERTY(QString recordingStatus READ recordingStatus NOTIFY recordingStatusChanged)
    Q_PROPERTY(QString recordingStatusNote READ recordingStatusNote NOTIFY recordingStatusNoteChanged)
    Q_PROPERTY(QVariantList savedRuns READ savedRuns NOTIFY savedRunsChanged)
    Q_PROPERTY(QString evidencePath READ evidencePath NOTIFY evidencePathChanged)

public:
    explicit LabsTrackingController(QObject *parent = nullptr);
    ~LabsTrackingController() override;

    QString state() const { return m_state; }
    qreal progress() const { return m_progress; }
    QString statusMessage() const { return m_statusMessage; }
    QVariantList testCases() const { return m_testCases; }
    QVariantMap summary() const { return m_summary; }
    bool deliberateFailure() const { return m_deliberateFailure; }
    bool runWorkload() const { return m_runWorkload; }
    QVariantList tracks() const { return m_tracks; }
    int selectedTrackIndex() const { return m_selectedTrackIndex; }
    QVariantMap selectedTrack() const { return m_selectedTrack; }
    QString recordingPath() const { return m_recordingPath; }
    QString recordingHash() const { return m_recordingHash; }
    QString recordingStatus() const { return m_recordingStatus; }
    QString recordingStatusNote() const { return m_recordingStatusNote; }
    QVariantList savedRuns() const { return m_savedRuns; }
    QString evidencePath() const { return m_evidencePath; }

    void setDeliberateFailure(bool v);
    void setRunWorkload(bool v);
    void setRecordingPath(const QString &p);

    Q_INVOKABLE void startVerification();
    Q_INVOKABLE void startRecordingAnalysis(const QString &path = QString(), const QString &cameraId = QStringLiteral("cam-analysis"), const QString &unitId = QStringLiteral("unit-analysis"));
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void saveEvidence(const QString &label = QString());
    Q_INVOKABLE void loadEvidence(const QString &filePath);
    Q_INVOKABLE void selectTrack(int index);
    Q_INVOKABLE void refreshSavedRuns();

signals:
    void stateChanged();
    void progressChanged();
    void statusMessageChanged();
    void testCasesChanged();
    void summaryChanged();
    void deliberateFailureChanged();
    void runWorkloadChanged();
    void tracksChanged();
    void selectedTrackIndexChanged();
    void selectedTrackChanged();
    void recordingPathChanged();
    void recordingHashChanged();
    void recordingStatusChanged();
    void recordingStatusNoteChanged();
    void savedRunsChanged();
    void evidencePathChanged();

private slots:
    void onProcessReadyRead();
    void onProcessFinished(int exitCode, QProcess::ExitStatus exitStatus);
    void onProcessErrorOccurred(QProcess::ProcessError error);

private:
    void parseEventLine(const QByteArray &line);
    QString evidenceDirectory() const;

    QString m_state{QStringLiteral("idle")};
    qreal m_progress{0.0};
    QString m_statusMessage;
    QVariantList m_testCases;
    QVariantMap m_summary;
    bool m_deliberateFailure{false};
    bool m_runWorkload{false};
    QVariantList m_tracks;
    int m_selectedTrackIndex{-1};
    QVariantMap m_selectedTrack;
    QString m_recordingPath;
    QString m_recordingHash;
    QString m_recordingStatus{QStringLiteral("not_verified")};
    QString m_recordingStatusNote{QStringLiteral("No recording selected. Genuine missing recording access is reported as NOT VERIFIED.")};
    QVariantList m_savedRuns;
    QString m_evidencePath;

    QProcess *m_process{nullptr};
    QByteArray m_buffer;
    bool m_isAnalysisMode{false};
};
