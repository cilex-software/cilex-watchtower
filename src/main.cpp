#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QFontDatabase>
#include <QImage>
#include <QTimer>
#include <QDebug>

namespace {

// Load the self-hosted, bundled fonts (OFL) so the families are available to
// every QML file without a per-file FontLoader.
void loadBundledFonts()
{
    const QStringList files = {
        QStringLiteral(":/fonts/SpaceGrotesk-Variable.ttf"),
        QStringLiteral(":/fonts/JetBrainsMono-Regular.ttf"),
        QStringLiteral(":/fonts/JetBrainsMono-Medium.ttf"),
        QStringLiteral(":/fonts/JetBrainsMono-SemiBold.ttf"),
    };
    for (const QString &f : files) {
        if (QFontDatabase::addApplicationFont(f) < 0)
            qWarning() << "Watchtower: failed to load bundled font" << f;
    }
}

// Dev/verification hook: if WT_SCREENSHOT=<path> is set, grab the root window to
// that PNG once it has rendered, then quit. WT_SCREENSHOT_MS overrides the delay.
void maybeArmScreenshot(QQmlApplicationEngine &engine)
{
    const QByteArray path = qgetenv("WT_SCREENSHOT");
    if (path.isEmpty() || engine.rootObjects().isEmpty())
        return;
    auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (!win)
        return;
    int delayMs = qEnvironmentVariableIntValue("WT_SCREENSHOT_MS");
    if (delayMs <= 0)
        delayMs = 900;
    QTimer::singleShot(delayMs, win, [win, path]() {
        const QImage img = win->grabWindow();
        if (!img.isNull() && img.save(QString::fromLocal8Bit(path)))
            qInfo() << "Watchtower: screenshot saved" << path << img.size();
        else
            qWarning() << "Watchtower: screenshot failed" << path;
        QCoreApplication::quit();
    });
}

} // namespace

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("Watchtower"));
    QGuiApplication::setApplicationDisplayName(QStringLiteral("Watchtower"));
    QGuiApplication::setOrganizationName(QStringLiteral("Cilex Vision"));

    // QtMultimedia (GStreamer backend, VA-API HW decode) renders video frames
    // through the scene graph; pin the OpenGL RHI backend before any window.
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    // Unstyled "Basic" Controls style so our design tokens fully dictate the look.
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    loadBundledFonts();

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed,
        &app, []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);

    // Optional camera to focus in the video test (by IP); empty -> first camera.
    engine.rootContext()->setContextProperty("wtTestIp", qEnvironmentVariable("WT_TEST_IP"));

    // WT_VIDEOTEST loads the single-stream video test instead of the app shell.
    const QString entry = qEnvironmentVariableIsSet("WT_VIDEOTEST")
        ? QStringLiteral("qrc:/qt/qml/Watchtower/qml/VideoTest.qml")
        : QStringLiteral("qrc:/qt/qml/Watchtower/qml/Main.qml");
    engine.load(QUrl(entry));

    maybeArmScreenshot(engine);

    return app.exec();
}
