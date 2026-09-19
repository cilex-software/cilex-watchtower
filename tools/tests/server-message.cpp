// Client-side test of the `message ?? detail` read (src/models/ServerMessage.h).
//
// Bodies are REAL: rows 1-2 measured from the pilot (GET /cameras/x/ptz unauthenticated,
// and auth/jwt.py:205 as CV serialised it in reply17 §3); rows 3-4 from CV live probes in
// reply14 §2 and reply17 §1. Row 2 is the defect this read cannot fix from the client:
// a code-only site with no sentence anywhere, which is what CV reply17 §4 adds.
//
// Build + run (Qt 6.12):
//   g++ -std=c++17 -fPIC -o /tmp/svrmsg tools/tests/server-message.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -L$QT/lib -lQt6Core && LD_LIBRARY_PATH=$QT/lib /tmp/svrmsg
#include "ServerMessage.h"
#include <QCoreApplication>
#include <QDebug>
int fails = 0;
static void check(const char *name, const QByteArray &body, const QString &want) {
    const QString got = wt::serverMessage(body);
    const bool ok = (got == want);
    if (!ok) ++fails;
    qInfo().noquote() << (ok ? "PASS" : "FAIL") << name << "->" << (got.isEmpty() ? "<empty>" : got);
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
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
