#pragma once

#include <QObject>
#include <QSettings>
#include <QtQml/qqmlregistration.h>

// Global, persisted user preferences (QSettings — ~/.config/Cilex Vision/
// Watchtower.conf). Exposed to QML as a singleton. The full Preferences screen
// (S10) edits these; for now it carries the default stream quality.
class Settings : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // false = SD (substream, default — lighter/more responsive); true = HD (main).
    Q_PROPERTY(bool defaultStreamHd READ defaultStreamHd WRITE setDefaultStreamHd NOTIFY defaultStreamHdChanged)

public:
    explicit Settings(QObject *parent = nullptr);

    bool defaultStreamHd() const { return m_defaultStreamHd; }
    void setDefaultStreamHd(bool v);

signals:
    void defaultStreamHdChanged();

private:
    QSettings m_settings;
    bool m_defaultStreamHd = false;
};
