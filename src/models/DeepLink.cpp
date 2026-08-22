#include "DeepLink.h"
#include "AuthController.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileOpenEvent>
#include <QGuiApplication>
#include <QUrl>
#include <QUrlQuery>
#if defined(Q_OS_MACOS)
#  include <CoreServices/CoreServices.h>   // LSRegisterURL — bundle self-registration
#elif defined(Q_OS_WIN)
#  include <QSettings>
#else
#  include <QProcess>
#endif

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

// Per-OS scheme claim. Everything here is best-effort and logged — a failure to
// register must never block boot; Warden's `deeplink_ok` beat field is the
// honest witness of the outcome.
void DeepLink::ensureSchemeRegistered()
{
    if (qEnvironmentVariableIsSet("WT_NO_SCHEME_REG"))
        return;
#if defined(Q_OS_MACOS)
    // WRITTEN ON LINUX — the operator's next mac build verifies (house pattern).
    // LaunchServices reads CFBundleURLTypes from the bundle's Info.plist, but only
    // for bundles it has SEEN; LSRegisterURL introduces ours explicitly.
    QDir d(QCoreApplication::applicationDirPath());     // …/Contents/MacOS
    if (d.cdUp() && d.cdUp() && d.absolutePath().endsWith(QLatin1String(".app"))) {
        const CFStringRef path = d.absolutePath().toCFString();
        const CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, path,
                                                           kCFURLPOSIXPathStyle, true);
        CFRelease(path);
        if (url) {
            const OSStatus st = LSRegisterURL(url, true);
            CFRelease(url);
            if (st == noErr) { qInfo("[DEEPLINK] cilex:// registered (bundle %s)",
                                     qPrintable(d.absolutePath())); return; }
            qWarning("[DEEPLINK] LSRegisterURL failed (status %d) — `open cilex://…` "
                     "will not resolve until the bundle is registered", int(st));
            return;
        }
    }
    qWarning("[DEEPLINK] not running from a .app bundle — cilex:// cannot register "
             "(dir %s)", qPrintable(QCoreApplication::applicationDirPath()));
#elif defined(Q_OS_WIN)
    // Per-user claim (HKCU): no admin, no installer dependency, self-heals moved
    // installs. The installer's HKLM keys (if any) remain; HKCU wins for the user.
    QSettings reg(QStringLiteral("HKEY_CURRENT_USER\\Software\\Classes"),
                  QSettings::NativeFormat);
    const QString exe = QDir::toNativeSeparators(QCoreApplication::applicationFilePath());
    const QString want = QLatin1Char('"') + exe + QStringLiteral("\" \"%1\"");
    if (reg.value(QStringLiteral("cilex/shell/open/command/.")).toString() != want) {
        reg.setValue(QStringLiteral("cilex/."), QStringLiteral("URL:Cilex Watchtower Link"));
        reg.setValue(QStringLiteral("cilex/URL Protocol"), QString());
        reg.setValue(QStringLiteral("cilex/shell/open/command/."), want);
        qInfo("[DEEPLINK] cilex:// registered to %s (HKCU)", qPrintable(exe));
    }
#else
    // Linux: per-user .desktop handler + xdg-mime default. Cold launches via the
    // handler run the BARE binary (no run.sh env) — saved session covers sign-in,
    // same caveat as LaunchServices cold launches on macOS.
    const QString appsDir = QDir::homePath() + QStringLiteral("/.local/share/applications");
    QDir().mkpath(appsDir);
    const QString exe = QCoreApplication::applicationFilePath();
    QString body = QStringLiteral("[Desktop Entry]\nType=Application\n"
                                  "Name=Cilex Watchtower Link Handler\nNoDisplay=true\n");
    body += QStringLiteral("Exec=\"%1\" %u\n").arg(exe);
    body += QStringLiteral("MimeType=x-scheme-handler/cilex;\n");
    const QString desktopPath = appsDir + QStringLiteral("/cilex-watchtower-url.desktop");
    QFile f(desktopPath);
    QByteArray cur;
    if (f.open(QIODevice::ReadOnly)) { cur = f.readAll(); f.close(); }
    if (cur != body.toUtf8()) {
        if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            f.write(body.toUtf8()); f.close();
            qInfo("[DEEPLINK] wrote %s (Exec -> %s)", qPrintable(desktopPath), qPrintable(exe));
        } else {
            qWarning("[DEEPLINK] cannot write %s — cilex:// will not register",
                     qPrintable(desktopPath));
            return;
        }
    }
    QProcess::startDetached(QStringLiteral("xdg-mime"),
                            {QStringLiteral("default"),
                             QStringLiteral("cilex-watchtower-url.desktop"),
                             QStringLiteral("x-scheme-handler/cilex")});
#endif
}
