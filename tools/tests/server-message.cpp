// Client-side test of the `message ?? detail` read (src/models/ServerMessage.h).
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
// HISTORY, because it is the point of the file. I wrote in reply18 §4 that the frozen case
// pinning `service_suspended -> service_suspended` would "fail when CV ships, so someone has
// to look". That was WRONG — cilex-pro-mobile's reply19 §3 caught it: captured bytes are
// unaffected by any deploy. The live mode was added as the real tripwire, asserting that
// auth/jwt.py was still UNCODED. It fired in production within the hour (CV reply20 §2:
// "I have shipped, and it is still green ... a passing test describing a wire that no longer
// exists"), which is exactly what it was for.
//
// So the frozen bodies below were RE-CAPTURED on 2026-09-20 after CV shipped 654b9df /
// 869aab5 / e614cac / b7ddb53, and the live assertion has been flipped from "jwt.py is
// uncoded" to the contract that replaced it. Every body marked MEASURED was fetched from the
// pilot by this box; the gated ones CV rendered through the real handler and published in
// reply20 §2, because reaching them needs a state nobody should create on a live box.
//
// PROVENANCE UPGRADED 2026-09-20. The four I could not reach were originally pinned on CV's
// published table alone. cilex-pro-mobile's rule — "verify what is handed to you ESPECIALLY
// when it matches what you asked for; agreement is not evidence" — landed the same night CV
// admitted writing a param set for Pro Mobile from the ASK rather than from their code. So
// all seven were checked against source rather than against the letter:
//   auth/jwt.py:85  token_expired            :91  invalid_token
//              :140 not_authenticated        :155 invalid_token_claims
//              :199 password_change_required :208 service_suspended
//              :250 role_not_authorized (+ role=user.role)
// :199 and :208 pass NO `detail`; errors.py:55 is `detail=code if detail is None else detail`,
// so both send the bare code there — which is what these fixtures assert. Seven for seven,
// no discrepancy. The check confirming the table is worth as much as one overturning it:
// the point is that it was checked.
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

int fails = 0;

static void check(const char *name, const QByteArray &body, const QString &want) {
    const QString got = wt::serverMessage(body);
    const bool ok = (got == want);
    if (!ok) { ++fails; qInfo().noquote() << "FAIL" << name << "-> got:" << got << " want:" << want; }
    else       qInfo().noquote() << "PASS" << name << "->" << (got.isEmpty() ? "<empty>" : got);
}

// ---------------------------------------------------------------- live mode
static void say(bool ok, const QString &what) {
    if (!ok) ++fails;
    qInfo().noquote() << (ok ? "PASS" : "FAIL") << what;
}

// One unauthenticated request. Returns the parsed body; `code` gets the HTTP status.
static QJsonObject probe(QNetworkAccessManager &nam, const QString &url,
                         const QByteArray &post, int &code, const QByteArray &cookie = {}) {
    QNetworkRequest req{QUrl(url)};
    req.setTransferTimeout(8000);
    if (!cookie.isEmpty())
        req.setRawHeader("Cookie", cookie);
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

static void assertCoded(const QJsonObject &o, const QString &where) {
    const QString c = o.value("code").toString();
    const QString d = o.value("detail").toString();
    const QString m = o.value("message").toString();
    say(!c.isEmpty(), QStringLiteral("  %1 carries `code` (%2)").arg(where, c));
    say(!m.isEmpty(), QStringLiteral("  %1 carries a human `message`").arg(where));
    say(wt::serverMessage(o) == m && m != d,
        QStringLiteral("  %1 the read picks the sentence, not `detail` (%2)").arg(where, d));
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

    // 3. THE TRIPWIRE, now inverted. It used to assert auth/jwt.py was UNCODED and it fired
    //    when CV shipped (654b9df et al). What replaces it is the contract that arrived: the
    //    shared dependency 51 routers run must carry a code AND a sentence. If a rollback or
    //    a regression takes either away, the wall goes back to rendering `detail` — a bare
    //    enum on the code-only sites — and this fails instead of nobody noticing.
    QJsonObject shared = probe(nam, base + "/cameras/x/ptz", QByteArray(), code);
    say(code == 401, QStringLiteral("GET /cameras/x/ptz -> 401 (got %1)").arg(code));
    assertCoded(shared, QStringLiteral("jwt.py"));

    // 4. The same body from a DIFFERENT router is the proof it is the dependency and not one
    //    handler being polite (CV reply20 §2 makes exactly this claim; this checks it).
    QJsonObject other = probe(nam, base + "/streams", QByteArray(), code);
    say(code == 401, QStringLiteral("GET /streams -> 401 (got %1)").arg(code));
    say(other == shared, QStringLiteral("  identical body from another router (shared dependency)"));

    // 5. A garbage cookie reaches _decode_token, a different jwt.py site.
    QJsonObject bad = probe(nam, base + "/cameras/x/ptz", QByteArray(), code,
                            QByteArray("access_token=not-a-real-token"));
    say(code == 401, QStringLiteral("GET /cameras/x/ptz (garbage cookie) -> 401 (got %1)").arg(code));
    assertCoded(bad, QStringLiteral("_decode_token"));

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

    // ---- auth/jwt.py, the shared dependency, AFTER CV coded it (MEASURED here 2026-09-20).
    //      Note the read now returns something DIFFERENT from `detail` on the most-hit error
    //      on the whole API: the wall says "You are not signed in.", not "Authentication
    //      required". That difference is what this thread was for.
    check("jwt.py not_authenticated",
          R"({"code":"not_authenticated","detail":"Authentication required","message":"You are not signed in."})",
          "You are not signed in.");
    check("jwt.py invalid_token",
          R"({"code":"invalid_token","detail":"Invalid token","message":"Your session is not valid. Please sign in again."})",
          "Your session is not valid. Please sign in again.");
    // The remaining two of CV's seven (reply20 §3). Not measured on the wire — `token_expired`
    // needs an aged token and `invalid_token_claims` a hand-crafted JWT — but both bodies are
    // verified against auth/jwt.py:85 and :155 (see PROVENANCE above). THE SHAPE IS THE POINT: at these terse prose sites `message` is NOT
    // a copy of `detail`, which is new from CV and is exactly why `detail` alone is not
    // good enough — "Token expired" is barely better than `token_expired` on a guard's
    // screen, and the read now gets the real sentence instead.
    check("jwt.py token_expired",
          R"({"code":"token_expired","detail":"Token expired","message":"Your session has expired. Please sign in again."})",
          "Your session has expired. Please sign in again.");
    check("jwt.py invalid_token_claims",
          R"({"code":"invalid_token_claims","detail":"Invalid token claims","message":"Your session is not valid. Please sign in again."})",
          "Your session is not valid. Please sign in again.");

    // ---- the gated jwt.py sites (CV reply20 §2, rendered through the real handler; reaching
    //      them live needs a state nobody should create on a running box). Bodies verified
    //      against auth/jwt.py:199/:208/:250 + errors.py:55 — see PROVENANCE above.
    //      The 423 is byte-for-byte the "after" row photographed in reply18 §1.
    check("jwt.py service_suspended (coded)",
          R"({"code":"service_suspended","detail":"service_suspended","message":"Service suspended — contact your provider."})",
          "Service suspended — contact your provider.");
    check("jwt.py password_change_required",
          R"({"code":"password_change_required","detail":"password_change_required","message":"You must change your password before continuing."})",
          "You must change your password before continuing.");
    // role_not_authorized carries the role as its OWN field rather than interpolated into the
    // sentence — asked for by both clients independently, and what makes «Нужна роль: …»
    // possible at all. The parse must ignore the extra field cleanly.
    check("jwt.py role_not_authorized (+role field)",
          R"({"code":"role_not_authorized","detail":"Role 'viewer' not authorized for this resource","message":"Your role does not have access to this resource.","role":"viewer"})",
          "Your role does not have access to this resource.");

    // ---- LEGACY, not dead: an un-upgraded backend still sends the code alone with no
    //      sentence anywhere. `message ?? detail` then returns the enum, correctly, because
    //      the enum is all there is. Kept so the parse stays pinned for old boxes — NOT as a
    //      claim about the current wire, which is the mistake this file already made once.
    check("legacy uncoded box (pre-e8b0a4a)", R"({"detail":"service_suspended"})",
          "service_suspended");

    // ---- SSO: detail is the ENUM, sentence only in `message` (CV reply14 §2).
    check("SSO enum in detail",
          R"({"code":"SSO_TOKEN_INVALID","detail":"SSO_TOKEN_INVALID","message":"This single sign-on link is not valid. Sign in again."})",
          "This single sign-on link is not valid. Sign in again.");
    // ---- PTZ, prose shape (e614cac): either read yields the sentence.
    check("PTZ live_control_suspended",
          R"({"code":"live_control_suspended","detail":"Live control is suspended by the owner","message":"Live control is suspended by the owner"})",
          "Live control is suspended by the owner");

    // ---- degenerate bodies must not throw or invent.
    check("empty object", R"({})", "");
    check("not json", "<html>502 Bad Gateway</html>", "");
    check("message empty string", R"({"detail":"fallback","message":""})", "fallback");

    qInfo().noquote() << (fails ? QString("%1 FAILED").arg(fails) : QStringLiteral("all passed"));
    return fails ? 1 : 0;
}
