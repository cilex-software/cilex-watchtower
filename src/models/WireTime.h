#pragma once
#include <QByteArray>
#include <QJsonValue>
#include <QStringView>
#include <QSet>
#include <QString>
#include <QtGlobal>

// A client CANNOT recover the right instant from a timestamp that arrived
// without a timezone. It CAN see that the STRING is the wrong shape, and say so.
//
// CORRECTION 2026-09-22. This box wrote the opposite — "nothing client-side can
// detect it" — into qml/GroupsStatus.js, docs/DEVELOPMENT.md, and two messages
// to other systems. cilex-pro-mobile drew the distinction (recovering the
// instant vs. recognising the shape), was right, and shipped the detector on
// their side first (7358240). This is the same alarm on ours.
//
// WHAT IT WATCHES FOR. Both our parsers read a naive ISO string as LOCAL time:
// QDateTime::fromString(s, Qt::ISODate) yields timeSpec=0, and QV4's Date.parse
// agrees (both measured, Qt 6.12, 2026-09-22). On this MSK box that is a silent
// 3-hour shift; in a UTC container it is none — so the SAME build misreads the
// SAME wire differently depending on where it runs, and every downstream
// comparison (freshness windows, "silent since", "detecting but not recording")
// is wrong by the local offset with nothing looking wrong. What prevents it is
// server-side and unpinned: cilex-vision's iso_ms() emits an offset iff the
// datetime it is handed is tz-aware, and the columns are TIMESTAMPTZ. Their
// route tests assert `wire == iso_ms(input)`, which passes just as well if BOTH
// sides go naive — so the guarantee is real, and nothing on either side would
// notice it lapsing. This would.
//
// NAMES THE FIELD, NEVER THE VALUE (mobile's rule, adopted): a detector that
// prints payload into a log is a different problem wearing a fix's clothes.
//
// NOT gated behind a dev hook, deliberately. It fires at most once per field per
// process and only on a shape that has never been observed on this wire, so the
// healthy cost is one branch per parse — and a detector behind a flag nobody
// sets is a detector nobody has. GUI thread only (all callers are network-reply
// handlers); the once-per-field set is not synchronised and does not need to be.
namespace wt {


// ±HH:MM or ±HHMM at the end. Hand-rolled and allocation-free on purpose: these
// call sites run for every timestamp of every camera on every /streams poll, and
// this repo has a long history of GUI-thread work that looked free per item.
inline bool hasOffsetTail(QStringView s)
{
    const qsizetype n = s.size();
    const auto d = [&](qsizetype i) { return s[i].isDigit(); };
    const auto sign = [&](qsizetype i) { return s[i] == u'+' || s[i] == u'-'; };
    if (n >= 6 && sign(n - 6) && s[n - 3] == u':' && d(n - 5) && d(n - 4) && d(n - 2) && d(n - 1))
        return true;
    if (n >= 5 && sign(n - 5) && d(n - 4) && d(n - 3) && d(n - 2) && d(n - 1))
        return true;
    return false;
}

inline QString wireInstant(const QJsonValue &v, const char *field)
{
    const QString s = v.toString();
    if (s.isEmpty())
        return s;

    // Only a date-TIME can carry an offset; a bare date legitimately has none,
    // and flagging "2026-09-22" would train the reader to ignore the warning.
    const qsizetype t = s.indexOf(QLatin1Char('T'));
    if (t < 0 || !s.contains(QLatin1Char(':')))
        return s;

    if (s.endsWith(QLatin1Char('Z')) || s.endsWith(QLatin1Char('z')))
        return s;
    if (hasOffsetTail(QStringView(s)))
        return s;

    static QSet<QByteArray> said;
    const QByteArray key(field);
    if (!said.contains(key)) {
        said.insert(key);
        qWarning().noquote()
            << QStringLiteral("Watchtower: WIRE TIMESTAMP '%1' carries no timezone offset. It will "
                              "be read as LOCAL time — a silent shift of this machine's UTC offset "
                              "in every comparison downstream. Expected an offset or 'Z' "
                              "(cilex-vision iso_ms + TIMESTAMPTZ). Value deliberately not logged; "
                              "said once per field.").arg(QString::fromUtf8(field));
    }
    return s;
}

}   // namespace wt
