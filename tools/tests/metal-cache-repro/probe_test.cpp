// Exercises the REPO's MetalCacheProbe.cpp exactly as the app compiles it.
#include "MetalCacheProbe.h"
#include <QGuiApplication>
#include <QMediaPlayer>
#include <QVideoSink>
#include <QVideoFrame>
#include <QImage>
#include <QTimer>
#include <QUrl>
#include <cstdio>

static int g_metalPassed = 0, g_b1Lines = 0;
static void downstream(QtMsgType, const QMessageLogContext &, const QString &m)   // stands in for FlightRecorder
{
    if (m.contains(QLatin1String("Metal texture cache was released"))) { ++g_metalPassed; return; }
    if (m.startsWith(QLatin1String("[MTLCACHE]"))) { ++g_b1Lines; if (g_b1Lines <= 14 || !m.startsWith(QLatin1String("[MTLCACHE]   #"))) printf("  | %s\n", qPrintable(m.left(170))); }
}

int main(int argc, char **argv)
{
    qInstallMessageHandler(downstream);
    MetalCacheProbe::install();                                 // in FRONT of "the recorder", as in main.cpp
    QGuiApplication app(argc, argv);
    MetalCacheProbe::startPeriodic(&app);
    const bool scoped = qEnvironmentVariableIsSet("SCOPED");
    QMediaPlayer player; QVideoSink sink; player.setVideoSink(&sink);
    MetalCacheProbe::noteSink("test harvest (render-less)", &sink);
    int frames = 0;
    QObject::connect(&sink, &QVideoSink::videoFrameChanged, [&](const QVideoFrame &f) {
        if (!f.isValid()) return; ++frames;
        if (scoped) { MetalCacheProbe::ExpectedScope s("test harvest"); (void)f.toImage(); }
        else (void)f.toImage();
    });
    QObject::connect(&player, &QMediaPlayer::mediaStatusChanged, [&](QMediaPlayer::MediaStatus s) {
        if (s != QMediaPlayer::EndOfMedia) return;
        printf("  end of media: frames=%d — waiting 16 s for the idle-episode summary...\n", frames);
        QTimer::singleShot(16000, &app, [&] {
            printf("  RESULT scoped=%d frames=%d  Metal lines passed downstream=%d  [MTLCACHE] lines=%d\n",
                   scoped, frames, g_metalPassed, g_b1Lines);
            app.quit(); });
    });
    player.setSource(QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1]))); player.play();
    return app.exec();
}
