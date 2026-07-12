// Standalone deterministic reproducer for the retained-blank-m_swFrame defect
// (see ../2026-07-12-qffmpegvideobuffer-blank-swframe.md and
// third_party/qt-patches/6.12/0001-*.patch).
//
// Plays a local hardware-decodable clip through QMediaPlayer → QVideoSink and
// calls toImage() on every delivered frame. Pair it with the LD_PRELOAD seam
// (../tools/xfer-interpose.c) forcing one av_hwframe_transfer_data failure:
//
//   UNPATCHED Qt 6.12 : the toImage() of the poisoned frame SIGSEGVs inside
//                       qImageFromVideoFrame (texture path maps first and
//                       fails gracefully; the CPU-converter fallback maps
//                       second, gets fake-success null planes, crashes).
//   PATCHED Qt        : that toImage() returns a null image gracefully, AND
//                       the explicit second map probe below re-attempts the
//                       transfer (watch for the seam's "first REAL transfer
//                       after forced window" line) — failure is not sticky.
//
// Exit codes: 0 = completed (patched behavior), crash = unpatched defect.
//
// Build & run: see README.md next to this file.

#include <QGuiApplication>
#include <QMediaPlayer>
#include <QVideoSink>
#include <QVideoFrame>
#include <QTimer>
#include <cstdio>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    if (argc < 2) {
        fprintf(stderr, "usage: qvf-repro <hw-decodable-video-file> [frames-to-run]\n");
        return 2;
    }
    const int maxFrames = argc > 2 ? atoi(argv[2]) : 400;

    QMediaPlayer player;
    QVideoSink sink;
    player.setVideoSink(&sink);

    int frames = 0, nullImages = 0, retryProbes = 0;
    QObject::connect(&sink, &QVideoSink::videoFrameChanged, &sink,
                     [&](const QVideoFrame &frame) {
        if (!frame.isValid())
            return;
        ++frames;
        const QImage img = frame.toImage();   // crashes here on unpatched Qt when poisoned
        if (img.isNull()) {
            ++nullImages;
            fprintf(stderr, "[REPRO] frame %d: toImage null (graceful map failure)\n", frames);
            // Patched-Qt retry semantics: a later map of the SAME buffer must
            // re-attempt the transfer instead of returning fake success.
            QVideoFrame probe(frame);
            if (probe.map(QVideoFrame::ReadOnly)) {
                const bool valid = probe.planeCount() > 0 && probe.bits(0) != nullptr;
                fprintf(stderr, "[REPRO] frame %d: second map -> %s\n", frames,
                        valid ? "VALID planes (transfer retried & succeeded)"
                              : "FAKE SUCCESS with null planes (DEFECT PRESENT)");
                probe.unmap();
                if (!valid)
                    ++retryProbes;   // defect signature reached without crashing (0002-only build)
            } else {
                fprintf(stderr, "[REPRO] frame %d: second map failed gracefully (retry attempted)\n", frames);
            }
        }
        if (frames >= maxFrames)
            app.quit();
    });
    QObject::connect(&player, &QMediaPlayer::mediaStatusChanged, &app,
                     [&](QMediaPlayer::MediaStatus st) {
        if (st == QMediaPlayer::EndOfMedia || st == QMediaPlayer::InvalidMedia)
            app.quit();
    });

    player.setSource(QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1])));
    player.play();
    QTimer::singleShot(120000, &app, &QCoreApplication::quit);   // hard stop

    const int rc = app.exec();
    fprintf(stderr, "[REPRO] done: frames=%d nullImages=%d fakeSuccessProbes=%d -> %s\n",
            frames, nullImages, retryProbes,
            retryProbes ? "DEFECT-SIGNATURE-OBSERVED" : "CLEAN");
    return rc;
}
