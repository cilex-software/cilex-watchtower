#pragma once

#include <QSet>
#include <QStringList>

namespace wt {

// Empty strings are real cells. Repeated camera IDs become holes instead of
// shifting the remaining cells; a view may contain each camera at most once.
inline QStringList uniqueLiveCells(const QStringList &cells)
{
    QStringList result;
    QSet<QString> seen;
    result.reserve(cells.size());
    for (const auto &id : cells) {
        if (id.isEmpty() || seen.contains(id)) {
            result.append(QString());
        } else {
            seen.insert(id);
            result.append(id);
        }
    }
    return result;
}

} // namespace wt
