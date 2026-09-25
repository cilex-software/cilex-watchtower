#include "MetalCacheProbe.h"

#include <QDateTime>
#include <QMutex>
#include <QPointer>
#include <QString>
#include <QThread>
#include <QTimer>
#include <QVideoSink>

#include <vector>

#if defined(Q_OS_UNIX)
#  include <cstdlib>
#  include <execinfo.h>
#endif

namespace {

QtMessageHandler s_prev = nullptr;
thread_local const char *t_expected = nullptr;
QMutex s_mx;

// A new episode begins after this much silence. Floods run at 60/s, so 10 s of quiet
// means the producer really stopped rather than the frames merely stuttering.
constexpr qint64 kGapMs = 10000;

struct Episode
{
    int id = 0;
    qint64 startMs = 0;
    qint64 lastMs = 0;
    long long n = 0;
    const char *who = nullptr;
};
Episode s_expected;     // guarded by s_mx
Episode s_unexpected;   // guarded by s_mx
int s_nextId = 0;       // guarded by s_mx

struct SinkRec
{
    const char *role;
    QPointer<QVideoSink> sink;
    const void *raw;
    QThread *thread;    // the sink's thread at registration: only that thread may read it
};
std::vector<SinkRec> s_sinks; // guarded by s_mx

bool isMetalCacheWarning(const QString &msg)
{
    // Our own lines say "Metal-cache warning" precisely so they can never match this.
    return msg.contains(QLatin1String("Metal texture cache was released"));
}

// Straight into the next handler (the flight recorder's tee): never through qInfo()
// from inside a handler. Its category null-check makes a default context safe.
void emitLine(const QString &line)
{
    if (s_prev)
        s_prev(QtInfoMsg, QMessageLogContext(), line);
}

QString hhmmss(qint64 ms)
{
    return QDateTime::fromMSecsSinceEpoch(ms).toString(QStringLiteral("HH:mm:ss.zzz"));
}

QString summary(const char *kind, const Episode &e)
{
    const double secs = (e.lastMs - e.startMs) / 1000.0;
    return QStringLiteral("[MTLCACHE] %1 episode #%2 ENDED: n=%3 over %4 s (%5..%6, %7/s)%8")
        .arg(QLatin1String(kind)).arg(e.id).arg(e.n).arg(secs, 0, 'f', 1)
        .arg(hhmmss(e.startMs), hhmmss(e.lastMs))
        .arg(secs > 0 ? e.n / secs : double(e.n), 0, 'f', 0)
        .arg(e.who ? QStringLiteral(" source=%1").arg(QLatin1String(e.who)) : QString());
}

void emitBacktrace()
{
#if defined(Q_OS_UNIX)
    void *frames[48];
    const int n = backtrace(frames, 48);
    char **syms = backtrace_symbols(frames, n);
    // Skip this function, the handler and Qt's logging plumbing; keep the rest — the
    // interesting frames are AVFVideoBuffer::textureHandle's CALLERS.
    for (int i = 2; i < n; ++i)
        emitLine(QStringLiteral("[MTLCACHE]   %1").arg(QString::fromLocal8Bit(syms ? syms[i] : "?"))); // macOS numbers its own frames
    std::free(syms);
#else
    emitLine(QStringLiteral("[MTLCACHE]   (no backtrace on this platform)"));
#endif
}

void emitSinks()
{
    std::vector<SinkRec> copy;
    {
        QMutexLocker l(&s_mx);
        copy = s_sinks;
    }
    if (copy.empty()) {
        emitLine(QStringLiteral("[MTLCACHE]   sinks: none registered"));
        return;
    }
    for (const SinkRec &r : copy) {
        QString state;
        if (!r.sink)
            state = QStringLiteral("destroyed");
        else if (QThread::currentThread() != r.thread)
            state = QStringLiteral("alive (other thread — rhi not read)");
        else
            state = QStringLiteral("alive rhi=%1")
                        .arg(r.sink->rhi() ? QStringLiteral("%1").arg(quintptr(r.sink->rhi()), 0, 16)
                                           : QStringLiteral("NULL (no Metal texture cache)"));
        emitLine(QStringLiteral("[MTLCACHE]   sink %1 %2: %3")
                     .arg(QLatin1String(r.role)).arg(quintptr(r.raw), 0, 16).arg(state));
    }
}

void handler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    if (!isMetalCacheWarning(msg)) {
        if (s_prev)
            s_prev(type, ctx, msg);
        return;
    }
    const qint64 now = QDateTime::currentMSecsSinceEpoch();

    if (t_expected) {
        // Proven benign (MetalCacheProbe.h): counted, not printed.
        QString closed, opened;
        {
            QMutexLocker l(&s_mx);
            if (s_expected.n && now - s_expected.lastMs > kGapMs)
                closed = summary("expected", s_expected), s_expected = Episode();
            if (!s_expected.n) {
                s_expected = Episode{++s_nextId, now, now, 0, t_expected};
                opened = QStringLiteral("[MTLCACHE] expected episode #%1 STARTED source=%2 — counted, not printed: a "
                                        "render-less sink's zero-copy Metal texture fails, Qt converts via upload, "
                                        "image correct (reproduced + verified 2026-09-25)")
                             .arg(s_expected.id).arg(QLatin1String(t_expected));
            }
            ++s_expected.n;
            s_expected.lastMs = now;
        }
        if (!closed.isEmpty())
            emitLine(closed);
        if (!opened.isEmpty())
            emitLine(opened);
        return;
    }

    // Unexplained: make it self-diagnosing, then let the original line through.
    bool first = false;
    int id = 0;
    long long n = 0;
    QString closed;
    {
        QMutexLocker l(&s_mx);
        if (s_unexpected.n && now - s_unexpected.lastMs > kGapMs)
            closed = summary("UNEXPECTED", s_unexpected), s_unexpected = Episode();
        if (!s_unexpected.n) {
            s_unexpected = Episode{++s_nextId, now, now, 0, nullptr};
            first = true;
        }
        n = ++s_unexpected.n;
        s_unexpected.lastMs = now;
        id = s_unexpected.id;
    }
    if (!closed.isEmpty())
        emitLine(closed);
    if (first) {
        QThread *t = QThread::currentThread();
        emitLine(QStringLiteral("[MTLCACHE] UNEXPECTED Metal-cache warning — episode #%1, NOT from a known-benign "
                                "producer. thread=%2 [%3]. Backtrace (the caller of toImage()/texture creation "
                                "is the producer), then every registered sink:")
                     .arg(id)
                     .arg(t && !t->objectName().isEmpty() ? t->objectName() : QStringLiteral("unnamed"))
                     .arg(quintptr(QThread::currentThreadId()), 0, 16));
        emitBacktrace();
        emitSinks();
    } else if (n % 1000 == 0) {
        emitLine(QStringLiteral("[MTLCACHE] UNEXPECTED episode #%1 still going: n=%2").arg(id).arg(n));
    }
    if (s_prev)
        s_prev(type, ctx, msg);
}

} // namespace

namespace MetalCacheProbe {

void install()
{
    s_prev = qInstallMessageHandler(handler);
    // One line per launch, so a deployment is provable from the flight recorder alone.
    emitLine(QStringLiteral("[MTLCACHE] probe armed: harvest-sink Metal-cache warnings are counted (proven benign "
                            "2026-09-25); any other occurrence logs thread + backtrace + sink rhi states"));
}

void startPeriodic(QObject *parent)
{
    auto *t = new QTimer(parent);
    t->setInterval(5000);
    QObject::connect(t, &QTimer::timeout, t, [] {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        QString a, b;
        {
            QMutexLocker l(&s_mx);
            if (s_expected.n && now - s_expected.lastMs > kGapMs)
                a = summary("expected", s_expected), s_expected = Episode();
            if (s_unexpected.n && now - s_unexpected.lastMs > kGapMs)
                b = summary("UNEXPECTED", s_unexpected), s_unexpected = Episode();
        }
        // Not inside a handler here, so the normal logging path is the right one.
        if (!a.isEmpty())
            qInfo().noquote() << a;
        if (!b.isEmpty())
            qInfo().noquote() << b;
    });
    t->start();
}

void noteSink(const char *role, QVideoSink *sink)
{
    if (!sink)
        return;
    QMutexLocker l(&s_mx);
    for (SinkRec &r : s_sinks) {
        if (qstrcmp(r.role, role) == 0) {        // one live record per role: the latest
            r = SinkRec{role, sink, sink, sink->thread()};
            return;
        }
    }
    s_sinks.push_back(SinkRec{role, sink, sink, sink->thread()});
}

ExpectedScope::ExpectedScope(const char *who) : m_prev(t_expected) { t_expected = who; }
ExpectedScope::~ExpectedScope() { t_expected = m_prev; }

} // namespace MetalCacheProbe
