#include "Settings.h"

Settings::Settings(QObject *parent)
    : QObject(parent)
{
    m_defaultStreamHd = m_settings.value(QStringLiteral("video/defaultStreamHd"), false).toBool();
}

void Settings::setDefaultStreamHd(bool v)
{
    if (m_defaultStreamHd == v)
        return;
    m_defaultStreamHd = v;
    m_settings.setValue(QStringLiteral("video/defaultStreamHd"), v);
    emit defaultStreamHdChanged();
}
