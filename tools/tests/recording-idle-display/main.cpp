#include "CameraStatus.h"
#include "RecordingHealth.h"
#include <QQmlContext>
#include <QQmlEngine>
#include <QtQuickTest/quicktest.h>

class FixtureSettings : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool badgeTimers READ badgeTimers CONSTANT)
public:
    bool badgeTimers() const { return false; }
};

class HealthNormalizer : public QObject
{
    Q_OBJECT
public:
    Q_INVOKABLE QVariantMap normalize(const QVariantMap &wire, qint64 now) const
    {
        return wt::recordingHealth::normalize(QJsonObject::fromVariantMap(wire), now);
    }
};

class Setup : public QObject
{
    Q_OBJECT
    FixtureSettings settings;
    HealthNormalizer normalizer;
public slots:
    void applicationAvailable()
    {
        qmlRegisterUncreatableType<CameraStatus>("Watchtower", 1, 0, "CameraStatus", "Enums only");
        qmlRegisterSingletonInstance("Watchtower", 1, 0, "Settings", &settings);
        const auto directory = qEnvironmentVariable("WT_RECORDING_TEST_QML_DIR", PRODUCT_QML_DIR);
        qmlRegisterSingletonType(QUrl::fromLocalFile(directory + "/Theme.qml"),
                                 "Watchtower", 1, 0, "Theme");
    }
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        engine->rootContext()->setContextProperty("productQmlDirectory",
            QUrl::fromLocalFile(qEnvironmentVariable("WT_RECORDING_TEST_QML_DIR", PRODUCT_QML_DIR) + "/"));
        engine->rootContext()->setContextProperty("healthNormalizer", &normalizer);
        engine->rootContext()->setContextProperty("outputDirectory", qEnvironmentVariable("WT_RECORDING_TEST_OUTPUT"));
    }
};

QUICK_TEST_MAIN_WITH_SETUP(recording_idle_display, Setup)
#include "main.moc"
