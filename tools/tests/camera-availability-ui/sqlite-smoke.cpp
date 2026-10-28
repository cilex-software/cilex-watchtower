#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTextStream>
#include <QVariant>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

// Link/run with the selected installed or staged runtime; never touches app data.
int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QJsonObject result{{"passed", false}};
    const auto finish = [&](int code, const QString &error = QString()) {
        if (!error.isEmpty()) result.insert("error", error);
        QTextStream(stdout) << QJsonDocument(result).toJson(QJsonDocument::Compact) << Qt::endl;
        return code;
    };
    if (app.arguments().size() != 2) return finish(2, "Pass the absolute installed/staged runtime directory.");
    const QString runtime = QFileInfo(app.arguments().at(1)).canonicalFilePath();
    if (runtime.isEmpty() || !QFileInfo(runtime).isDir()) return finish(2, "Runtime directory not found.");
    QCoreApplication::setLibraryPaths({runtime});
    result.insert("runtime", runtime);
    result.insert("driverAvailable", QSqlDatabase::isDriverAvailable("QSQLITE"));
    if (!QSqlDatabase::isDriverAvailable("QSQLITE")) return finish(1, "Packaged QSQLITE driver unavailable.");
    QTemporaryDir directory;
    if (!directory.isValid()) return finish(1, "Temporary database directory unavailable.");
    const QString path = directory.filePath("availability-runtime.sqlite");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "availability-smoke-write");
        db.setDatabaseName(path);
        if (!db.open()) return finish(1, db.lastError().text());
        QSqlQuery query(db);
        if (!query.exec("PRAGMA journal_mode=WAL") || !query.exec("PRAGMA synchronous=FULL")
                || !db.transaction() || !query.exec("CREATE TABLE journal(value INTEGER NOT NULL)")
                || !query.exec("INSERT INTO journal VALUES(37)") || !db.commit())
            return finish(1, "SQLite durable commit failed: " + query.lastError().text());
        db.close();
    }
    QSqlDatabase::removeDatabase("availability-smoke-write");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "availability-smoke-read");
        db.setDatabaseName(path);
        if (!db.open()) return finish(1, "SQLite reopen failed.");
        QSqlQuery query(db);
        if (!query.exec("SELECT value FROM journal") || !query.next() || query.value(0).toInt() != 37)
            return finish(1, "Committed row missing after reopen.");
        db.close();
    }
    QSqlDatabase::removeDatabase("availability-smoke-read");
#ifdef Q_OS_WIN
    for (const auto &library : {L"Qt6Core.dll", L"Qt6Sql.dll", L"qsqlite.dll"}) {
        wchar_t buffer[32768] = {};
        if (!GetModuleFileNameW(GetModuleHandleW(library), buffer, 32768)) return finish(1, "Loaded library identity unavailable.");
        const QString loaded = QFileInfo(QString::fromWCharArray(buffer)).canonicalFilePath();
        const QString relative = QDir(runtime).relativeFilePath(loaded);
        if (relative.startsWith("../") || QDir::isAbsolutePath(relative))
            return finish(1, "Library loaded outside selected runtime.");
        result.insert(QString::fromWCharArray(library), loaded);
    }
#endif
    result.insert("openCommitReopen", true);
    result.insert("passed", true);
    return finish(0);
}
