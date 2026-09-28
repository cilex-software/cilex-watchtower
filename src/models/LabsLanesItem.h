#pragma once
#include <QColor>
#include <QPointer>
#include <QQuickPaintedItem>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

#include "LabsTimeline.h"     // complete type: moc and the QML registrar need it for the property

// The Labs lane's ten rows, painted in ONE item. A row per analyser (wtlabs::laneKeys()
// order); each observation a bar from its start to its end, at least 2 px, merged with its
// neighbours at pixel resolution (wtlabs::runs). A Repeater of Rectangles -- how the MOTION
// lane draws ~200 episodes a day -- would be thousands of delegates here: one camera filed
// 590 Labs rows in ONE hour (hiwatch-083bc1df39d1, 2026-09-26 22:00Z).
//
// A row cut at the endpoint's ceiling shades the part of the window it did NOT load, so an
// empty stretch there can never read as "nothing found".
class LabsLanesItem : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(LabsTimeline *timeline READ timeline WRITE setTimeline NOTIFY changed)
    Q_PROPERTY(double winS READ winS WRITE setWinS NOTIFY changed)
    Q_PROPERTY(double winE READ winE WRITE setWinE NOTIFY changed)
    Q_PROPERTY(qreal rowH READ rowH WRITE setRowH NOTIFY changed)
    Q_PROPERTY(QVariantList colors READ colors WRITE setColors NOTIFY changed)   // per row
    Q_PROPERTY(QString hoverId READ hoverId WRITE setHoverId NOTIFY changed)
    Q_PROPERTY(QString selId READ selId WRITE setSelId NOTIFY changed)

public:
    explicit LabsLanesItem(QQuickItem *parent = nullptr);

    LabsTimeline *timeline() const { return m_timeline; }
    void setTimeline(LabsTimeline *t);
    double winS() const { return m_winS; }
    void setWinS(double v);
    double winE() const { return m_winE; }
    void setWinE(double v);
    qreal rowH() const { return m_rowH; }
    void setRowH(qreal v);
    QVariantList colors() const { return m_colors; }
    void setColors(const QVariantList &v);
    QString hoverId() const { return m_hoverId; }
    void setHoverId(const QString &v);
    QString selId() const { return m_selId; }
    void setSelId(const QString &v);

    void paint(QPainter *p) override;

    // The observation under (x, y) in item coordinates, within 3 px; "" if none.
    Q_INVOKABLE QString idAt(qreal x, qreal y) const;
    // Where an observation is drawn, for placing its card: {x, y, w, h}; empty if absent.
    Q_INVOKABLE QVariantMap rectOf(const QString &id) const;

signals:
    void changed();

private:
    int rowOf(const QString &key) const;
    QRectF barRect(double startMs, double endMs, int row) const;

    QPointer<LabsTimeline> m_timeline;
    double m_winS = 0, m_winE = 0;
    qreal m_rowH = 9;
    QVariantList m_colors;
    QString m_hoverId, m_selId;
};
