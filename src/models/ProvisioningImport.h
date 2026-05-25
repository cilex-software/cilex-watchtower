#pragma once

#include <QString>
#include <QVector>
#include "Types.h"

// Imports cameras from a Cilex Vision Provisioner export
// (cilex-provisioning-*.json): a top-level object with a "cameras" array, each
// entry carrying rtsp_url, assigned_ip, mac, model, vendor, firmware, serial,
// and provisioning status. Names/groups are derived (the export has none).
namespace wt {

struct ProvisioningResult {
    QVector<CameraData> cameras;
    QString error;
    bool ok = false;
};

ProvisioningResult importProvisioning(const QString &path);

} // namespace wt
