#pragma once
#include <QByteArray>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSysInfo>

// X-Watchtower-Station: <hostname> on EVERY request the wall makes.
//
// Agreed 2026-08-09/10 and never built; found missing on 2026-09-19 when a second
// machine had been watching the wall for days and the fleet could not name it
// (docs/letters/2026-09-19-a-wall-that-cannot-say-who-it-is.md). It is the only identity
// a RUNNING wall offers: CV deliberately refuses to attribute a session by peer IP,
// because the docker bridge rewrites every tailnet client to one gateway address — on
// 2026-08-09 that let a phone vouch for the booth's wall. CV joins this hint to an
// EXISTING station row and never creates one, so it names sessions; it does not replace
// the station token that makes the row exist in the first place.
//
// A QNetworkAccessManager subclass rather than 139 call sites: every request in src/
// is built ad hoc, and a header added by hand in 139 places is a header that goes
// missing in the 140th. createRequest() is the one funnel they all pass through.
// No Q_OBJECT: this adds no signals, slots or properties, so it needs no moc.
class StationNam : public QNetworkAccessManager
{
public:
    explicit StationNam(QObject *parent = nullptr) : QNetworkAccessManager(parent) {}

    // Cached: QSysInfo::machineHostName() hits the OS, and this runs on every request.
    static QByteArray stationName()
    {
        static const QByteArray name = QSysInfo::machineHostName().toUtf8();
        return name;
    }

protected:
    QNetworkReply *createRequest(Operation op, const QNetworkRequest &req,
                                 QIODevice *outgoingData) override
    {
        if (req.hasRawHeader("X-Watchtower-Station") || stationName().isEmpty())
            return QNetworkAccessManager::createRequest(op, req, outgoingData);
        QNetworkRequest tagged(req);
        tagged.setRawHeader("X-Watchtower-Station", stationName());
        return QNetworkAccessManager::createRequest(op, tagged, outgoingData);
    }
};
