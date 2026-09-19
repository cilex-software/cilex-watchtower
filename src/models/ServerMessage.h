#pragma once
#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QString>

// `message ?? detail` — cilex-vision's error contract since e8b0a4a (their letter
// 2026-09-19-a-wall-that-cannot-say-who-it-is.reply14-cilex-vision.md §2).
//
// CV froze `detail` byte-for-byte per raise site, because clients were already matching
// on it. That leaves two shapes on the wire:
//
//   legacy detail was the SENTENCE -> detail unchanged, `code` added      (nothing to do)
//   legacy detail was the CODE     -> detail unchanged, sentence in `message`
//
// so reading `detail` alone puts a raw enum in front of a guard wherever the second shape
// applies. `message` is ABSENT, not empty, on a site CV has not coded, which is what makes
// this safe to apply everywhere: an uncoded route falls through to `detail` exactly as before.
//
// SCOPE — deliberately every client that surfaces a server string, not just /auth. The
// first cut of this (1d04cf9) was /auth only, on the reasoning that CV had not coded the
// other routers. That reasoning was wrong: `auth/jwt.py` is the SHARED dependency 51
// routers run, so its 401/423 bodies arrive on playback, The Watch and PTZ replies too.
//
// HISTORICAL, and left here because it is why this read exists at all. As of 2026-09-20
// ~01:00, two jwt.py sites were code-only — `service_suspended` and `password_change_required`
// (:205/:196) sent the bare code in `detail` with no `code` field — and PlaybackClient's 401
// branch feeds HealthScreen's playback strip, so a suspended service printed the bare enum
// `service_suspended` at a guard. Photographed, reply18 §1.
// **No longer true.** CV coded all seven jwt.py sites the same night (654b9df / 869aab5 /
// e614cac / b7ddb53); every one now carries a `code` and a human `message`. Measured here
// 2026-09-20: GET /cameras/x/ptz unauthenticated returns
// {"code":"not_authenticated","detail":"Authentication required","message":"You are not signed in."}
// Dated and marked rather than deleted, because a claim about someone ELSE's system stated
// in the present tense is the one that outlives every letter (CV's own reply20 §5, about a
// comment of theirs describing our screen). The scope reasoning above stands on its own and
// never depended on those two sites being uncoded.
// Pinned by tools/tests/server-message.cpp — `--live` fails if a rollback takes it away.
namespace wt {

inline QString serverMessage(const QJsonObject &o)
{
    const QString msg = o.value(QStringLiteral("message")).toString();
    return msg.isEmpty() ? o.value(QStringLiteral("detail")).toString() : msg;
}

inline QString serverMessage(const QByteArray &raw)
{
    return serverMessage(QJsonDocument::fromJson(raw).object());
}

}   // namespace wt
