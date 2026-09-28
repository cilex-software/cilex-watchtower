#pragma once
// Labs on the Playback timeline -- the parts that decide what the Labs lane SHOWS, kept free
// of the network and of painting so tools/tests/labs-timeline.cpp can pin them (the
// LabsStation.h pattern).
//
// SOURCE: GET /labs/observations?camera_id&start&end&analyzer&lang&limit -- cilex-vision's
// "Labs observations for the enriched timeline" (routers/labs.py:1887). Camera-scoped
// server-side, not admin-gated; the button that shows this lane is admin-only here.
//
// ONE REQUEST PER ANALYSER, not one for all. The endpoint returns the NEWEST `limit` rows of
// a window (limit <= 2000), so one all-analyser request lets a chatty analyser crowd the
// others out: track_linking filed 202 rows in one hour of one camera on 2026-09-27, so a day
// of it alone exceeds the cap. Per analyser, every row can say for itself that it was cut,
// and each query is an index scan ((analyzer, camera_id, start_time DESC), measured in
// pg_indexes 2026-09-28).
#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QTimeZone>
#include <QUrl>
#include <QUrlQuery>
#include <QVariantMap>
#include <QVector>
#include <algorithm>
#include <cmath>

namespace wtlabs {

// The ten analysers the lane has a row for, in row order: the operator's list (2026-09-28).
inline const QStringList &laneKeys()
{
    static const QStringList keys = {
        QStringLiteral("audio_energy"), QStringLiteral("blob_geometry"), QStringLiteral("camera_health"),
        QStringLiteral("colour_histogram"), QStringLiteral("foreground_mask"),
        QStringLiteral("frame_difference"), QStringLiteral("illumination"), QStringLiteral("optical_flow"),
        QStringLiteral("perceptual_hash"), QStringLiteral("track_linking")};
    return keys;
}

// The endpoint's own ceiling (Query(500, ge=1, le=2000)). An answer this long may have
// been cut: the server says nothing more, so the row says "2000+" rather than "2000".
constexpr int kPageLimit = 2000;

struct Obs {
    QString id;
    qint64 startMs = 0;
    qint64 endMs = 0;          // >= startMs; a point observation has end == start
    QVariantMap row;           // the server's whole row, for the card
};

// One /labs/observations answer, sorted by start. A row without an id or a start time
// cannot be placed or named, so it is dropped -- and COUNTED, never silently.
inline QVector<Obs> parseObservations(const QJsonArray &arr, int *dropped = nullptr)
{
    QVector<Obs> out;
    out.reserve(arr.size());
    int bad = 0;
    for (const QJsonValue &v : arr) {
        const QJsonObject o = v.toObject();
        const QDateTime s = QDateTime::fromString(o.value(QStringLiteral("start_time")).toString(), Qt::ISODateWithMs);
        const QDateTime e = QDateTime::fromString(o.value(QStringLiteral("end_time")).toString(), Qt::ISODateWithMs);
        Obs ob;
        ob.id = o.value(QStringLiteral("observation_id")).toString();
        if (ob.id.isEmpty() || !s.isValid()) {
            ++bad;
            continue;
        }
        ob.startMs = s.toMSecsSinceEpoch();
        ob.endMs = e.isValid() ? std::max(ob.startMs, e.toMSecsSinceEpoch()) : ob.startMs;
        ob.row = o.toVariantMap();
        out.push_back(ob);
    }
    std::stable_sort(out.begin(), out.end(), [](const Obs &a, const Obs &b) { return a.startMs < b.startMs; });
    if (dropped)
        *dropped = bad;
    return out;
}

// The observation under `ms`. Measured against what is DRAWN: an observation spans at least
// `minSpanMs` (the painter's 2-px minimum), and the pointer may be `tolMs` off it. When the
// pointer is inside several, the SMALLEST wins -- a short track drawn inside a long one must
// be reachable, or it is only decoration; when inside none, the nearest within tolerance
// wins. Ties go to the later row, the one painted on top. -1 when none.
inline int hitTest(const QVector<Obs> &v, double ms, double tolMs, double minSpanMs = 0)
{
    int best = -1;
    bool bestInside = false;
    double bestKey = 0;
    for (int i = 0; i < v.size(); ++i) {
        const double s = double(v[i].startMs);
        const double e = std::max(double(v[i].endMs), s + minSpanMs);
        if (s - tolMs > ms)
            break;                                   // sorted by start: nothing later can reach
        const double d = ms < s ? s - ms : (ms > e ? ms - e : 0.0);
        if (d > tolMs)
            continue;
        const bool inside = d == 0.0;
        const double key = inside ? e - s : d;       // inside: smallest span; near: nearest
        if (best < 0 || (inside && !bestInside) || (inside == bestInside && key <= bestKey)) {
            best = i;
            bestInside = inside;
            bestKey = key;
        }
    }
    return best;
}

// Horizontal runs for painting. Observations that touch at pixel resolution merge into one
// run, so a day of thousands paints as at most `width` rectangles and the shape of the day
// stays visible. Every observation is at least `minW` wide, so a 1-second one survives a
// 24-hour view. Clipped to [0, width].
struct Run {
    double x0 = 0, x1 = 0;
    int count = 0;
};
inline QVector<Run> runs(const QVector<Obs> &v, double winS, double winE, double width, double minW = 2.0)
{
    QVector<Run> out;
    const double span = winE - winS;
    if (!(span > 0) || !(width > 0))
        return out;
    for (const Obs &o : v) {
        double x0 = (double(o.startMs) - winS) / span * width;
        double x1 = std::max(x0 + minW, (double(o.endMs) - winS) / span * width);
        if (x1 < 0 || x0 > width)
            continue;
        x0 = std::max(0.0, x0);
        x1 = std::min(width, x1);
        if (!out.isEmpty() && x0 <= out.last().x1 + 0.5) {
            out.last().x1 = std::max(out.last().x1, x1);
            ++out.last().count;
        } else {
            out.push_back(Run{x0, x1, 1});
        }
    }
    return out;
}

// The request for one analyser and window. UTC with milliseconds; lang is the UI language.
inline QUrl observationsUrl(const QString &base, const QString &cameraId, qint64 startMs, qint64 endMs,
                            const QString &analyzer, const QString &lang, int limit = kPageLimit)
{
    QUrl u(base + QStringLiteral("/labs/observations"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("camera_id"), cameraId);
    q.addQueryItem(QStringLiteral("start"),
                   QDateTime::fromMSecsSinceEpoch(startMs, QTimeZone::UTC).toString(Qt::ISODateWithMs));
    q.addQueryItem(QStringLiteral("end"),
                   QDateTime::fromMSecsSinceEpoch(endMs, QTimeZone::UTC).toString(Qt::ISODateWithMs));
    q.addQueryItem(QStringLiteral("analyzer"), analyzer);
    q.addQueryItem(QStringLiteral("lang"), lang == QLatin1String("ru") ? QStringLiteral("ru") : QStringLiteral("en"));
    q.addQueryItem(QStringLiteral("limit"), QString::number(std::clamp(limit, 1, kPageLimit)));
    u.setQuery(q);
    return u;
}

}   // namespace wtlabs
