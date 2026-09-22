#include "ClipTranscoder.h"
#include <memory>
#include <QCoreApplication>
#include <QDateTime>
#include <QGuiApplication>
#include <QFontMetrics>
#include <QPainter>
#include <QImage>
#include <QTemporaryFile>

#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QRegularExpression>
#include <QtMath>

namespace {
QString s_chosenFfmpeg;                  // set by probeCapabilities()
ClipTranscoder::Caps s_caps;             // ditto
}


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
// C\\:/Windows/Fonts/arial.ttf, the form the filtergraph parser accepts.
//
// The drive-letter colon needs the TWO-LEVEL escape `\\:` (a backslash to survive the
// filterchain-description parse, escaping a backslash that then escapes the colon at the
// option-value parse). A single `\:` was tolerated by the ffmpeg bundled through 2026-07-06
// (N-125444) but is REJECTED by the 7.1.3 release the Windows CI now bundles — an unquoted
// `fontfile=C\:/...` fails with "No option name near '/...'" (exit -22), which silently broke
// every compress/burn export that carries a name/timestamp overlay. Measured + fixed on-box
// 2026-07-08: `\\:` encodes clean on 7.1.3, overlays render. See
// docs/perf/2026-07-08-win-export-drawtext-ffmpeg71.md.
static QString escFilterPath(QString p)
{
    p.replace(QLatin1Char('\\'), QLatin1Char('/'));
    p.replace(QLatin1Char(':'), QStringLiteral("\\\\:"));
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
        // Unpredictable name, created 0600 by QTemporaryFile — a fixed wt_cap_<name>
        // path in shared /tmp is a symlink-follow target on a multi-user box (audit
        // 2026-09-03, Low). autoRemove stays off: ffmpeg reads it after we close it,
        // and the existing completion path deletes m_nameFile.
        QTemporaryFile tf(QDir::temp().filePath(QStringLiteral("wt_cap_XXXXXX.txt")));
        tf.setAutoRemove(false);
        if (tf.open()) { tf.write(label.toUtf8()); m_nameFile = tf.fileName(); tf.close(); }
        else m_nameFile.clear();
    }

    const bool wantName = burnName && !label.isEmpty();
    const bool wantTs   = burnTimestamp && startEpochMs > 0;
    const bool useImageOverlays = (wantName || wantTs) && !s_caps.drawtext;

    QStringList args{ QStringLiteral("-y"), QStringLiteral("-hide_banner"),
                      QStringLiteral("-loglevel"), QStringLiteral("error"), QStringLiteral("-stats"),
                      QStringLiteral("-i"), src, QStringLiteral("-an") };

    QString filter;
    QString complex;
    if (useImageOverlays) {
        // NO drawtext in this build, so Qt draws the text and ffmpeg only composites.
        // Needs nothing beyond the core `overlay` filter, which is why a dependency-
        // free LGPL ffmpeg can ship the feature at all. Renders at the OUTPUT size, so
        // the scale has to happen before the overlay.
        m_assetDir = QDir::temp().filePath(QStringLiteral("wt_ovl_%1")
                                           .arg(QDateTime::currentMSecsSinceEpoch()));
        QDir().mkpath(m_assetDir);
        // Output geometry: the source height unless we are downscaling. Width is
        // unknown until ffmpeg scales, so lay the chips out against a 16:9 estimate —
        // they are anchored to corners, so a width mismatch shifts nothing visible.
        const int outH = heightPx > 0 ? heightPx : 1080;
        const int outW = outH * 16 / 9;
        int tsCount = 0;
        if (!renderOverlayAssets(m_assetDir, wantName ? label : QString(),
                                 wantTs ? startEpochMs : 0, durationMs, outW, outH, &tsCount)) {
            cleanup();
            emit failed(QStringLiteral("Couldn't render the overlay images."));
            return;
        }
        const QString scale = heightPx > 0
            ? QStringLiteral("scale=-2:%1").arg(heightPx)
            : QStringLiteral("null");
        QStringList chain;
        chain << QStringLiteral("[0:v]") + scale + QStringLiteral("[v0]");
        QString cur = QStringLiteral("[v0]");
        int idx = 1;
        if (wantName) {
            args << QStringLiteral("-loop") << QStringLiteral("1")
                 << QStringLiteral("-i") << m_assetDir + QStringLiteral("/name.png");
            chain << QStringLiteral("%1[%2:v]overlay=x=16:y=12:eof_action=pass[vn]")
                         .arg(cur).arg(idx++);
            cur = QStringLiteral("[vn]");
        }
        if (wantTs && tsCount > 0) {
            args << QStringLiteral("-framerate") << QStringLiteral("1")
                 << QStringLiteral("-i") << m_assetDir + QStringLiteral("/ts_%06d.png");
            chain << QStringLiteral("%1[%2:v]overlay=x=W-w-16:y=H-h-12:eof_action=pass[vt]")
                         .arg(cur).arg(idx++);
            cur = QStringLiteral("[vt]");
        }
        complex = chain.join(QLatin1Char(';'));
        args << QStringLiteral("-filter_complex") << complex
             << QStringLiteral("-map") << cur
             << QStringLiteral("-shortest");
    } else {
        // Caption goes to a temp file so arbitrary camera names need no escaping.
        filter = buildFilter(heightPx, burnName && !m_nameFile.isEmpty(),
                             burnTimestamp, m_nameFile, startEpochMs);
    }

    if (filter.isEmpty() && complex.isEmpty()) {
        args << QStringLiteral("-c") << QStringLiteral("copy");
    } else {
        // Windows/W2: the bundled Windows ffmpeg is LGPL and has NO libx264 (GPL), so the
        // compress/burn re-encode uses libopenh264 (LGPL, software, identical on every GPU --
        // matches the W5 multi-GPU matrix). -preset/-crf are libx264-only; drive a
        // resolution-scaled average bitrate instead (~CRF-23-equivalent for low-motion
        // surveillance footage). Verified on-hardware 2026-07-06 (ffmpeg N-125444 LGPL:
        // scale+drawtext+libopenh264 -> clean H.264). See docs/perf/2026-07-06-win-export-encoder.md.
        // Plain STD/HIGH export (no filter) is unaffected (direct download, no ffmpeg).
        if (!filter.isEmpty())
            args << QStringLiteral("-vf") << filter;
        // ENCODER BY CAPABILITY, not by platform. A bundled LGPL ffmpeg has no libx264
        // (GPL), so the choice has to follow what the chosen binary actually carries:
        // libx264 where it exists (quality-targeted CRF), otherwise Apple's
        // VideoToolbox on macOS or libopenh264 as Windows has always used. Both of the
        // latter are bitrate-targeted; -preset/-crf are libx264-only.
        const int refH = heightPx > 0 ? heightPx : 1080;
        const int kbps = qBound(800, refH * refH / 180, 8000);  // ~1.3M@480, 2.9M@720, 6.5M@1080
        if (s_caps.libx264) {
            args << QStringLiteral("-c:v") << QStringLiteral("libx264")
                 << QStringLiteral("-preset") << QStringLiteral("veryfast")
                 << QStringLiteral("-crf") << QStringLiteral("23");
        } else if (s_caps.videotoolbox) {
            args << QStringLiteral("-c:v") << QStringLiteral("h264_videotoolbox")
                 << QStringLiteral("-b:v") << QStringLiteral("%1k").arg(kbps);
        } else {
            args << QStringLiteral("-c:v") << QStringLiteral("libopenh264")
                 << QStringLiteral("-b:v") << QStringLiteral("%1k").arg(kbps);
        }
        args << QStringLiteral("-pix_fmt") << QStringLiteral("yuv420p")
             << QStringLiteral("-movflags") << QStringLiteral("+faststart");
    }
    args << dst;

    if (qEnvironmentVariableIsSet("WT_TRACE"))
        qInfo("[FFCMD] %s %s", qUtf8Printable(ffmpegProgram()),
              qUtf8Printable(args.join(QLatin1Char(' '))));
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

    m_proc->start(ffmpegProgram(), args);
}

ClipTranscoder::Caps ClipTranscoder::caps() { return s_caps; }

// Draw one overlay image: transparent background, white text, dark shadow so it stays
// legible over both a bright driveway and a black night sky.
static bool drawChip(const QString &path, const QString &text, int w, int h, int px)
{
    QImage img(w, h, QImage::Format_ARGB32);
    img.fill(Qt::transparent);
    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setRenderHint(QPainter::TextAntialiasing, true);
    QFont f = QGuiApplication::font();
    f.setPixelSize(px);
    f.setWeight(QFont::DemiBold);
    p.setFont(f);
    const QRect r = img.rect().adjusted(px / 2, 0, -px / 2, 0);
    // A 1px dark outline in four directions reads on any background without a slab.
    p.setPen(QColor(0, 0, 0, 200));
    for (int dx = -1; dx <= 1; ++dx)
        for (int dy = -1; dy <= 1; ++dy)
            if (dx || dy)
                p.drawText(r.translated(dx, dy), Qt::AlignVCenter | Qt::AlignLeft, text);
    p.setPen(QColor(255, 255, 255));
    p.drawText(r, Qt::AlignVCenter | Qt::AlignLeft, text);
    p.end();
    return img.save(path, "PNG");
}

bool ClipTranscoder::renderOverlayAssets(const QString &dir, const QString &label,
                                         qint64 startEpochMs, qint64 durationMs,
                                         int outW, int outH, int *tsCount)
{
    if (tsCount) *tsCount = 0;
    if (outW <= 0 || outH <= 0)
        return false;
    // Scale the type to the output so a 480p clip is not branded with 1440p-sized
    // text. 2.2% of height matches what drawtext was producing at 1440p.
    const int px = qBound(14, int(outH * 0.022), 48);
    const int chipH = px * 2;

    bool ok = true;
    if (!label.isEmpty()) {
        QFont probe = QGuiApplication::font();
        probe.setPixelSize(px);
        probe.setWeight(QFont::DemiBold);
        const int w = qMin(outW, QFontMetrics(probe).horizontalAdvance(label) + px * 2);
        ok = drawChip(dir + QStringLiteral("/name.png"), label, qMax(16, w), chipH, px) && ok;
    }
    if (startEpochMs > 0 && durationMs > 0) {
        // EXPLICIT offset, captured once: the text says which clock it is on, so a
        // clip exported from another timezone cannot be silently misread.
        const QDateTime t0 = QDateTime::fromMSecsSinceEpoch(startEpochMs);
        const int offMin = t0.offsetFromUtc() / 60;
        const QString off = QStringLiteral("UTC%1%2:%3")
                                .arg(offMin < 0 ? QLatin1Char('-') : QLatin1Char('+'))
                                .arg(qAbs(offMin) / 60, 2, 10, QLatin1Char('0'))
                                .arg(qAbs(offMin) % 60, 2, 10, QLatin1Char('0'));
        const int n = int((durationMs + 999) / 1000) + 1;      // cover the tail second
        QFont probe = QGuiApplication::font();
        probe.setPixelSize(px);
        probe.setWeight(QFont::DemiBold);
        const QString widest = QStringLiteral("0000-00-00 00:00:00 ") + off;
        const int w = qMin(outW, QFontMetrics(probe).horizontalAdvance(widest) + px * 2);
        for (int i = 0; i < n && ok; ++i) {
            const QString txt = t0.addMSecs(qint64(i) * 1000).toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"))
                                + QLatin1Char(' ') + off;
            ok = drawChip(QStringLiteral("%1/ts_%2.png").arg(dir).arg(i, 6, 10, QLatin1Char('0')),
                          txt, qMax(16, w), chipH, px);
        }
        if (ok && tsCount) *tsCount = n;
    }
    return ok;
}

QStringList ClipTranscoder::ffmpegCandidates()
{
    QStringList c;
    const QString override = qEnvironmentVariable("WT_FFMPEG");
    if (!override.isEmpty())
        c << override;                   // explicit wins, always
    // A BUNDLED ffmpeg beside the executable outranks anything on the machine. This is
    // how Windows already ships the feature: packaging/windows/deploy.ps1 downloads a
    // PINNED, SHA-256-verified LGPL build and drops ffmpeg.exe next to the exe, so no
    // user ever installs anything. macOS bundles nothing yet, which is why overlays
    // depend on what happens to be on the operator's machine; this entry is inert
    // until the mac packaging does the same, and then costs no further code.
    c << QCoreApplication::applicationDirPath() + QStringLiteral("/ffmpeg");
#ifdef Q_OS_MACOS
    // Homebrew's capable build is keg-only, so it lives here and NOT on PATH. Both
    // prefixes listed because Apple Silicon and Intel differ.
    c << QStringLiteral("/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
      << QStringLiteral("/usr/local/opt/ffmpeg-full/bin/ffmpeg");
#endif
    c << QStringLiteral("ffmpeg");       // whatever PATH offers, last
    return c;
}

QString ClipTranscoder::ffmpegProgram()
{
    return s_chosenFfmpeg.isEmpty() ? QStringLiteral("ffmpeg") : s_chosenFfmpeg;
}

void ClipTranscoder::probeCapabilities(QObject *ctx,
                                       std::function<void(bool, bool)> done)
{
    // Walk the candidates in order and take the FIRST that can do drawtext. If none
    // can, fall back to the first that merely runs, so the compression ladder still
    // works — losing overlays must not also cost the operator their downscale.
    auto cands = std::make_shared<QStringList>(ffmpegCandidates());
    auto firstWorking = std::make_shared<QString>();
    auto step = std::make_shared<std::function<void(int)>>();

    *step = [ctx, done, cands, firstWorking, step](int i) {
        if (i >= cands->size()) {                       // exhausted
            const bool any = !firstWorking->isEmpty();
            s_chosenFfmpeg = any ? *firstWorking : QString();
            if (any)
                qInfo("[FFMPEG] using %s (no drawtext)", qUtf8Printable(*firstWorking));
            done(any, false);
            return;
        }
        const QString prog = cands->at(i);
        qInfo("[FFMPEG] probing candidate %d/%d: %s", i + 1, int(cands->size()), qUtf8Printable(prog));
        auto *p = new QProcess(ctx);
        auto answered = std::make_shared<bool>(false);
        auto settle = [p, answered, step, i, prog, firstWorking, done](bool ran, bool drawtext) {
            if (*answered) return;
            *answered = true;
            p->deleteLater();
            if (ran && firstWorking->isEmpty())
                *firstWorking = prog;
            // TAKE THE FIRST THAT RUNS AND CAN ENCODE. drawtext is no longer a
            // selection criterion: when it is absent we render the overlays in Qt and
            // composite with the core `overlay` filter, so a dependency-free LGPL
            // build is fully capable. Candidate ORDER is therefore the preference, and
            // the bundled binary — the one we ship, pin and test — comes first.
            if (ran && s_caps.any()) {
                s_chosenFfmpeg = prog;
                qInfo("[FFMPEG] using %s (drawtext %s, encoder %s)", qUtf8Printable(prog),
                      drawtext ? "yes" : "no — overlays rendered in Qt",
                      s_caps.libx264 ? "libx264"
                        : s_caps.videotoolbox ? "h264_videotoolbox" : "libopenh264");
                done(true, true);
                return;
            }
            (*step)(i + 1);
        };
        QObject::connect(p, &QProcess::finished, ctx, [p, prog, settle](int, QProcess::ExitStatus) {
            // `ffmpeg -filters` prints one line per filter: " ... drawtext  V->V  ...".
            // Match with the surrounding spaces so "drawtext" inside another filter
            // name cannot pass. stdout only — the banner is suppressed.
            const QByteArray filters = p->readAllStandardOutput();
            const bool dt = filters.contains(" drawtext ");
            // Encoders are a separate question and a blocking one: a build with no
            // usable H.264 encoder cannot burn anything in, whatever its filters say.
            QProcess enc;
            enc.start(prog, {QStringLiteral("-hide_banner"), QStringLiteral("-encoders")});
            enc.waitForFinished(4000);
            const QByteArray e = enc.readAllStandardOutput();
            s_caps.drawtext     = dt;
            s_caps.libx264      = e.contains("libx264");
            s_caps.videotoolbox = e.contains("h264_videotoolbox");
            s_caps.openh264     = e.contains("libopenh264");
            settle(true, dt);
        });
        QObject::connect(p, &QProcess::errorOccurred, ctx, [settle](QProcess::ProcessError) {
            settle(false, false);                       // absent, or refused to start
        });
        p->start(prog, {QStringLiteral("-hide_banner"), QStringLiteral("-filters")});
    };
    (*step)(0);
}

void ClipTranscoder::cleanup()
{
    if (!m_assetDir.isEmpty()) { QDir(m_assetDir).removeRecursively(); m_assetDir.clear(); }
    if (!m_nameFile.isEmpty()) { QFile::remove(m_nameFile); m_nameFile.clear(); }
    if (m_proc) { m_proc->deleteLater(); m_proc = nullptr; }
}
