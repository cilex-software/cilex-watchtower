#include "ProvisioningImport.h"

#include "CameraStatus.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>

using namespace wt;

ProvisioningResult wt::importProvisioning(const QString &path)
{
    ProvisioningResult result;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        result.error = QStringLiteral("Cannot open file: %1").arg(path);
        return result;
    }

    QJsonParseError parseError {};
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &parseError);
    if (doc.isNull() || !doc.isObject()) {
        result.error = QStringLiteral("Invalid provisioning JSON: %1").arg(parseError.errorString());
        return result;
    }

    const QJsonObject root = doc.object();
    const QString iface = root.value(QStringLiteral("provisioning_interface")).toString();
    const QJsonArray cameras = root.value(QStringLiteral("cameras")).toArray();

    int index = 0;
    for (const QJsonValue &value : cameras) {
        const QJsonObject c = value.toObject();

        CameraData cam;
        cam.ip = c.value(QStringLiteral("assigned_ip")).toString();
        cam.mac = c.value(QStringLiteral("mac")).toString();
        cam.model = c.value(QStringLiteral("model")).toString();
        cam.vendor = c.value(QStringLiteral("vendor")).toString();
        cam.firmware = c.value(QStringLiteral("firmware")).toString();
        cam.serial = c.value(QStringLiteral("serial")).toString();
        cam.rtspUrl = c.value(QStringLiteral("rtsp_url")).toString();

        // Derive id/name (the export has no friendly name). Use the IP's last
        // octet for a short, stable label.
        const QString make = c.value(QStringLiteral("make")).toString();
        const QString lastOctet = cam.ip.section(QLatin1Char('.'), -1);
        cam.id = cam.ip.isEmpty() ? QStringLiteral("cam-%1").arg(index + 1) : cam.ip;
        cam.name = lastOctet.isEmpty()
                       ? QStringLiteral("Camera %1").arg(index + 1)
                       : QStringLiteral("%1 %2").arg(make.isEmpty() ? QStringLiteral("Camera") : make, lastOctet);

        // The provisioning status reflects reachability/activation, not stream
        // health. Treat an active+activated camera as live (the tile's player
        // refines this at runtime); recording is unknown without an NVR.
        const bool active = c.value(QStringLiteral("status")).toString() == QLatin1String("active")
            && c.value(QStringLiteral("activation_status")).toBool();
        cam.live = active ? CameraStatus::Live : CameraStatus::Offline;
        cam.recording = CameraStatus::RecUnknown;

        cam.groupId = QStringLiteral("g-provisioned");
        cam.groupName = iface.isEmpty() ? QStringLiteral("Provisioned cameras")
                                        : QStringLiteral("Provisioned · %1").arg(iface);
        cam.pattern = index % 4;
        cam.hasAudio = false;
        cam.favorite = false;

        result.cameras.push_back(cam);
        ++index;
    }

    result.ok = true;
    return result;
}
