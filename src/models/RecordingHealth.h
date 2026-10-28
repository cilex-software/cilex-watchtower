#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStringList>
#include <QVariantMap>

// Wire v1 agreed for this change on 2026-10-28. Catalogue availability and
// recorder progress are independent; neither establishes durable media coverage.
namespace wt::recordingHealth {
inline qint64 instant(const QJsonValue &value)
{
    const QString text = value.toString();
    static const QRegularExpression zone(QStringLiteral("(?:Z|[+-]\\d{2}:\\d{2})$"));
    if (!zone.match(text).hasMatch()) return -1;
    const auto dt = QDateTime::fromString(text, Qt::ISODateWithMs);
    return dt.isValid() ? dt.toMSecsSinceEpoch() : -1;
}

inline bool fresh(const QJsonObject &wire, qint64 now)
{
    const qint64 observed = instant(wire.value(QStringLiteral("observed_at")));
    const qint64 until = instant(wire.value(QStringLiteral("valid_until")));
    // A materially future observation cannot certify local freshness. A small
    // clock-skew allowance is explicit, and never extends the supplied deadline.
    return observed > 0 && observed <= now + 30000 && until >= observed && until > now;
}

inline QString state(const QJsonObject &wire, const char *key, const QStringList &allowed)
{
    const QString value = wire.value(QLatin1String(key)).toString();
    return allowed.contains(value) ? value : QStringLiteral("unknown");
}

inline QVariantMap lane(const QJsonObject &wire, qint64 now)
{
    QVariantMap out = wire.toVariantMap();
    const bool current = fresh(wire, now);
    out[QStringLiteral("fresh")] = current;
    out[QStringLiteral("capture_state")] = current ? state(wire, "capture_state",
        {QStringLiteral("progressing"), QStringLiteral("stopped"), QStringLiteral("idle"),
         QStringLiteral("disabled"), QStringLiteral("unknown")}) : QStringLiteral("unknown");
    out[QStringLiteral("archive_state")] = current ? state(wire, "archive_state",
        {QStringLiteral("current"), QStringLiteral("delayed"), QStringLiteral("unavailable"),
         QStringLiteral("idle"), QStringLiteral("disabled"), QStringLiteral("unknown")}) : QStringLiteral("unknown");
    for (const QString &key : {QStringLiteral("last_available_end"), QStringLiteral("incident_started_at")}) {
        const auto value = instant(wire.value(key));
        if (value <= 0 || value > now + 30000) out[key] = QVariant();
    }
    const auto delay = wire.value(QStringLiteral("archive_delay_s"));
    if (!current || !delay.isDouble() || delay.toDouble() < 0)
        out[QStringLiteral("archive_delay_s")] = QVariant();
    return out;
}

inline QVariantMap normalize(const QJsonObject &wire, qint64 now)
{
    if (wire.value(QStringLiteral("version")).toInt() != 1)
        return {{QStringLiteral("version"), 0}, {QStringLiteral("fresh"), false},
                {QStringLiteral("capture_state"), QStringLiteral("unknown")},
                {QStringLiteral("archive_state"), QStringLiteral("unknown")}};
    QVariantMap out = lane(wire, now);
    const QJsonObject lanes = wire.value(QStringLiteral("streams")).toObject();
    QVariantMap normalized;
    bool required = false, uncertain = false;
    QStringList captures, archives;
    double largestDelay = -1;
    for (const QString &name : {QStringLiteral("main"), QStringLiteral("sub")}) {
        const auto source = lanes.value(name).toObject();
        const auto item = lane(source, now);
        normalized[name] = item;
        if (!source.value(QStringLiteral("expected")).isBool()) uncertain = true;
        if (!source.value(QStringLiteral("expected")).toBool()) continue;
        required = true;
        captures.append(item.value(QStringLiteral("capture_state")).toString());
        archives.append(item.value(QStringLiteral("archive_state")).toString());
        const auto delay = item.value(QStringLiteral("archive_delay_s"));
        if (!delay.isNull() && delay.toDouble() > largestDelay) largestDelay = delay.toDouble();
    }
    out[QStringLiteral("streams")] = normalized;
    // A failed required main lane cannot be masked by a healthy sub lane or an
    // optimistic aggregate. Unspecified required-lane membership stays unknown.
    if (out.value(QStringLiteral("fresh")).toBool() && required) {
        if (uncertain) { captures.append(QStringLiteral("unknown")); archives.append(QStringLiteral("unknown")); }
        const QStringList captureOrder {QStringLiteral("stopped"), QStringLiteral("unknown"),
            QStringLiteral("progressing"), QStringLiteral("idle"), QStringLiteral("disabled")};
        const QStringList archiveOrder {QStringLiteral("unavailable"), QStringLiteral("delayed"),
            QStringLiteral("unknown"), QStringLiteral("current"), QStringLiteral("idle"), QStringLiteral("disabled")};
        for (const auto &value : captureOrder)
            if (captures.contains(value)) { out[QStringLiteral("capture_state")] = value; break; }
        for (const auto &value : archiveOrder)
            if (archives.contains(value)) { out[QStringLiteral("archive_state")] = value; break; }
        if (largestDelay >= 0) out[QStringLiteral("archive_delay_s")] = largestDelay;
    } else if (!required && uncertain) {
        out[QStringLiteral("capture_state")] = QStringLiteral("unknown");
        out[QStringLiteral("archive_state")] = QStringLiteral("unknown");
    }
    return out;
}
}
