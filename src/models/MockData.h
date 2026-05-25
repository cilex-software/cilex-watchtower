#pragma once

#include <QVector>
#include "Types.h"

// Deterministic mock dataset mirroring the design prototype's shapes. Swappable
// for a real camera/NVR backend behind the same struct types.
namespace wt::mock {

QVector<GroupData> groups();
QVector<CameraData> cameras();   // ~137 cameras across the leaf groups
QVector<EventData> events();
QVector<SavedViewData> savedViews();

} // namespace wt::mock
