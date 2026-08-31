#include "PlaybackClient.h"

#include <QMutex>
#include <QColor>
#include <QImage>
#include "HlsProxy.h"
#include <QThread>
#include "AuthController.h"
#include "ClipTranscoder.h"

#include <QNetworkAccessManager>
#include <QNetworkCookie>
#include <QNetworkCookieJar>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QFile>
#include <QDateTime>
#include <QTimeZone>

// The operator's IANA timezone (e.g. "Europe/Moscow"). The coverage calendar
// buckets footage days with date(start_time AT TIME ZONE tz) on the backend, so
// we must send the operator's local tz or day-dots bucket in UTC and land on the
// wrong calendar day near midnight (pilot is UTC+3 — a 3h skew). Everything else
// in the UI already renders in system-local time, so the system tz is the
// operator's tz; fall back to UTC if the zone has no IANA id.
static QString operatorTz()
{
    const QByteArray id = QTimeZone::systemTimeZone().id();
    return id.isEmpty() ? QStringLiteral("UTC") : QString::fromUtf8(id);
}

// Running requests a NAM currently has open to `host` — how full its 6-connection
// per-host pool is when we dispatch a session POST ([PBTIME] diagnostics).
static int runningTo(QNetworkAccessManager *nam, const QString &host)
{
    int n = 0;
    const auto replies = nam->findChildren<QNetworkReply *>();
    for (auto *r : replies)
        if (r->isRunning() && r->url().host() == host)
            ++n;
    return n;
}

PlaybackClient::PlaybackClient(QObject *parent)
    : QObject(parent)
{
    auto *auth = AuthController::instance();
    // OWN QNetworkAccessManager — not the shared AuthController one. QNAM opens at
    // most 6 concurrent connections per host, and the shared NAM also carries the
    // event-thumbnail (CvImageProvider) + events/health traffic to the same backend;
    // a calendar day-open's session POST queued behind that storm for SECONDS
    // (measured 2026-07-02: inflight=12 → 2.3 s, inflight=6 → 0.5 s, inflight=0 →
    // 0.17 s, while the same POST via curl was always ~0.25 s — the "historic
    // playback is awfully slow" report). A private pool makes playback control calls
    // (sessions/coverage/timeline/exports) independent of thumbnail storms. The auth
    // cookie is mirrored from AuthController (same pattern as HlsProxy::setAuthToken).
    m_nam = new QNetworkAccessManager(this);
    m_baseUrl = auth->baseUrl();
    applyAuthCookie();

    // The HLS proxy runs on its OWN thread so it keeps serving the player's segment reads even while the GUI
    // thread is blocked — e.g. inside QMediaPlayer teardown on the wall↔Live transition, where a GUI-thread
    // proxy deadlocked (stop() waits for the demuxer, the demuxer waits for a segment, the proxy can't serve
    // it). It has its own NAM, so we hand it the upstream URL + the session token over queued calls.
    m_proxyThread = new QThread(this);
    m_proxyThread->setObjectName(QStringLiteral("hls-proxy"));
    m_proxy = new HlsProxy;                   // no parent — lives on m_proxyThread
    m_proxy->moveToThread(m_proxyThread);
    connect(m_proxyThread, &QThread::finished, m_proxy, &QObject::deleteLater);
    m_proxyThread->start();
    QMetaObject::invokeMethod(m_proxy, "init", Qt::BlockingQueuedConnection);   // NAM + listen, on the proxy thread
    QMetaObject::invokeMethod(m_proxy, "setUpstream", Qt::QueuedConnection, Q_ARG(QString, m_baseUrl));
    QMetaObject::invokeMethod(m_proxy, "setAuthToken", Qt::QueuedConnection, Q_ARG(QString, auth->token()));

    connect(auth, &AuthController::baseUrlChanged, this, [this, auth]() {
        m_baseUrl = auth->baseUrl();
        applyAuthCookie();
        QMetaObject::invokeMethod(m_proxy, "setUpstream", Qt::QueuedConnection, Q_ARG(QString, m_baseUrl));
        QMetaObject::invokeMethod(m_proxy, "setAuthToken", Qt::QueuedConnection, Q_ARG(QString, auth->token()));
    });
    // A silent refresh replaces the token without touching `authenticated` or
    // baseUrl — the two signals below. Without this connection our private NAM
    // and the proxy keep the pre-refresh cookie and every session open 401s.
    connect(auth, &AuthController::tokenChanged, this, [this, auth]() {
        applyAuthCookie();
        QMetaObject::invokeMethod(m_proxy, "setAuthToken", Qt::QueuedConnection, Q_ARG(QString, auth->token()));
    });
    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (auth->authenticated()) {          // (re)login — refresh our + the proxy's cookie
            applyAuthCookie();
            QMetaObject::invokeMethod(m_proxy, "setAuthToken", Qt::QueuedConnection, Q_ARG(QString, auth->token()));
        } else {                              // signed out — drop resolved state
            m_loggedIn = false;
            m_loggingIn = false;
            emit loggedInChanged();
        }
    });
}

PlaybackClient::~PlaybackClient()
{
    if (m_proxyThread) {
        m_proxyThread->quit();
        m_proxyThread->wait(3000);            // m_proxy is deleteLater'd on the thread's finished signal
    }
}

void PlaybackClient::setStatus(const QString &s)
{
    if (m_status == s)
        return;
    m_status = s;
    emit statusChanged();
}

// Mirror the backend session cookie into our private NAM's jar (the login itself
// happens on AuthController's NAM; ours never sees the Set-Cookie).
void PlaybackClient::setAuthFault(bool v, const QString &detail)
{
    if (m_authFault == v && m_authFaultDetail == detail)
        return;
    m_authFault = v;
    m_authFaultDetail = detail;
    if (v)
        qWarning().noquote() << "[WT-DEGRADED] subsystem=playback reason=auth state=FAULT detail="
                             << (detail.isEmpty() ? QStringLiteral("(none)") : detail);
    else
        qInfo().noquote() << "[WT-DEGRADED] subsystem=playback state=CLEARED";
    emit authFaultChanged();
}

void PlaybackClient::applyAuthCookie()
{
    const QString token = AuthController::instance()->token();
    if (token.isEmpty())
        return;
    QNetworkCookie cookie("access_token", token.toUtf8());
    m_nam->cookieJar()->setCookiesFromUrl({cookie}, QUrl(m_baseUrl));
}

void PlaybackClient::ensureReady()
{
    if (m_loggedIn || m_loggingIn)
        return;
    if (!AuthController::instance()->authenticated()) {
        setStatus(QStringLiteral("Not signed in"));
        return;
    }
    m_loggingIn = true;
    setStatus(QStringLiteral("Connecting to cilex-vision…"));
    fetchStreams();
}

void PlaybackClient::fetchStreams()
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/streams")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        m_loggingIn = false;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401) {
            AuthController::instance()->noteUnauthorized();
            setStatus(QStringLiteral("Not signed in"));
            return;
        }
        const auto arr = QJsonDocument::fromJson(reply->readAll())
                             .object().value("streams").toArray();
        m_ipToCamId.clear();
        m_macToCamId.clear();
        for (const auto &v : arr) {
            const auto o = v.toObject();
            const QString id = o.value("camera_id").toString();
            m_ipToCamId.insert(o.value("ip").toString(), id);
            // camera_id is "<slug>-<machex>"; index by the trailing hex too.
            const int dash = id.lastIndexOf('-');
            if (dash > 0)
                m_macToCamId.insert(id.mid(dash + 1), id);
        }
        m_loggedIn = true;                   // signed in + streams resolved = ready
        emit loggedInChanged();
        setStatus(QString());
        emit camerasResolved();
        flushPendingSessions();
    });
}

QString PlaybackClient::cameraIdForIp(const QString &ip) const
{
    return m_ipToCamId.value(ip);
}

QString PlaybackClient::cameraIdForMac(const QString &mac) const
{
    QString hex = mac.toLower();
    hex.remove(':').remove('-');
    if (m_macToCamId.contains(hex))
        return m_macToCamId.value(hex);
    return hex.isEmpty() ? QString() : QStringLiteral("hiwatch-") + hex;
}

void PlaybackClient::openSession(const QString &cameraId, const QString &wallStartIso,
                                 const QString &wallEndIso, bool hevcCapable,
                                 const QString &tag)
{
    m_sessionTag = tag;
    if (cameraId.isEmpty()) {
        emit sessionFailed("This camera is not known to the recording backend.", tag);
        return;
    }
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated()) {
            emit sessionFailed(QStringLiteral("Not signed in to the recording backend."), tag);
            return;
        }
        // queue: resolve streams, then retry once ready.
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraId, wallStartIso, wallEndIso, hevcCapable, tag]() {
                    openSession(cameraId, wallStartIso, wallEndIso, hevcCapable, tag);
                }, Qt::SingleShotConnection);
        return;
    }

    requestSession(cameraId, wallStartIso, wallEndIso, hevcCapable, 0, tag);
}

// `tag` is CAPTURED per request and stamped on this request's own emissions.
// It must NOT read m_sessionTag at reply time: two in-flight opens (a scrub
// re-open racing an earlier open or its retry) would stamp the OLDER session's
// reply with the NEWER tag — the stale session then passes every consumer's
// ownership filter, flips the player's source back, and lands the hero at the
// old window's start, paused (operator screenshots, 2026-08-06).
void PlaybackClient::requestSession(const QString &cameraId, const QString &wallStartIso,
                                    const QString &wallEndIso, bool hevcCapable, int attempt,
                                    const QString &tag)
{
#ifdef Q_OS_MACOS
    // Apple's HLS authoring rules do not allow HEVC in MPEG-TS (HEVC requires fMP4), and
    // review sessions serve HEVC-in-TS (measured 2026-08-17: hevc/Main/2560x1440 in seg .ts).
    // Three decode-level overrides changed nothing on the operator's M1 — the media stack
    // never surfaced a single frame. So declare the truth the contract's flag exists for:
    // this platform cannot play the HEVC variant; ask for H.264. Server-side verified the
    // same evening: hevc_capable=false returns h264/Main (640x360 transcode tier — a playing
    // 360p beats a 1440p poster; the quality-tier conversation belongs to CV, not this flag).
    hevcCapable = false;
#endif
    // [PBTIME] pairs with the QML open-path stage logs (see PlaybackScreen.qml).
    static const bool pbTime = qEnvironmentVariableIsSet("WT_TRACE")
                               || qEnvironmentVariableIsSet("WT_TTFF_DAYS");
    QElapsedTimer httpTimer;
    httpTimer.start();
    setStatus(attempt == 0 ? QStringLiteral("Opening session…") : QStringLiteral("Reconnecting…"));
    QNetworkRequest req{QUrl(m_baseUrl + "/review/sessions")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"camera_id", cameraId},
                     {"wall_start", wallStartIso},
                     {"wall_end", wallEndIso},
                     {"hevc_capable", hevcCapable}};
    // Ask 1 (Cilex Vision route B): request the continuous-timeline manifest so mid-session seeks land
    // without a re-open. Validated (Qt harness: direct seeks land 81% on continuous vs 0% on legacy), so the
    // client now defaults to "continuous"; WT_SEEK_MODE=legacy forces the old per-fragment-discontinuity path.
    QString seekMode = qEnvironmentVariable("WT_SEEK_MODE");
    if (seekMode.isEmpty()) seekMode = QStringLiteral("continuous");
    body["seek_mode"] = seekMode;
    // HEAD SPLIT. An opt-in boolean CV shipped 2026-07-18 for Cilex Pro Mobile
    // (review.py:47-52): a window whose head lands mid-segment serves fragment 0 as a
    // trimmed ~1.2 s piece followed by the trimmed remainder. "Watchtower's default
    // sessions are untouched" — and we had never sent it; a grep of src/ and qml/ found
    // zero occurrences until now (Linux dev box, letter 2026-08-30).
    //
    // It targets the one thing measured to gate the first frame. The player waits for
    // ONE COMPLETE segment and renders ~220 ms later, and ours is ~6.7 MB, which at the
    // booth's measured ~13.5 Mbit/s is ~4.0 s of pure transfer. On the pilot,
    // head_split takes frag0 from 2,587,820 B to 330,316 B — 7.8x. Note their code
    // comment says 10-40 KB; that was mobile's ladder, ours is 1440p, so 330 KB.
    //
    // This is the server-side version of the split I tried and failed to emulate
    // client-side on 2026-08-31 (truncating the body and aborting upstream made TTFF
    // WORSE — see docs/perf/2026-08-31-*.md §10). Done properly it costs no extra
    // request, loses no footage, and churns no connection.
    //
    // NOW ON BY DEFAULT — but it was OFF for several hours first, and the reason is
    // worth keeping. When we first sent it (2026-08-31) the flag engaged and the trimmed
    // fragment was then never served: `seg/0.ts` returned 503 with a 64-byte body, 11-13
    // times per open, and NO first frame at all. Our 503 path is built for CV's
    // documented "a cold fragment remuxes sub-second, then 200"; that never came.
    // Default-on at that moment would have taken historic playback away from the guards
    // on the only station in production.
    //
    // CV root-caused it from our `frag0s=1.200` signal within the hour: one ffmpeg was
    // running TWO libx264 encoders at source resolution, and review sources are
    // 2560x1440 HEVC, so the process was SIGKILLed by the cgroup
    // (memcg OOM, anon-rss 1,276,060 kB against a 1,536 MB cap → "head-pieces failed
    // rc=-9"). It had only ever been exercised on the mobile ladder, where the source is
    // a small rendition and two encoder contexts fit. They now run two sequential passes.
    //
    // RE-MEASURED HERE AFTER THEIR FIX, which is the condition they asked for before we
    // trusted it. Instant-open path, live pilot, arms alternating:
    //
    //     head_split   frag0s=1.200   seg0 200   1,419,776 B in 1,307 ms
    //                  frag0s=1.200   seg0 200   1,168,420 B in   742 ms
    //     control      frag0s=18.927  seg0 200   7,432,016 B in 5,159 ms
    //                  frag0s= 7.927  seg0 200   7,425,248 B in 5,693 ms
    //                  frag0s=25.924  seg0 200   7,160,920 B in 4,315 ms
    //
    // 2/2 engaged opens served cleanly, zero 503s. **Segment 0 falls from ~5,050 ms to
    // ~1,000 ms** — about four seconds off the single dominant cost on the open path,
    // and throughput is unchanged (~13 Mbit/s either way), so the win is purely fewer
    // bytes, which is exactly what it claims to be.
    //
    // WT_PB_NO_HEAD_SPLIT=1 reverts. If historic playback ever dies with repeated 503s
    // on seg/0.ts, that is this: set it in the booth's warden.conf APP_ENV and restart
    // Warden. The live wall does not use review sessions and is unaffected either way.
    if (!qEnvironmentVariableIsSet("WT_PB_NO_HEAD_SPLIT"))
        body["head_split"] = true;
    if (pbTime) {
        auto *sharedNam = AuthController::instance()->nam();
        const QString host = QUrl(m_baseUrl).host();
        qInfo("[PBTIME] session_dispatch inflight_own=%d inflight_shared=%d",
              runningTo(m_nam, host),
              m_nam == sharedNam ? -1 : runningTo(sharedNam, host));
    }
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, cameraId, wallStartIso, wallEndIso, hevcCapable, attempt, httpTimer, tag]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        if (pbTime) {
            // Server-Timing is CV's OWN decomposition of this request and has shipped
            // on every response since 2026-07-11 (CV letter 2026-08-29 §3). Session
            // creation is now the largest single item on the open path — measured
            // 2026-08-31: 7,785 / 7,714 / 7,481 ms for 2,010 / 48,481 / 2,252,683
            // byte responses, i.e. payload-independent and therefore not transfer.
            // Without their serve= term we cannot say whether that is CV's processing
            // or the link, and would be guessing at the biggest number we have.
            const QByteArray st = reply->rawHeader("Server-Timing");
            qInfo("[PBTIME] session_http ms=%lld code=%d bytes=%lld attempt=%d st=[%s]",
                  (long long)httpTimer.elapsed(), code, (long long)raw.size(), attempt,
                  st.constData());
        }
        if (code != 200) {
            // 401 = auth. Silence here is the 2026-08-10 P0: playback died and
            // nothing anywhere said so. Ask AuthController for one refresh and
            // retry ONCE with the new cookie; only then call it a fault.
            if (code == 401 && attempt < 3) {
                qWarning().noquote() << "[WT-DEGRADED] subsystem=playback reason=auth "
                                        "action=refresh-and-retry attempt=" << attempt;
                AuthController::instance()->noteUnauthorized();
                QTimer::singleShot(1200, this, [this, cameraId, wallStartIso, wallEndIso, hevcCapable, tag]() {
                    applyAuthCookie();                       // pick up whatever the refresh produced
                    requestSession(cameraId, wallStartIso, wallEndIso, hevcCapable, 3, tag);
                });
                return;
            }
            if (code == 401) {                               // refresh did not help: SAY SO, loudly
                setAuthFault(true, QJsonDocument::fromJson(raw).object().value("detail").toString());
            }
            // code 0 = no HTTP response (transport failure: timeout / unreachable /
            // reset). Usually transient — retry a couple of times with a short
            // backoff before surfacing the failure (a plain HTTP POST, no pipeline
            // teardown involved, so retrying here is safe).
            if (code == 0 && attempt < 2) {
                QTimer::singleShot(500, this, [this, cameraId, wallStartIso, wallEndIso, hevcCapable, attempt, tag]() {
                    requestSession(cameraId, wallStartIso, wallEndIso, hevcCapable, attempt + 1, tag);
                });
                return;
            }
            const QString detail = QJsonDocument::fromJson(raw).object().value("detail").toString();
            const QString msg = !detail.isEmpty() ? detail
                        : code == 0 ? QStringLiteral("Couldn't reach the recording backend (%1).").arg(reply->errorString())
                        : QStringLiteral("Session error (%1).").arg(code);
            emit sessionFailed(msg, tag);
            setStatus(QString());
            return;
        }
        const auto obj = QJsonDocument::fromJson(raw).object();
        const QString sid = obj.value("session_id").toString();
        const auto man = obj.value("manifest").toObject();
        const auto fragsArr = man.value("fragments").toArray();
        // Fragments cross the C++→QML boundary as POSITIONAL PRIMITIVE ROWS
        // [cs, ce, wsMs, weMs, disc, boundary, codec, tier, resolution, stream_type],
        // pre-filtered to availability=="ready" — NOT per-fragment QVariantMaps.
        // Marshalling thousands of maps builds a huge QV4 heap graph (a
        // VariantAssociation wrapper + key strings per map, Qt ≥6.10); under session
        // churn that accumulation made a forced QML GC drain its mark stack for
        // MINUTES on the GUI thread — the rare "GUI wedge" (HANG #1, 2026-07-02 night
        // soak; live stack captured 2026-07-03: runGC→MarkStack::drain inside this
        // signal's fromQVariantMap). Every consumer dropped non-ready rows and used
        // only these ten fields, so nothing is lost — and the payload shrinks ~50×.
        // See docs/perf/2026-07-03-night-soak-gui-wedge.prompt.md.
        QVariantList frags;
        double compactDuration = 0.0;
        for (const auto &fv : fragsArr) {
            const auto fo = fv.toObject();
            if (fo.value("availability").toString() != QLatin1String("ready"))
                continue;
            const double ce = fo.value("compact_end").toDouble();
            compactDuration = qMax(compactDuration, ce);
            frags.append(QVariant(QVariantList{
                fo.value("compact_start").toDouble(), ce,
                double(QDateTime::fromString(fo.value("wall_start").toString(), Qt::ISODateWithMs).toMSecsSinceEpoch()),
                double(QDateTime::fromString(fo.value("wall_end").toString(), Qt::ISODateWithMs).toMSecsSinceEpoch()),
                fo.value("discontinuity").toBool(),
                fo.value("boundary").toString(),
                fo.value("codec").toString(),
                fo.value("tier").toString(),
                fo.value("resolution").toString(),
                fo.value("stream_type").toString()}));
        }
        QVariantMap meta;
        meta["wall_start"] = man.value("wall_start").toString();
        meta["wall_end"] = man.value("wall_end").toString();
        meta["clipped_to_finalized"] = man.value("clipped_to_finalized").toBool();
        meta["live_gap_s"] = man.value("live_gap_s").toDouble();
        // manifest "events" deliberately NOT forwarded: no QML consumer exists, and on
        // heavy days it was hundreds more QVariantMaps of pure GC load per open.
        meta["seek_mode"] = man.value("seek_mode").toString();   // "continuous" ⇒ client may seek directly within a run
        setStatus(QString());
        setAuthFault(false, QString());                      // playback is demonstrably authorised again
        emit sessionReady(sid, compactDuration, frags, meta, tag);
    });
}

namespace {
QMutex s_thumbMx;
QHash<QString, QImage> s_thumbTiles;      // "<tag>#<index>" → decoded tile
}

QImage PlaybackClient::thumbTile(const QString &key)
{
    QMutexLocker l(&s_thumbMx);
    return s_thumbTiles.value(key);
}

void PlaybackClient::fetchThumbnails(const QString &cameraId, const QString &tag,
                                     const QString &wallStartIso, const QString &wallEndIso,
                                     int count, int height,
                                     const QString &precision, const QString &format)
{
    if (cameraId.isEmpty() || !m_loggedIn)
        return;
    QUrl url(m_baseUrl + "/review/thumbnails");
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("camera_id"), cameraId);
    q.addQueryItem(QStringLiteral("wall_start"), wallStartIso);   // Z-suffixed UTC (contract: +00:00 422s)
    q.addQueryItem(QStringLiteral("wall_end"), wallEndIso);
    q.addQueryItem(QStringLiteral("count"), QString::number(count));
    q.addQueryItem(QStringLiteral("height"), QString::number(height));
    q.addQueryItem(QStringLiteral("precision"), precision);
    if (format != QLatin1String("json"))
        q.addQueryItem(QStringLiteral("format"), format);
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply, cameraId, tag]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        static const bool trace = qEnvironmentVariableIsSet("WT_TRACE");
        if (trace) {
            const QByteArray st = reply->rawHeader("Server-Timing");
            qInfo().noquote() << QStringLiteral("[THUMBS] tag=%1 code=%2 Server-Timing=%3")
                                 .arg(tag).arg(code).arg(QString::fromLatin1(st));
        }
        if (code != 200) {
            emit thumbnailsReady(cameraId, tag, {}, {});          // honest empty — caller shows nothing
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        // Decode ONCE here (sheet or per-tile b64), crop tiles, and hand QML
        // provider URLs — per-tile x/width read off the metadata (NOT uniform;
        // mixed aspect ratios are legitimate), gaps never occupy a sheet slot.
        // sprite is an OBJECT {jpeg_b64,width,height} (probed live 2026-07-12).
        const QString spriteB64 = obj.value(QStringLiteral("sprite")).toObject()
                                     .value(QStringLiteral("jpeg_b64")).toString();
        QImage sheet;
        if (!spriteB64.isEmpty())
            sheet = QImage::fromData(QByteArray::fromBase64(spriteB64.toLatin1()), "JPG");
        QVariantList tiles;
        int idx = 0;
        for (const auto &tv : obj.value(QStringLiteral("thumbnails")).toArray()) {
            const auto to = tv.toObject();
            QVariantMap t;
            t.insert(QStringLiteral("wallTime"), to.value(QStringLiteral("wall_time")).toString());
            t.insert(QStringLiteral("reason"), to.value(QStringLiteral("reason")).toString());
            QImage tileImg;
            const QString b64 = to.value(QStringLiteral("jpeg_b64")).toString();
            if (!b64.isEmpty())
                tileImg = QImage::fromData(QByteArray::fromBase64(b64.toLatin1()), "JPG");
            else if (!sheet.isNull() && to.contains(QStringLiteral("x")))
                tileImg = sheet.copy(to.value(QStringLiteral("x")).toInt(), 0,
                                     to.value(QStringLiteral("width")).toInt(), sheet.height());
            if (!tileImg.isNull()) {
                // URL-proof key: '#' becomes a fragment, '|' is illegal in URLs —
                // both truncate/mangle the provider id (tiles paint dark filler).
                // A hash of the tag sidesteps every reserved character forever.
                const QString key = QString::number(qHash(tag)) + QStringLiteral("_") + QString::number(idx);
                {
                    QMutexLocker l(&s_thumbMx);
                    s_thumbTiles.insert(key, tileImg);
                    // bound the store: drop oldest-ish beyond 256 entries
                    while (s_thumbTiles.size() > 256)
                        s_thumbTiles.erase(s_thumbTiles.begin());
                }
                t.insert(QStringLiteral("tileUrl"), QStringLiteral("image://thumbtile/") + key);
            } else {
                t.insert(QStringLiteral("tileUrl"), QString());
            }
            tiles.append(t);
            ++idx;
        }
        emit thumbnailsReady(cameraId, tag, tiles, QString());
    });
}

void PlaybackClient::fetchCoverage(const QString &cameraId)
{
    if (cameraId.isEmpty())
        return;
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated())
            return;
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraId]() { fetchCoverage(cameraId); },
                Qt::SingleShotConnection);
        return;
    }
    QUrl url(m_baseUrl + "/review/coverage");
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("camera_id"), cameraId);
    q.addQueryItem(QStringLiteral("tz"), operatorTz());
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply, cameraId]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200) {
            // Endpoint not shipped yet (404) or error: honest pending state.
            emit coverageReady(cameraId, false, 0, {});
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const int retentionDays = obj.value("retention_days").toInt();
        QVariantList days;
        for (const auto &dv : obj.value("days").toArray())
            days.append(dv.toObject().toVariantMap());
        emit coverageReady(cameraId, true, retentionDays, days);
    });
}

void PlaybackClient::openMosaicSession(const QStringList &cameraIds, const QString &wallStartIso,
                                       const QString &wallEndIso, int cols, int rows,
                                       const QString &replaces, int prewarmAt)
{
    if (cameraIds.isEmpty()) {
        emit mosaicSessionFailed(QStringLiteral("No cameras selected for the wall."), false);
        return;
    }
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated()) {
            emit mosaicSessionFailed(QStringLiteral("Not signed in to the recording backend."), false);
            return;
        }
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraIds, wallStartIso, wallEndIso, cols, rows, replaces, prewarmAt]() {
                    openMosaicSession(cameraIds, wallStartIso, wallEndIso, cols, rows, replaces, prewarmAt);
                }, Qt::SingleShotConnection);
        return;
    }
    setStatus(QStringLiteral("Opening wall session…"));
    QNetworkRequest req{QUrl(m_baseUrl + "/review/mosaic-sessions")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonArray ids;
    for (const QString &id : cameraIds) ids.append(id);
    QJsonObject body{{"camera_ids", ids}, {"wall_start", wallStartIso}, {"wall_end", wallEndIso}};
    if (cols > 0 && rows > 0)
        body.insert("layout", QJsonObject{{"cols", cols}, {"rows", rows}});
    if (!replaces.isEmpty())                 // B2a: reap the prior session on open
        body.insert("replaces", replaces);
    if (prewarmAt >= 0)                       // B3: warm around this fragment on create
        body.insert("prewarm_at", prewarmAt);
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray raw = reply->readAll();
        setStatus(QString());
        if (code != 200) {
            // 404 = the mosaic endpoint isn't deployed yet → honest "pending"
            // (not an error). Any other code is a real failure to surface.
            const bool pending = (code == 404);
            QString detail = QJsonDocument::fromJson(raw).object().value("detail").toString();
            emit mosaicSessionFailed(
                pending ? QStringLiteral("backend compositing pending")
                        : (detail.isEmpty() ? QStringLiteral("Wall session error (%1).").arg(code) : detail),
                pending);
            return;
        }
        const auto obj = QJsonDocument::fromJson(raw).object();
        const QString sid = obj.value("session_id").toString();
        const auto grid = obj.value("grid").toObject().toVariantMap();
        QVariantList cells;
        for (const auto &cv : obj.value("cells").toArray())
            cells.append(cv.toObject().toVariantMap());
        const auto man = obj.value("manifest").toObject();
        QVariantList frags;
        double compactDuration = 0.0;
        for (const auto &fv : man.value("fragments").toArray()) {
            const auto fo = fv.toObject();
            frags.append(fo.toVariantMap());
            if (fo.value("availability").toString() == "ready")
                compactDuration = qMax(compactDuration, fo.value("compact_end").toDouble());
        }
        QVariantMap meta;
        meta["wall_start"] = man.value("wall_start").toString();
        meta["wall_end"] = man.value("wall_end").toString();
        meta["clipped_to_finalized"] = man.value("clipped_to_finalized").toBool();
        meta["live_gap_s"] = man.value("live_gap_s").toDouble();
        emit mosaicSessionReady(sid, grid, cells, compactDuration, frags, meta);
    });
}

void PlaybackClient::disposeMosaicSession(const QString &sessionId)
{
    if (sessionId.isEmpty() || !m_loggedIn)
        return;
    QNetworkRequest req{QUrl(m_baseUrl + "/review/mosaic-sessions/" + sessionId)};
    QNetworkReply *reply = m_nam->deleteResource(req);
    connect(reply, &QNetworkReply::finished, reply, &QNetworkReply::deleteLater);   // fire-and-forget
}

void PlaybackClient::prewarmMosaic(const QString &sessionId, int atFrag, int ahead)
{
    if (sessionId.isEmpty() || atFrag < 0 || !m_loggedIn)
        return;
    QNetworkRequest req{QUrl(m_baseUrl + "/review/mosaic-sessions/" + sessionId + "/prewarm")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"at_frag", atFrag}};
    if (ahead > 0)
        body.insert("ahead", ahead);
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, reply, &QNetworkReply::deleteLater);   // fire-and-forget (202)
}

void PlaybackClient::fetchCoverageUnion(const QStringList &cameraIds)
{
    if (cameraIds.isEmpty())
        return;
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated()) {
            emit coverageUnionReady(false, 0, {});
            return;
        }
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraIds]() { fetchCoverageUnion(cameraIds); }, Qt::SingleShotConnection);
        return;
    }
    QUrl url(m_baseUrl + "/review/coverage");
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("camera_ids"), cameraIds.join(','));
    q.addQueryItem(QStringLiteral("tz"), operatorTz());
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200) {
            emit coverageUnionReady(false, 0, {});   // endpoint not shipped → honest pending
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const int retentionDays = obj.value("retention_days").toInt();
        QVariantList unionDays;
        for (const auto &dv : obj.value("union").toArray())
            unionDays.append(dv.toString());
        emit coverageUnionReady(true, retentionDays, unionDays);
    });
}

void PlaybackClient::fetchTimeline(const QString &cameraId, const QString &startIso,
                                   const QString &endIso, int buckets)
{
    if (cameraId.isEmpty() || startIso.isEmpty() || endIso.isEmpty())
        return;
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated())
            return;
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this, cameraId, startIso, endIso, buckets]() {
                    fetchTimeline(cameraId, startIso, endIso, buckets);
                }, Qt::SingleShotConnection);
        return;
    }
    QUrl url(m_baseUrl + "/events/timeline");
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("start"), startIso);
    q.addQueryItem(QStringLiteral("end"), endIso);
    q.addQueryItem(QStringLiteral("camera_ids"), cameraId);
    if (buckets > 0)
        q.addQueryItem(QStringLiteral("buckets"), QString::number(buckets));
    url.setQuery(q);
    QNetworkReply *reply = m_nam->get(QNetworkRequest{url});
    connect(reply, &QNetworkReply::finished, this, [this, reply, cameraId]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        if (code != 200) {
            emit timelineReady(cameraId, QStringLiteral("error"), {});
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const QString mode = obj.value("mode").toString();
        QVariantList blocks;
        for (const auto &bv : obj.value("cameras").toObject().value(cameraId).toArray())
            blocks.append(bv.toObject().toVariantMap());
        emit timelineReady(cameraId, mode, blocks);
    });
}

void PlaybackClient::flushPendingSessions() { /* queued via SingleShotConnection */ }

QString PlaybackClient::playlistUrl(const QString &sessionId) const
{
    return m_proxy->localBase() + "/review/sessions/" + sessionId + "/playlist.m3u8";
}

QString PlaybackClient::mosaicPlaylistUrl(const QString &sessionId) const
{
    return m_proxy->localBase() + "/review/mosaic-sessions/" + sessionId + "/playlist.m3u8";
}

void PlaybackClient::createExport(const QString &cameraId, const QString &wallStartIso,
                                  const QString &wallEndIso, const QString &mode,
                                  const QString &destPath, const QString &groupId,
                                  const QString &purpose, bool hevcCapable,
                                  const QVariantMap &post)
{
    m_lastExport = { cameraId, wallStartIso, wallEndIso, mode, destPath, groupId, purpose, post, true };
    QNetworkRequest req{QUrl(m_baseUrl + "/review/exports")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"camera_id", cameraId}, {"wall_start", wallStartIso},
                     {"wall_end", wallEndIso}, {"mode", mode}, {"hevc_capable", hevcCapable}};
    if (!groupId.isEmpty()) body.insert("group_id", groupId);
    if (!purpose.isEmpty()) body.insert("purpose", purpose);
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, destPath, post]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        // 422 = High requested over a span that has aged to the standard sub (the
        // grey-out/confirm race). Surface the backend's explanation; the operator
        // can re-export at Standard quality.
        if (code == 422) {
            const QString detail = obj.value("detail").toString();
            emit exportFailed(QString(), detail.isEmpty()
                ? QStringLiteral("High-quality export needs the high-res original, which has aged to standard storage for part of this selection. Export at Standard quality instead.")
                : detail);
            return;
        }
        const QString jobId = obj.value("job_id").toString();
        if (jobId.isEmpty()) {
            emit exportFailed(QString(), "Export request rejected.");
            return;
        }
        m_exportDest.insert(jobId, destPath);
        if (!post.isEmpty()) m_exportPost.insert(jobId, post);   // client compression/overlays
        emit exportStarted(jobId);
        QTimer::singleShot(1500, this, [this, jobId]() { pollExport(jobId); });
    });
}

void PlaybackClient::retryLastExportAsHigh()
{
    if (!m_lastExport.valid)
        return;
    const LastExport e = m_lastExport;   // copy — createExport overwrites m_lastExport
    createExport(e.cameraId, e.wallStart, e.wallEnd, e.mode, e.destPath, e.groupId, e.purpose,
                 /*hevcCapable=*/true, e.post);
}

void PlaybackClient::createMosaicExport(const QString &sessionId, const QString &wallStartIso,
                                        const QString &wallEndIso, const QString &mode,
                                        const QString &destPath, const QString &groupId,
                                        const QString &purpose)
{
    QNetworkRequest req{QUrl(m_baseUrl + "/review/mosaic-sessions/" + sessionId + "/exports")};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QJsonObject body{{"wall_start", wallStartIso}, {"wall_end", wallEndIso}, {"mode", mode}};
    if (!groupId.isEmpty()) body.insert("group_id", groupId);
    if (!purpose.isEmpty()) body.insert("purpose", purpose);
    QNetworkReply *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, destPath]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200) {
            emit exportFailed(QString(), code == 404
                ? QStringLiteral("Combined-grid export isn't available yet (backend E2 pending).")
                : QStringLiteral("Combined-grid export rejected (%1).").arg(code));
            return;
        }
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const QString jobId = obj.value("job_id").toString();
        if (jobId.isEmpty()) { emit exportFailed(QString(), "Combined-grid export rejected."); return; }
        m_exportDest.insert(jobId, destPath);
        emit exportStarted(jobId);
        QTimer::singleShot(1500, this, [this, jobId]() { pollExport(jobId); });
    });
}

void PlaybackClient::fetchExports()
{
    if (!m_loggedIn) {
        if (!AuthController::instance()->authenticated()) { emit exportsListReady({}); return; }
        ensureReady();
        connect(this, &PlaybackClient::camerasResolved, this,
                [this]() { fetchExports(); }, Qt::SingleShotConnection);
        return;
    }
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/review/exports?limit=200")});
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (code != 200) { emit exportsListReady({}); return; }   // endpoint absent / error → empty (honest)
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        QVariantList out;
        for (const auto &v : obj.value("exports").toArray()) {
            QVariantMap m = v.toObject().toVariantMap();
            // Route the token download through the local proxy (same as pollExport's
            // download), so "Open" works with the session.
            QString dl = m.value("download_url").toString();
            if (!dl.isEmpty()) {
                dl.replace("/api/review/", "/review/");
                m["downloadUrl"] = m_proxy->localBase() + dl;
            } else {
                m["downloadUrl"] = QString();
            }
            out.append(m);
        }
        emit exportsListReady(out);
    });
}

void PlaybackClient::pollExport(const QString &jobId)
{
    QNetworkReply *reply = m_nam->get(QNetworkRequest{QUrl(m_baseUrl + "/review/exports/" + jobId)});
    connect(reply, &QNetworkReply::finished, this, [this, reply, jobId]() {
        reply->deleteLater();
        const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
        const QString state = obj.value("state").toString();
        emit exportProgress(jobId, state);
        if (state == "ready") {
            QString dl = obj.value("download_url").toString();
            dl.replace("/api/review/", "/review/");      // route via the local proxy
            downloadExport(jobId, m_proxy->localBase() + dl, m_exportDest.value(jobId));
        } else if (state == "failed" || state == "error") {
            emit exportFailed(jobId, obj.value("error_msg").toString());
        } else {
            QTimer::singleShot(2000, this, [this, jobId]() { pollExport(jobId); });
        }
    });
}

void PlaybackClient::downloadExport(const QString &jobId, const QString &url,
                                    const QString &destPath)
{
    if (destPath.isEmpty()) {
        emit exportFailed(jobId, "No export destination set.");
        return;
    }
    auto *file = new QFile(destPath);
    if (!file->open(QIODevice::WriteOnly)) {
        file->deleteLater();
        emit exportFailed(jobId, "Cannot write to " + destPath);
        return;
    }
    QNetworkRequest req{QUrl(url)};
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = m_nam->get(req);
    // Stream chunks straight to disk so a large clip never sits in memory.
    connect(reply, &QNetworkReply::readyRead, file, [reply, file]() { file->write(reply->readAll()); });
    connect(reply, &QNetworkReply::finished, this, [this, reply, file, jobId, destPath]() {
        reply->deleteLater();
        file->write(reply->readAll());
        file->flush();
        const qint64 sz = file->size();
        file->close();
        file->deleteLater();
        m_exportDest.remove(jobId);
        if (reply->error() == QNetworkReply::NoError && sz > 0) {
            // Client-side post-processing (compression ladder / overlay burn-in): the
            // downloaded clip becomes the transcode source; the final lands back at
            // destPath. cilex-vision's export is clean footage (no overlays) — exactly
            // the source we want.
            if (m_exportPost.contains(jobId)) {
                const QVariantMap post = m_exportPost.take(jobId);
                const QString srcTmp = destPath + QStringLiteral(".src.mp4");
                QFile::remove(srcTmp);
                if (QFile::rename(destPath, srcTmp)) {
                    emit exportProgress(jobId, QStringLiteral("compressing"));
                    runPostProcess(jobId, srcTmp, destPath, post);
                    return;
                }
                // couldn't stage the source → fall through, deliver the original as-is
            }
            emit exportSaved(jobId, destPath);
        } else {
            QFile::remove(destPath);   // don't leave a partial/empty file behind
            emit exportFailed(jobId, reply->error() == QNetworkReply::NoError
                                         ? QStringLiteral("Downloaded clip was empty.")
                                         : reply->errorString());
        }
    });
}

void PlaybackClient::runPostProcess(const QString &jobId, const QString &srcPath,
                                    const QString &dstPath, const QVariantMap &post)
{
    auto *tc = new ClipTranscoder(this);
    connect(tc, &ClipTranscoder::progress, this, [this, jobId](int pct) {
        emit exportProgress(jobId, QStringLiteral("compressing %1%").arg(pct));
    });
    connect(tc, &ClipTranscoder::finished, this, [this, jobId, srcPath, tc](const QString &out) {
        QFile::remove(srcPath);
        tc->deleteLater();
        emit exportSaved(jobId, out);
    });
    connect(tc, &ClipTranscoder::failed, this, [this, jobId, srcPath, dstPath, tc](const QString &err) {
        // Keep the operator's footage: restore the un-transcoded original at dstPath,
        // and report the compression failure honestly.
        QFile::remove(dstPath);
        QFile::rename(srcPath, dstPath);
        tc->deleteLater();
        emit exportFailed(jobId, QStringLiteral("Couldn't compress the clip (%1) — kept the original-quality export.").arg(err));
    });
    tc->start(srcPath, dstPath, post.value(QStringLiteral("height")).toInt(),
              post.value(QStringLiteral("name")).toBool(),
              post.value(QStringLiteral("timestamp")).toBool(),
              post.value(QStringLiteral("label")).toString(),
              post.value(QStringLiteral("startEpochMs")).toLongLong(),
              post.value(QStringLiteral("durationMs")).toLongLong());
}

QImage ThumbTileProvider::requestImage(const QString &id, QSize *size, const QSize &requested)
{
    QImage img = PlaybackClient::thumbTile(id);
    if (img.isNull()) {
        static const bool trace = qEnvironmentVariableIsSet("WT_TRACE");
        if (trace)
            qInfo().noquote() << QStringLiteral("[THUMBTILE] MISS id=%1").arg(id);
        img = QImage(16, 9, QImage::Format_RGB32);
        img.fill(QColor(0x16, 0x14, 0x0f));
    }
    if (requested.isValid() && requested.width() > 0)
        img = img.scaled(requested, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    if (size)
        *size = img.size();
    return img;
}
