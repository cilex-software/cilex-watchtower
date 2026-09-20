#pragma once
#include <QByteArray>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileDevice>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSysInfo>
#include <QUrl>

#include "ServerMessage.h"

// Self-provisioning a station, so that no human ever handles a station token.
//
// THE PROBLEM THIS REMOVES. A station only appears on the fleet/health page once a row
// exists in CV's `client_stations`, and that row has only ever come from a secret somebody
// carried to the box: either an admin minting a per-station token in the console and pasting
// it into warden.conf, or the shared bootstrap secret baked in when the installer was CUT and
// delivered out-of-band. The second was a CI step. CI Windows builds have been off since
// 2026-08-16 and installers now come from build-local.ps1, which has no such step — so every
// locally built installer since then produces a station with STATION_TOKEN empty, invisible
// to the fleet, exactly as WT-OFFICE-01 was found to be on 2026-09-19.
//
// THE OBSERVATION THAT FIXES IT. `POST /client/stations` (CV client_reports.py:1403)
// authenticates with the OPERATOR'S ORDINARY COOKIE SESSION — `Depends(get_current_user)` —
// and mints the token server-side, returning it once. It needs no station token to call. So
// an admin who has signed in to Watchtower has already proved everything CV requires; the
// app can provision its own station and write the credential itself. The token does not stop
// existing, but it stops being something a person mints, copies, carries or pastes.
//
// WHAT THIS DELIBERATELY DOES NOT DO, and why. It does not try to make the station row from
// the authenticated session alone, without a credential. CV measured that
// `machine_key` is `machine_id_hash or "host:<host>"` and registration upserts
// ON CONFLICT (machine_key) — and the booth's real provisioned row is keyed
// `host:wt-sm-vnutri-01` in production. A session asserting a hostname would therefore
// UPSERT ONTO an existing station's row and refresh its facts, letting any signed-in user
// make a dead station look alive. That is the dead-man defeated by the mechanism meant to
// replace it. This path uses the provisioning endpoint instead, which creates a real station
// identity, so Warden keeps beating and `warden_up` keeps meaning what it means.
//
// GATED HARD, because creating a station row is a write on a live fleet:
//   * only under Warden (WT_UNDER_WARDEN), so a developer's desktop never enrols;
//   * only when Warden reports it has NO token (WT_WARDEN_TOKEN=missing) — a station that
//     already has one is never re-minted, so this cannot rotate a working credential out
//     from under a beating Warden;
//   * only for an admin session — CV would 403 anything else, and we do not ask;
//   * once per process;
//   * WT_NO_STATION_ENROL=1 disables it outright.
// The token is written with owner-only permissions and NEVER logged, printed, or put in a
// crash bundle.
namespace wt {

// Same file Warden reads last, so this wins over a machine-wide /etc conf
// (warden.py load_config tries /etc first, then this, and later assignments win).
inline QString wardenConfPath()
{
    return QDir::homePath() + QStringLiteral("/.config/watchtower-warden/warden.conf");
}

// Replace the STATION_TOKEN= line in place, preserving every other line and comment, and
// leave the file owner-only. Returns false with a reason the caller can log.
inline bool writeStationToken(const QString &token, QString *why)
{
    const QString path = wardenConfPath();
    QDir().mkpath(QFileInfo(path).absolutePath());

    QStringList lines;
    QFile in(path);
    if (in.open(QIODevice::ReadOnly | QIODevice::Text))
        lines = QString::fromUtf8(in.readAll()).split(QLatin1Char('\n'));
    in.close();

    bool replaced = false;
    for (QString &line : lines) {
        if (line.trimmed().startsWith(QLatin1String("STATION_TOKEN="))) {
            line = QStringLiteral("STATION_TOKEN=") + token;
            replaced = true;
            break;                       // only the first; Warden takes the last assignment
        }
    }
    if (!replaced)
        lines << QStringLiteral("STATION_TOKEN=") + token;

    QFile out(path);
    if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        if (why) *why = out.errorString();
        return false;
    }
    out.write(lines.join(QLatin1Char('\n')).toUtf8());
    out.close();
    // A live ingest credential on disk: owner-only, explicitly, never left to the umask.
    // Same rule AuthController::persist() applies to the session token (audit 2026-09-03).
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    return true;
}

// Can the supervising Warden pick up a token written underneath it, without a restart?
// refresh_station_token() landed in 1.4.4. Unknown or older versions cannot, and an
// enrolment against one of those is a success that changes nothing until a restart.
inline bool wardenRereadsToken()
{
    const QList<QByteArray> got = qgetenv("WT_WARDEN_VERSION").split('.');
    const int need[3] = {1, 4, 4};
    for (int i = 0; i < 3; ++i) {
        const int have = i < got.size() ? got.at(i).toInt() : 0;
        if (have != need[i])
            return have > need[i];
    }
    return true;
}

inline bool enrolmentWanted()
{
    if (qEnvironmentVariableIsSet("WT_NO_STATION_ENROL"))
        return false;
    if (!qEnvironmentVariableIsSet("WT_UNDER_WARDEN"))
        return false;                    // unsupervised: nothing would use the token
    return qgetenv("WT_WARDEN_TOKEN") == QByteArrayLiteral("missing");
}

// Mint this machine a station identity using the session the operator already has.
// `report` receives one human line on every outcome — success included — and never the token.
template <typename F>
inline void enrolStation(QNetworkAccessManager *nam, const QString &baseUrl,
                         const QString &role, F report)
{
    // `attempted` latches ONLY once a POST goes out, so one enrolment per process.
    // `explained` is separate, so a "why not" line is said once without ever blocking a
    // later attempt. Those were one flag until 2026-09-21 and it was a real defect:
    //
    //   the office wall signs in as `office`, a VIEWER. On start it restores that session,
    //   the non-admin branch below fired, set the single flag and reported "sign in as an
    //   administrator". The owner then DID sign in as an admin — in the same process — and
    //   the very first line returned silently on that flag. Admin session, Warden 1.4.4,
    //   correct address, no token, and no second message to explain it. He was told for
    //   hours to do the one thing he had already done.
    //
    // A role gate that latches turns "not yet" into "never" for the whole run.
    static bool attempted = false;
    static bool explained = false;
    if (attempted || !nam || baseUrl.isEmpty())
        return;

    if (!enrolmentWanted()) {
        // The silent early return was the other half of the same defect: four branches
        // that reported nothing, so "never ran" and "ran and worked" looked identical from
        // outside. Say why, once — except when the station simply already has a token,
        // which is the healthy case and deserves no line at all.
        if (!explained && !qEnvironmentVariableIsSet("WT_NO_STATION_ENROL")) {
            if (!qEnvironmentVariableIsSet("WT_UNDER_WARDEN")) {
                explained = true;
                report(QStringLiteral("not running under Warden — nothing here would use a "
                                      "station token, so enrolment is skipped"));
            } else if (qgetenv("WT_WARDEN_TOKEN") != QByteArrayLiteral("set")) {
                explained = true;
                report(QStringLiteral("Warden did not say whether this station has a token "
                                      "— an older supervisor. Enrolment skipped; Warden "
                                      "1.4.4 or later reports it."));
            }
        }
        return;
    }

    const QString r = role.toLower();
    if (r != QLatin1String("admin") && r != QLatin1String("el_padrino")) {
        // Says why, once — and does NOT latch. Signing in as an admin afterwards, in this
        // same process, must still enrol.
        if (!explained) {
            explained = true;
            report(QStringLiteral("station has no token and this session is '%1' — only an "
                                  "administrator can provision one. Sign in as an admin on "
                                  "this machine and it will enrol itself.").arg(role));
        }
        return;
    }
    attempted = true;

    const QString host = QSysInfo::machineHostName();
    if (host.isEmpty()) {
        report(QStringLiteral("cannot enrol: this machine reports no hostname"));
        return;
    }
    QJsonObject body{
        {QStringLiteral("host"), host},
        {QStringLiteral("note"), QStringLiteral("self-provisioned by Watchtower on %1")
                                     .arg(QDateTime::currentDateTimeUtc().toString(Qt::ISODate))},
    };
    QNetworkRequest req{QUrl(baseUrl + QStringLiteral("/client/stations"))};
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(15000);
    QNetworkReply *reply = nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    QObject::connect(reply, &QNetworkReply::finished, nam, [reply, host, report]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        if (code != 201) {
            const QString why = wt::serverMessage(raw);
            report(QStringLiteral("station enrolment refused (HTTP %1)%2")
                       .arg(code).arg(why.isEmpty() ? QString() : QStringLiteral(": ") + why));
            return;
        }
        const QString token =
            QJsonDocument::fromJson(raw).object().value(QStringLiteral("token")).toString();
        if (token.isEmpty()) {
            report(QStringLiteral("station enrolment returned no token — nothing written"));
            return;
        }
        QString why;
        if (!writeStationToken(token, &why)) {
            report(QStringLiteral("station minted but warden.conf could not be written (%1) "
                                  "— the credential is LOST, mint again").arg(why));
            return;
        }
        // Warden only re-reads STATION_TOKEN in place from 1.4.4 (refresh_station_token).
        // An older supervisor will not notice the file changed, and — on Windows — will
        // never restart itself to find out: the scheduled task repeats every 30 minutes
        // with MultipleInstances IgnoreNew (warden/install-windows.ps1:134-139), so the
        // repeat is a no-op while one is already running. Enrolling against such a Warden
        // SUCCEEDS and changes nothing until the box is restarted, which is the silent
        // success this whole thread exists to stamp out. Say which of the two happened.
        if (wardenRereadsToken())
            report(QStringLiteral("station '%1' provisioned and written to %2 — Warden picks "
                                  "it up within a heartbeat; no token was handled by anyone")
                       .arg(host, wardenConfPath()));
        else
            report(QStringLiteral("station '%1' provisioned and written to %2, but Warden %3 "
                                  "cannot re-read it while running — RESTART WARDEN (or the "
                                  "machine) or this station stays invisible")
                       .arg(host, wardenConfPath(),
                            QString::fromUtf8(qgetenv("WT_WARDEN_VERSION")).isEmpty()
                                ? QStringLiteral("(version unknown)")
                                : QString::fromUtf8(qgetenv("WT_WARDEN_VERSION"))));
    });
}

}   // namespace wt
