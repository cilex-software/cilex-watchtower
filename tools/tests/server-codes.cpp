// Tests for rendering CV's error CODES in the reader's language (src/models/ServerCodes.h).
//
// Bodies below are CV's real shapes, read out of services/query-api on 2026-09-20 — not
// copied from their letters, after a night in which a list supplied from memory turned out
// to be five-elevenths wrong and a param set was written from an ask rather than from code.
//
// What this pins, in order of what would hurt most if it broke:
//   1. no KNOWN code ever reaches a guard as a bare enum or as English;
//   2. an UNKNOWN code degrades to CV's own sentence, never to an invented diagnosis and
//      never to the identifier — CV adds codes without asking us;
//   3. role_not_authorized puts the role where Russian grammar wants it, which is the whole
//      reason both clients asked for it as a separate field;
//   4. the two codes CV sends with NO message at all stop being identifiers on screen.
//
// Build + run (Qt 6.12), from the repo root AFTER a build so the .qm exists:
//   g++ -std=c++17 -fPIC -o /tmp/svrcodes tools/tests/server-codes.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -I$QT/include/QtNetwork \
//       -L$QT/lib -lQt6Core -lQt6Network && LD_LIBRARY_PATH=$QT/lib /tmp/svrcodes build/watchtower_ru.qm
#include "ServerCodes.h"
#include <QCoreApplication>
#include <QDebug>
#include <QTranslator>

int fails = 0;

static bool isCyrillic(const QString &s)
{
    for (const QChar c : s)
        if (c.unicode() >= 0x0400 && c.unicode() <= 0x04FF)
            return true;
    return false;
}

// Every known code must produce Russian, and must NOT leak the identifier or CV's English.
static void known(const char *code, const QByteArray &body, const QString &mustContain = {})
{
    const QString got = wt::localisedServerError(body);
    QStringList bad;
    if (!isCyrillic(got))            bad << "not Russian";
    if (got.contains(QLatin1String(code))) bad << "leaks the code";
    if (!mustContain.isEmpty() && !got.contains(mustContain))
        bad << QStringLiteral("missing %1").arg(mustContain);
    if (bad.isEmpty())
        qInfo().noquote() << "PASS" << QString(code).leftJustified(30) << got;
    else {
        ++fails;
        qInfo().noquote() << "FAIL" << QString(code).leftJustified(30) << got
                          << " <-" << bad.join(", ");
    }
}

static void check(const char *name, const QByteArray &body, const QString &want)
{
    const QString got = wt::localisedServerError(body);
    if (got == want) qInfo().noquote() << "PASS" << QString(name).leftJustified(30) << got;
    else { ++fails; qInfo().noquote() << "FAIL" << name << "-> got:" << got << " want:" << want; }
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QTranslator t;
    if (argc < 2 || !t.load(QString::fromUtf8(argv[1]))) {
        qCritical("usage: server-codes <path/to/watchtower_ru.qm>");
        return 2;
    }
    app.installTranslator(&t);

    // ---- auth/jwt.py, the shared dependency 51 routers run
    known("not_authenticated",
          R"({"code":"not_authenticated","detail":"Authentication required","message":"You are not signed in."})");
    known("invalid_token",
          R"({"code":"invalid_token","detail":"Invalid token","message":"Your session is not valid. Please sign in again."})");
    known("invalid_token_claims",
          R"({"code":"invalid_token_claims","detail":"Invalid token claims","message":"Your session is not valid. Please sign in again."})");
    known("token_expired",
          R"({"code":"token_expired","detail":"Token expired","message":"Your session has expired. Please sign in again."})");
    known("password_change_required",
          R"({"code":"password_change_required","detail":"password_change_required","message":"You must change your password before continuing."})");

    // ---- the three 423s a status-only branch could never tell apart. Three codes, three
    //      distinct sentences — the defect the whole contract was negotiated to fix.
    known("service_suspended",
          R"({"code":"service_suspended","detail":"service_suspended","message":"Service suspended — contact your provider."})");
    known("service_locked",
          R"({"code":"service_locked","detail":"Locked by the service provider — contact your provider to lift.","message":"Locked by the service provider — contact your provider to lift."})");
    known("live_control_suspended",
          R"({"code":"live_control_suspended","detail":"Live control is suspended by the owner","message":"Live control is suspended by the owner"})");

    // ---- the role travels as its own field, so it can sit where the grammar wants it
    known("role_not_authorized",
          R"({"code":"role_not_authorized","detail":"Role 'viewer' not authorized for this resource","message":"Your role does not have access to this resource.","role":"viewer"})",
          QStringLiteral("viewer"));
    // ...and without it, we say the general thing rather than inventing a role
    known("role_not_authorized (no role field)",
          R"({"code":"role_not_authorized","message":"Your role does not have access to this resource."})");

    // ---- sign-in and account state
    known("invalid_credentials",
          R"({"code":"invalid_credentials","detail":"Invalid username or password","message":"Invalid username or password"})");
    known("account_inactive",
          R"({"code":"account_inactive","detail":"Account is no longer active","message":"Account is no longer active"})");
    known("account_deactivated",
          R"({"code":"account_deactivated","message":"This account has been deactivated — contact an administrator."})");
    known("current_password_incorrect",
          R"({"code":"current_password_incorrect","message":"Current password is incorrect"})");
    known("password_unchanged",
          R"({"code":"password_unchanged","message":"New password must differ from the current one"})");

    // ---- SSO: `detail` is the ENUM on every one of these, so a client reading `detail`
    //      alone showed the identifier. Now none of them can.
    known("SSO_TOKEN_INVALID",
          R"({"code":"SSO_TOKEN_INVALID","detail":"SSO_TOKEN_INVALID","message":"This single sign-on link is not valid. Sign in again."})");
    known("SSO_TOKEN_EXPIRED",
          R"({"code":"SSO_TOKEN_EXPIRED","detail":"SSO_TOKEN_EXPIRED","message":"Your single sign-on link has expired. Sign in again."})");
    known("SSO_ACCOUNT_MISSING",
          R"({"code":"SSO_ACCOUNT_MISSING","detail":"SSO_ACCOUNT_MISSING","message":"This account no longer exists on this server."})");
    known("SSO_ACCOUNT_DEACTIVATED",
          R"({"code":"SSO_ACCOUNT_DEACTIVATED","detail":"SSO_ACCOUNT_DEACTIVATED","message":"This account has been deactivated on this server."})");
    known("SSO_ROLE_DENIED",
          R"({"code":"SSO_ROLE_DENIED","detail":"SSO_ROLE_DENIED","message":"This account is not allowed to sign in here."})");
    known("SSO_USERNAME_TAKEN",
          R"({"code":"SSO_USERNAME_TAKEN","detail":"SSO_USERNAME_TAKEN","message":"That username already belongs to another account on this server."})");
    known("SSO_NOT_CONFIGURED",
          R"({"code":"SSO_NOT_CONFIGURED","detail":"SSO_NOT_CONFIGURED","message":"Single sign-on is not set up on this server."})");

    // ---- the ones CV sends with NO message at all. Before this they reached a guard as
    //      the bare identifier; streams.py:1646 carries only in_use/budget beside the code.
    known("opt_tier_budget_exhausted",
          R"({"code":"opt_tier_budget_exhausted","detail":"opt_tier_budget_exhausted","in_use":8,"budget":8})");
    known("station_credential_rejected",
          R"({"code":"station_credential_rejected","detail":"station_credential_rejected"})");
    known("station_revoked",
          R"({"code":"station_revoked","detail":"station_revoked"})");
    known("station_exchange_rate_limited",
          R"({"code":"station_exchange_rate_limited","detail":"station_exchange_rate_limited"})");
    known("display_session_out_of_scope",
          R"({"code":"display_session_out_of_scope","detail":"display_session_out_of_scope"})");
    known("display_session_expired",
          R"({"code":"display_session_expired","detail":"display_session_expired"})");

    // ---- DEGRADATION. CV adds codes without asking us; an unknown one must fall through
    //      to their sentence, never to the identifier and never to something invented.
    check("unknown code -> CV's sentence",
          R"({"code":"brand_new_thing","detail":"brand_new_thing","message":"The widget fell off."})",
          QStringLiteral("The widget fell off."));
    check("unknown code, no message -> detail",
          R"({"code":"brand_new_thing","detail":"Something went wrong upstream"})",
          QStringLiteral("Something went wrong upstream"));
    check("no code at all -> message ?? detail (an older backend)",
          R"({"detail":"Authentication required"})",
          QStringLiteral("Authentication required"));
    check("legacy uncoded, code-only detail -> unchanged",
          R"({"detail":"service_suspended"})", QStringLiteral("service_suspended"));
    check("empty body -> empty", R"({})", QString());
    check("not json -> empty", "<html>502</html>", QString());

    qInfo().noquote() << (fails ? QStringLiteral("%1 FAILED").arg(fails)
                                : QStringLiteral("all passed"));
    return fails ? 1 : 0;
}
