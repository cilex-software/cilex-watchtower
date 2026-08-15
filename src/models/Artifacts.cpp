#include "Artifacts.h"
#include "AuthController.h"

#include <QPainter>
#include <QFontMetrics>

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>
#include <QUrlQuery>

Artifacts::Artifacts(QObject *parent)
    : QObject(parent)
{
}

QString Artifacts::defaultSnapshotDir() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
    if (base.isEmpty())
        base = QDir::homePath();
    return base + QStringLiteral("/Watchtower");
}

QString Artifacts::snapshotDir() const
{
    QString dir = m_settings.value(QStringLiteral("snapshots/dir")).toString();
    if (dir.isEmpty())
        dir = defaultSnapshotDir();
    QDir().mkpath(dir);
    return dir;
}

void Artifacts::setSnapshotDir(const QString &dir)
{
    QString d = dir;
    if (d.startsWith(QLatin1String("file:")))   // from the QML FolderDialog
        d = QUrl(d).toLocalFile();
    if (d == m_settings.value(QStringLiteral("snapshots/dir")).toString())
        return;
    m_settings.setValue(QStringLiteral("snapshots/dir"), d);
    if (!d.isEmpty())
        QDir().mkpath(d);
    emit snapshotDirChanged();
}

QString Artifacts::newSnapshotPath(const QString &camId) const
{
    QString safeId = camId;
    safeId.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    const QString stamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
    return snapshotDir() + QStringLiteral("/%1_%2.png").arg(safeId, stamp);
}

QString Artifacts::saveImageWithTimestamp(const QVariant &grabbedImage,
                                          const QString &camId,
                                          const QString &stampText)
{
    QImage img = grabbedImage.value<QImage>();
    if (img.isNull() || stampText.isEmpty())
        return QString();
    if (img.format() != QImage::Format_RGB32 && img.format() != QImage::Format_ARGB32)
        img = img.convertToFormat(QImage::Format_RGB32);

    QPainter pt(&img);
    pt.setRenderHint(QPainter::Antialiasing);
    pt.setRenderHint(QPainter::TextAntialiasing);
    QFont f(QStringLiteral("monospace"));
    f.setStyleHint(QFont::Monospace);
    f.setPixelSize(qMax(14, img.width() / 72));
    pt.setFont(f);
    const QFontMetrics fm(f);
    const int padX = fm.height() / 2, padY = fm.height() / 4;
    const QRect text = fm.boundingRect(stampText);
    const int barW = text.width() + 2 * padX;
    const int barH = fm.height() + 2 * padY;
    const int margin = fm.height() / 2;
    const QRect bar(img.width() - barW - margin, img.height() - barH - margin, barW, barH);
    pt.fillRect(bar, QColor(0, 0, 0, 190));
    pt.setPen(QColor(255, 255, 255));
    pt.drawText(bar.adjusted(padX, 0, -padX, 0), Qt::AlignVCenter | Qt::AlignLeft, stampText);
    pt.end();

    const QString path = newSnapshotPath(camId);
    return img.save(path) ? path : QString();
}

QString Artifacts::defaultExportDir() const
{
    QString base = QStandardPaths::writableLocation(QStandardPaths::MoviesLocation);
    if (base.isEmpty())
        base = QDir::homePath();
    return base + QStringLiteral("/Watchtower");
}

QString Artifacts::exportDir() const
{
    QString dir = m_settings.value(QStringLiteral("exports/dir")).toString();
    if (dir.isEmpty())
        dir = defaultExportDir();
    QDir().mkpath(dir);
    return dir;
}

void Artifacts::setExportDir(const QString &dir)
{
    QString d = dir;
    if (d.startsWith(QLatin1String("file:")))   // from the QML FolderDialog
        d = QUrl(d).toLocalFile();
    if (d == m_settings.value(QStringLiteral("exports/dir")).toString())
        return;
    m_settings.setValue(QStringLiteral("exports/dir"), d);
    if (!d.isEmpty())
        QDir().mkpath(d);
    emit exportDirChanged();
}

QString Artifacts::newExportPath(const QString &camId, const QString &ext) const
{
    QString safeId = camId;
    safeId.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    if (safeId.isEmpty())
        safeId = QStringLiteral("clip");
    const QString stamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
    return exportDir() + QStringLiteral("/%1_%2.%3").arg(safeId, stamp, ext);
}

void Artifacts::captureMainStreamSnapshot(const QString &camId, const QString &camName,
                                          const QString &mainRtspUrl)
{
    // Was: http://<host>:1984/api/frame.jpeg?src=<stream>, go2rtc's own HTTP API,
    // with a hard-coded port and no authentication — carrying the TODO that asked
    // for exactly the endpoint we now use. **:1984 was CLOSED on 2026-08-15** (CV
    // deleted the publish; every producer URL on that port carried a camera
    // password). Verified refused on both LAN and tailnet, so this path was dead,
    // not deprecated.
    //
    // The replacement is query-api's cached camera snapshot, authenticated with the
    // session cookie like every other backend call. Measured 2026-08-16: 1280×720
    // JPEG — the same width go2rtc's transcode produces, so an operator's saved
    // snapshot loses no resolution in the move.
    //
    // mainRtspUrl is no longer needed to build the URL. It is still accepted and
    // validated, because it is the caller's proof that this camera HAS a main
    // stream — capturing a still for a camera with no stream should fail, not
    // silently save a substream frame.
    Q_UNUSED(mainRtspUrl);
    auto *auth = AuthController::instance();
    if (!auth || auth->baseUrl().isEmpty()) {
        emit snapshotCaptureFailed(camId, camName, QStringLiteral("not signed in"));
        return;
    }
    const QUrl rtsp(mainRtspUrl);
    if (rtsp.scheme() != QLatin1String("rtsp") || rtsp.host().isEmpty() || rtsp.path().size() <= 1) {
        emit snapshotCaptureFailed(camId, camName, QStringLiteral("invalid rtsp url"));
        return;
    }

    QString safeCam = camId;
    safeCam.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    const QUrl httpUrl(auth->baseUrl() + QStringLiteral("/streams/cameras/")
                       + safeCam + QStringLiteral("/snapshot"));

    if (!m_nam)
        m_nam = new QNetworkAccessManager(this);

    QNetworkRequest req(httpUrl);
    // Private NAM, so the login cookie never lands in this jar — attach it per
    // request, the same contract CvImageProvider uses.
    req.setRawHeader("Cookie", "access_token=" + auth->token().toUtf8());
    // First pull can take 1–3s on a cache miss (the backend fills from the stream
    // behind its own semaphore). Be patient.
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, camId, camName]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            emit snapshotCaptureFailed(camId, camName, reply->errorString());
            return;
        }
        const QByteArray data = reply->readAll();
        if (data.size() < 1024) {   // sanity: a real keyframe JPEG is much larger
            emit snapshotCaptureFailed(camId, camName, QStringLiteral("empty snapshot response"));
            return;
        }
        // Save as .jpg (the data is JPEG, not PNG — newSnapshotPath defaults to
        // PNG so we swap the suffix here without touching that helper).
        QString path = newSnapshotPath(camId);
        if (path.endsWith(QStringLiteral(".png"), Qt::CaseInsensitive))
            path.chop(4), path.append(QStringLiteral(".jpg"));
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly) || f.write(data) != data.size()) {
            emit snapshotCaptureFailed(camId, camName, QStringLiteral("file write failed"));
            return;
        }
        f.close();
        emit snapshotCaptured(path, camId, camName);
    });
}
