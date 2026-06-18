#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>
#include <QVariantList>
#include <QString>

class QNetworkAccessManager;

// Loads cilex-vision's active Camera Map for the Situation Map view: the active
// floor plan's pre-signed background image + the camera-pin placements
// (GET /maps?status=active → /maps/{id} → /maps/{id}/objects). Camera positions
// are normalized 0..1 (top-left origin). Authenticated GETs go through the shared
// AuthController NAM. See docs/letters/2026-06-18-events-redesign-unassign-and-placement*.
class SiteMapModel : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(QString backgroundUrl READ backgroundUrl NOTIFY changed)
    Q_PROPERTY(QString planName READ planName NOTIFY changed)
    Q_PROPERTY(int planWidth READ planWidth NOTIFY changed)
    Q_PROPERTY(int planHeight READ planHeight NOTIFY changed)
    Q_PROPERTY(int placedCount READ placedCount NOTIFY changed)

public:
    explicit SiteMapModel(QObject *parent = nullptr);

    bool ready() const { return m_ready; }
    QString backgroundUrl() const { return m_backgroundUrl; }
    QString planName() const { return m_planName; }
    int planWidth() const { return m_planWidth; }
    int planHeight() const { return m_planHeight; }
    int placedCount() const { return int(m_placements.size()); }

    // [{ cameraId, x, y, rotation, name }] per placed camera pin on the active plan.
    Q_INVOKABLE QVariantList placements() const { return m_placements; }
    Q_INVOKABLE void load();

signals:
    void changed();

private:
    void fetchDetail(const QString &mapId);
    void fetchObjects(const QString &mapId);

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    bool m_ready = false;
    QString m_backgroundUrl;
    QString m_planName;
    int m_planWidth = 0;
    int m_planHeight = 0;
    QVariantList m_placements;
};
