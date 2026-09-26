#pragma once
#include <QObject>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;

// Labs screen (operator decision 2026-09-26: "status and switches" first). Admin-only,
// like cilex-vision's own /admin/labs: the programme hands work to machines and shows
// per-analyser cost, which is no viewer's business (their /labs/pipeline docstring).
//
// SERVER: GET /labs/pipeline, ONE call, lists every analyser -- switched-off ones too --
// with its state, cost, counts and (for switched-on ones) the camera-hours still waiting.
// The switch is PATCH /labs/analyzers/{slug}, audited server-side; its answer updates the
// row, so a switch change costs no second request.
//
// HOW OFTEN, and why so rarely: the server work behind this is NOT cheap. The first
// version asked /labs/scan/status per analyser every 5 min, and cilex-vision measured one
// such call at 5.26 s and ~1 GB of page reads (161 MB from disk) -- churn that slows
// playback opens on the pilot. So: at most every 30 minutes while the screen is open, or
// when the operator presses Refresh, one request at a time, never overlapping.
//
// STATION: whether THIS machine is scanning, from the worker's status.json, and
// Pause/Resume through control.json (LabsStation.h). Local files, read every 5 s.
//
// Honest states: before the first answer everything is unknown; a server that stops
// answering keeps its last answer on screen WITH ITS TIME; an unmeasured cost stays
// unknown, never 0.
class LabsModel : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool loaded READ loaded NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    // "" | "admin_only" | "unreachable" | "refused". The rows stay as last received.
    Q_PROPERTY(QString errorCode READ errorCode NOTIFY changed)
    Q_PROPERTY(QString errorText READ errorText NOTIFY changed)
    Q_PROPERTY(QVariantList analyzers READ analyzers NOTIFY changed)
    Q_PROPERTY(int enabledCount READ enabledCount NOTIFY changed)
    Q_PROPERTY(QVariant projectedCpuHoursPerDay READ projectedCpuHoursPerDay NOTIFY changed)
    Q_PROPERTY(bool projectedIsFloor READ projectedIsFloor NOTIFY changed)
    Q_PROPERTY(QString generatedAt READ generatedAt NOTIFY changed)
    Q_PROPERTY(bool canEdit READ canEdit NOTIFY changed)
    Q_PROPERTY(QString busySlug READ busySlug NOTIFY changed)
    Q_PROPERTY(QString changeError READ changeError NOTIFY changed)
    Q_PROPERTY(QVariantMap station READ station NOTIFY stationChanged)
    Q_PROPERTY(QString stationError READ stationError NOTIFY stationChanged)

public:
    explicit LabsModel(QObject *parent = nullptr);

    // Minimum age of the last answer before a routine refresh asks again.
    static constexpr qint64 kFloorMs = 30LL * 60 * 1000;

    bool loaded() const { return m_loaded; }
    bool loading() const { return m_loading; }
    QString errorCode() const { return m_errorCode; }
    QString errorText() const { return m_errorText; }
    QVariantList analyzers() const { return m_rows; }
    int enabledCount() const { return m_enabledCount; }
    QVariant projectedCpuHoursPerDay() const { return m_projected; }
    bool projectedIsFloor() const { return m_projectedIsFloor; }
    QString generatedAt() const { return m_generatedAt; }
    bool canEdit() const;
    QString busySlug() const { return m_busySlug; }
    QString changeError() const { return m_changeError; }
    QVariantMap station() const { return m_station; }
    QString stationError() const { return m_stationError; }

    // `force`: the operator pressed Refresh -- ask now, whatever the age of the answer.
    Q_INVOKABLE void refresh(bool force = false);
    Q_INVOKABLE void refreshStation();
    Q_INVOKABLE void setAnalyzerEnabled(const QString &slug, bool on);
    Q_INVOKABLE void setStationPaused(bool paused);

signals:
    void changed();
    void stationChanged();

private:
    void fail(const QString &code, const QString &text);
    void recount();

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;

    bool m_loaded = false;
    bool m_loading = false;
    bool m_refreshWanted = false;      // asked while signed out: refresh on sign-in
    qint64 m_lastAskMs = 0;
    QString m_errorCode, m_errorText;
    QVariantList m_rows;
    int m_enabledCount = 0;
    QVariant m_projected;
    bool m_projectedIsFloor = false;
    QString m_generatedAt;
    QString m_busySlug, m_changeError;

    QVariantMap m_station;
    QString m_stationError;
};
