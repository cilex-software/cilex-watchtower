#pragma once
#include <QAbstractListModel>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;

// One analyser's FINDINGS, fleet-wide, for the Labs Findings view (operator request
// 2026-09-29; the data and its rules are in LabsFindingsData.h). Newest first, one page at a
// time, the next page asked for only when the list scrolls near its end -- "All" is a
// period, never a request for everything at once.
//
// Honest states: `state` says whether the server answered ("ok"), has no such endpoint yet
// ("absent", a 404 without a code of its own), refused ("admin_only"), or failed ("error",
// with its words). A changed analyser, period or filter is a different list: the rows go at
// once and an answer still in flight for the old one is dropped when it lands, so one list's
// rows can never appear under another's filter.
class LabsFindingsModel : public QAbstractListModel
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString analyzer READ analyzer WRITE setAnalyzer NOTIFY inputsChanged)
    Q_PROPERTY(QString period READ period WRITE setPeriod NOTIFY inputsChanged)
    Q_PROPERTY(QString facet READ facet WRITE setFacet NOTIFY inputsChanged)
    Q_PROPERTY(QString lang READ lang WRITE setLang NOTIFY inputsChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY inputsChanged)

    Q_PROPERTY(int count READ count NOTIFY stateChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY stateChanged)          // the first page
    Q_PROPERTY(bool loadingMore READ loadingMore NOTIFY stateChanged)  // a further page
    Q_PROPERTY(bool hasMore READ hasMore NOTIFY stateChanged)
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString errorText READ errorText NOTIFY stateChanged)
    Q_PROPERTY(QVariant total READ total NOTIFY stateChanged)
    Q_PROPERTY(QVariantList facets READ facets NOTIFY stateChanged)
    Q_PROPERTY(QString generatedAt READ generatedAt NOTIFY stateChanged)
    Q_PROPERTY(int dropped READ dropped NOTIFY stateChanged)

public:
    enum Roles { ItemRole = Qt::UserRole + 1 };
    static constexpr int kPageSize = 40;

    explicit LabsFindingsModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString analyzer() const { return m_analyzer; }
    void setAnalyzer(const QString &v);
    QString period() const { return m_period; }
    void setPeriod(const QString &v);
    QString facet() const { return m_facet; }
    void setFacet(const QString &v);
    QString lang() const { return m_lang; }
    void setLang(const QString &v);
    bool active() const { return m_active; }
    void setActive(bool v);

    int count() const { return m_items.size(); }
    bool loading() const { return m_loading; }
    bool loadingMore() const { return m_loadingMore; }
    bool hasMore() const { return m_hasMore; }
    QString state() const { return m_state; }
    QString errorText() const { return m_errorText; }
    QVariant total() const { return m_total; }
    QVariantList facets() const { return m_facets; }
    QString generatedAt() const { return m_generatedAt; }
    int dropped() const { return m_dropped; }

    Q_INVOKABLE QVariantMap get(int row) const;
    // Ask again from the first page (the operator's Refresh, or a changed filter).
    Q_INVOKABLE void reload();
    // The next page, if there is one and none is on its way. The list calls it near its end.
    Q_INVOKABLE void loadMore();
    // Row `row` as the Events player takes an event (wtlabs::findingAsEvent); `knownCam` is
    // that camera's entry from the app's camera list, or {} when the app does not know it.
    Q_INVOKABLE QVariantMap asEvent(int row, const QVariantMap &knownCam) const;
    // A Paths row's `path` metric as [{x, y}] in picture fractions (wtlabs::decodePath).
    Q_INVOKABLE QVariantList decodePath(const QString &path) const;

signals:
    void inputsChanged();
    void stateChanged();

private:
    QString key() const;
    void schedule();
    void fetch(bool more);

    QNetworkAccessManager *m_nam = nullptr;
    QString m_baseUrl;

    QString m_analyzer, m_period = QStringLiteral("24h"), m_facet, m_lang = QStringLiteral("en");
    bool m_active = false;

    QVariantList m_items;
    QString m_cursor;
    bool m_hasMore = false;
    bool m_loading = false, m_loadingMore = false;
    QString m_state, m_errorText, m_generatedAt;
    QVariant m_total;
    QVariantList m_facets;
    int m_dropped = 0;
    int m_generation = 0;
    bool m_scheduled = false;
    QString m_haveKey;               // the analyser|period|filter|language the rows answer for
};
