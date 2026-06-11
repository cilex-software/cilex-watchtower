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
#include <QtQml/qqml.h>
#include <QProcessEnvironment>
#include <gst/gst.h>
#include <sys/resource.h>

#include "AuthController.h"

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

    // Native (FreeType-hinted) text rendering — crisper for this dense UI than
    // the default distance-field rendering, which can look soft at small sizes.
    QQuickWindow::setTextRenderType(QQuickWindow::NativeTextRendering);

    // Unstyled "Basic" Controls style so our design tokens fully dictate the look.
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    loadBundledFonts();

    // Raise the file-descriptor soft limit to the hard limit so transient bursts
    // of GStreamer pipeline create/destroy (rapid layout switches → many sockets
    // + pipe pairs in flight) don't hit a 1024-fd default the launcher may have
    // imposed. RtspVideoSource also caps concurrent teardowns; this is belt-
    // and-suspenders against environment-imposed limits.
    {
        struct rlimit rl;
        if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
            rl.rlim_cur = rl.rlim_max;
            setrlimit(RLIMIT_NOFILE, &rl);
        }
    }

    // Initialize GStreamer for the opt-in low-latency RTSP path (RtspVideoSource).
    // Idempotent — QtMultimedia's backend also inits it for the default path.
    gst_init(nullptr, nullptr);

    // Session owner + the one shared network manager every model uses. Created
    // before the engine loads so AuthController::instance() is valid when the
    // QML-instantiated models are constructed.
    auto *auth = new AuthController(&app);
    auth->restoreSession();
    // Opt-in dev convenience: WT_CV_AUTOLOGIN skips the login screen using the
    // WT_CV_USER/WT_CV_PASS service creds (previous always-on behaviour).
    if (qEnvironmentVariableIsSet("WT_CV_AUTOLOGIN") && !auth->authenticated()) {
        const auto env = QProcessEnvironment::systemEnvironment();
        auth->loginWithPassword(env.value("WT_CV_URL"),
                                env.value("WT_CV_USER", "admin"),
                                env.value("WT_CV_PASS", "admin"));
    }

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed,
        &app, []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);

    // Exposed to QML as a context property (not a module type) so it does not
    // interfere with the qt_add_qml_module type registry.
    engine.rootContext()->setContextProperty("AuthController", auth);

    // Optional camera to focus in the video test (by IP); empty -> first camera.
    engine.rootContext()->setContextProperty("wtTestIp", qEnvironmentVariable("WT_TEST_IP"));
    // Optional initial section (dev: WT_SECTION=groups|live|...).
    engine.rootContext()->setContextProperty("wtSection", qEnvironmentVariable("WT_SECTION"));
    // Optional camera to open focused on boot, by IP (dev: WT_FOCUS_IP=192.168.1.108).
    engine.rootContext()->setContextProperty("wtFocusIp", qEnvironmentVariable("WT_FOCUS_IP"));
    // Optional camera to open in Playback on boot, by IP (dev: WT_PLAYBACK_IP=192.168.1.106).
    engine.rootContext()->setContextProperty("wtPlaybackIp", qEnvironmentVariable("WT_PLAYBACK_IP"));
    // Optional: open WT_PLAYBACK_IP's playback on a specific day (dev:
    // WT_PLAYBACK_DAY=2026-05-28), or at a local instant when a "T" is present
    // (dev: WT_PLAYBACK_DAY=2026-06-07T00:44:10 → that day, seeked there −15s).
    engine.rootContext()->setContextProperty("wtPlaybackDay", qEnvironmentVariable("WT_PLAYBACK_DAY"));
    // Optional: open synchronized wall playback on boot over the live page's cameras
    // (dev: WT_WALL_DAY=2026-05-29, or WT_WALL_DAY=live for the last hour).
    engine.rootContext()->setContextProperty("wtWallDay", qEnvironmentVariable("WT_WALL_DAY"));
    // Live RTSP path: low-latency by default (custom GStreamer pipeline →
    // QVideoSink, rtspsrc latency≈150 ms). QMediaPlayer's default 2000 ms
    // jitter buffer is unusable for monitoring — proven so during the spike.
    // WT_LEGACY=1 falls back to the QMediaPlayer path for A/B comparison or
    // emergency fallback if rtspsrc tuning misbehaves. WT_LOWLATENCY is still
    // honored as a no-op for old muscle memory / scripts.
    const bool useLegacy = qEnvironmentVariableIsSet("WT_LEGACY");
    engine.rootContext()->setContextProperty("wtLowLatency", !useLegacy);
    // RTSP jitter-buffer override for the low-latency path. Default 500 ms (see
    // VideoSurface.qml). Lower = fresher live, more prone to green-frame resets
    // under packet loss; higher = steadier, more glass-to-glass lag.
    engine.rootContext()->setContextProperty("wtRtspLatencyMs",
        qEnvironmentVariableIntValue("WT_RTSP_LATENCY_MS"));
    // Build identifier (short git SHA), shown on the login screen so a relaunch
    // confirms which binary is running. Set via CMake compile definition.
#ifdef WT_GIT_SHA
    engine.rootContext()->setContextProperty("wtBuild", QStringLiteral(WT_GIT_SHA));
#else
    engine.rootContext()->setContextProperty("wtBuild", QStringLiteral("dev"));
#endif

    // WT_VIDEOTEST loads the single-stream video test instead of the app shell.
    const QString entry = qEnvironmentVariableIsSet("WT_VIDEOTEST")
        ? QStringLiteral("qrc:/qt/qml/Watchtower/qml/VideoTest.qml")
        : QStringLiteral("qrc:/qt/qml/Watchtower/qml/Main.qml");
    engine.load(QUrl(entry));

    maybeArmScreenshot(engine);

    return app.exec();
}
