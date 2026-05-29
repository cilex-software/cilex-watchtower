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
    // Groups are owned by cilex-vision (the /groups API) — no local groups table.
    // The cameras.group_id column is kept but vestigial (membership comes from
    // /streams at runtime).
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
        "SELECT mac, ip, model, vendor, firmware, serial, rtsp_url, rtsp_sub_url,"
        "       name, group_id, favorite, live, recording "
        "FROM cameras ORDER BY sort_order, ip"));
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
        c.groupId = q.value(9).toString();   // overridden by backend membership on load
        c.favorite = q.value(10).toInt() != 0;
        c.live = q.value(11).toInt();
        c.recording = q.value(12).toInt();
        out.push_back(c);
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

void CameraStore::setFavorite(const QString &mac, bool favorite)
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.prepare(QStringLiteral("UPDATE cameras SET favorite=:f WHERE mac=:m"));
    q.bindValue(QStringLiteral(":f"), favorite ? 1 : 0);
    q.bindValue(QStringLiteral(":m"), mac);
    q.exec();
}
