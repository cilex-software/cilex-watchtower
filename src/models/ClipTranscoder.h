#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QProcess>
#include <functional>

// Offline, client-side clip transcoder (ffmpeg via QProcess). Used to post-process a
// downloaded export: optionally downscale to a smaller rendition (the compression
// ladder) and/or burn in the camera-name + the per-frame footage wall-clock timestamp.
//
// Why ffmpeg rather than the GStreamer pipeline we use for live: the footage timestamp
// must read clip_start + each frame's PTS as a formatted local date — ffmpeg's drawtext
// `%{pts:localtime:<epoch>:<fmt>}` does exactly that natively (verified), whereas
// GStreamer needs a custom per-frame text probe. This is a one-shot batch encode, not a
// latency-sensitive live path, so a CLI process is the simpler, more robust tool. We use
// software libx264 (not VA-API) so an export never contends with the live wall on the
// single shared iGPU.
//
// One transcode at a time per instance. Emits best-effort progress (parsed from ffmpeg's
// `time=` against the known duration), then finished(dst) or failed(error).
class ClipTranscoder : public QObject
{
    Q_OBJECT
public:
    explicit ClipTranscoder(QObject *parent = nullptr);
    ~ClipTranscoder() override;

    // Transcode src -> dst. heightPx == 0 keeps the source height (overlay-only, no
    // scale). burnName/burnTimestamp add the overlays; label is the camera caption;
    // startEpochMs is the wall-clock of the clip's first frame (PTS 0); durationMs is
    // used only for the progress percentage.
    void start(const QString &src, const QString &dst, int heightPx,
               bool burnName, bool burnTimestamp, const QString &label,
               qint64 startEpochMs, qint64 durationMs);
    bool busy() const { return m_proc != nullptr; }

    // RUNTIME CAPABILITY PROBE. macOS bundles no ffmpeg — start() below launches a bare
    // "ffmpeg" off PATH — so what this class can actually do differs per machine, and
    // the UI must not offer what the local binary cannot deliver. Homebrew split the
    // formula: stock `ffmpeg` 9.0.1 is a 25-option build with no freetype / harfbuzz /
    // fontconfig and therefore NO drawtext, while `ffmpeg-full` 9.0.2 carries all four.
    // Measured on the operator's Mac 2026-09-23, where every export with overlays ran
    // the whole download and then died on "Filter not found", losing the requested
    // downscale with it.
    //
    // Asynchronous on purpose: a local exec of ~100 ms has no business on the GUI
    // thread, and the answer is only needed by the time an export drawer opens. `done`
    // fires once, on ctx's thread; haveFfmpeg=false means nothing is on PATH at all.
    static void probeCapabilities(QObject *ctx,
                                  std::function<void(bool haveFfmpeg, bool haveDrawtext)> done);

    // The binary the probe settled on. Empty until probeCapabilities() has answered,
    // after which start() uses it. A bare "ffmpeg" off PATH is NOT good enough on
    // macOS: Homebrew ships a slim `ffmpeg` (no drawtext) and puts the capable build
    // in `ffmpeg-full`, which is KEG-ONLY — deliberately not linked onto PATH — so it
    // is invisible to a plain exec. Worse, the slim one cannot simply be replaced:
    // gstreamer and freerdp depend on it, and gstreamer is what plays our live wall.
    // So we look for a capable build in the places Homebrew puts one, and fall back to
    // PATH. WT_FFMPEG overrides everything.
    static QString ffmpegProgram();
    static QStringList ffmpegCandidates();

    // What the chosen binary can do, filled in by probeCapabilities(). drawtext is
    // optional now: without it we render the overlays ourselves (see
    // renderOverlayAssets) and composite with the core `overlay` filter, which every
    // ffmpeg has. The ENCODER is not optional, and which one exists depends on the
    // build: a bundled LGPL ffmpeg has no libx264 (GPL), so macOS uses Apple's
    // h264_videotoolbox and Windows uses libopenh264.
    struct Caps {
        bool drawtext = false;
        bool libx264 = false;
        bool videotoolbox = false;
        bool openh264 = false;
        bool any() const { return libx264 || videotoolbox || openh264; }
    };
    static Caps caps();

    // Render the burn-in overlays as images, in Qt, at the OUTPUT resolution.
    // Returns false if nothing could be written. `dir` is created and owned by the
    // caller. Produces:
    //   name.png            one static caption, when `label` is non-empty
    //   ts_%06d.png         one per second of the clip, when startEpochMs > 0
    // Qt draws the text, so this needs no freetype, no fontconfig and no font file
    // hunting, and it renders the fleet's Cyrillic camera names the same way the rest
    // of the UI already does. It also makes the CLOCK OURS: ffmpeg's drawtext
    // `%{pts:localtime:...}` formats in the EXPORTING MACHINE's timezone, so the same
    // footage exported from two places carried two different burned-in times (found
    // by the Linux dev box, 2026-09-23). These images carry an explicit UTC offset so
    // the text is unambiguous wherever it was produced.
    static bool renderOverlayAssets(const QString &dir, const QString &label,
                                    qint64 startEpochMs, qint64 durationMs,
                                    int outW, int outH, int *tsCount);

    // Exposed for unit-style checks: the -vf filtergraph for the given options ("" = none).
    static QString buildFilter(int heightPx, bool burnName, bool burnTimestamp,
                               const QString &nameFilePath, qint64 startEpochMs);
    static QString fontFile();   // a usable system TTF, or "" to fall back to fontconfig

signals:
    void progress(int percent);          // 0..100, best-effort
    void finished(const QString &dst);
    void failed(const QString &error);

private:
    void cleanup();

    QProcess *m_proc = nullptr;
    QString m_dst;
    QString m_assetDir;     // Qt-rendered overlay images, removed on completion
    QString m_nameFile;     // temp file holding the caption (deleted on completion)
    qint64 m_durationMs = 0;
    QString m_tail;         // last slice of stderr (for an error message)
};
