#include "DeepLink.h"
#include "AuthController.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileOpenEvent>
#include <QGuiApplication>
#include <QCryptographicHash>
#include <QRandomGenerator>
#include <QUrl>
#include <QUrlQuery>
#include <cstring>              // strchr — base32 alphabet lookup
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


// ---- opaque token codec (operator order 2026-08-22/23) --------------------
// Links leave the building: guards forward them, customers run competitors'
// products. The WIRE FORM therefore exposes no internals — no site address, no
// camera ids, no parameter names, no hint of fleet shape. The INNER grammar is
// unchanged (v=1&site=…&event=… / camera+at — the pinned contract); only its
// bytes are obfuscated. HONEST SECURITY LABEL: the key below ships inside
// every client binary, so this is OBFUSCATION against casual readers, not
// cryptography against a determined one — the operator set exactly that bar.
// If real secrecy is ever required, token prefix 's' is reserved for
// server-minted random ids (payload stored in CV, nothing derivable offline).
//
// Token layout (prefix 'a'):  "a" + base32lower( nonce[4] || RC4_K(payload || sum4) )
//   K     = SHA256("cilex-link-a1|" + OBF_CONST + nonce)
//   sum4  = first 4 bytes of SHA256(payload)   — integrity + wrong-key detector
//   nonce = 4 random bytes — identical payloads mint different links
// base32 LOWERCASE because the token rides the URL HOST position and QUrl
// (like many parsers) lowercases hosts — a mixed-case encoding would corrupt.

static const unsigned char kObfConst[16] = {
    0x9b, 0x41, 0xd7, 0x22, 0x5e, 0xc8, 0x0f, 0xa3,
    0x77, 0x1c, 0xe9, 0x54, 0x08, 0xbd, 0x63, 0x2a };   // shared across Cilex apps; not a secret boundary

static QByteArray rc4Apply(const QByteArray &key, QByteArray data)
{
    unsigned char S[256];
    for (int i = 0; i < 256; ++i) S[i] = (unsigned char)i;
    for (int i = 0, j = 0; i < 256; ++i) {
        j = (j + S[i] + (unsigned char)key.at(i % key.size())) & 255;
        std::swap(S[i], S[j]);
    }
    int i = 0, j = 0;
    for (char &c : data) {
        i = (i + 1) & 255;
        j = (j + S[i]) & 255;
        std::swap(S[i], S[j]);
        c = char((unsigned char)c ^ S[(S[i] + S[j]) & 255]);
    }
    return data;
}

static const char *kB32 = "abcdefghijklmnopqrstuvwxyz234567";

static QString b32enc(const QByteArray &in)
{
    QString out; out.reserve((in.size() * 8 + 4) / 5);
    int acc = 0, bits = 0;
    for (unsigned char c : in) {
        acc = (acc << 8) | c; bits += 8;
        while (bits >= 5) { out += QLatin1Char(kB32[(acc >> (bits - 5)) & 31]); bits -= 5; }
    }
    if (bits > 0) out += QLatin1Char(kB32[(acc << (5 - bits)) & 31]);
    return out;
}

static QByteArray b32dec(const QString &in, bool *ok)
{
    QByteArray out; out.reserve(in.size() * 5 / 8);
    int acc = 0, bits = 0; *ok = true;
    for (QChar qc : in) {
        const char *p = strchr(kB32, qc.toLatin1());
        if (!p || qc.toLatin1() == 0) { *ok = false; return {}; }
        acc = (acc << 5) | int(p - kB32); bits += 5;
        if (bits >= 8) { out += char((acc >> (bits - 8)) & 255); bits -= 8; }
    }
    return out;
}

static QByteArray linkKey(const QByteArray &nonce)
{
    QByteArray seed("cilex-link-a1|");
    seed += QByteArray(reinterpret_cast<const char *>(kObfConst), sizeof(kObfConst));
    seed += nonce;
    return QCryptographicHash::hash(seed, QCryptographicHash::Sha256);
}

QString DeepLink::encodeToken(const QByteArray &innerQuery, const QByteArray &nonce)
{
    const QByteArray sum4 = QCryptographicHash::hash(innerQuery, QCryptographicHash::Sha256).left(4);
    const QByteArray cipher = rc4Apply(linkKey(nonce), innerQuery + sum4);
    return QStringLiteral("a") + b32enc(nonce + cipher);
}

QByteArray DeepLink::decodeToken(const QString &token)
{
    if (token.size() < 2 || token.at(0) != QLatin1Char('a'))
        return {};
    bool ok = false;
    const QByteArray raw = b32dec(token.mid(1), &ok);
    if (!ok || raw.size() < 4 + 4 + 1)
        return {};
    const QByteArray nonce = raw.left(4);
    QByteArray plain = rc4Apply(linkKey(nonce), raw.mid(4));
    const QByteArray sum4 = plain.right(4);
    plain.chop(4);
    if (QCryptographicHash::hash(plain, QCryptographicHash::Sha256).left(4) != sum4)
        return {};   // wrong key, corruption, or foreign token — refuse, never garbage-parse
    return plain;
}

QString DeepLink::eventLink(const QString &eventId) const
{
    if (eventId.isEmpty() || currentSite().isEmpty())
        return QString();
    // Inner grammar unchanged (the pinned contract); wire form opaque since the
    // operator's 2026-08-22 order — no internals visible in a forwarded link.
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("v"), QStringLiteral("1"));
    q.addQueryItem(QStringLiteral("site"), currentSite());
    q.addQueryItem(QStringLiteral("event"), eventId);
    QByteArray nonce(4, Qt::Uninitialized);
    for (int i = 0; i < 4; ++i) nonce[i] = char(QRandomGenerator::global()->bounded(256));
    return QStringLiteral("cilex://") + encodeToken(q.toString(QUrl::FullyEncoded).toUtf8(), nonce);
}

QVariantMap DeepLink::parse(const QString &url) const
{
    QVariantMap out;
    out[QStringLiteral("ok")] = false;
    out[QStringLiteral("currentSite")] = currentSite();
    const QUrl u(url.trimmed());
    if (!u.isValid() || u.scheme().compare(QStringLiteral("cilex"), Qt::CaseInsensitive) != 0)
        return out;
    // Two accepted wire forms: opaque token in the host slot (minted since
    // 2026-08-23), and the legacy readable form cilex://open?… (the pilot's
    // first two days of links — parse-accept forever, mint never).
    QUrlQuery q(u);
    if (u.host() != QLatin1String("open")) {
        const QByteArray inner = decodeToken(u.host());
        if (inner.isEmpty())
            return out;   // foreign/corrupt token — honest refusal upstream
        q = QUrlQuery(QString::fromUtf8(inner));
    }
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
