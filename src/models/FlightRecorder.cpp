#include "FlightRecorder.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QMutex>
#include <QMutexLocker>
#include <QStandardPaths>
#include <QSysInfo>
#include <QThread>

#include <cstdio>

namespace {

// All state is process-lifetime and leaked deliberately: the recorder must keep
// working during static destruction (Qt logs on the way down) — a destructor
// that closed the file would race the last messages.
QMutex *s_mutex = nullptr;               // guards file + size + rotation
QFile *s_file = nullptr;
qint64 s_size = 0;
qint64 s_maxBytes = 10 * 1024 * 1024;    // per file (WT_FLIGHTREC_BYTES)
int s_keep = 5;                          // rotated files kept (WT_FLIGHTREC_KEEP)
QString s_dir;
QtMessageHandler s_prev = nullptr;       // chained — console/journald unchanged

// A handler can be re-entered from its own thread if writing the file itself
// warns (disk full, permissions). Forward-only in that case — never recurse.
thread_local bool t_inHandler = false;

char levelChar(QtMsgType t)
{
    switch (t) {
    case QtDebugMsg:    return 'D';
    case QtInfoMsg:     return 'I';
    case QtWarningMsg:  return 'W';
    case QtCriticalMsg: return 'C';
    case QtFatalMsg:    return 'F';
    }
    return '?';
}

// current -> .1 -> .2 -> … -> .keep (oldest dropped). Called under s_mutex.
void rotateLocked()
{
    s_file->close();
    const QString base = s_dir + QStringLiteral("/watchtower.log");
    QFile::remove(base + QStringLiteral(".") + QString::number(s_keep));
    for (int i = s_keep - 1; i >= 1; --i)
        QFile::rename(base + QStringLiteral(".") + QString::number(i),
                      base + QStringLiteral(".") + QString::number(i + 1));
    QFile::rename(base, base + QStringLiteral(".1"));
    s_file->setFileName(base);
    s_file->open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text);
    s_size = 0;
}

void writeLineLocked(const QByteArray &line)
{
    if (!s_file->isOpen())
        return;
    s_file->write(line);
    s_file->flush();                     // Qt buffer -> kernel: survives our death
    s_size += line.size();
    if (s_size >= s_maxBytes)
        rotateLocked();
}

void handler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    if (!t_inHandler && s_file) {
        t_inHandler = true;
        // Fixed file format, independent of QT_MESSAGE_PATTERN (which styles the
        // console): ISO-ms timestamp · level · thread · category · message.
        QByteArray line;
        line.reserve(msg.size() + 64);
        line += QDateTime::currentDateTime().toString(Qt::ISODateWithMs).toUtf8();
        line += ' ';
        line += levelChar(type);
        line += " [";
        line += QByteArray::number(quintptr(QThread::currentThreadId()), 16);
        line += "] ";
        if (ctx.category && qstrcmp(ctx.category, "default") != 0) {
            line += ctx.category;
            line += ": ";
        }
        // A pathological message (a base64 blob in an error string) must not blow
        // through the rotation budget in one line.
        const QByteArray body = msg.toUtf8();
        if (body.size() > 8192) {
            line += body.left(8192);
            line += "…[truncated ";
            line += QByteArray::number(body.size());
            line += " bytes]";
        } else {
            line += body;
        }
        line += '\n';
        {
            QMutexLocker lock(s_mutex);
            writeLineLocked(line);
        }
        t_inHandler = false;
    }
    if (s_prev)
        s_prev(type, ctx, msg);          // console/journald exactly as before
}

} // namespace

namespace FlightRecorder {

void install(const char *buildSha)
{
    if (qEnvironmentVariableIsSet("WT_FLIGHTREC_OFF"))
        return;

    QString dir = qEnvironmentVariable("WT_FLIGHTREC_DIR");
    if (dir.isEmpty())
        dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
              + QStringLiteral("/flightrec");
    if (!QDir().mkpath(dir)) {
        std::fprintf(stderr, "watchtower: flight recorder disabled — cannot create %s\n",
                     qPrintable(dir));
        return;
    }

    const qint64 envBytes = qEnvironmentVariableIntValue("WT_FLIGHTREC_BYTES");
    if (envBytes > 4096)
        s_maxBytes = envBytes;
    const int envKeep = qEnvironmentVariableIntValue("WT_FLIGHTREC_KEEP");
    if (envKeep >= 1 && envKeep <= 50)
        s_keep = envKeep;

    auto *f = new QFile(dir + QStringLiteral("/watchtower.log"));
    if (!f->open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        std::fprintf(stderr, "watchtower: flight recorder disabled — cannot open %s\n",
                     qPrintable(f->fileName()));
        delete f;
        return;
    }

    s_dir = dir;
    s_mutex = new QMutex;
    s_size = f->size();
    s_file = f;
    s_prev = qInstallMessageHandler(handler);

    // Session boundary marker — Warden slices "this run" on these lines, and a
    // post-mortem reader sees at a glance which build/Qt/OS produced what follows.
    qInfo("=== watchtower start pid=%lld build=%s qt=%s os=%s (flightrec %s, %lldKB x%d) ===",
          QCoreApplication::applicationPid(), buildSha, qVersion(),
          qPrintable(QSysInfo::prettyProductName()), qPrintable(dir),
          s_maxBytes / 1024, s_keep);
}

QString directory()
{
    return s_dir;
}

} // namespace FlightRecorder
