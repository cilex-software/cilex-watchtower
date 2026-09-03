#include "FlightRecorder.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QMutex>
#include <QMutexLocker>
#include <QSaveFile>
#include <QSslSocket>
#include <QStandardPaths>
#include <QSysInfo>
#include <QThread>
#include <QTimer>
#include <QUuid>

#include <cstdio>
#include <cstring>
#include <ctime>

#if defined(Q_OS_WIN)
#  include <windows.h>
#  include <psapi.h>
#  include <dbghelp.h>
#else
#  include <fcntl.h>
#  include <unistd.h>
#  if defined(Q_OS_LINUX)
#    include <elf.h>            // NT_GNU_BUILD_ID walk — ELF is a Linux concept;
#    include <link.h>           // macOS is Mach-O (M1 defect #4: dyld walk is the
#  endif                        //  M2 item; until then the module list degrades honestly)
#endif

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

// ---- crash-marker statics (CW-03) — pre-armed at install() so the fatal
// handler needs nothing but snprintf + open/write. Fixed buffers on purpose:
// no allocation, no Qt, no locks at crash time.
char s_reportId[40] = "";
char s_markerPath[512] = "";
char s_build[48] = "dev";
char s_qtVer[32] = "";
long long s_monoBaseMs = 0;              // uptime base (CLOCK_MONOTONIC / GetTickCount64)
#if defined(Q_OS_WIN)
wchar_t s_markerPathW[512] = L"";
wchar_t s_dumpPathW[512] = L"";
#endif

long long monoMs()
{
#if defined(Q_OS_WIN)
    return (long long)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

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

// Consecutive-duplicate collapse (2026-08-22, the Mac Metal-texture flood: the same
// "cannot create texture" line twice per frame for seconds — ~400 lines carrying one
// fact, eating the flightrec budget and burying everything else). Byte-identical
// consecutive messages are counted, not re-written; the count flushes as one summary
// line when a different message arrives, and every 500th repeat leaves a heartbeat so
// an infinite storm is still visible while it runs. Guarded by s_mutex.
static QByteArray s_dupBody;
static int s_dupCount = 0;

void handler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    bool suppressConsole = false;
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
            if (body == s_dupBody) {
                ++s_dupCount;
                suppressConsole = true;
                if (s_dupCount % 500 == 0) {
                    QByteArray hb = QDateTime::currentDateTime().toString(Qt::ISODateWithMs).toUtf8();
                    hb += " I (previous message still repeating, x";
                    hb += QByteArray::number(s_dupCount);
                    hb += " so far)\n";
                    writeLineLocked(hb);
                }
            } else {
                if (s_dupCount > 0) {
                    QByteArray fl = QDateTime::currentDateTime().toString(Qt::ISODateWithMs).toUtf8();
                    fl += " I (previous message repeated x";
                    fl += QByteArray::number(s_dupCount);
                    fl += " more)\n";
                    writeLineLocked(fl);
                    std::fprintf(stderr, "(previous message repeated x%d more)\n", s_dupCount);
                }
                s_dupCount = 0;
                s_dupBody = body;
                writeLineLocked(line);
            }
        }
        t_inHandler = false;
    }
    if (s_prev && !suppressConsole)
        s_prev(type, ctx, msg);          // console/journald exactly as before
}

// ---------------------------------------------------------------- CW-02
// Modules/BuildID snapshot. One line per loaded module:
//   <base-hex> <buildid-or-pe-key> <path>
// The BuildID is what matches a backtrace's `lib.so(+0xOFFSET)` frames to the
// EXACT binary — a guard box's Qt may not be the Qt we still have.
#if defined(Q_OS_LINUX)
struct ModWalk { QByteArray lines; };

int phdrCb(struct dl_phdr_info *info, size_t, void *out)
{
    auto *w = static_cast<ModWalk *>(out);
    QByteArray id;
    for (int i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_NOTE)
            continue;
        const char *p = reinterpret_cast<const char *>(info->dlpi_addr + ph->p_vaddr);
        const char *end = p + ph->p_memsz;
        while (p + sizeof(ElfW(Nhdr)) <= end) {
            const auto *nh = reinterpret_cast<const ElfW(Nhdr) *>(p);
            const char *name = p + sizeof(ElfW(Nhdr));
            const char *desc = name + ((nh->n_namesz + 3) & ~3u);
            if (desc + nh->n_descsz > end)
                break;
            if (nh->n_type == NT_GNU_BUILD_ID && nh->n_namesz == 4
                && memcmp(name, "GNU", 4) == 0) {
                id = QByteArray(desc, int(nh->n_descsz)).toHex();
                break;
            }
            p = desc + ((nh->n_descsz + 3) & ~3u);
        }
        if (!id.isEmpty())
            break;
    }
    const bool mainExe = !info->dlpi_name || !info->dlpi_name[0];
    w->lines += "0x" + QByteArray::number(qulonglong(info->dlpi_addr), 16) + ' '
              + (id.isEmpty() ? QByteArray("-") : id) + ' '
              + (mainExe ? QCoreApplication::applicationFilePath().toLocal8Bit()
                         : QByteArray(info->dlpi_name))
              + '\n';
    return 0;
}

QByteArray moduleLines()
{
    ModWalk w;
    dl_iterate_phdr(phdrCb, &w);
    return w.lines;
}
#elif defined(Q_OS_WIN)
// Windows: TimeDateStamp+SizeOfImage identify the module on a symbol server;
// the RSDS record (PDB GUID+age) identifies the matching .pdb — which CI must
// archive per release (plan CW-17). Parsed from the loaded image in memory.
QByteArray moduleLines()
{
    QByteArray out;
    HMODULE mods[1024];
    DWORD needed = 0;
    if (!EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed))
        return out;
    const int n = qMin(int(needed / sizeof(HMODULE)), 1024);
    for (int i = 0; i < n; ++i) {
        wchar_t wpath[MAX_PATH];
        if (!GetModuleFileNameW(mods[i], wpath, MAX_PATH))
            continue;
        const auto *base = reinterpret_cast<const unsigned char *>(mods[i]);
        QByteArray id = "-";
        const auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
        if (dos->e_magic == IMAGE_DOS_SIGNATURE) {
            const auto *nt = reinterpret_cast<const IMAGE_NT_HEADERS *>(base + dos->e_lfanew);
            if (nt->Signature == IMAGE_NT_SIGNATURE) {
                id = "ts=" + QByteArray::number(uint(nt->FileHeader.TimeDateStamp), 16)
                   + ",size=" + QByteArray::number(uint(nt->OptionalHeader.SizeOfImage), 16);
                const IMAGE_DATA_DIRECTORY &dd =
                    nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DEBUG];
                if (dd.VirtualAddress && dd.Size >= sizeof(IMAGE_DEBUG_DIRECTORY)) {
                    const auto *dbg = reinterpret_cast<const IMAGE_DEBUG_DIRECTORY *>(
                        base + dd.VirtualAddress);
                    for (DWORD k = 0; k < dd.Size / sizeof(IMAGE_DEBUG_DIRECTORY); ++k) {
                        if (dbg[k].Type != IMAGE_DEBUG_TYPE_CODEVIEW || !dbg[k].AddressOfRawData)
                            continue;
                        const unsigned char *cv = base + dbg[k].AddressOfRawData;
                        if (dbg[k].SizeOfData >= 24 && memcmp(cv, "RSDS", 4) == 0) {
                            const GUID *g = reinterpret_cast<const GUID *>(cv + 4);
                            const DWORD age = *reinterpret_cast<const DWORD *>(cv + 20);
                            char gb[80];
                            std::snprintf(gb, sizeof gb,
                                          ",pdb=%08lX%04X%04X%02X%02X%02X%02X%02X%02X%02X%02X:%lu",
                                          (unsigned long)g->Data1, g->Data2, g->Data3,
                                          g->Data4[0], g->Data4[1], g->Data4[2], g->Data4[3],
                                          g->Data4[4], g->Data4[5], g->Data4[6], g->Data4[7],
                                          (unsigned long)age);
                            id += gb;
                            break;
                        }
                    }
                }
            }
        }
        out += "0x" + QByteArray::number(quintptr(mods[i]), 16) + ' ' + id + ' '
             + QString::fromWCharArray(wpath).toLocal8Bit() + '\n';
    }
    return out;
}
#else
// macOS: modules are Mach-O, not ELF/PE — the dyld-API walk is the M2 item of
// docs/plans/mac-port/. Until it exists this returns an HONEST empty list (the
// crash marker, console and backtrace channels are unaffected); an empty
// modules.txt on a Mac means "not implemented", never "no modules".
QByteArray moduleLines() { return {}; }

#endif

QByteArray s_lastModules;                 // change detector — rewrite only on delta

void snapshotModules()
{
    if (s_dir.isEmpty())
        return;
    const QByteArray lines = moduleLines();
    if (lines.isEmpty() || lines == s_lastModules)
        return;
    QSaveFile f(s_dir + QStringLiteral("/modules.txt"));   // atomic: Warden may read mid-write
    if (!f.open(QIODevice::WriteOnly))
        return;
    f.write("# watchtower modules pid=" + QByteArray::number(qlonglong(QCoreApplication::applicationPid()))
            + " build=" + s_build + " qt=" + s_qtVer + " at="
            + QDateTime::currentDateTimeUtc().toString(Qt::ISODate).toUtf8() + '\n');
    f.write(lines);
    if (!f.commit())
        return;
    s_lastModules = lines;
#if !defined(Q_OS_WIN)
    // Raw maps alongside: address-range truth for OOM/fragmentation forensics.
    QFile maps(QStringLiteral("/proc/self/maps"));
    if (maps.open(QIODevice::ReadOnly)) {
        QSaveFile m(s_dir + QStringLiteral("/maps.txt"));
        if (m.open(QIODevice::WriteOnly)) {
            m.write(maps.readAll());
            m.commit();
        }
    }
#endif
    const int count = lines.count('\n');
    qInfo("[FLTREC] modules snapshot: %d modules -> %s/modules.txt", count, qPrintable(s_dir));
}

} // namespace

namespace FlightRecorder {

void install(const char *buildSha)
{
    // ---- part A: arm the crash marker (CW-03) — UNCONDITIONAL. The log-tee
    // knob must never be able to switch off crash forensics.
    s_monoBaseMs = monoMs();
    qstrncpy(s_build, buildSha, sizeof(s_build));
    qstrncpy(s_qtVer, qVersion(), sizeof(s_qtVer));
    const QString crashDir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + QStringLiteral("/crash");
    if (QDir().mkpath(crashDir)) {
        const QByteArray id = QUuid::createUuid().toString(QUuid::WithoutBraces).toUtf8();
        qstrncpy(s_reportId, id.constData(), sizeof(s_reportId));
        const QByteArray marker = (crashDir + QStringLiteral("/marker-") + id
                                   + QStringLiteral(".json")).toLocal8Bit();
        qstrncpy(s_markerPath, marker.constData(), sizeof(s_markerPath));
#if defined(Q_OS_WIN)
        const QString mw = crashDir + QStringLiteral("/marker-") + id + QStringLiteral(".json");
        const QString dw = crashDir + QStringLiteral("/minidump-") + id + QStringLiteral(".dmp");
        if (mw.size() < 511 && dw.size() < 511) {   // toWCharArray doesn't terminate
            s_markerPathW[mw.toWCharArray(s_markerPathW)] = 0;
            s_dumpPathW[dw.toWCharArray(s_dumpPathW)] = 0;
        }
#endif
    }

    // ---- part B: the log tee (env-gated).
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
    // post-mortem reader sees at a glance which version/build/Qt/OS produced
    // what follows (operator ask 2026-08-03: pasted log tails must identify
    // themselves; per-record timestamps come from the default message pattern
    // set in main()).
#ifndef WT_VERSION
#define WT_VERSION "dev"
#endif
    qInfo("=== watchtower start v%s pid=%lld build=%s qt=%s os=%s (flightrec %s, %lldKB x%d) ===",
          WT_VERSION, QCoreApplication::applicationPid(), buildSha, qVersion(),
          qPrintable(QSysInfo::prettyProductName()), qPrintable(dir),
          s_maxBytes / 1024, s_keep);
}

// WHICH TLS BACKEND DID THIS BUILD ACTUALLY GET, and can it speak https at all?
// Asked by CV 2026-09-03 for all three platforms; no single agent has all three
// boxes, so every build states it and the question is closed by measurement
// instead of by letter.
//
// It decides whether an https:// base URL can work AT ALL, and how a certificate
// is validated: SChannel checks the WINDOWS store, OpenSSL the system CA bundle.
// backend=<empty> means https cannot be opened under any configuration.
//
// MUST BE CALLED AFTER THE QGuiApplication EXISTS. Qt cannot scan plugin paths
// until then, so calling it from install() — which runs before the app object —
// reported supportsSsl=0 available=[] on a box whose tls\qschannelbackend.dll is
// present and byte-identical to the SDK's. That was a false negative produced by
// the probe, not a property of the build, and it was one edit away from being
// reported to CV as fact.
void logTlsBackend()
{
    qInfo("[TLS] supportsSsl=%d backend=%s available=[%s] lib=%s",
          int(QSslSocket::supportsSsl()),
          qPrintable(QSslSocket::activeBackend()),
          qPrintable(QSslSocket::availableBackends().join(QLatin1Char(','))),
          qPrintable(QSslSocket::sslLibraryVersionString()));
}

QString directory()
{
    return s_dir;
}

void startPeriodic(QObject *parent)
{
    if (s_dir.isEmpty())
        return;                          // recorder off → snapshots off (dev knob)
    auto *t = new QTimer(parent);
    t->setInterval(30000);
    QObject::connect(t, &QTimer::timeout, snapshotModules);
    t->start();
    // First shot after 5 s: the heavy lazy libraries (FFmpeg/VA plugins) load in
    // the first seconds; 5 s catches the settled set without waiting half a tick.
    QTimer::singleShot(5000, parent, snapshotModules);
}

#if defined(Q_OS_WIN)
void writeCrashArtifacts(unsigned long exceptionCode, long rssMb, void *exceptionPointers)
{
    if (!s_markerPathW[0])
        return;
    // Marker JSON (normal CRT is fine inside an unhandled-exception filter).
    HANDLE mf = CreateFileW(s_markerPathW, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
    if (mf != INVALID_HANDLE_VALUE) {
        char line[640];
        const int len = std::snprintf(line, sizeof(line),
            "{\"schema\":1,\"report_id\":\"%s\",\"kind\":\"exception\",\"exception\":\"0x%08lX\","
            "\"signal\":null,\"epoch\":%lld,\"uptime_s\":%lld,\"rss_mb\":%ld,\"pid\":%lu,"
            "\"build\":\"%s\",\"qt\":\"%s\",\"minidump\":true}\n",
            s_reportId, exceptionCode, (long long)time(nullptr),
            (monoMs() - s_monoBaseMs) / 1000, rssMb, (unsigned long)GetCurrentProcessId(),
            s_build, s_qtVer);
        DWORD written = 0;
        if (len > 0)
            WriteFile(mf, line, DWORD(len), &written, nullptr);
        CloseHandle(mf);
    }
    // Minidump (CW-04): small, module-listed, stack-carrying. WER LocalDumps
    // (installer registry key) remains the belt-and-braces for filter-bypassing
    // crashes (fast-fail, /GS) — we still return EXCEPTION_CONTINUE_SEARCH.
    HANDLE df = CreateFileW(s_dumpPathW, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
    if (df != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION mei;
        mei.ThreadId = GetCurrentThreadId();
        mei.ExceptionPointers = static_cast<EXCEPTION_POINTERS *>(exceptionPointers);
        mei.ClientPointers = FALSE;
        MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), df,
                          MINIDUMP_TYPE(MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules
                                        | MiniDumpScanMemory),
                          exceptionPointers ? &mei : nullptr, nullptr, nullptr);
        CloseHandle(df);
    }
}
#else
int openCrashMarker(int sig, long rssMb)
{
    if (!s_markerPath[0])
        return -1;
    // Async-signal-safe: open/write/snprintf on preformatted statics only.
    const int fd = ::open(s_markerPath, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0)
        return -1;
    char line[640];
    const int len = std::snprintf(line, sizeof(line),
        "{\"schema\":1,\"report_id\":\"%s\",\"kind\":\"signal\",\"signal\":%d,"
        "\"epoch\":%lld,\"uptime_s\":%lld,\"rss_mb\":%ld,\"pid\":%lld,"
        "\"build\":\"%s\",\"qt\":\"%s\"}\n",
        s_reportId, sig, (long long)time(nullptr),
        (monoMs() - s_monoBaseMs) / 1000, rssMb, (long long)getpid(),
        s_build, s_qtVer);
    if (len > 0)
        ::write(fd, line, size_t(len));
    return fd;                            // caller appends backtrace lines + closes
}
#endif

} // namespace FlightRecorder
