#include "ClipTranscoder.h"

#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QRegularExpression>
#include <QtMath>

ClipTranscoder::ClipTranscoder(QObject *parent) : QObject(parent) {}

ClipTranscoder::~ClipTranscoder() { cleanup(); }

QString ClipTranscoder::fontFile()
{
    static const QStringList kCandidates = {
#if defined(Q_OS_WIN)
        // Windows: the bundled LGPL ffmpeg may lack fontconfig, so drawtext needs an
        // EXPLICIT fontfile — the empty fallback that works on Linux would fail here.
        QStringLiteral("C:/Windows/Fonts/segoeui.ttf"),
        QStringLiteral("C:/Windows/Fonts/arial.ttf"),
        QStringLiteral("C:/Windows/Fonts/tahoma.ttf"),
        QStringLiteral("C:/Windows/Fonts/verdana.ttf"),
#else
        QStringLiteral("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
        QStringLiteral("/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"),
#endif
    };
    for (const QString &f : kCandidates)
        if (QFile::exists(f))
            return f;
    return QString();   // fall back to fontconfig's default (no fontfile= option)
}

// Escape a filesystem path for use INSIDE an ffmpeg -vf filtergraph option value
// (drawtext fontfile=/textfile=), where ':' separates options and '\' escapes. No-op on
// POSIX paths (no colon/backslash); on Windows converts C:\Windows\Fonts\arial.ttf ->
// C\:/Windows/Fonts/arial.ttf, the form the filtergraph parser accepts.
static QString escFilterPath(QString p)
{
    p.replace(QLatin1Char('\\'), QLatin1Char('/'));
    p.replace(QLatin1Char(':'), QStringLiteral("\\:"));
    return p;
}

// Build the -vf filtergraph. Returns "" when no scale and no overlays are requested.
// The escaping here is exact and verified against ffmpeg 6.1 (no shell layer — this
// string is passed as a single QProcess argument):
//   • camera name → a textfile (zero escaping of arbitrary names/IPs/parens),
//   • timestamp   → text='%{pts\:localtime\:<epoch>\:%Y-%m-%d %H\\\:%M\\\:%S}'
//     (\: escapes the option-separator colons; \\\: escapes the strftime colons).
QString ClipTranscoder::buildFilter(int heightPx, bool burnName, bool burnTimestamp,
                                    const QString &nameFilePath, qint64 startEpochMs)
{
    QStringList parts;
    if (heightPx > 0)
        parts << QStringLiteral("scale=-2:%1").arg(heightPx);

    const int refH = heightPx > 0 ? heightPx : 1080;     // font sized to the output frame
    const int fs = qBound(18, int(qRound(refH / 30.0)), 44);
    const QString font = fontFile();
    const QString fontOpt = font.isEmpty() ? QString()
                                           : (QStringLiteral(":fontfile=") + escFilterPath(font));
    const QString style = QStringLiteral(":fontsize=%1:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=7%2")
                              .arg(fs).arg(fontOpt);

    if (burnName && !nameFilePath.isEmpty())
        parts << (QStringLiteral("drawtext=textfile=%1:expansion=none:x=14:y=14").arg(escFilterPath(nameFilePath)) + style);

    if (burnTimestamp) {
        const qint64 epochSec = startEpochMs / 1000;
        const QString ts = QStringLiteral("drawtext=text='%{pts\\:localtime\\:")
                           + QString::number(epochSec)
                           + QStringLiteral("\\:%Y-%m-%d %H\\\\\\:%M\\\\\\:%S}':x=w-tw-14:y=h-th-14")
                           + style;
        parts << ts;
    }
    return parts.join(QLatin1Char(','));
}

void ClipTranscoder::start(const QString &src, const QString &dst, int heightPx,
                           bool burnName, bool burnTimestamp, const QString &label,
                           qint64 startEpochMs, qint64 durationMs)
{
    if (m_proc) { emit failed(QStringLiteral("A transcode is already running.")); return; }
    m_dst = dst;
    m_durationMs = durationMs;
    m_tail.clear();

    // Caption goes to a temp file so arbitrary camera names need no filter escaping.
    if (burnName && !label.isEmpty()) {
        m_nameFile = QDir::temp().filePath(QStringLiteral("wt_cap_%1.txt")
                         .arg(QFileInfo(dst).completeBaseName()));
        QFile f(m_nameFile);
        if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) { f.write(label.toUtf8()); f.close(); }
        else m_nameFile.clear();
    }

    const QString filter = buildFilter(heightPx, burnName && !m_nameFile.isEmpty(),
                                       burnTimestamp, m_nameFile, startEpochMs);

    QStringList args{ QStringLiteral("-y"), QStringLiteral("-hide_banner"),
                      QStringLiteral("-loglevel"), QStringLiteral("error"), QStringLiteral("-stats"),
                      QStringLiteral("-i"), src, QStringLiteral("-an") };
    if (filter.isEmpty()) {
        args << QStringLiteral("-c") << QStringLiteral("copy");
    } else {
        // NOTE (Windows/W2): libx264 is GPL and is NOT in the LGPL ffmpeg we bundle, so the
        // compress/burn re-encode will fail on Windows until this is resolved on-hardware —
        // either switch to h264_mf (Media Foundation, LGPL-clean, but different rate-control
        // options than -preset/-crf) or libopenh264, per `ffmpeg -encoders | findstr 264` on
        // the box. Plain STD/HIGH export (no filter) is unaffected (direct download, no ffmpeg).
        // See docs/plans/windows-port/W2-*.prompt.md.
        args << QStringLiteral("-vf") << filter
             << QStringLiteral("-c:v") << QStringLiteral("libx264")
             << QStringLiteral("-preset") << QStringLiteral("veryfast")
             << QStringLiteral("-crf") << QStringLiteral("23")
             << QStringLiteral("-pix_fmt") << QStringLiteral("yuv420p")
             << QStringLiteral("-movflags") << QStringLiteral("+faststart");
    }
    args << dst;

    m_proc = new QProcess(this);
    m_proc->setProcessChannelMode(QProcess::SeparateChannels);
    connect(m_proc, &QProcess::readyReadStandardError, this, [this]() {
        const QString chunk = QString::fromUtf8(m_proc->readAllStandardError());
        m_tail = (m_tail + chunk).right(800);
        if (m_durationMs <= 0) return;
        // ffmpeg -stats lines carry "time=HH:MM:SS.xx"; map to a percentage.
        static const QRegularExpression re(QStringLiteral("time=(\\d+):(\\d+):(\\d+(?:\\.\\d+)?)"));
        QRegularExpressionMatchIterator it = re.globalMatch(chunk);
        QRegularExpressionMatch last;
        while (it.hasNext()) last = it.next();
        if (last.hasMatch()) {
            const double sec = last.captured(1).toInt() * 3600 + last.captured(2).toInt() * 60
                               + last.captured(3).toDouble();
            emit progress(qBound(0, int(sec * 1000.0 / m_durationMs * 100.0), 100));
        }
    });
    connect(m_proc, &QProcess::finished, this, [this](int code, QProcess::ExitStatus st) {
        const bool ok = (st == QProcess::NormalExit && code == 0
                         && QFileInfo::exists(m_dst) && QFileInfo(m_dst).size() > 0);
        const QString dst = m_dst, tail = m_tail;
        cleanup();
        if (ok) emit finished(dst);
        else    emit failed(tail.isEmpty() ? QStringLiteral("ffmpeg exited with code %1").arg(code)
                                           : tail.trimmed().section(QLatin1Char('\n'), -1));
    });
    connect(m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        if (!m_proc) return;
        const QString err = m_proc->errorString();
        cleanup();
        emit failed(err.isEmpty() ? QStringLiteral("Couldn't start ffmpeg.") : err);
    });

    m_proc->start(QStringLiteral("ffmpeg"), args);
}

void ClipTranscoder::cleanup()
{
    if (!m_nameFile.isEmpty()) { QFile::remove(m_nameFile); m_nameFile.clear(); }
    if (m_proc) { m_proc->deleteLater(); m_proc = nullptr; }
}
