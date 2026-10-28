#pragma once
#include <QObject>
#include <QVariantMap>

// Evidence ingress only. Persistence and privileged synchronization belong to
// CameraAvailabilityService and its single worker.
class AvailabilityObservationBus : public QObject {
    Q_OBJECT
public:
    static AvailabilityObservationBus *instance();
    static void publish(const QVariantMap &observation);
    Q_INVOKABLE void publishObservation(const QVariantMap &observation) { publish(observation); }
signals:
    void observationReady(const QVariantMap &observation);
private:
    explicit AvailabilityObservationBus(QObject *parent) : QObject(parent) {}
};
