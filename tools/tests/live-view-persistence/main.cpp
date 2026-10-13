#include "Settings.h"
#include "SavedViewModel.h"

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QScopedPointer>
#include <QSettings>
#include <QTemporaryDir>
#include <cstdio>

static int failures = 0;
static void check(bool condition, const char *label)
{
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", label);
    if (!condition) ++failures;
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName("WatchtowerIsolatedTests");
    QCoreApplication::setApplicationName("LiveViewPersistence");
    QSettings::setDefaultFormat(QSettings::IniFormat);
    qunsetenv("WT_DEMO");
    QTemporaryDir temporary;
    const bool probe = app.arguments().size() == 2;
    const QString path = probe ? app.arguments().at(1) : temporary.path();
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, path);
    QSettings::setPath(QSettings::IniFormat, QSettings::SystemScope, path);

    Settings settings;
    const QStringList sparse = {"cam-a", "", "cam-outside-group", "", ""};
    const QStringList bridgeExpected = {"cam-a", "cam-from-qml", "", "", ""};
    if (probe) {
        check(settings.hasLiveCells("street"), "explicit cells survive a separate process");
        check(settings.liveCells("street") == sparse, "holes and outside-group camera survive a separate process");
        check(settings.liveCells("qml-bridge") == bridgeExpected,
              "sparse membership edited through the real QML bridge reaches disk");
        return failures ? 1 : 0;
    }

    check(temporary.isValid(), "isolated settings directory created");
    check(!settings.hasLiveCells("street"), "absence retains legacy dynamic membership");
    settings.setLiveLayout("street", {"cam-b", "cam-a"});
    settings.setLiveCells("street", sparse);
    check(settings.hasLiveCells("street") && settings.liveCells("street") == sparse,
          "explicit membership retains internal and trailing holes");
    check(!settings.hasLiveCells("entrances"), "editing one group view leaves another untouched");
    check(settings.liveLayout("street") == QStringList({"cam-b", "cam-a"}),
          "new membership does not rewrite legacy ordering");

    settings.setLiveCells("qml-bridge", sparse);
    QQmlEngine engine;
    engine.rootContext()->setContextProperty("Settings", &settings);
    QQmlComponent component(&engine);
    component.setData(R"(
        import QtQml
        QtObject {
            property bool completed: false
            property bool originalUnchanged: false
            Component.onCompleted: {
                var original = Settings.liveCells("qml-bridge");
                var cells = original.slice().map(function(id) { return id; });
                cells[1] = "cam-from-qml";
                cells[2] = "";
                originalUnchanged = original[1] === "" && original[2] === "cam-outside-group";
                Settings.setLiveCells("qml-bridge", cells);
                completed = true;
            }
        }
    )", QUrl::fromLocalFile(path + "/live-view-persistence.qml"));
    QScopedPointer<QObject> bridge(component.create());
    if (component.isError()) std::fprintf(stderr, "%s", qPrintable(component.errorString()));
    check(bridge && bridge->property("completed").toBool(),
          "real QStringList invokable results support QML slice and map");
    check(bridge && bridge->property("originalUnchanged").toBool(),
          "editing a sliced QML cell list leaves the original sequence intact");
    check(settings.liveCells("qml-bridge") == bridgeExpected,
          "QML can fill and clear cells through the actual Settings invokable");

    QProcess child;
    child.start(app.applicationFilePath(), {path});
    check(child.waitForFinished(10000) && child.exitCode() == 0,
          "cell changes reach disk before normal shutdown");
    std::printf("%s", child.readAllStandardOutput().constData());

    settings.setLiveCells("entrances", {"", "cam-c", "cam-c", "cam-d", "cam-d"});
    check(settings.liveCells("entrances") == QStringList({"", "cam-c", "", "cam-d", ""}),
          "duplicate IDs become holes without shifting other cells or leading holes");
    settings.setLiveCells("empty", {});
    check(settings.hasLiveCells("empty") && settings.liveCells("empty").isEmpty(),
          "zero cameras is an explicit empty view");
    settings.clearLiveCells("street");
    check(!settings.hasLiveCells("street") && settings.liveLayout("street").size() == 2,
          "opening a legacy view can clear cells while preserving old ordering");
    settings.setLiveCells("street", sparse);
    settings.clearLiveLayout("street");
    check(!settings.hasLiveCells("street") && settings.liveLayout("street").isEmpty(),
          "reset removes explicit membership and legacy arrangement");

    QSettings raw;
    QJsonObject legacy{{"id", "legacy"}, {"name", "Legacy view"}, {"layoutSize", 4},
                       {"groupId", "street"}, {"statusFilter", "online"}};
    raw.setValue("savedViews", QJsonDocument(QJsonArray{legacy}).toJson(QJsonDocument::Compact));
    SavedViewModel views;
    const auto old = views.list().at(0).toMap();
    check(!old.value("hasCells").toBool() && old.value("layout").toString() == "4",
          "pre-membership saved views remain readable and dynamic");
    views.saveCurrent("Sparse view", false, "5x7", "online", "alpha", "street", "Street", "", true, sparse);
    views.saveCurrent("Empty view", false, "5x7", "", "alpha", "street", "Street", "", true, {});
    views.saveCurrent("Unique view", false, "4", "", "live", "street", "Street", "", true,
                      {"cam-a", "cam-a", "cam-b"});

    SavedViewModel loaded;
    const auto saved = loaded.list();
    check(saved.size() == 4, "new views persist alongside the legacy view");
    check(saved.at(0).toMap().value("cells").toStringList() == QStringList({"cam-a", "", "cam-b"}),
          "saved views reject duplicate membership while retaining slots");
    check(saved.at(1).toMap().value("hasCells").toBool()
          && saved.at(1).toMap().value("cells").toStringList().isEmpty(),
          "an empty saved view stays distinct from an old group view");
    const auto restored = saved.at(2).toMap();
    check(restored.value("cells").toStringList() == sparse
          && restored.value("groupId").toString() == "street"
          && restored.value("statusFilter").toString() == "online"
          && restored.value("sortMode").toString() == "alpha",
          "same-group saved views independently retain membership, holes, filter and sort");
    check(!saved.at(3).toMap().value("hasCells").toBool(), "saving new views does not migrate an old view implicitly");
    check(loaded.data(loaded.index(2), SavedViewModel::CellsRole).toStringList() == sparse,
          "list-model roles expose the same captured membership");
    return failures ? 1 : 0;
}
