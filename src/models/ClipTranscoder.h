#pragma once

#include <QObject>
#include <QString>
#include <QProcess>

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
    QString m_nameFile;     // temp file holding the caption (deleted on completion)
    qint64 m_durationMs = 0;
    QString m_tail;         // last slice of stderr (for an error message)
};
