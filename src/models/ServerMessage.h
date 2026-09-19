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
// Two of its sites are code-only TODAY — `service_suspended` and `password_change_required`
// (jwt.py:205/196) send the bare code in `detail` with no `code` field at all — and
// PlaybackClient's 401 branch feeds HealthScreen's playback strip, so a suspended service
// would print `service_suspended` at a guard right now. CV's reply17 §4 adds the sentences;
// this is the read that lets them arrive.
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
