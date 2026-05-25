#include "CameraStore.h"

#include "CameraStatus.h"
#include "ProvisioningImport.h"

#include <QDebug>
#include <QDir>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>

CameraStore::CameraStore(QObject *parent)
    : QObject(parent)
{
    m_conn = QStringLiteral("watchtower_store_%1").arg(reinterpret_cast<quintptr>(this));
}

CameraStore::~CameraStore()
{
    {
        QSqlDatabase db = QSqlDatabase::database(m_conn, false);
        if (db.isOpen())
            db.close();
    }
    QSqlDatabase::removeDatabase(m_conn);
}

bool CameraStore::open()
{
    QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (dir.isEmpty())
        dir = QDir::homePath() + QStringLiteral("/.local/share/Watchtower");
    QDir().mkpath(dir);
    const QString path = dir + QStringLiteral("/watchtower.db");

    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_conn);
    db.setDatabaseName(path);
    if (!db.open()) {
        qWarning() << "CameraStore: cannot open" << path << "-" << db.lastError().text();
        return false;
    }
    return ensureSchema();
}

bool CameraStore::ensureSchema()
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    bool ok = q.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS cameras ("
        "  mac TEXT PRIMARY KEY, ip TEXT, model TEXT, vendor TEXT, firmware TEXT, serial TEXT,"
        "  rtsp_url TEXT, rtsp_sub_url TEXT,"
        "  name TEXT, group_id TEXT, favorite INTEGER DEFAULT 0,"
        "  live INTEGER, recording INTEGER, sort_order INTEGER)"));
    ok = ok && q.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS groups ("
        "  id TEXT PRIMARY KEY, name TEXT, parent_id TEXT, sort_order INTEGER)"));
    if (!ok)
        qWarning() << "CameraStore: schema error -" << q.lastError().text();
    return ok;
}

bool CameraStore::isEmpty() const
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(QStringLiteral("SELECT COUNT(*) FROM cameras"), db);
    if (q.next())
        return q.value(0).toInt() == 0;
    return true;
}

QVector<wt::CameraData> CameraStore::cameras() const
{
    QVector<wt::CameraData> out;
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.exec(QStringLiteral(
        "SELECT c.mac, c.ip, c.model, c.vendor, c.firmware, c.serial, c.rtsp_url, c.rtsp_sub_url,"
        "       c.name, c.group_id, c.favorite, c.live, c.recording, g.name "
        "FROM cameras c LEFT JOIN groups g ON c.group_id = g.id "
        "ORDER BY c.sort_order, c.ip"));
    while (q.next()) {
        wt::CameraData c;
        c.mac = q.value(0).toString();
        c.ip = q.value(1).toString();
        c.id = c.ip;                       // tile code = IP
        c.model = q.value(2).toString();
        c.vendor = q.value(3).toString();
        c.firmware = q.value(4).toString();
        c.serial = q.value(5).toString();
        c.rtspUrl = q.value(6).toString();
        c.rtspSubUrl = q.value(7).toString();
        c.name = q.value(8).toString();
        c.groupId = q.value(9).toString();
        c.favorite = q.value(10).toInt() != 0;
        c.live = q.value(11).toInt();
        c.recording = q.value(12).toInt();
        c.groupName = q.value(13).toString();
        out.push_back(c);
    }
    return out;
}

QVector<wt::GroupData> CameraStore::groups() const
{
    QVector<wt::GroupData> out;
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.exec(QStringLiteral("SELECT id, name, parent_id FROM groups ORDER BY sort_order, name"));
    while (q.next()) {
        wt::GroupData g;
        g.id = q.value(0).toString();
        g.name = q.value(1).toString();
        g.parentId = q.value(2).toString();
        out.push_back(g);
    }
    return out;
}

int CameraStore::importProvisioning(const QString &path, QString *error)
{
    const wt::ProvisioningResult res = wt::importProvisioning(path);
    if (!res.ok) {
        if (error)
            *error = res.error;
        return -1;
    }

    QSqlDatabase db = QSqlDatabase::database(m_conn);
    db.transaction();

    int order = 0;
    {
        QSqlQuery m(QStringLiteral("SELECT COALESCE(MAX(sort_order), -1) FROM cameras"), db);
        if (m.next())
            order = m.value(0).toInt() + 1;
    }

    for (const wt::CameraData &c : res.cameras) {
        if (c.mac.isEmpty())
            continue;
        QSqlQuery q(db);
        // Device fields refresh on conflict; name/group_id/favorite are NOT touched
        // (preserve the operator's edits across re-imports).
        q.prepare(QStringLiteral(
            "INSERT INTO cameras (mac, ip, model, vendor, firmware, serial, rtsp_url, rtsp_sub_url,"
            "  name, group_id, favorite, live, recording, sort_order)"
            " VALUES (:mac,:ip,:model,:vendor,:fw,:serial,:rtsp,:sub,:name,:gid,0,:live,:rec,:ord)"
            " ON CONFLICT(mac) DO UPDATE SET ip=excluded.ip, model=excluded.model,"
            "  vendor=excluded.vendor, firmware=excluded.firmware, serial=excluded.serial,"
            "  rtsp_url=excluded.rtsp_url, rtsp_sub_url=excluded.rtsp_sub_url,"
            "  live=excluded.live, recording=excluded.recording"));
        q.bindValue(QStringLiteral(":mac"), c.mac);
        q.bindValue(QStringLiteral(":ip"), c.ip);
        q.bindValue(QStringLiteral(":model"), c.model);
        q.bindValue(QStringLiteral(":vendor"), c.vendor);
        q.bindValue(QStringLiteral(":fw"), c.firmware);
        q.bindValue(QStringLiteral(":serial"), c.serial);
        q.bindValue(QStringLiteral(":rtsp"), c.rtspUrl);
        q.bindValue(QStringLiteral(":sub"), c.rtspSubUrl);
        q.bindValue(QStringLiteral(":name"), c.name);   // INSERT-only default (derived)
        q.bindValue(QStringLiteral(":gid"), c.groupId);
        q.bindValue(QStringLiteral(":live"), c.live);
        q.bindValue(QStringLiteral(":rec"), c.recording);
        q.bindValue(QStringLiteral(":ord"), order++);
        if (!q.exec())
            qWarning() << "CameraStore: upsert" << c.mac << "-" << q.lastError().text();
    }

    // Ensure the import's group exists so its name resolves.
    if (!res.cameras.isEmpty()) {
        QSqlQuery gq(db);
        gq.prepare(QStringLiteral(
            "INSERT INTO groups (id, name, parent_id, sort_order) VALUES (:id,:name,'',0)"
            " ON CONFLICT(id) DO NOTHING"));
        gq.bindValue(QStringLiteral(":id"), res.cameras.first().groupId);
        gq.bindValue(QStringLiteral(":name"), res.cameras.first().groupName);
        gq.exec();
    }

    db.commit();
    return int(res.cameras.size());
}

void CameraStore::setName(const QString &mac, const QString &name)
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.prepare(QStringLiteral("UPDATE cameras SET name=:n WHERE mac=:m"));
    q.bindValue(QStringLiteral(":n"), name);
    q.bindValue(QStringLiteral(":m"), mac);
    q.exec();
}

void CameraStore::setGroup(const QString &mac, const QString &groupId)
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.prepare(QStringLiteral("UPDATE cameras SET group_id=:g WHERE mac=:m"));
    q.bindValue(QStringLiteral(":g"), groupId);
    q.bindValue(QStringLiteral(":m"), mac);
    q.exec();
}

void CameraStore::setFavorite(const QString &mac, bool favorite)
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.prepare(QStringLiteral("UPDATE cameras SET favorite=:f WHERE mac=:m"));
    q.bindValue(QStringLiteral(":f"), favorite ? 1 : 0);
    q.bindValue(QStringLiteral(":m"), mac);
    q.exec();
}

void CameraStore::upsertGroup(const wt::GroupData &group)
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.prepare(QStringLiteral(
        "INSERT INTO groups (id, name, parent_id, sort_order) VALUES (:id,:name,:pid,:ord)"
        " ON CONFLICT(id) DO UPDATE SET name=excluded.name, parent_id=excluded.parent_id"));
    q.bindValue(QStringLiteral(":id"), group.id);
    q.bindValue(QStringLiteral(":name"), group.name);
    q.bindValue(QStringLiteral(":pid"), group.parentId);
    q.bindValue(QStringLiteral(":ord"), group.count);   // reuse as sort hint
    q.exec();
}

void CameraStore::removeGroup(const QString &id)
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.prepare(QStringLiteral("DELETE FROM groups WHERE id=:id"));
    q.bindValue(QStringLiteral(":id"), id);
    q.exec();
    // Cameras in the removed group fall back to ungrouped.
    QSqlQuery c(db);
    c.prepare(QStringLiteral("UPDATE cameras SET group_id='' WHERE group_id=:id"));
    c.bindValue(QStringLiteral(":id"), id);
    c.exec();
}
