#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>

class QQmlApplicationEngine;
class QTranslator;

// UI language controller (EN/RU). Default follows the OS language (QLocale::system());
// the operator's explicit choice (Preferences → Time & language) overrides it and persists
// in QSettings. Switching is LIVE — swap the QTranslator + QQmlApplicationEngine::retranslate()
// re-evaluates every qsTr() binding without a restart. Cross-platform (Linux + Windows): the
// .qm files are embedded in the binary via qt_add_translations, and QLocale::system() reflects
// the Windows display language too.
class LanguageController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString language READ language NOTIFY languageChanged)          // effective code: "en" | "ru"
    Q_PROPERTY(QString systemLanguage READ systemLanguage CONSTANT)            // detected OS default
    Q_PROPERTY(bool followingSystem READ followingSystem NOTIFY languageChanged) // no explicit override set
public:
    explicit LanguageController(QQmlApplicationEngine *engine, QObject *parent = nullptr);

    QString language() const { return m_language; }
    QString systemLanguage() const { return m_systemLanguage; }
    bool followingSystem() const { return m_followingSystem; }

    // EN/RU + native names, for the Preferences selector.
    Q_INVOKABLE QVariantList availableLanguages() const;
    // Set the UI language ("en"/"ru"): persists the override + applies live.
    Q_INVOKABLE void setLanguage(const QString &code);
    // Revert to the OS default (clears the stored override), applies live.
    Q_INVOKABLE void useSystemLanguage();

    // Install the initial translator BEFORE engine.load() so the first frame is translated.
    void applyInitial();

signals:
    void languageChanged();

private:
    static QString normalize(const QString &code);   // map anything → "en"/"ru"
    void apply(const QString &code);                 // swap translator + retranslate

    QQmlApplicationEngine *m_engine = nullptr;
    QTranslator *m_translator = nullptr;
    QString m_language;         // effective ("en"/"ru")
    QString m_systemLanguage;   // OS default ("en"/"ru")
    bool m_followingSystem = true;
};
