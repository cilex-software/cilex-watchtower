// Client-side test of the `message ?? detail` read (src/models/ServerMessage.h).
//
// Bodies are REAL: rows 1-2 measured from the pilot (GET /cameras/x/ptz unauthenticated,
// and auth/jwt.py:205 as CV serialised it in reply17 §3); rows 3-4 from CV live probes in
// reply14 §2 and reply17 §1. Row 2 is the defect this read cannot fix from the client:
// a code-only site with no sentence anywhere, which is what CV reply17 §4 adds.
//
// TWO MODES, and the second one exists because the first cannot do what I claimed.
//
//   (no args)         FROZEN: drives captured bodies through the real parse. Fast, offline,
//                     pins the PARSE. It cannot notice CV changing the wire — the bytes are
//                     frozen here, so it keeps passing against yesterday's server forever.
//   --live <baseUrl>  LIVE: probes the running backend and asserts the CONTRACT. This is the
//                     half that notices. Read-only, unauthenticated, no credentials, nothing
//                     that touches a lockout counter.
//
// I wrote in reply18 §4 that the frozen case pinning `service_suspended -> service_suspended`
// would "fail when CV ships, so someone has to look". THAT WAS WRONG and cilex-pro-mobile's
// reply19 §3 caught it: a captured body is unaffected by anything CV deploys. The live mode's
// third probe is the real tripwire — it asserts auth/jwt.py is STILL UNCODED, and fails the
// moment CV ships their reply17 §4, which is the signal to re-capture and map the new codes.
//
// Build + run (Qt 6.12):
//   g++ -std=c++17 -fPIC -o /tmp/svrmsg tools/tests/server-message.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -I$QT/include/QtNetwork \
//       -L$QT/lib -lQt6Core -lQt6Network && LD_LIBRARY_PATH=$QT/lib /tmp/svrmsg
//   LD_LIBRARY_PATH=$QT/lib /tmp/svrmsg --live http://192.168.1.4:8000
#include "ServerMessage.h"
#include <QCoreApplication>
#include <QDebug>
#include <QEventLoop>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTimer>
int fails = 0;
static void check(const char *name, const QByteArray &body, const QString &want) {
    const QString got = wt::serverMessage(body);
    const bool ok = (got == want);
    if (!ok) ++fails;
    qInfo().noquote() << (ok ? "PASS" : "FAIL") << name << "->" << (got.isEmpty() ? "<empty>" : got);
}

// ---------------------------------------------------------------- live mode
static void say(bool ok, const QString &what) {
    if (!ok) ++fails;
    qInfo().noquote() << (ok ? "PASS" : "FAIL") << what;
}

// One unauthenticated request. Returns the parsed body; `code` gets the HTTP status.
static QJsonObject probe(QNetworkAccessManager &nam, const QString &url,
                         const QByteArray &post, int &code) {
    QNetworkRequest req{QUrl(url)};
    req.setTransferTimeout(8000);
    if (!post.isNull())
        req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QNetworkReply *r = post.isNull() ? nam.get(req) : nam.post(req, post);
    QEventLoop loop;
    QObject::connect(r, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    loop.exec();
    code = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray raw = r->readAll();
    r->deleteLater();
    return QJsonDocument::fromJson(raw).object();
}

static int runLive(const QString &base) {
    QNetworkAccessManager nam;
    int code = 0;

    // 1. routers/auth.py, PROSE shape: detail is the sentence, code beside it.
    QJsonObject me = probe(nam, base + "/auth/me", QByteArray(), code);
    say(code == 401, QStringLiteral("GET /auth/me -> 401 (got %1)").arg(code));
    say(me.contains("code"), QStringLiteral("  carries `code` (%1)").arg(me.value("code").toString()));
    say(wt::serverMessage(me) == me.value("detail").toString(),
        QStringLiteral("  prose shape: message == detail"));

    // 2. SSO, CODE-IN-DETAIL shape: the sentence is ONLY in `message`. This is the case
    //    that justifies the whole read — if it ever stops holding, we want to know.
    QJsonObject sso = probe(nam, base + "/auth/sso", QByteArray(R"({"token":"not-a-jwt"})"), code);
    const QString d = sso.value("detail").toString(), m = sso.value("message").toString();
    say(code == 401, QStringLiteral("POST /auth/sso -> 401 (got %1)").arg(code));
    say(d == sso.value("code").toString() && !d.isEmpty(),
        QStringLiteral("  detail IS the enum (%1)").arg(d));
    say(!m.isEmpty() && m != d, QStringLiteral("  sentence lives in `message`"));
    say(wt::serverMessage(sso) == m, QStringLiteral("  the read picks the sentence, not the enum"));

    // 3. THE TRIPWIRE. auth/jwt.py is the shared dependency 51 routers run, and CV's
    //    reply17 §3 measured it as UNCODED. While that holds, a 401 from any protected
    //    route carries `detail` and nothing else. When CV ships reply17 §4 this FAILS —
    //    which is the point: it is the only assertion here that a deploy can move.
    QJsonObject shared = probe(nam, base + "/cameras/x/ptz", QByteArray(), code);
    say(code == 401, QStringLiteral("GET /cameras/x/ptz -> 401 (got %1)").arg(code));
    const bool uncoded = !shared.contains("code");
    if (uncoded)
        say(true, QStringLiteral("  auth/jwt.py still uncoded (detail=\"%1\") — expected, nothing to do")
                      .arg(shared.value("detail").toString()));
    else
        say(false, QStringLiteral("  auth/jwt.py IS NOW CODED (code=%1) -> re-capture the frozen "
                                  "bodies above and map the new codes to Russian")
                       .arg(shared.value("code").toString()));
    return fails;
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    const QStringList args = app.arguments();
    if (args.size() >= 3 && args.at(1) == QLatin1String("--live")) {
        qInfo().noquote() << "LIVE contract probe against" << args.at(2);
        runLive(args.at(2));
        qInfo().noquote() << (fails ? QString("%1 FAILED").arg(fails) : QStringLiteral("all passed"));
        return fails ? 1 : 0;
    }
    // 1. auth/jwt.py TODAY: prose-only, no code, no message -> must fall through to detail
    check("jwt.py uncoded 401", R"({"detail":"Authentication required"})",
          "Authentication required");
    // 2. auth/jwt.py TODAY: CODE-ONLY in detail, nothing to rescue it (the defect)
    check("jwt.py service_suspended (today)", R"({"detail":"service_suspended"})",
          "service_suspended");
    // 3. SSO: detail is the ENUM, sentence only in message -> must prefer message
    check("SSO enum in detail", R"({"code":"SSO_TOKEN_INVALID","detail":"SSO_TOKEN_INVALID","message":"This single sign-on link is not valid. Sign in again."})",
          "This single sign-on link is not valid. Sign in again.");
    // 4. prose shape (PTZ e614cac): detail == message, either read is the sentence
    check("PTZ live_control_suspended", R"({"code":"live_control_suspended","detail":"Live control is suspended by the owner","message":"Live control is suspended by the owner"})",
          "Live control is suspended by the owner");
    // 5. degenerate bodies must not throw or invent
    check("empty object", R"({})", "");
    check("not json", "<html>502 Bad Gateway</html>", "");
    check("message empty string", R"({"detail":"fallback","message":""})", "fallback");
    qInfo().noquote() << (fails ? QString("%1 FAILED").arg(fails) : QStringLiteral("all passed"));
    return fails ? 1 : 0;
}
