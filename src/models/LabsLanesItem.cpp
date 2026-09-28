#include "LabsLanesItem.h"
#include "LabsTimeline.h"

#include <QPainter>

namespace {
const QColor kLaneBg(0x15, 0x14, 0x12);               // the FOOTAGE / MOTION lanes' own ground
const QColor kRowLine(52, 48, 42, 150);               // their hairline, a touch fainter
const QColor kHover(0xf0, 0xec, 0xe4);                // Theme.ink
const QColor kSel(0xff, 0xff, 0xff);
const QColor kAccent(0xe8, 0xa1, 0x3a);               // Theme.accent
constexpr qreal kMinW = 2.0;
constexpr qreal kHitPx = 3.0;
}   // namespace

LabsLanesItem::LabsLanesItem(QQuickItem *parent)
    : QQuickPaintedItem(parent)
{
    setAntialiasing(false);                            // crisp 1-px edges, like the other lanes
    connect(this, &LabsLanesItem::changed, this, [this]() { update(); });
    connect(this, &QQuickItem::widthChanged, this, [this]() { update(); });
    connect(this, &QQuickItem::heightChanged, this, [this]() { update(); });
}

void LabsLanesItem::setTimeline(LabsTimeline *t)
{
    if (t == m_timeline)
        return;
    if (m_timeline)
        disconnect(m_timeline, nullptr, this, nullptr);
    m_timeline = t;
    if (m_timeline)
        connect(m_timeline, &LabsTimeline::revisionChanged, this, [this]() { update(); });
    emit changed();
}

void LabsLanesItem::setWinS(double v) { if (v != m_winS) { m_winS = v; emit changed(); } }
void LabsLanesItem::setWinE(double v) { if (v != m_winE) { m_winE = v; emit changed(); } }
void LabsLanesItem::setRowH(qreal v) { if (v != m_rowH && v > 0) { m_rowH = v; emit changed(); } }
void LabsLanesItem::setColors(const QVariantList &v) { m_colors = v; emit changed(); }
void LabsLanesItem::setHoverId(const QString &v) { if (v != m_hoverId) { m_hoverId = v; emit changed(); } }
void LabsLanesItem::setSelId(const QString &v) { if (v != m_selId) { m_selId = v; emit changed(); } }

int LabsLanesItem::rowOf(const QString &key) const
{
    return wtlabs::laneKeys().indexOf(key);
}

QRectF LabsLanesItem::barRect(double startMs, double endMs, int row) const
{
    const double span = m_winE - m_winS;
    const qreal w = width();
    if (!(span > 0) || row < 0)
        return {};
    const qreal x0 = (startMs - m_winS) / span * w;
    const qreal x1 = std::max(x0 + kMinW, qreal((endMs - m_winS) / span * w));
    const qreal y = row * m_rowH;
    return QRectF(x0, y + 1.5, x1 - x0, std::max(qreal(2), m_rowH - 3));
}

void LabsLanesItem::paint(QPainter *p)
{
    const qreal w = width();
    p->fillRect(QRectF(0, 0, w, height()), kLaneBg);
    const QStringList &keys = wtlabs::laneKeys();
    for (int r = 0; r < keys.size(); ++r) {
        const qreal y = r * m_rowH;
        if (r > 0)
            p->fillRect(QRectF(0, y, w, 1), kRowLine);
        if (!m_timeline)
            continue;
        // Not loaded: a row cut at the ceiling misses the OLDEST part of the window.
        const qint64 cut = m_timeline->cutBeforeMs(keys[r]);
        if (cut > 0 && cut > m_winS && m_winE > m_winS) {
            const qreal xc = std::min(w, qreal((cut - m_winS) / (m_winE - m_winS) * w));
            const QRectF band(0, y + 1, xc, m_rowH - 1);
            p->save();
            p->setClipRect(band);
            p->setPen(QPen(QColor(110, 102, 87, 110), 1));   // Theme.ink3, faint hatch
            for (qreal x = -m_rowH; x < xc; x += 4)
                p->drawLine(QPointF(x, y + m_rowH), QPointF(x + m_rowH, y));
            p->restore();
        }
        const QColor c = r < m_colors.size() ? m_colors[r].value<QColor>() : kAccent;
        const auto rs = wtlabs::runs(m_timeline->rows(keys[r]), m_winS, m_winE, w, kMinW);
        for (const wtlabs::Run &run : rs)
            p->fillRect(QRectF(run.x0, y + 1.5, std::max(kMinW, run.x1 - run.x0),
                               std::max(qreal(2), m_rowH - 3)), c);
    }
    // Hovered and selected on top, so a merged run never hides which one the card is about.
    if (m_timeline) {
        for (const QString &id : {m_selId, m_hoverId}) {
            QString key;
            int i = -1;
            if (id.isEmpty() || !m_timeline->locate(id, &key, &i))
                continue;
            const wtlabs::Obs &o = m_timeline->rows(key).at(i);
            const QRectF r = barRect(double(o.startMs), double(o.endMs), rowOf(key));
            p->fillRect(r, id == m_selId ? kSel : kHover);
            if (id == m_selId) {
                p->setPen(QPen(kAccent, 1));
                p->drawRect(r.adjusted(-1, -1, 0, 0));
            }
        }
    }
}

QString LabsLanesItem::idAt(qreal x, qreal y) const
{
    if (!m_timeline || !(m_winE > m_winS) || width() <= 0 || m_rowH <= 0)
        return {};
    const int row = int(y / m_rowH);
    const QStringList &keys = wtlabs::laneKeys();
    if (row < 0 || row >= keys.size())
        return {};
    const double msPerPx = (m_winE - m_winS) / width();
    const double ms = m_winS + x * msPerPx;
    // The 2-px minimum width is part of what the operator sees, so it is part of the target.
    const QVector<wtlabs::Obs> &v = m_timeline->rows(keys[row]);
    const int i = wtlabs::hitTest(v, ms, kHitPx * msPerPx, kMinW * msPerPx);
    return i >= 0 ? v[i].id : QString();
}

QVariantMap LabsLanesItem::rectOf(const QString &id) const
{
    QString key;
    int i = -1;
    if (!m_timeline || !m_timeline->locate(id, &key, &i))
        return {};
    const wtlabs::Obs &o = m_timeline->rows(key).at(i);
    const QRectF r = barRect(double(o.startMs), double(o.endMs), rowOf(key));
    return {{QStringLiteral("x"), r.x()}, {QStringLiteral("y"), r.y()},
            {QStringLiteral("w"), r.width()}, {QStringLiteral("h"), r.height()}};
}
