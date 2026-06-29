// Minimal standalone reproducer for the QtMultimedia FFmpeg-backend per-source-change memory leak.
//
// Switching QMediaPlayer media with a VIDEO OUTPUT attached leaks ~one decoded frame + decoder context per
// setSource(): the prior decode pipeline's CPU buffers (heap + anonymous mmap) are not released while an
// output holds frames across the switch. A BARE QMediaPlayer (no output, frames dropped) only plateaus — so
// the leak requires an attached output (QVideoWidget here; QML VideoOutput in our app). NOT the GPU/VA-API
// surface pool (those are freed), reproduces under software decode, and persists Qt 6.8.3 -> 6.12.0.
//
// Build:  cmake -S . -B build -DCMAKE_PREFIX_PATH=<your Qt>/gcc_64 && cmake --build build
// Run (needs a display):  ./build/qtmediaplayer_leak <video-file-or-url> [iterations=200]
//   any decodable video reproduces it; a 2560x1440 clip gives the clearest signal. Generate one with:
//     ffmpeg -f lavfi -i testsrc=size=2560x1440:rate=15:duration=20 -c:v libx264 -pix_fmt yuv420p out.mp4
//   Pass --sink to use a bare QVideoSink instead (shows the plateau, i.e. the leak does NOT reproduce).
//
// Watch the printed RSS: with the widget it climbs ~linearly with the open count; with --sink it plateaus.

#include <QApplication>
#include <QMediaPlayer>
#include <QVideoWidget>
#include <QVideoSink>
#include <QTimer>
#include <QUrl>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QByteArrayList>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static long rssMb() {
    QFile f(QStringLiteral("/proc/self/statm"));            // field 2 = resident pages
    if (!f.open(QIODevice::ReadOnly)) return -1;
    const QByteArrayList p = f.readAll().simplified().split(' ');
    if (p.size() < 2) return -1;
    return (p[1].toLong() * (sysconf(_SC_PAGESIZE) / 1024)) / 1024;
}

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    bool bareSink = false, uniqueUrls = false; const char *path = nullptr; int N = 200;
    for (int a = 1; a < argc; ++a) {
        if (!strcmp(argv[a], "--sink")) bareSink = true;
        else if (!strcmp(argv[a], "--unique")) uniqueUrls = true;   // distinct URL per open (mirrors per-session sids)
        else if (!path) path = argv[a];
        else N = atoi(argv[a]);
    }
    if (!path) { fprintf(stderr, "usage: %s [--sink] [--unique] <video-file|dir|url> [iterations=200]\n", argv[0]); return 2; }
    // A directory => cycle through its files each open (distinct CONTENT per open, like real footage).
    QList<QUrl> urls;
    QFileInfo fi(QString::fromLocal8Bit(path));
    if (fi.isDir()) { const QStringList fs = QDir(fi.absoluteFilePath()).entryList(QDir::Files, QDir::Name);
        for (const QString &f : fs) urls << QUrl::fromLocalFile(QDir(fi.absoluteFilePath()).absoluteFilePath(f)); }
    else urls << QUrl::fromUserInput(QString::fromLocal8Bit(path));
    if (urls.isEmpty()) { fprintf(stderr, "no media\n"); return 2; }
    printf("cycling %lld source(s)\n", (long long)urls.size());

    QMediaPlayer player;
    QVideoWidget widget;
    QVideoSink sink;
    if (bareSink) { player.setVideoSink(&sink); }           // control: no output -> only plateaus
    else { widget.resize(640, 360); widget.show(); player.setVideoOutput(&widget); }  // faithful: an output
    QObject::connect(&player, &QMediaPlayer::errorOccurred, [](QMediaPlayer::Error e, const QString &s) {
        fprintf(stderr, "  media error %d: %s\n", int(e), qPrintable(s)); });

    const long rss0 = rssMb();
    static int i = 0;
    QTimer loop;
    QObject::connect(&loop, &QTimer::timeout, &app, [&]() {
        if (i >= N) {
            const long d = rssMb() - rss0;
            printf("DONE (%s): %d opens, RSS %ld -> %ld MB  (+%ld MB, ~%.2f MB/open)\n",
                   bareSink ? "bare sink" : "video widget", i, rss0, rssMb(), d, double(d) / (i ? i : 1));
            fflush(stdout); app.quit(); return;
        }
        if (i % 10 == 0) { printf("open %3d  RSS=%ld MB\n", i, rssMb()); fflush(stdout); }
        player.stop();
        player.setSource(QUrl());                            // clear  (a real client switching recordings)
        QUrl u = urls.at(i % urls.size());                   // cycle the sources (distinct content per open)
        if (uniqueUrls) u.setQuery(QStringLiteral("i=%1").arg(i));
        player.setSource(u);                                 // new source == a fresh decode pipeline
        player.play();
        ++i;
    });
    loop.start(1000);                                        // ~1 s/open: enough to start decoding + render
    return app.exec();
}
