#include "DeepLink.h"
#include "AuthController.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QEvent>
#include <QFileOpenEvent>
#include <QGuiApplication>
#include <QUrl>
#include <QUrlQuery>

DeepLink::DeepLink(AuthController *auth, QObject *parent)
    : QObject(parent), m_auth(auth)
{
    // FileOpen events land on the QGuiApplication object itself.
    qApp->installEventFilter(this);
}

QString DeepLink::currentSite() const
{
    const QUrl base(m_auth ? m_auth->baseUrl() : QString());
    if (!base.isValid() || base.host().isEmpty())
        return QString();
    return base.port() > 0 ? QStringLiteral("%1:%2").arg(base.host()).arg(base.port())
                           : base.host();
}

QString DeepLink::eventLink(const QString &eventId) const
{
    if (eventId.isEmpty() || currentSite().isEmpty())
        return QString();
    QUrl u(QStringLiteral("cilex://open"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("v"), QStringLiteral("1"));
    q.addQueryItem(QStringLiteral("site"), currentSite());
    q.addQueryItem(QStringLiteral("event"), eventId);
    u.setQuery(q);
    return u.toString();
}

QVariantMap DeepLink::parse(const QString &url) const
{
    QVariantMap out;
    out[QStringLiteral("ok")] = false;
    out[QStringLiteral("currentSite")] = currentSite();
    const QUrl u(url.trimmed());
    if (!u.isValid() || u.scheme().compare(QStringLiteral("cilex"), Qt::CaseInsensitive) != 0)
        return out;
    const QUrlQuery q(u);
    const QString site = q.queryItemValue(QStringLiteral("site"));
    const QString event = q.queryItemValue(QStringLiteral("event"));
    if (site.isEmpty() || event.isEmpty())
        return out;
    out[QStringLiteral("ok")] = true;
    out[QStringLiteral("site")] = site;
    out[QStringLiteral("event")] = event;
    out[QStringLiteral("sameSite")] =
        site.compare(currentSite(), Qt::CaseInsensitive) == 0;
    return out;
}

void DeepLink::copyText(const QString &text) const
{
    QGuiApplication::clipboard()->setText(text);
}

void DeepLink::submit(const QString &url)
{
    if (!url.trimmed().startsWith(QStringLiteral("cilex:"), Qt::CaseInsensitive))
        return;
    m_pending = url.trimmed();
    emit pendingUrlChanged();
    emit linkReceived(m_pending);
    qInfo("[LINK] received %s", qPrintable(m_pending));
}

void DeepLink::clearPending()
{
    if (m_pending.isEmpty())
        return;
    m_pending.clear();
    emit pendingUrlChanged();
}

bool DeepLink::eventFilter(QObject *obj, QEvent *ev)
{
    if (ev->type() == QEvent::FileOpen) {
        const auto *fo = static_cast<QFileOpenEvent *>(ev);
        const QString u = fo->url().isValid() ? fo->url().toString() : fo->file();
        submit(u);
        return true;
    }
    return QObject::eventFilter(obj, ev);
}
