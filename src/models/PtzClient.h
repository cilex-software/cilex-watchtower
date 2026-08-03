#pragma once
#include <QObject>
#include <QHash>
#include <QTimer>
#include <functional>

class QNetworkAccessManager;

// PTZ / motorized-lens control client. Watchtower never talks to cameras
// directly (the backend owns camera credentials + lockout backoff), so every
// operation goes through cilex-vision endpoints speced in
// docs/letters/2026-07-16-ptz-lens-control-endpoint.md:
//
//   GET  /cameras/{id}/ptz              -> {"supported":"none|lens|ptz","home_supported":bool}
//   POST /cameras/{id}/ptz/continuous   {"pan":-1..1,"tilt":-1..1,"zoom":-1..1}  all-zero = stop
//   POST /cameras/{id}/ptz/focus        {"speed":-1..1}                          0 = stop
//   POST /cameras/{id}/ptz/focus/auto   {}
//   POST /cameras/{id}/ptz/reset        {}   restore defaults (home preset / lens default + AF)
//
// Until the backend ships them, probe() surfaces 404/405/501 as pendingBackend
// so the panel can render an HONEST pending state (never a silent no-op).
// WT_DEMO short-circuits to a local mock (demo builds only, per product rule).
class PtzClient : public QObject
{
    Q_OBJECT
public:
    explicit PtzClient(QObject *parent = nullptr);

    Q_INVOKABLE void probe(const QString &camId);
    Q_INVOKABLE void continuousMove(const QString &camId, double pan, double tilt, double zoom);
    Q_INVOKABLE void stopMove(const QString &camId);
    Q_INVOKABLE void focusMove(const QString &camId, double speed);
    Q_INVOKABLE void focusAuto(const QString &camId);
    Q_INVOKABLE void restoreDefaults(const QString &camId);
    // One-touch autofocus with the HARD client debounce the 2026-08-03 letter
    // asks for: one command per camera per 5 s no matter how many triggers
    // (tile button, triple-click, panel) fire. The entry point every UI uses.
    Q_INVOKABLE void focusAutoRequest(const QString &camId);
    // Cached probe result for UI gating: "" unknown, "pending", or supported.
    Q_INVOKABLE QString capsFor(const QString &camId) const;
    // TRUE once a focus command answered 501 (reply² §3: the camera itself
    // cannot focus — authoritative, session-cached; `lens` is only a hint).
    // Zoom/pan survive: only focus affordances hide on this.
    Q_INVOKABLE bool focusDead(const QString &camId) const { return m_focusDead.contains(camId); }

signals:
    // supported: "none" | "lens" | "ptz"; pendingBackend: endpoint absent upstream
    void capsReady(const QString &camId, const QString &supported,
                   bool homeSupported, bool pendingBackend);
    // message: the backend's human sentence (§2 of 2026-08-03-triple-click-
    // autofocus.md — rendered VERBATIM by the UI), "" for ops without one.
    void opDone(const QString &camId, const QString &what, const QString &message);
    void opFailed(const QString &camId, const QString &what, const QString &message);
    void focusSupportChanged(const QString &camId, bool supported);

private:
    struct Caps { QString supported; bool home = false; bool pending = false; };
    void post(const QString &camId, const QString &what, const QString &tail,
              const QByteArray &json);
    void armSafetyStop(std::function<void()> stopFn);

    QNetworkAccessManager *m_nam = nullptr;
    QHash<QString, Caps> m_caps;         // per-camera probe cache (session-lived)
    QHash<QString, qint64> m_lastFocusMs; // per-camera focus-auto debounce stamps
    QHash<QString, QString> m_focusDead; // camId -> the 501's sentence, replayed verbatim
    QTimer m_safety;                     // a missed release must never leave a camera moving
    std::function<void()> m_safetyStop;
    bool m_demo = false;
};
