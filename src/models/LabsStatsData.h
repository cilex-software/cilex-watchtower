#pragma once
#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

// Labs statistics by period (operator request 2026-09-28): for each analyser, how much of
// the footage recorded in a period it has CHECKED, how much is still WAITING, and what it
// FOUND -- over the last 24 hours, the last 7 days, and all footage.
//
// Operator decisions, same day:
//   * A period means FOOTAGE RECORDED in it, not work done in it. So checked + in progress
//     + waiting + given up is all of that footage, and the bar is a true progress bar.
//   * An "event" is a FINDING: a record where the analyser found something. Routine
//     readings (day/night every 30 min, "nothing moved" windows) do not count. Which
//     records are findings is cilex-vision's rule, per analyser.
//
// SOURCE. GET /labs/stats, asked of cilex-vision on 2026-09-28
// (docs/letters/2026-09-28-labs-statistics-by-period-cilex-watchtower-linux.md). Until the
// server has it (404), "all" is read from GET /labs/pipeline -- checked = done, waiting =
// queue_remaining, in progress = leases still live -- and the two periods say they are
// waiting for the server. Nothing is estimated: a figure the server did not give stays
// ABSENT (an invalid QVariant, shown as "—"), never 0.
namespace wtlabs {

inline const QStringList &statsWindows()
{
    static const QStringList w{QStringLiteral("24h"), QStringLiteral("7d"), QStringLiteral("all")};
    return w;
}

inline QVariant statNum(const QJsonValue &v)
{
    return v.isDouble() ? QVariant(v.toDouble()) : QVariant();
}

// One analyser in one window, from the server's answer. Keys (QML reads them):
//   slug, enabled, cameraHours, checked, inProgress, waiting, givenUp, findings, records,
//   segmentsScanned, checkedEver (the "all" window only: checked hours whose footage the
//   server has since deleted are in it, and not in cameraHours).
inline QVariantMap statRow(const QString &slug, bool enabled, const QJsonObject &w)
{
    QVariantMap r;
    r[QStringLiteral("slug")] = slug;
    r[QStringLiteral("enabled")] = enabled;
    r[QStringLiteral("cameraHours")] = statNum(w.value(QStringLiteral("camera_hours")));
    r[QStringLiteral("checked")] = statNum(w.value(QStringLiteral("checked")));
    r[QStringLiteral("inProgress")] = statNum(w.value(QStringLiteral("in_progress")));
    r[QStringLiteral("waiting")] = statNum(w.value(QStringLiteral("waiting")));
    r[QStringLiteral("givenUp")] = statNum(w.value(QStringLiteral("given_up")));
    r[QStringLiteral("findings")] = statNum(w.value(QStringLiteral("findings")));
    r[QStringLiteral("records")] = statNum(w.value(QStringLiteral("records")));
    r[QStringLiteral("segmentsScanned")] = statNum(w.value(QStringLiteral("segments_scanned")));
    r[QStringLiteral("checkedEver")] = statNum(w.value(QStringLiteral("checked_ever")));
    return r;
}

// GET /labs/stats -> {source: "server", generatedAt, computedAt,
//                     windows: {"24h": {from, to, rows: [statRow...]}, "7d": ..., "all": ...}}
// A window the answer does not carry is left out, and the screen says the server did not
// count it -- it is never filled from another window.
inline QVariantMap parseStats(const QJsonObject &o)
{
    QVariantMap out;
    out[QStringLiteral("source")] = QStringLiteral("server");
    out[QStringLiteral("generatedAt")] = o.value(QStringLiteral("generated_at")).toString();
    out[QStringLiteral("computedAt")] = o.value(QStringLiteral("computed_at")).toString();
    const QJsonObject bounds = o.value(QStringLiteral("windows")).toObject();
    QVariantMap windows;
    for (const QString &w : statsWindows()) {
        QVariantList rows;
        bool any = false;
        for (const QJsonValue &v : o.value(QStringLiteral("analyzers")).toArray()) {
            const QJsonObject a = v.toObject();
            const QString slug = a.value(QStringLiteral("analyzer")).toString();
            const QJsonValue wv = a.value(QStringLiteral("windows")).toObject().value(w);
            if (slug.isEmpty() || !wv.isObject())
                continue;
            any = true;
            rows.append(statRow(slug, a.value(QStringLiteral("enabled")).toBool(), wv.toObject()));
        }
        if (!any)
            continue;
        const QJsonObject b = bounds.value(w).toObject();
        QVariantMap win;
        win[QStringLiteral("from")] = b.value(QStringLiteral("from")).toString();
        win[QStringLiteral("to")] = b.value(QStringLiteral("to")).toString();
        win[QStringLiteral("rows")] = rows;
        windows[w] = win;
    }
    out[QStringLiteral("windows")] = windows;
    return out;
}

// Leases still live at `now`, per analyser, from /labs/pipeline's in_flight. The pipeline's
// `claimed` count also holds leases that ran out hours ago and wait for the lazy sweep at
// the next claim (5 of them on the pilot on 2026-09-28, 8 h past expiry): those are not
// "in progress", and counting them so would be false.
inline QHash<QString, int> liveLeases(const QJsonObject &pipeline, const QDateTime &now)
{
    QHash<QString, int> n;
    for (const QJsonValue &v : pipeline.value(QStringLiteral("in_flight")).toArray()) {
        const QJsonObject l = v.toObject();
        const QDateTime exp = QDateTime::fromString(l.value(QStringLiteral("lease_expires_at")).toString(), Qt::ISODateWithMs);
        if (exp.isValid() && exp > now)
            ++n[l.value(QStringLiteral("analyzer")).toString()];
    }
    return n;
}

// Before the server has /labs/stats: the "all" window from what /labs/pipeline already
// says. cameraHours, givenUp and findings are unknown there, so they stay absent: the bar
// is checked | in progress | waiting, and the server's waiting count can include failed
// hours that will not be handed out again (its own docstring) -- the screen says so.
inline QVariantMap statsFromPipeline(const QVariantList &rows, const QJsonObject &pipeline,
                                     const QDateTime &now)
{
    const QHash<QString, int> live = liveLeases(pipeline, now);
    QVariantList out;
    for (const QVariant &v : rows) {
        const QVariantMap p = v.toMap();
        const QString slug = p.value(QStringLiteral("slug")).toString();
        QVariantMap r;
        r[QStringLiteral("slug")] = slug;
        r[QStringLiteral("enabled")] = p.value(QStringLiteral("enabled"));
        r[QStringLiteral("cameraHours")] = QVariant();
        r[QStringLiteral("checked")] = p.value(QStringLiteral("done"));
        r[QStringLiteral("inProgress")] = QVariant(double(live.value(slug)));
        r[QStringLiteral("waiting")] = p.value(QStringLiteral("waiting"));
        r[QStringLiteral("givenUp")] = QVariant();
        r[QStringLiteral("failed")] = p.value(QStringLiteral("failed"));
        r[QStringLiteral("findings")] = QVariant();
        r[QStringLiteral("records")] = p.value(QStringLiteral("observations"));
        r[QStringLiteral("segmentsScanned")] = QVariant();
        r[QStringLiteral("checkedEver")] = p.value(QStringLiteral("done"));
        out.append(r);
    }
    QVariantMap win;
    win[QStringLiteral("from")] = QString();
    win[QStringLiteral("to")] = pipeline.value(QStringLiteral("generated_at")).toString();
    win[QStringLiteral("rows")] = out;
    QVariantMap windows;
    windows[QStringLiteral("all")] = win;
    QVariantMap s;
    s[QStringLiteral("source")] = QStringLiteral("pipeline");
    s[QStringLiteral("generatedAt")] = pipeline.value(QStringLiteral("generated_at")).toString();
    // The waiting figure is the server's cached queue count, which carries its own time.
    s[QStringLiteral("computedAt")] = pipeline.value(QStringLiteral("queue_computed_at")).toString();
    s[QStringLiteral("windows")] = windows;
    return s;
}

// Widths of a stacked bar's segments within `width` px. A segment with a value above zero
// is never drawn narrower than `minPx`, so 9 checked hours beside 3,100 waiting stay visible;
// the room it needs is taken from the segments that can spare it, in proportion, so the
// widths still add up to exactly `width`. A zero draws nothing. All zeros, or a negative or
// non-finite value, draws no bar at all: an empty vector.
inline QVector<double> barWidths(const QVector<double> &values, double width, double minPx)
{
    QVector<double> w(values.size(), 0.0);
    double total = 0;
    int nonZero = 0;
    for (double v : values) {
        if (!(v >= 0) || v != v || v > 1e300)
            return {};
        total += v;
        if (v > 0) ++nonZero;
    }
    if (total <= 0 || width <= 0)
        return {};
    if (nonZero * minPx >= width) {                 // too narrow to honour the floor: share it
        for (int i = 0; i < values.size(); ++i)
            w[i] = values[i] > 0 ? width / nonZero : 0.0;
        return w;
    }
    for (int i = 0; i < values.size(); ++i)
        w[i] = width * values[i] / total;
    // Raise every small segment to the floor, then take the difference from the segments
    // above the floor. Repeat: taking can push another one under it (a handful of rounds).
    for (int round = 0; round < values.size() + 1; ++round) {
        double deficit = 0, spare = 0;
        for (int i = 0; i < w.size(); ++i) {
            if (values[i] > 0 && w[i] < minPx) { deficit += minPx - w[i]; w[i] = minPx; }
        }
        if (deficit <= 1e-9)
            break;
        for (int i = 0; i < w.size(); ++i)
            if (values[i] > 0 && w[i] > minPx) spare += w[i] - minPx;
        for (int i = 0; i < w.size(); ++i)
            if (values[i] > 0 && w[i] > minPx) w[i] -= deficit * (w[i] - minPx) / spare;
    }
    return w;
}

// barWidths for QML: the segments as the screen has them, where an ABSENT segment (the
// server did not count it) means no bar at all -- never a bar drawn as if it were 0.
inline QVariantList barWidthsVariant(const QVariantList &values, double width, double minPx)
{
    QVector<double> v;
    v.reserve(values.size());
    for (const QVariant &x : values) {
        bool ok = false;
        const double d = x.toDouble(&ok);
        if (!x.isValid() || x.isNull() || !ok)
            return {};
        v.append(d);
    }
    QVariantList out;
    for (double w : barWidths(v, width, minPx))
        out.append(w);
    return out;
}

}   // namespace wtlabs
