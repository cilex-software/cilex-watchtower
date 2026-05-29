#include "CameraStore.h"

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
    // Per-operator prefs keyed by the backend camera_id: display-name override +
    // favorite. Camera identity + stream URLs come from cilex-vision /streams.
    const bool ok = q.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS prefs ("
        "  camera_id TEXT PRIMARY KEY, display_name TEXT, favorite INTEGER DEFAULT 0)"));
    if (!ok)
        qWarning() << "CameraStore: schema error -" << q.lastError().text();
    return ok;
}

QHash<QString, QPair<QString, bool>> CameraStore::prefs() const
{
    QHash<QString, QPair<QString, bool>> out;
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.exec(QStringLiteral("SELECT camera_id, display_name, favorite FROM prefs"));
    while (q.next())
        out.insert(q.value(0).toString(),
                   qMakePair(q.value(1).toString(), q.value(2).toInt() != 0));
    return out;
}

void CameraStore::setDisplayName(const QString &cameraId, const QString &name)
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.prepare(QStringLiteral(
        "INSERT INTO prefs (camera_id, display_name, favorite) VALUES (:id,:n,0)"
        " ON CONFLICT(camera_id) DO UPDATE SET display_name=excluded.display_name"));
    q.bindValue(QStringLiteral(":id"), cameraId);
    q.bindValue(QStringLiteral(":n"), name);
    q.exec();
}

void CameraStore::setFavoritePref(const QString &cameraId, bool favorite)
{
    QSqlDatabase db = QSqlDatabase::database(m_conn);
    QSqlQuery q(db);
    q.prepare(QStringLiteral(
        "INSERT INTO prefs (camera_id, display_name, favorite) VALUES (:id,'',:f)"
        " ON CONFLICT(camera_id) DO UPDATE SET favorite=excluded.favorite"));
    q.bindValue(QStringLiteral(":id"), cameraId);
    q.bindValue(QStringLiteral(":f"), favorite ? 1 : 0);
    q.exec();
}
