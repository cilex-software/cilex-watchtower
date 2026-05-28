#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;

// Storage-subsystem health from cilex-vision's GET /health/storage
// { status, degraded, storage_agent_reachable, circuit_open, last_error, reason }.
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
    Q_PROPERTY(bool ok READ ok NOTIFY changed)

public:
    explicit StorageHealth(QObject *parent = nullptr);

    bool loaded() const { return m_loaded; }
    QString status() const { return m_status; }
    bool degraded() const { return m_degraded; }
    bool reachable() const { return m_reachable; }
    bool circuitOpen() const { return m_circuitOpen; }
    QString reason() const { return m_reason; }
    bool ok() const { return m_loaded && m_status == QLatin1String("ok") && !m_degraded && m_reachable && !m_circuitOpen; }

    Q_INVOKABLE void refresh();

signals:
    void changed();

private:
    void fetch();

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    bool m_loading = false;
    bool m_loaded = false;
    QString m_status, m_reason;
    bool m_degraded = false;
    bool m_reachable = true;
    bool m_circuitOpen = false;
};
