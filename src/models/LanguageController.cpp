#include "LanguageController.h"

#include <QCoreApplication>
#include <QQmlApplicationEngine>
#include <QTranslator>
#include <QLocale>
#include <QSettings>
#include <QDebug>

namespace {
const char *kSettingsKey = "ui/language";
}

LanguageController::LanguageController(QQmlApplicationEngine *engine, QObject *parent)
    : QObject(parent), m_engine(engine)
{
    // OS default. On Linux this is the LANG/locale; on Windows the display language.
    m_systemLanguage = normalize(QLocale::system().name());   // e.g. "ru_RU" -> "ru"

    // An explicit operator choice (persisted) overrides the OS default. Absent => follow OS.
    QSettings s;
    if (s.contains(kSettingsKey)) {
        m_language = normalize(s.value(kSettingsKey).toString());
        m_followingSystem = false;
    } else {
        m_language = m_systemLanguage;
        m_followingSystem = true;
    }
}

QString LanguageController::normalize(const QString &code)
{
    // Only EN/RU are shipped; anything else falls back to English.
    return code.startsWith(QStringLiteral("ru"), Qt::CaseInsensitive) ? QStringLiteral("ru")
                                                                      : QStringLiteral("en");
}

QVariantList LanguageController::availableLanguages() const
{
    return {
        QVariantMap{{"code", "en"}, {"name", "English"},  {"nativeName", "English"}},
        QVariantMap{{"code", "ru"}, {"name", "Russian"},  {"nativeName", QString::fromUtf8("Русский")}},
    };
}

void LanguageController::applyInitial()
{
    // Dev: WT_LANG=ru|en forces the UI language for this run (screenshot
    // verification in both locales) without touching the persisted setting.
    const QString envLang = qEnvironmentVariable("WT_LANG");
    if (!envLang.isEmpty()) { apply(normalize(envLang)); return; }
    apply(m_language);
}

void LanguageController::setLanguage(const QString &code)
{
    const QString norm = normalize(code);
    QSettings().setValue(kSettingsKey, norm);   // persist the explicit override
    m_followingSystem = false;
    if (norm != m_language || m_translator == nullptr)
        apply(norm);
    else
        emit languageChanged();                  // followingSystem flipped
}

void LanguageController::useSystemLanguage()
{
    QSettings().remove(kSettingsKey);            // clear the override -> follow OS again
    m_followingSystem = true;
    apply(m_systemLanguage);
}

void LanguageController::apply(const QString &code)
{
    // Remove any previously installed translator first (so RU->EN reverts to the source strings).
    if (m_translator) {
        QCoreApplication::removeTranslator(m_translator);
        delete m_translator;
        m_translator = nullptr;
    }

    // Load the embedded .qm for every language, English included
    // (qt_add_translations puts them at :/i18n/).
    //
    // English IS the source language, so its catalogue is almost entirely
    // unfinished and lrelease drops those entries — the source literal is used,
    // exactly as before. It is loaded anyway for the one thing a source-language
    // catalogue is genuinely needed for: PLURALS. Without a catalogue Qt cannot
    // choose a form, it only substitutes %n into the source, so `%n segment(s)`
    // printed literally as "465 segment(s)" on the Playback coverage readout
    // (observed on screen, 2026-08-10). The EN catalogue carries the two forms.
    auto *tr = new QTranslator(this);
    if (tr->load(QStringLiteral("watchtower_") + code, QStringLiteral(":/i18n"))) {
        QCoreApplication::installTranslator(tr);
        m_translator = tr;
    } else {
        if (code != QStringLiteral("en"))
            qWarning() << "[i18n] no translation embedded for" << code << "— falling back to English";
        delete tr;
    }

    m_language = code;
    // Live re-evaluation of every qsTr() binding in the loaded QML (no restart).
    if (m_engine)
        m_engine->retranslate();
    emit languageChanged();
}
