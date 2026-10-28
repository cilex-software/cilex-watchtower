#include "AvailabilityObservationBus.h"
#include <QCoreApplication>
#include <QPointer>
#include <QThread>

AvailabilityObservationBus *AvailabilityObservationBus::instance()
{
    static QPointer<AvailabilityObservationBus> bus;
    // main constructs this before any model or media worker is started.
    if (!bus && qApp && QThread::currentThread() == qApp->thread())
        bus = new AvailabilityObservationBus(qApp);
    return bus;
}

void AvailabilityObservationBus::publish(const QVariantMap &observation)
{
    if (!qApp || QCoreApplication::closingDown()) return;
    QMetaObject::invokeMethod(qApp, [observation] {
        if (auto *bus = instance()) emit bus->observationReady(observation);
    }, Qt::QueuedConnection);
}
