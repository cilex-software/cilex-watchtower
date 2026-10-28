#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QString>
#include <QVariantMap>

// Pure evidence rules shared with deterministic fixtures. These classify an
// observation, never the global physical condition of a camera.
namespace wt::availability {
constexpr qint64 liveConfirmationMs = 75000;
constexpr qint64 freshDecodedFrameMs = 5000;
constexpr qint64 observationGapMs = 25000;
constexpr qint64 freshSnapshotMs = 15000;

inline QString instant()
{
    return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
}

inline QVariantMap observation(const QString &camera, const QString &domain,
                               const QString &provenance, const QString &state,
                               const QString &transition, const QString &reason,
                               const QVariantMap &details = {})
{
    return {{QStringLiteral("camera_id"), camera.isEmpty() ? QVariant() : QVariant(camera)},
            {QStringLiteral("domain"), domain}, {QStringLiteral("provenance"), provenance},
            {QStringLiteral("state"), state}, {QStringLiteral("transition"), transition},
            {QStringLiteral("reason_code"), reason}, {QStringLiteral("observed_at"), instant()},
            {QStringLiteral("details"), details}};
}

inline QString reachability(const QString &status)
{
    if (status == QLatin1String("online")) return QStringLiteral("available");
    if (status == QLatin1String("offline")) return QStringLiteral("unavailable");
    if (status == QLatin1String("maintenance")) return QStringLiteral("not_monitored");
    if (status == QLatin1String("error")) return QStringLiteral("degraded");
    return QStringLiteral("unknown");
}

inline QString catalogue(const QString &recording, const QString &status, bool enabled)
{
    if (!enabled || status == QLatin1String("maintenance")
        || recording == QLatin1String("armed") || recording == QLatin1String("idle")
        || recording == QLatin1String("disabled")) return QStringLiteral("not_monitored");
    // Legacy capture vocabulary cannot certify archive coverage or loss.
    return QStringLiteral("unknown");
}

inline QString snapshot(int httpStatus, bool decoded, qint64 ageMs, const QString &source)
{
    if (httpStatus == 401 || httpStatus == 403 || httpStatus == 0 || httpStatus >= 500)
        return QStringLiteral("unknown");
    if (httpStatus != 200 || !decoded) return QStringLiteral("unavailable");
    if (ageMs < 0) return QStringLiteral("unknown");
    if (ageMs > freshSnapshotMs) return QStringLiteral("degraded");
    // A young recorded/cache fallback is not affirmative evidence of live delivery.
    if (source != QLatin1String("live")) return QStringLiteral("unknown");
    return QStringLiteral("available");
}

// The stamp must originate at the incoming/decoded sample boundary. A sink's
// cached frame, playing flag, frame PTS or unchanged pixels cannot satisfy this.
inline bool freshDecoded(qint64 arrivedAt, qint64 now)
{
    return arrivedAt >= 0 && now >= arrivedAt && now - arrivedAt <= freshDecodedFrameMs;
}
inline bool freshDecoded(qint64 arrivedAt, qint64 now, qint64 arrivedWall, qint64 nowWall)
{
    return freshDecoded(arrivedAt, now) && arrivedWall >= 0 && nowWall >= arrivedWall
        && nowWall - arrivedWall <= freshDecodedFrameMs;
}
inline bool schedulingGap(qint64 previousTick, qint64 now)
{
    return now < previousTick || now - previousTick > observationGapMs;
}
inline bool observationClockGap(qint64 previousTick, qint64 now,
                                qint64 previousWall, qint64 nowWall)
{
    if (schedulingGap(previousTick, now) || nowWall < previousWall) return true;
    // Some monotonic clocks stop while the computer sleeps. Wall time exposes
    // that missing interval; large clock corrections also conservatively gap.
    return qAbs((nowWall - previousWall) - (now - previousTick)) > observationGapMs;
}
inline bool confirmedMissingFrame(qint64 startedAt, qint64 lastPositive, qint64 now)
{
    const qint64 last = lastPositive >= 0 ? lastPositive : startedAt;
    return now >= last && now - last >= liveConfirmationMs;
}
}
