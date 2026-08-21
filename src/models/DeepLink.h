#pragma once
#include <QObject>
#include <QVariantMap>

class AuthController;

// Shareable video links (operator order 2026-08-21): every event carries a
// globally-unique address `cilex://open?v=1&site=<host[:port]>&event=<uuid>`
// that a recipient's Watchtower (or Cilex Pro Mobile) opens to that exact
// clip. SECURITY MODEL, stated once: the link IDENTIFIES, it never AUTHORIZES.
// Possession of a link grants nothing — the receiving app must be signed in to
// the named installation, and every fetch behind the reveal (event row, still,
// review session) goes through the server's normal auth. Fine-grained
// per-user/per-camera ACLs are the server's half (letter
// docs/letters/2026-08-21-share-links-contract.md); this class is transport.
//
// Receiving: macOS delivers registered-scheme opens as QFileOpenEvent (both
// cold launch and into the running instance); Windows/Linux pass the URL in
// argv (single-instance routing is those ports' packaging work, noted in the
// design doc). A URL that arrives before QML is up waits in pendingUrl.
class DeepLink : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString pendingUrl READ pendingUrl NOTIFY pendingUrlChanged)
public:
    explicit DeepLink(AuthController *auth, QObject *parent = nullptr);

    QString pendingUrl() const { return m_pending; }

    // Mint this installation's link for an event. Site = host[:port] of the
    // CURRENT base URL — upgraded to a server-issued installation UUID once CV
    // ships one (contract letter §2).
    Q_INVOKABLE QString eventLink(const QString &eventId) const;

    // Parse any string. Returns {ok, site, event, sameSite, currentSite}.
    // sameSite compares case-insensitively against the current base URL's
    // host[:port] — a mismatch is surfaced to the user honestly, never
    // silently retargeted.
    Q_INVOKABLE QVariantMap parse(const QString &url) const;

    Q_INVOKABLE void copyText(const QString &text) const;

    // Feed a candidate URL (argv at boot, or the FileOpen filter).
    void submit(const QString &url);
    Q_INVOKABLE void clearPending();

signals:
    void pendingUrlChanged();
    void linkReceived(const QString &url);

protected:
    bool eventFilter(QObject *obj, QEvent *ev) override;

private:
    QString currentSite() const;
    AuthController *m_auth = nullptr;
    QString m_pending;
};
