#pragma once
#include <QDateTime>
#include <QTimeZone>
#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <QUrl>
#include <QUrlQuery>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

// Labs FINDINGS for one analyser, fleet-wide -- the list the Statistics view opens when an
// analyser is clicked (operator request 2026-09-29): every finding of that kind in a period,
// newest first, each playable, with one-button filters on what the analyser measured.
//
// SOURCE: GET /labs/findings, asked of cilex-vision on 2026-09-29
// (docs/letters/2026-09-29-labs-findings-list-cilex-watchtower-linux.md). Only FINDINGS --
// the server's rule per analyser (labs_findings.py), the same set /labs/stats counts -- in the
// period by the footage's hour, newest first, paged by an opaque cursor (never an offset, so
// a page cannot repeat or skip rows as new findings arrive). Each item is an ObservationOut
// row (the shape /labs/observations serves, which the Playback lane already reads) plus the
// camera's name. Until the server has the endpoint (404) the view says so; nothing here is
// estimated, and nothing is read from another endpoint in its place.
namespace wtlabs {

inline const QStringList &findingsPeriods()
{
    static const QStringList p{QStringLiteral("24h"), QStringLiteral("7d"), QStringLiteral("all")};
    return p;
}

// The request for one page. `facet` and `cursor` are left out when empty, never sent blank.
inline QUrl findingsUrl(const QString &base, const QString &analyzer, const QString &period,
                        const QString &facet, const QString &cursor, int limit, const QString &lang)
{
    // Built by hand, every value percent-encoded: QUrlQuery leaves '+', '/' and '=' as they
    // are in a query, and the server (Starlette) reads a '+' in a query as a SPACE -- a
    // base64-style cursor would come back corrupted and the next page would fail. Caught by
    // tools/tests/labs-findings.cpp before it ever reached the server.
    auto enc = [](const QString &v) { return QString::fromLatin1(QUrl::toPercentEncoding(v)); };
    QStringList parts;
    parts << QStringLiteral("analyzer=") + enc(analyzer)
          << QStringLiteral("period=") + enc(findingsPeriods().contains(period) ? period : QStringLiteral("24h"));
    if (!facet.isEmpty())
        parts << QStringLiteral("facet=") + enc(facet);
    if (!cursor.isEmpty())
        parts << QStringLiteral("cursor=") + enc(cursor);
    parts << QStringLiteral("limit=") + QString::number(qBound(1, limit, 100))
          << QStringLiteral("lang=") + (lang == QStringLiteral("ru") ? lang : QStringLiteral("en"));
    QUrl url(base + QStringLiteral("/labs/findings"));
    url.setQuery(parts.join(QLatin1Char('&')), QUrl::StrictMode);
    return url;
}

struct FindingsPage {
    QVariantList items;        // server order (newest first); each row + startMs/endMs
    QString nextCursor;        // "" = no more pages
    QVariant total;            // findings for (analyser, period, facet); invalid = not counted
    QVariantList facets;       // [{id, label, count}] -- this analyser's one-button filters
    QString generatedAt;
    int dropped = 0;           // rows without an id or a readable start: counted, never shown
};

inline FindingsPage parseFindings(const QJsonObject &o)
{
    FindingsPage p;
    p.generatedAt = o.value(QStringLiteral("generated_at")).toString();
    p.nextCursor = o.value(QStringLiteral("next_cursor")).toString();
    const QJsonValue t = o.value(QStringLiteral("total"));
    if (t.isDouble())
        p.total = t.toDouble();
    for (const QJsonValue &v : o.value(QStringLiteral("items")).toArray()) {
        const QJsonObject r = v.toObject();
        const QString id = r.value(QStringLiteral("observation_id")).toString();
        const QDateTime s = QDateTime::fromString(r.value(QStringLiteral("start_time")).toString(), Qt::ISODateWithMs);
        QDateTime e = QDateTime::fromString(r.value(QStringLiteral("end_time")).toString(), Qt::ISODateWithMs);
        if (id.isEmpty() || !s.isValid()) {
            ++p.dropped;
            continue;
        }
        if (!e.isValid() || e < s)
            e = s;                           // a point in time: end == start, never before it
        QVariantMap m = r.toVariantMap();
        m[QStringLiteral("startMs")] = double(s.toMSecsSinceEpoch());
        m[QStringLiteral("endMs")] = double(e.toMSecsSinceEpoch());
        p.items.append(m);
    }
    for (const QJsonValue &v : o.value(QStringLiteral("facets")).toArray()) {
        const QJsonObject f = v.toObject();
        const QString id = f.value(QStringLiteral("id")).toString();
        if (id.isEmpty())
            continue;
        QVariantMap m;
        m[QStringLiteral("id")] = id;
        m[QStringLiteral("label")] = f.value(QStringLiteral("label")).toString().isEmpty()
                                         ? id : f.value(QStringLiteral("label")).toString();
        const QJsonValue c = f.value(QStringLiteral("count"));
        m[QStringLiteral("count")] = c.isDouble() ? QVariant(c.toDouble()) : QVariant();
        p.facets.append(m);
    }
    return p;
}

// A finding as the Events player takes an event (EvHeroPlayer reads id, cam{id,name,ip,
// preRollMs,postRollMs}, ts, durationSec): the finding's own window, the camera's recording
// profile for the roll. `cam` comes from the app's camera list; a camera it does not know is
// still playable by id -- named by the server's camera_name, never invented.
inline QVariantMap findingAsEvent(const QVariantMap &item, const QVariantMap &knownCam)
{
    QVariantMap cam = knownCam;
    const QString camId = item.value(QStringLiteral("camera_id")).toString();
    if (cam.isEmpty()) {
        cam[QStringLiteral("id")] = camId;
        cam[QStringLiteral("name")] = item.value(QStringLiteral("camera_name")).toString().isEmpty()
                                          ? camId : item.value(QStringLiteral("camera_name")).toString();
        cam[QStringLiteral("ip")] = QString();
        cam[QStringLiteral("preRollMs")] = -1;
        cam[QStringLiteral("postRollMs")] = -1;
    }
    const double s = item.value(QStringLiteral("startMs")).toDouble();
    const double e = item.value(QStringLiteral("endMs")).toDouble();
    QVariantMap ev;
    ev[QStringLiteral("id")] = QStringLiteral("labs:") + item.value(QStringLiteral("observation_id")).toString();
    ev[QStringLiteral("cam")] = cam;
    ev[QStringLiteral("tsMs")] = s;
    // A QDateTime reaches QML as a JS Date -- EvHeroPlayer calls ev.ts.getTime().
    ev[QStringLiteral("ts")] = QDateTime::fromMSecsSinceEpoch(qint64(s), QTimeZone::UTC);
    ev[QStringLiteral("durationSec")] = qMax(1.0, (e - s) / 1000.0);
    ev[QStringLiteral("rawType")] = QStringLiteral("labs:") + item.value(QStringLiteral("analyzer")).toString();
    return ev;
}

// A Paths (track_linking) row's `path`, as points in the picture: the analyser writes its
// trajectory as equal-time points, two characters each (x, then y), every coordinate one
// character of the base64url alphabet, quantised to 64 levels of its axis and decoded as
// (index + 0.5) / 64 -- cilex-vision's labs_track_linking.py, PATH_ALPHABET and
// Episode.path_string. A string with an odd length or a character outside the alphabet is
// not a path: nothing is returned rather than a guessed one.
inline QVariantList decodePath(const QString &path)
{
    static const QString alphabet =
        QStringLiteral("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_");
    QVariantList out;
    if (path.isEmpty() || path.size() % 2 != 0)
        return out;
    for (int i = 0; i + 1 < path.size(); i += 2) {
        const int ix = alphabet.indexOf(path.at(i)), iy = alphabet.indexOf(path.at(i + 1));
        if (ix < 0 || iy < 0)
            return {};
        QVariantMap p;
        p[QStringLiteral("x")] = (ix + 0.5) / 64.0;
        p[QStringLiteral("y")] = (iy + 0.5) / 64.0;
        out << p;
    }
    return out;
}

}   // namespace wtlabs
