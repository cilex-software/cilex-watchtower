#pragma once
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QStringList>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;

// Labs screen (operator decision 2026-09-26: "status and switches" first).
//
// SERVER: which analysers cilex-vision has switched on, how much of the archive each has
// covered, what each costs, and the on/off switch (admin only, audited server-side).
// All from GET /labs/scan/status on the operator's session; the switch is
// PATCH /labs/analyzers/{slug}. A station-only route (/labs/analyzers) exists too, but the
// app never holds the station token -- "never put service credentials in a station's app
// env" (CLAUDE.md).
//
// STATION: whether THIS machine is scanning, from the worker's status.json, and
// Pause/Resume through control.json (LabsStation.h). No network involved.
//
// Honest states throughout: before the first answer everything is unknown, a server that
// stops answering keeps the last answer ON SCREEN WITH ITS AGE rather than clearing it,
// and a cost or coverage the server does not know stays unknown, never 0.
class LabsModel : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool loaded READ loaded NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    // "" | "none_enabled" | "unreachable" | "refused". The rows stay as last received.
    Q_PROPERTY(QString errorCode READ errorCode NOTIFY changed)
    Q_PROPERTY(QString errorText READ errorText NOTIFY changed)
    Q_PROPERTY(QVariantList analyzers READ analyzers NOTIFY changed)
    Q_PROPERTY(int enabledCount READ enabledCount NOTIFY changed)
    Q_PROPERTY(QVariant projectedCpuHoursPerDay READ projectedCpuHoursPerDay NOTIFY changed)
    Q_PROPERTY(QString generatedAt READ generatedAt NOTIFY changed)
    Q_PROPERTY(bool canEdit READ canEdit NOTIFY changed)
    Q_PROPERTY(QString busySlug READ busySlug NOTIFY changed)
    Q_PROPERTY(QString changeError READ changeError NOTIFY changed)
    Q_PROPERTY(QVariantMap station READ station NOTIFY stationChanged)
    Q_PROPERTY(QString stationError READ stationError NOTIFY stationChanged)

public:
    explicit LabsModel(QObject *parent = nullptr);

    bool loaded() const { return m_loaded; }
    bool loading() const { return m_loading; }
    QString errorCode() const { return m_errorCode; }
    QString errorText() const { return m_errorText; }
    QVariantList analyzers() const { return m_rows; }
    int enabledCount() const { return m_enabledCount; }
    QVariant projectedCpuHoursPerDay() const { return m_projected; }
    QString generatedAt() const { return m_generatedAt; }
    bool canEdit() const;
    QString busySlug() const { return m_busySlug; }
    QString changeError() const { return m_changeError; }
    QVariantMap station() const { return m_station; }
    QString stationError() const { return m_stationError; }

    // `force` skips the once-a-minute floor (after a switch change, the answer MUST be new).
    Q_INVOKABLE void refresh(bool force = false);
    Q_INVOKABLE void refreshStation();
    Q_INVOKABLE void setAnalyzerEnabled(const QString &slug, bool on);
    Q_INVOKABLE void setStationPaused(bool paused);

signals:
    void changed();
    void stationChanged();

private:
    void fetchSeed(int i);
    void fetchDetail(const QString &slug);
    void finish();
    void fail(const QString &code, const QString &text);

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;

    bool m_loaded = false;
    bool m_loading = false;
    QString m_errorCode, m_errorText;
    QVariantList m_rows;
    int m_enabledCount = 0;
    QVariant m_projected;
    QString m_generatedAt;
    QString m_busySlug, m_changeError;

    QStringList m_candidates;          // slugs to ask about until one is switched on
    QStringList m_lastEnabled;         // from the previous answer: the likeliest seed
    QJsonObject m_seed;
    QHash<QString, QJsonObject> m_detail;
    int m_pending = 0;
    int m_generation = 0;              // a newer refresh() makes older replies moot
    bool m_refreshWanted = false;      // asked while signed out: refresh on sign-in
    qint64 m_lastAskMs = 0;            // when the last full refresh began (monotonic)

    QVariantMap m_station;
    QString m_stationError;
};
