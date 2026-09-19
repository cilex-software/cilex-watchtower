#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;

// Storage-subsystem health from cilex-vision's GET /health/storage.
//
// CV's 912dc73 (reply to docs/letters/2026-08-10-storage-health-probe-false-
// unreachable.md) made this endpoint CACHED — it never probes on read, so it is
// free to poll — and added the field that matters: an explicit `state` of
// ok | intermittent | unreachable | unknown, plus last_ok_at.
//
// `intermittent` means "failing right now, but the agent answered within 180s"
// — a Docker stall burst, NOT a degraded subsystem and NOT a red. Rendering one
// timed-out probe as a confident red is the defect we reported; rendering CV's
// state verbatim, with the age of the last good check beside it, is the fix they
// asked us to build (their §2: one authority beats two sample windows).
// Uses the shared session (AuthController) — no own login. Polled by the Health
// screen while it's visible. `loaded` is false until the first successful fetch
// (so the UI can show "status unknown" honestly when the backend is unreachable).
class StorageHealth : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool loaded READ loaded NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(bool degraded READ degraded NOTIFY changed)
    Q_PROPERTY(bool reachable READ reachable NOTIFY changed)
    Q_PROPERTY(bool circuitOpen READ circuitOpen NOTIFY changed)
    Q_PROPERTY(QString reason READ reason NOTIFY changed)
    // CV's `reason` is CURATED (a short status phrase, sometimes a code); `last_error` is
    // RAW EVIDENCE — str(exc) from the storage agent, truncated to 160 chars server-side
    // (cilex-vision agent_client.py:150, health_summary.py:745). They were one property
    // here until 2026-09-20, which meant a Python traceback rendered as if it were a
    // curated sentence and nobody could tell which they were reading. Kept apart now:
    // chrome is the app's own voice, evidence stays as it came.
    Q_PROPERTY(QString lastError READ lastError NOTIFY changed)
    Q_PROPERTY(bool ok READ ok NOTIFY changed)
    // Rendered VERBATIM — never re-derived from the booleans.
    Q_PROPERTY(QString state READ state NOTIFY changed)
    Q_PROPERTY(QString lastOkAt READ lastOkAt NOTIFY changed)
    Q_PROPERTY(QString checkedAt READ checkedAt NOTIFY changed)
    Q_PROPERTY(int consecutiveFailures READ consecutiveFailures NOTIFY changed)

public:
    explicit StorageHealth(QObject *parent = nullptr);

    bool loaded() const { return m_loaded; }
    QString status() const { return m_status; }
    bool degraded() const { return m_degraded; }
    bool reachable() const { return m_reachable; }
    bool circuitOpen() const { return m_circuitOpen; }
    QString reason() const { return m_reason; }
    QString lastError() const { return m_lastError; }
    QString state() const { return m_state; }
    QString lastOkAt() const { return m_lastOkAt; }
    QString checkedAt() const { return m_checkedAt; }
    int consecutiveFailures() const { return m_consecutiveFailures; }
    // Trust `state` when the backend sends it; fall back to the old booleans only
    // for a backend that predates 912dc73.
    bool ok() const {
        if (!m_loaded)
            return false;
        if (!m_state.isEmpty())
            return m_state == QLatin1String("ok");
        return m_status == QLatin1String("ok") && !m_degraded && m_reachable && !m_circuitOpen;
    }

    Q_INVOKABLE void refresh();

signals:
    void changed();

private:
    void fetch();

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    bool m_loading = false;
    bool m_loaded = false;
    QString m_status, m_reason, m_lastError, m_state, m_lastOkAt, m_checkedAt;
    int m_consecutiveFailures = 0;
    bool m_degraded = false;
    bool m_reachable = true;
    bool m_circuitOpen = false;
};
