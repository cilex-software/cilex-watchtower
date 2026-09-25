// B1 isolated reproduction: does a render-less QVideoSink + toImage() emit
// "cannot create texture, Metal texture cache was released?" on macOS?
#include <QGuiApplication>
#include <QMediaPlayer>
#include <QVideoSink>
#include <QVideoFrame>
#include <QImage>
#include <QTimer>
#include <QUrl>
#include <cstdio>
#include <cstdlib>
#include <QElapsedTimer>
#include <algorithm>
#include <execinfo.h>
#include <private/qvideoframeconverter_p.h>

static int g_metal = 0; static bool g_bt = false; static QtMessageHandler g_prev = nullptr;
static void handler(QtMsgType t, const QMessageLogContext &c, const QString &m)
{
    if (m.contains(QLatin1String("Metal texture cache"))) {
        if (!g_metal++ ) {
            void *fr[40]; const int n = backtrace(fr, 40);
            fprintf(stderr, "---- first Metal warning: \"%s\" — backtrace:\n", qPrintable(m));
            backtrace_symbols_fd(fr, n, 2);
        }
        return;
    }
    if (g_prev) g_prev(t, c, m);
}

int main(int argc, char **argv)
{
    g_prev = qInstallMessageHandler(handler);
    QGuiApplication app(argc, argv);
    const QString mode = qEnvironmentVariable("MODE", QStringLiteral("toImage"));
    QMediaPlayer player; QVideoSink sink;               // bare sink: like FrameCache::harvestSink()
    player.setVideoSink(&sink);
    int frames = 0, imgOk = 0, imgNull = 0, mapOk = 0, mapFail = 0; bool described = false;
    QObject::connect(&sink, &QVideoSink::videoFrameChanged, [&](const QVideoFrame &f) {
        if (!f.isValid()) return;
        ++frames;
        if (!described) { described = true;
            printf("  first frame: %dx%d pixelFormat=%d planes=%d handleType=%d  sink.rhi()=%p\n",
                   f.width(), f.height(), int(f.pixelFormat()), f.planeCount(), int(f.handleType()), (void*)sink.rhi()); }
        if (mode == QLatin1String("toImage")) { const QImage i = f.toImage(); i.isNull() ? ++imgNull : ++imgOk; }
        else if (mode == QLatin1String("forceCpu")) { const QImage i = qImageFromVideoFrame(f, true); i.isNull() ? ++imgNull : ++imgOk; }
        else if (mode == QLatin1String("compare")) {
            QElapsedTimer tm; tm.start();
            const QImage a = f.toImage(); const qint64 ta = tm.nsecsElapsed(); tm.restart();
            const QImage b = qImageFromVideoFrame(f, true); const qint64 tb = tm.nsecsElapsed();
            static qint64 sumA = 0, sumB = 0; static long long hist[256] = {0}; static int maxd = 0; static long long npx = 0;
            sumA += ta; sumB += tb;
            const QImage ra = a.convertToFormat(QImage::Format_RGB32), rb = b.convertToFormat(QImage::Format_RGB32);
            for (int y = 0; y < ra.height(); y += 2) {
                const QRgb *pa = reinterpret_cast<const QRgb*>(ra.constScanLine(y)), *pb = reinterpret_cast<const QRgb*>(rb.constScanLine(y));
                for (int x = 0; x < ra.width(); x += 2) {
                    const int d = std::max({std::abs(qRed(pa[x])-qRed(pb[x])), std::abs(qGreen(pa[x])-qGreen(pb[x])), std::abs(qBlue(pa[x])-qBlue(pb[x]))});
                    ++hist[d]; maxd = std::max(maxd, d); ++npx;
                }
            }
            if (frames == 10 && qEnvironmentVariableIsSet("BARS")) {
                const QImage src(QStringLiteral("src.png"));
                const QImage s32 = src.convertToFormat(QImage::Format_RGB32), a32 = a.convertToFormat(QImage::Format_RGB32), b32 = b.convertToFormat(QImage::Format_RGB32);
                const int y = 150;   // top band: the seven 75% bars
                printf("  bar centre (x)   SOURCE (truth)      toImage (today)     forceCpu\n");
                for (int i = 0; i < 7; ++i) {
                    const int x = 160 + 171 * i + 85;   // smptehdbars: 1/8 margin then 7 bars of ~1280*3/4/7
                    const QRgb t = s32.pixel(x, y), p1 = a32.pixel(x, y), p2 = b32.pixel(x, y);
                    printf("  x=%4d  (%3d,%3d,%3d)   (%3d,%3d,%3d)   (%3d,%3d,%3d)\n", x, qRed(t), qGreen(t), qBlue(t),
                           qRed(p1), qGreen(p1), qBlue(p1), qRed(p2), qGreen(p2), qBlue(p2));
                }
                std::exit(0);
            }
            if (frames == 60) { a.save(QStringLiteral("f60_toImage.png")); b.save(QStringLiteral("f60_forceCpu.png"));
                printf("  f60 colorspace=%d range=%d transfer=%d mirrored=%d rotation=%d\n", int(f.surfaceFormat().colorSpace()),
                       int(f.surfaceFormat().colorRange()), int(f.surfaceFormat().colorTransfer()), int(f.mirrored()), int(f.rotation())); }
            if (frames == 180) {
                long long c = 0; int p50 = 0, p99 = 0, p999 = 0;
                for (int d = 0; d < 256; ++d) { c += hist[d]; if (!p50 && c >= npx*0.50) p50 = d; if (!p99 && c >= npx*0.99) p99 = d; if (!p999 && c >= npx*0.999) p999 = d; }
                printf("  per-pixel max channel diff over %lld sampled px: p50=%d p99=%d p99.9=%d max=%d  | share with diff 0: %.1f%%  <=2: %.1f%%\n",
                       npx, p50, p99, p999, maxd, 100.0*hist[0]/npx, 100.0*(hist[0]+hist[1]+hist[2])/npx);
                printf("  mean time/frame: toImage (GPU upload+readback) %.2f ms   forceCpu %.2f ms\n", sumA/180/1e6, sumB/180/1e6);
            }
            const bool same = a.size() == b.size() && a.convertToFormat(QImage::Format_RGB32) == b.convertToFormat(QImage::Format_RGB32);
            same ? ++imgOk : ++imgNull;
            if (!same && imgNull == 1) printf("  first mismatch: a=%dx%d fmt%d  b=%dx%d fmt%d\n", a.width(), a.height(), int(a.format()), b.width(), b.height(), int(b.format()));
        }
        else if (mode == QLatin1String("map")) { QVideoFrame c(f); if (c.map(QVideoFrame::ReadOnly)) { ++mapOk; c.unmap(); } else ++mapFail; }
        else { fprintf(stderr, "UNKNOWN MODE %s\n", qPrintable(mode)); std::exit(3); }
    });
    auto done = [&](const char *why) {
        printf("  MODE=%-8s %-11s frames=%d  metal_warnings=%d  toImage ok/null=%d/%d  map ok/fail=%d/%d\n",
               qPrintable(mode), why, frames, g_metal, imgOk, imgNull, mapOk, mapFail);
        app.quit();
    };
    QObject::connect(&player, &QMediaPlayer::mediaStatusChanged, [&](QMediaPlayer::MediaStatus s) {
        if (s == QMediaPlayer::EndOfMedia) done("end");
        else if (s == QMediaPlayer::InvalidMedia) done("INVALID");
    });
    QObject::connect(&player, &QMediaPlayer::errorOccurred, [&](QMediaPlayer::Error e, const QString &es) {
        printf("  player error %d: %s\n", int(e), qPrintable(es)); });
    QObject::connect(&player, &QMediaPlayer::mediaStatusChanged, [&](QMediaPlayer::MediaStatus s) {
        printf("  status=%d\n", int(s)); });
    QObject::connect(&player, &QMediaPlayer::playbackStateChanged, [&](QMediaPlayer::PlaybackState s) {
        printf("  playback=%d\n", int(s)); });
    QTimer::singleShot(20000, &app, [&] { done("TIMEOUT"); });
    player.setSource(QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1])));
    player.play();
    return app.exec();
}
