#include "LabsFindingsModel.h"
#include "AuthController.h"
#include "LabsFindingsData.h"
#include "ServerMessage.h"

#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTimer>

LabsFindingsModel::LabsFindingsModel(QObject *parent)
    : QAbstractListModel(parent)
{
    auto *auth = AuthController::instance();
    m_nam = auth->nam();
    m_baseUrl = auth->baseUrl();
    connect(auth, &AuthController::baseUrlChanged, this, [this, auth]() {
        m_baseUrl = auth->baseUrl();
        m_haveKey.clear();                    // another server: nothing on screen answers for it
        schedule();
    });
    connect(auth, &AuthController::authenticatedChanged, this, [this, auth]() {
        if (!auth->authenticated()) {         // signed out: forget the rows
            ++m_generation;
            beginResetModel();
            m_items.clear();
            endResetModel();
            m_cursor.clear();
            m_hasMore = m_loading = m_loadingMore = false;
            m_state.clear();
            m_errorText.clear();
            m_total = QVariant();
            m_facets.clear();
            m_haveKey.clear();
            emit stateChanged();
        } else {
            schedule();
        }
    });
}

int LabsFindingsModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_items.size();
}

QVariant LabsFindingsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_items.size() || role != ItemRole)
        return {};
    return m_items.at(index.row());
}

QHash<int, QByteArray> LabsFindingsModel::roleNames() const
{
    return {{ItemRole, "item"}};
}

void LabsFindingsModel::setAnalyzer(const QString &v)
{
    if (v == m_analyzer) return;
    m_analyzer = v;
    emit inputsChanged();
    schedule();
}

void LabsFindingsModel::setPeriod(const QString &v)
{
    if (v == m_period) return;
    m_period = v;
    emit inputsChanged();
    schedule();
}

void LabsFindingsModel::setFacet(const QString &v)
{
    if (v == m_facet) return;
    m_facet = v;
    emit inputsChanged();
    schedule();
}

void LabsFindingsModel::setLang(const QString &v)
{
    if (v == m_lang) return;
    m_lang = v;
    emit inputsChanged();
    schedule();
}

void LabsFindingsModel::setActive(bool v)
{
    if (v == m_active) return;
    m_active = v;
    emit inputsChanged();
    schedule();
}

QString LabsFindingsModel::key() const
{
    return m_analyzer + QLatin1Char('|') + m_period + QLatin1Char('|') + m_facet + QLatin1Char('|') + m_lang
           + QLatin1Char('|') + m_baseUrl;
}

void LabsFindingsModel::schedule()
{
    // Only while the view is on screen, for an analyser, and only when what the rows answer
    // for has changed: switching screens and back asks nothing again.
    if (!m_active || m_analyzer.isEmpty() || !AuthController::instance()->authenticated())
        return;
    if (key() == m_haveKey && !m_state.isEmpty() && m_state != QStringLiteral("error"))
        return;
    if (m_scheduled)
        return;
    m_scheduled = true;                       // several inputs set at once: ONE request
    QTimer::singleShot(0, this, [this]() {
        m_scheduled = false;
        if (m_active && !m_analyzer.isEmpty())
            reload();
    });
}

void LabsFindingsModel::reload()
{
    if (m_analyzer.isEmpty())
        return;
    ++m_generation;                           // an answer still on its way is for the old list
    beginResetModel();
    m_items.clear();
    endResetModel();
    m_cursor.clear();
    m_hasMore = false;
    m_loading = true;
    m_loadingMore = false;
    m_errorText.clear();
    m_total = QVariant();
    m_dropped = 0;
    m_haveKey = key();
    emit stateChanged();
    fetch(false);
}

void LabsFindingsModel::loadMore()
{
    if (!m_hasMore || m_loading || m_loadingMore || m_cursor.isEmpty())
        return;
    m_loadingMore = true;
    m_errorText.clear();
    emit stateChanged();
    fetch(true);
}

void LabsFindingsModel::fetch(bool more)
{
    const QUrl url = wtlabs::findingsUrl(m_baseUrl, m_analyzer, m_period, m_facet,
                                         more ? m_cursor : QString(), kPageSize, m_lang);
    const int gen = m_generation;
    QNetworkReply *reply = m_nam->get(QNetworkRequest(url));
    connect(reply, &QNetworkReply::finished, this, [this, reply, gen, more]() {
        reply->deleteLater();
        if (gen != m_generation)
            return;                           // the list changed while this was on its way
        m_loading = m_loadingMore = false;
        const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();
        if (code == 401)
            AuthController::instance()->noteUnauthorized();
        if (code == 200) {
            const wtlabs::FindingsPage p = wtlabs::parseFindings(QJsonDocument::fromJson(body).object());
            if (!p.items.isEmpty()) {
                beginInsertRows(QModelIndex(), m_items.size(), m_items.size() + p.items.size() - 1);
                m_items += p.items;
                endInsertRows();
            }
            m_cursor = p.nextCursor;
            m_hasMore = !m_cursor.isEmpty();
            m_dropped += p.dropped;
            if (!more || !p.facets.isEmpty())
                m_facets = p.facets;
            if (!more || p.total.isValid())
                m_total = p.total;
            m_generatedAt = p.generatedAt;
            m_state = QStringLiteral("ok");
            m_errorText.clear();
        } else {
            const QJsonObject o = QJsonDocument::fromJson(body).object();
            const QString slug = o.value(QStringLiteral("code")).toString().isEmpty()
                                     ? o.value(QStringLiteral("detail")).toString()
                                     : o.value(QStringLiteral("code")).toString();
            if (code == 404 && (slug.isEmpty() || slug == QStringLiteral("Not Found"))) {
                m_state = QStringLiteral("absent");       // no such endpoint on this server yet
                m_errorText.clear();
            } else if (code == 403) {
                m_state = QStringLiteral("admin_only");
                m_errorText = wt::serverMessage(body);
            } else {
                // The rows already on screen stay (a failed further page is not an empty
                // list); the reason is said, and the list can ask again.
                if (!more)
                    m_state = QStringLiteral("error");
                m_errorText = code == 0 ? reply->errorString()
                                        : QStringLiteral("HTTP %1 %2").arg(code).arg(wt::serverMessage(body));
            }
        }
        emit stateChanged();
    });
}

QVariantMap LabsFindingsModel::get(int row) const
{
    return (row >= 0 && row < m_items.size()) ? m_items.at(row).toMap() : QVariantMap();
}

QVariantMap LabsFindingsModel::asEvent(int row, const QVariantMap &knownCam) const
{
    if (row < 0 || row >= m_items.size())
        return {};
    return wtlabs::findingAsEvent(m_items.at(row).toMap(), knownCam);
}

QVariantList LabsFindingsModel::decodePath(const QString &path) const
{
    return wtlabs::decodePath(path);
}
