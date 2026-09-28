#pragma once
#include "LabsTimelineData.h"

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;
class QNetworkReply;

// What the Labs analysers found on ONE camera, for the Playback timeline's Labs lane
// (operator request 2026-09-28). Fetches /labs/observations once per analyser for the
// window the timeline is showing -- see LabsTimelineData.h for why per analyser -- and
// only while `active` (the lane is on screen).
//
// Honest states: every row says whether it is loading, loaded (with its count), cut at the
// endpoint's ceiling ("2000+", and where the cut falls), or failed (with the server's
// words). Nothing loaded never reads as "Labs saw nothing".
//
// Identity rule (Stability beats flicker): a CAMERA change clears everything at once -- one
// camera's markers must never sit under another camera's name. A WINDOW change for the same
// camera keeps the old markers on screen until each analyser's new answer replaces them.
class LabsTimeline : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString cameraId READ cameraId WRITE setCameraId NOTIFY inputsChanged)
    Q_PROPERTY(double startMs READ startMs WRITE setStartMs NOTIFY inputsChanged)
    Q_PROPERTY(double endMs READ endMs WRITE setEndMs NOTIFY inputsChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY inputsChanged)
    Q_PROPERTY(QString lang READ lang WRITE setLang NOTIFY inputsChanged)

    Q_PROPERTY(bool loading READ loading NOTIFY stateChanged)
    // At least one full answer (every analyser) has arrived for this camera and window.
    Q_PROPERTY(bool loaded READ loaded NOTIFY stateChanged)
    // "" | "admin_only" | "not_in_scope" | "unreachable" | "refused" -- set when EVERY
    // analyser failed; a single failed row is reported on that row.
    Q_PROPERTY(QString errorCode READ errorCode NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    // One entry per analyser, in wtlabs::laneKeys() order:
    //   {key, count, truncated, cutBeforeMs, state: "idle"|"loading"|"ok"|"error", error}
    Q_PROPERTY(QVariantList tracks READ tracks NOTIFY stateChanged)
    Q_PROPERTY(int total READ total NOTIFY stateChanged)
    // Bumped whenever any row's observations change: the painter repaints on it.
    Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)

public:
    explicit LabsTimeline(QObject *parent = nullptr);

    QString cameraId() const { return m_cameraId; }
    void setCameraId(const QString &v);
    double startMs() const { return m_startMs; }
    void setStartMs(double v);
    double endMs() const { return m_endMs; }
    void setEndMs(double v);
    bool active() const { return m_active; }
    void setActive(bool v);
    QString lang() const { return m_lang; }
    void setLang(const QString &v);

    bool loading() const { return m_inFlight > 0 || m_queue.size() > 0; }
    bool loaded() const { return m_loaded; }
    QString errorCode() const { return m_errorCode; }
    QString errorText() const { return m_errorText; }
    QVariantList tracks() const;
    int total() const;
    int revision() const { return m_revision; }

    // For the painter.
    const QVector<wtlabs::Obs> &rows(const QString &key) const;
    qint64 cutBeforeMs(const QString &key) const;     // truncated rows: older than this is NOT loaded
    bool locate(const QString &id, QString *key, int *index) const;

    // For QML: the card's content, and the dev hook's pick.
    Q_INVOKABLE QVariantMap observation(const QString &id) const;
    Q_INVOKABLE QString firstIdOf(const QString &key, double fromMs, double toMs) const;

signals:
    void inputsChanged();
    void stateChanged();
    void revisionChanged();

private:
    struct Track {
        QVector<wtlabs::Obs> obs;
        QString state = QStringLiteral("idle");
        QString error;
        bool truncated = false;
        qint64 cutBeforeMs = 0;
    };
    void schedule();
    void refetch();
    void pump();
    void onReply(QNetworkReply *reply, const QString &key, int generation);
    void clearAll();
    void rebuildIndex();
    void bump();

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;
    QTimer m_debounce;

    QString m_cameraId, m_lang = QStringLiteral("en");
    double m_startMs = 0, m_endMs = 0;
    bool m_active = false;

    // What the rows on screen answer for (camera + window), and the request in progress.
    QString m_haveCamera, m_haveLang;
    double m_haveStart = 0, m_haveEnd = 0;
    int m_generation = 0;
    QStringList m_queue;
    int m_inFlight = 0;
    int m_failed = 0;
    QString m_lastErrorCode, m_lastErrorText;

    QHash<QString, Track> m_tracks;
    QHash<QString, QPair<QString, int>> m_index;     // observation id -> (key, index)
    bool m_loaded = false;
    QString m_errorCode, m_errorText;
    int m_revision = 0;
};
