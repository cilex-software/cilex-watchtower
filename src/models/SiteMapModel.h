#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>
#include <QVariantList>
#include <QString>

class QNetworkAccessManager;

// Loads cilex-vision's Camera Maps for the Situation Map view: the full map
// list (GET /maps → id/name/status/updated_at), then the selected map's
// pre-signed background image + camera-pin placements (/maps/{id} →
// /maps/{id}/objects). Camera positions are normalized 0..1 (top-left origin).
// load() ALWAYS refetches — the 2026-08-06 staleness: the admin replaced the
// floor plan and the client kept rendering the deleted one because nothing
// ever asked again. An empty list CLEARS the state (a deleted map must not
// leave a ghost). Authenticated GETs go through the shared AuthController NAM.
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
    Q_PROPERTY(QVariantList mapsList READ mapsList NOTIFY changed)
    Q_PROPERTY(QString currentMapId READ currentMapId NOTIFY changed)

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
    QVariantList mapsList() const { return m_maps; }
    QString currentMapId() const { return m_currentId; }
    Q_INVOKABLE void load();
    Q_INVOKABLE void selectMap(const QString &mapId);

signals:
    void changed();

private:
    void fetchDetail(const QString &mapId);
    void fetchObjects(const QString &mapId);

    void clearPlan();
    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    bool m_ready = false;
    QString m_backgroundUrl;
    QString m_planName;
    int m_planWidth = 0;
    int m_planHeight = 0;
    QVariantList m_placements;
    QVariantList m_maps;
    QString m_currentId;
};
