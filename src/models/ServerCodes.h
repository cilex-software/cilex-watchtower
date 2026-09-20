#pragma once
#include <QCoreApplication>
#include <QJsonObject>
#include <QString>

#include "ServerMessage.h"

// CV's error CODES, rendered in the reader's language.
//
// WHY A CODE AND NOT THE SENTENCE. cilex-vision ships an English sentence beside every
// coded error, and until now this wall printed it verbatim — better than the bare enum it
// replaced, but still English on a screen read by Russian guards. Their prose cannot be
// translated here: matching on it would break the day they reword it, which is the whole
// reason the `code` field was negotiated over 2026-09-19/20 (letters reply9 through
// reply20). The code is the contract; the sentence is CV's copy; this is ours.
//
// THE RULES, agreed with cilex-pro-mobile (reply19 §1) and cilex-vision (reply20 §3):
//   * key off `code`, never off `detail` or `message`;
//   * DUPLICATE CODES MAP TO ONE STRING — `account_deactivated` and
//     SSO_ACCOUNT_DEACTIVATED stay two keys on the wire and become one piece of copy here.
//     Renaming a code is a wire change that breaks working clients to fix nothing a user
//     can see; two keys pointing at one string costs a line;
//   * an UNKNOWN code falls back to CV's own sentence (`message ?? detail`), never to a
//     raw enum and never to an invented diagnosis. CV adds codes without asking us, and a
//     client that renders a code it has not met yet must degrade to something a human can
//     read;
//   * `role_not_authorized` carries `role` as its OWN field — asked for independently by
//     both clients precisely so the role can sit where Russian grammar wants it. An
//     interpolated English sentence ("Role 'viewer' not authorized…") can never be
//     translated; a code plus a field can.
//
// SOURCED FROM CV's SOURCE, not from their letters. Every string below was written against
// the message CV actually raises, read out of services/query-api on 2026-09-20 — 22 literal
// codes plus the five display-session constants in auth/display_session.py. Two of those
// carry NO message at all (`opt_tier_budget_exhausted`, and the station/display-session
// set), so before this they reached a guard as bare identifiers; they are the ones this
// mapping helps most.
namespace wt {

// Russian (or whatever the UI language is) for a known code; empty for one we do not know.
inline QString copyForCode(const QString &code, const QJsonObject &body)
{
    const auto T = [](const char *s) { return QCoreApplication::translate("ServerError", s); };

    // --- sign-in and account state (routers/auth.py)
    if (code == QLatin1String("invalid_credentials"))
        return T("Wrong username or password");
    if (code == QLatin1String("account_inactive"))
        return T("This account is no longer active");
    if (code == QLatin1String("account_deactivated")
        || code == QLatin1String("SSO_ACCOUNT_DEACTIVATED"))
        return T("This account has been deactivated — contact an administrator");
    if (code == QLatin1String("current_password_incorrect"))
        return T("The current password is wrong");
    if (code == QLatin1String("password_unchanged"))
        return T("The new password must differ from the current one");

    // --- session state (auth/jwt.py — the shared dependency 51 routers run)
    if (code == QLatin1String("not_authenticated"))
        return T("You are not signed in");
    if (code == QLatin1String("invalid_token") || code == QLatin1String("invalid_token_claims"))
        return T("This session is not valid. Please sign in again");
    if (code == QLatin1String("token_expired"))
        return T("This session has expired. Please sign in again");
    if (code == QLatin1String("password_change_required"))
        return T("You must change your password before continuing");

    // --- the three 423s, which a status-only branch could never tell apart. That was the
    //     defect the whole code contract came from, so they get three distinct sentences.
    if (code == QLatin1String("service_suspended"))
        return T("Service suspended — contact your provider");
    if (code == QLatin1String("service_locked"))
        return T("Locked by the service provider — contact them to lift it");
    if (code == QLatin1String("live_control_suspended"))
        return T("Live camera control is suspended by the owner");

    // --- role, with the role as its own field so it can sit where the grammar wants it
    if (code == QLatin1String("role_not_authorized")) {
        const QString role = body.value(QStringLiteral("role")).toString();
        return role.isEmpty()
                   ? T("Your role does not have access to this")
                   : QCoreApplication::translate("ServerError",
                                                 "The role \"%1\" does not have access to this")
                         .arg(role);
    }

    // --- capacity. CV sends NO message for this one (streams.py:1646), so before this it
    //     reached a guard as the identifier itself. `in_use`/`budget` ride along as extra
    //     fields; deliberately not printed — a guard needs the wait, not the arithmetic.
    if (code == QLatin1String("opt_tier_budget_exhausted"))
        return T("All viewing channels are busy — try again in a few seconds");

    // --- single sign-on
    if (code == QLatin1String("SSO_TOKEN_INVALID"))
        return T("This single sign-on link is not valid. Sign in again");
    if (code == QLatin1String("SSO_TOKEN_EXPIRED"))
        return T("This single sign-on link has expired. Sign in again");
    if (code == QLatin1String("SSO_ACCOUNT_MISSING"))
        return T("This account no longer exists on this server");
    if (code == QLatin1String("SSO_ROLE_DENIED"))
        return T("This account is not allowed to sign in here");
    if (code == QLatin1String("SSO_USERNAME_TAKEN"))
        return T("That username already belongs to another account on this server");
    if (code == QLatin1String("SSO_NOT_CONFIGURED"))
        return T("Single sign-on is not set up on this server");

    // --- station / display-session (auth/display_session.py). These carry no message at
    //     all, so the enum was the only thing a reader ever got.
    if (code == QLatin1String("station_credential_rejected"))
        return T("This station's credentials were refused by the server");
    if (code == QLatin1String("station_revoked"))
        return T("This station has been revoked");
    if (code == QLatin1String("station_exchange_rate_limited"))
        return T("Too many attempts from this station — try again shortly");
    if (code == QLatin1String("display_session_out_of_scope"))
        return T("This display session is not allowed to see that");
    if (code == QLatin1String("display_session_expired"))
        return T("This display session has expired");

    return QString();                    // unknown code — caller falls back to CV's sentence
}

// What to SHOW a guard for a server error: our copy when we know the code, CV's own
// sentence when we do not, and `detail` when there is no sentence either.
//
// Never returns a bare code for anything in the table above, and never invents a diagnosis
// for one outside it. Logs should keep using serverMessage() — a translated string is worse
// for diagnosis than the server's own words, and the two audiences want different things.
inline QString localisedServerError(const QJsonObject &body)
{
    const QString mine = copyForCode(body.value(QStringLiteral("code")).toString(), body);
    return mine.isEmpty() ? serverMessage(body) : mine;
}

inline QString localisedServerError(const QByteArray &raw)
{
    return localisedServerError(QJsonDocument::fromJson(raw).object());
}

}   // namespace wt
