// Tests for self-provisioning a station (src/models/StationEnrolment.h).
//
// The network half is deliberately NOT exercised here: POST /client/stations creates a row
// in CV's live client_stations and mints a real credential, and this repo's rule is that
// writes to the shared pilot are announced before they are made. So what is tested is
// everything that decides WHETHER to call it, and everything that happens to the credential
// AFTERWARDS — the two halves where a mistake is silent and expensive:
//
//   * the gate, because a station that already has a token must never be re-minted (that
//     would rotate a working credential out from under a beating Warden), and an
//     unsupervised desktop must never enrol at all;
//   * the writer, because it edits a config file that is not ours alone and puts a live
//     ingest credential on disk.
//
// Build + run (Qt 6.12):
//   g++ -std=c++17 -fPIC -o /tmp/stenrol tools/tests/station-enrolment.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -I$QT/include/QtNetwork \
//       -L$QT/lib -lQt6Core -lQt6Network && LD_LIBRARY_PATH=$QT/lib /tmp/stenrol
#include "StationEnrolment.h"
#include <QCoreApplication>
#include <QDebug>
#include <QEventLoop>
#include <QNetworkAccessManager>
#include <QTemporaryDir>
#include <QTimer>
#include <algorithm>

int fails = 0;

static void ok(bool cond, const QString &what)
{
    if (!cond) ++fails;
    qInfo().noquote() << (cond ? "PASS" : "FAIL") << what;
}

// enrolmentWanted() reads the environment each call, so each case sets its own world.
static bool wanted(const char *underWarden, const char *token, bool optOut)
{
    qunsetenv("WT_UNDER_WARDEN"); qunsetenv("WT_WARDEN_TOKEN"); qunsetenv("WT_NO_STATION_ENROL");
    if (underWarden) qputenv("WT_UNDER_WARDEN", underWarden);
    if (token)       qputenv("WT_WARDEN_TOKEN", token);
    if (optOut)      qputenv("WT_NO_STATION_ENROL", "1");
    return wt::enrolmentWanted();
}

// THE REGRESSION THIS EXISTS FOR (2026-09-21). A viewer session must not lock out a later
// admin one. The office wall signs in as `office`, a VIEWER: on start it restored that
// session, the role gate fired, latched a single `tried` flag and reported "sign in as an
// administrator". The owner then DID — in the same process — and the first line of
// enrolStation returned on that flag, silently. Admin session, Warden 1.4.4, correct
// address, no token, no second message. Hours were spent telling him to do what he had
// already done.
//
// Needs a listener: run tools/tests/enrolstub.py on 127.0.0.1:8127 first, then
//   ./station-enrolment --seq http://127.0.0.1:8127
static int sequenceTest(QCoreApplication &app, const QString &base)
{
    qputenv("WT_UNDER_WARDEN", "1");
    qputenv("WT_WARDEN_TOKEN", "missing");
    qputenv("WT_WARDEN_VERSION", "1.4.4");
    qunsetenv("WT_NO_STATION_ENROL");
    QTemporaryDir home;
    qputenv("HOME", home.path().toUtf8());

    QNetworkAccessManager nam;
    QStringList said;
    auto say = [&said](const QString &line) { said << line; };

    wt::enrolStation(&nam, base, QStringLiteral("viewer"), say);
    ok(said.size() == 1 && said.first().contains(QStringLiteral("administrator")),
       "a viewer session says why, once");

    // ...and the admin sign-in that follows IN THE SAME PROCESS must still enrol.
    wt::enrolStation(&nam, base, QStringLiteral("admin"), say);
    QEventLoop loop;
    QTimer::singleShot(2500, &loop, &QEventLoop::quit);
    loop.exec();

    const bool enrolled = std::any_of(said.cbegin(), said.cend(), [](const QString &l) {
        return l.contains(QStringLiteral("provisioned"));
    });
    ok(enrolled, QStringLiteral("an ADMIN sign-in after a viewer one still enrols — said: %1")
                     .arg(said.join(QStringLiteral(" | "))));
    qInfo().noquote() << (fails ? QStringLiteral("%1 FAILED").arg(fails)
                                : QStringLiteral("all passed"));
    return fails ? 1 : 0;
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (argc >= 3 && QString::fromUtf8(argv[1]) == QLatin1String("--seq"))
        return sequenceTest(app, QString::fromUtf8(argv[2]));

    // ---- the gate
    ok(wanted("1", "missing", false) == true,
       "enrols: under Warden AND Warden reports no token");
    ok(wanted("1", "set", false) == false,
       "does NOT enrol when the station already has a token (never rotate a live one)");
    ok(wanted(nullptr, "missing", false) == false,
       "does NOT enrol when not under Warden (a developer desktop never provisions)");
    ok(wanted("1", "", false) == false,
       "does NOT enrol when Warden said nothing — unknown is not 'missing'");
    ok(wanted("1", nullptr, false) == false,
       "does NOT enrol against an older Warden that sends no WT_WARDEN_TOKEN at all");
    ok(wanted("1", "missing", true) == false,
       "WT_NO_STATION_ENROL=1 disables it outright");

    // ---- can the supervising Warden pick a token up in place? refresh_station_token
    //      landed in warden 1.4.4. Older ones succeed at enrolling and change NOTHING until
    //      a restart, which on Windows never happens by itself: the scheduled task repeats
    //      every 30 min with MultipleInstances IgnoreNew, a no-op while one is running.
    //      Getting this comparison wrong in either direction is a silent failure, so both
    //      directions are pinned.
    auto reread = [](const char *v) {
        if (v) qputenv("WT_WARDEN_VERSION", v); else qunsetenv("WT_WARDEN_VERSION");
        return wt::wardenRereadsToken();
    };
    ok(reread("1.4.4") == true,  "1.4.4 re-reads the token in place");
    ok(reread("1.4.5") == true,  "1.4.5 re-reads (later patch)");
    ok(reread("1.5.0") == true,  "1.5.0 re-reads (later minor)");
    ok(reread("2.0.0") == true,  "2.0.0 re-reads (later major)");
    ok(reread("1.4.3") == false, "1.4.3 does NOT — the version that shipped without it");
    ok(reread("1.4.2") == false, "1.4.2 does NOT — what wt-office-01 runs today");
    ok(reread("1.3.9") == false, "1.3.9 does NOT (earlier minor)");
    ok(reread("0.9.9") == false, "0.9.9 does NOT (earlier major)");
    ok(reread(nullptr) == false, "an unknown version is treated as CANNOT, never as can");
    ok(reread("") == false,      "an empty version is treated as CANNOT");

    // ---- the writer, against a throwaway HOME so no real warden.conf is touched
    QTemporaryDir home;
    ok(home.isValid(), "temp HOME created");
    qputenv("HOME", home.path().toUtf8());

    const QString conf = wt::wardenConfPath();
    ok(conf.startsWith(home.path()), "warden.conf path follows HOME: " + conf);

    // (a) no file yet -> creates one carrying the token
    QString why;
    ok(wt::writeStationToken("cvst_FIRST", &why), "writes when no conf exists: " + why);
    QFile f1(conf); f1.open(QIODevice::ReadOnly);
    ok(QString::fromUtf8(f1.readAll()).contains("STATION_TOKEN=cvst_FIRST"),
       "the token is in the file");
    f1.close();

    // (b) an existing conf keeps every other line, comments included, and the token is
    //     REPLACED rather than appended — a second STATION_TOKEN= line would mean Warden
    //     silently took the last one.
    QFile seed(conf);
    seed.open(QIODevice::WriteOnly | QIODevice::Truncate);
    seed.write("# a comment a human wrote\n"
               "BACKEND_URL=\n"
               "STATION_TOKEN=cvst_OLD\n"
               "APP_CMD=/home/x/run.sh\n");
    seed.close();
    ok(wt::writeStationToken("cvst_NEW", &why), "rewrites an existing conf: " + why);

    QFile f2(conf); f2.open(QIODevice::ReadOnly);
    const QString body = QString::fromUtf8(f2.readAll());
    f2.close();
    ok(body.contains("# a comment a human wrote"), "keeps the human's comment");
    ok(body.contains("APP_CMD=/home/x/run.sh"),   "keeps APP_CMD");
    ok(body.contains("BACKEND_URL="),             "keeps BACKEND_URL");
    ok(body.contains("STATION_TOKEN=cvst_NEW"),   "the new token is present");
    ok(!body.contains("cvst_OLD"),                "the old token is GONE, not shadowed");
    ok(body.count("STATION_TOKEN=") == 1,         "exactly one STATION_TOKEN line");

    // (c) a live ingest credential must not be world-readable
    const auto perms = QFile::permissions(conf);
    ok(perms.testFlag(QFileDevice::ReadOwner) && perms.testFlag(QFileDevice::WriteOwner),
       "owner can read and write it");
    ok(!perms.testFlag(QFileDevice::ReadGroup) && !perms.testFlag(QFileDevice::ReadOther),
       "group and other CANNOT read it");

    qInfo().noquote() << (fails ? QStringLiteral("%1 FAILED").arg(fails)
                                : QStringLiteral("all passed"));
    return fails ? 1 : 0;
}
