#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QVersionNumber>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QFontDatabase>
#include <QImage>
#include <QTimer>
#include <QDebug>
#include <QtQml/qqml.h>
#include <QProcessEnvironment>
#include <gst/gst.h>            // GStreamer is cross-platform (Linux VA-API / Windows d3d11)
#include <csignal>
#include <cstring>
#include <cstdio>
// Platform split: the RSS reader, the crash handler, the fd-limit raise, the glibc arena
// tuning and the Yama ptrace opt-in are all OS-specific. Qt is included above, so Q_OS_WIN /
// Q_OS_LINUX (from <QtGlobal>) are already defined here. Everything outside these blocks is
// portable Qt/QML/GStreamer. (Windows port W0 — docs/plans/windows-port/W0-*.prompt.md.)
#if defined(Q_OS_WIN)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#  include <psapi.h>            // GetProcessMemoryInfo (RSS) — link psapi (CMakeLists WIN32 block)
#else
#  include <sys/resource.h>     // getrlimit/setrlimit(RLIMIT_NOFILE)
#  include <sys/prctl.h>        // prctl(PR_SET_PTRACER) — Yama, Linux-only
#  include <malloc.h>           // mallopt/malloc_trim — glibc arena control, Linux-only
#  include <unistd.h>           // read/write/close/sysconf
#  include <fcntl.h>            // open, O_RDONLY
#  include <execinfo.h>         // backtrace — async-signal-safe crash trace
#endif

#include "AuthController.h"
#include "models/CvImageProvider.h"
#include "models/RtspVideoSource.h"
#include "models/MemTelemetry.h"
#include "models/FrameClock.h"
#include "models/FrameCache.h"
#include "models/LanguageController.h"

namespace {

// This process's resident size in MB. Linux: read /proc/self/statm with only open/read/close
// so it is async-signal-safe (called from the fatal-signal handler below). Windows: PSAPI
// WorkingSetSize — the SEH crash path is not bound by POSIX signal-safety, so this is fine.
long readRssMb()
{
#if defined(Q_OS_WIN)
    PROCESS_MEMORY_COUNTERS pmc;
    if (::GetProcessMemoryInfo(::GetCurrentProcess(), &pmc, sizeof(pmc)))
        return long(pmc.WorkingSetSize / (1024 * 1024));
    return -1;
#else
    int fd = ::open("/proc/self/statm", O_RDONLY);
    if (fd < 0)
        return -1;
    char b[64];
    ssize_t n = ::read(fd, b, sizeof(b) - 1);
    ::close(fd);
    if (n <= 0)
        return -1;
    b[n] = '\0';
    long pagesTotal = 0, pagesResident = 0;
    if (std::sscanf(b, "%ld %ld", &pagesTotal, &pagesResident) != 2)
        return -1;
    return pagesResident * (sysconf(_SC_PAGESIZE) / 1024) / 1024;
#endif
}

// Fatal-crash reporter. Prints WHAT killed the process and the RSS at death, so the terminal
// log alone disambiguates the failure modes we keep hitting, then hands off to the OS default
// so the real exit status / core dump / crash dump is preserved for offline analysis.
#if defined(Q_OS_WIN)
// Windows: an unhandled-exception filter. Logs the exception code + RSS, then
// EXCEPTION_CONTINUE_SEARCH so WER (or procdump -ma, the W3 soak-supervisor mechanism)
// produces the actual minidump — the analogue of the Linux re-raise-with-SIG_DFL below.
LONG WINAPI wtUnhandledException(EXCEPTION_POINTERS *info)
{
    const unsigned long code = (info && info->ExceptionRecord)
                                   ? (unsigned long)info->ExceptionRecord->ExceptionCode : 0UL;
    long rss = readRssMb();
    char line[320];
    int len = std::snprintf(line, sizeof(line),
        "\n[WT-FATAL] unhandled exception 0x%08lX; RSS=%ld MB. "
        "0xC0000005=access violation, 0xC00000FD=stack overflow = code crash; a memory dump "
        "(WER / procdump -ma, see docs W3) carries the stack.\n",
        code, rss);
    if (len > 0)
        ::fwrite(line, 1, size_t(len), stderr);
    ::fflush(stderr);
    return EXCEPTION_CONTINUE_SEARCH;   // let WER/procdump produce the dump, then terminate
}

void installCrashHandlers()
{
    ::SetUnhandledExceptionFilter(wtUnhandledException);
}
#else
// Linux: a POSIX signal handler.
//   • SIGTERM / SIGKILL at high RSS  → the OS/earlyoom killed us for memory ("Terminated"/"Killed") —
//     NOT a code bug; the fix is to use less RAM.
//   • SIGSEGV / SIGABRT / SIGBUS     → a genuine code crash — a backtrace follows.
// Re-raises with the default handler so the real exit status / core dump is preserved.
void wtFatalHandler(int sig)
{
    long rss = readRssMb();
    char line[320];
    int len = std::snprintf(line, sizeof(line),
        "\n[WT-FATAL] killed by signal %d (%s); RSS=%ld MB. "
        "SIGTERM(15)/SIGKILL(9) at high RSS = OOM/earlyoom (memory pressure), not a code crash; "
        "SIGSEGV(11)/SIGABRT(6)/SIGBUS(7) = code crash, backtrace follows.\n",
        sig, ::strsignal(sig), rss);
    if (len > 0)
        ::write(STDERR_FILENO, line, size_t(len));
    if (sig == SIGSEGV || sig == SIGABRT || sig == SIGBUS || sig == SIGFPE) {
        void *bt[64];
        int n = ::backtrace(bt, 64);
        ::backtrace_symbols_fd(bt, n, STDERR_FILENO);   // async-signal-safe (unlike _symbols)
    }
    ::signal(sig, SIG_DFL);
    ::raise(sig);
}

void installCrashHandlers()
{
    for (int s : {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGTERM})
        ::signal(s, wtFatalHandler);
}
#endif

// Load the self-hosted, bundled fonts (OFL) so the families are available to
// every QML file without a per-file FontLoader.
void loadBundledFonts()
{
    const QStringList files = {
        QStringLiteral(":/fonts/SpaceGrotesk-Variable.ttf"),
        QStringLiteral(":/fonts/JetBrainsMono-Regular.ttf"),
        QStringLiteral(":/fonts/JetBrainsMono-Medium.ttf"),
        QStringLiteral(":/fonts/JetBrainsMono-SemiBold.ttf"),
    };
    for (const QString &f : files) {
        if (QFontDatabase::addApplicationFont(f) < 0)
            qWarning() << "Watchtower: failed to load bundled font" << f;
    }
}

// Dev/verification hook: if WT_SCREENSHOT=<path> is set, grab the root window to
// that PNG once it has rendered, then quit. WT_SCREENSHOT_MS overrides the delay.
void maybeArmScreenshot(QQmlApplicationEngine &engine)
{
    const QByteArray path = qgetenv("WT_SCREENSHOT");
    if (path.isEmpty() || engine.rootObjects().isEmpty())
        return;
    auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (!win)
        return;
    int delayMs = qEnvironmentVariableIntValue("WT_SCREENSHOT_MS");
    if (delayMs <= 0)
        delayMs = 900;
    QTimer::singleShot(delayMs, win, [win, path]() {
        const QImage img = win->grabWindow();
        if (!img.isNull() && img.save(QString::fromLocal8Bit(path)))
            qInfo() << "Watchtower: screenshot saved" << path << img.size();
        else
            qWarning() << "Watchtower: screenshot failed" << path;
        QCoreApplication::quit();
    });
}

} // namespace

int main(int argc, char *argv[])
{
    // Capture the death cause (OOM/earlyoom SIGTERM vs a real code SIGSEGV) before anything else.
    installCrashHandlers();

    // WT_PTRACE_ANY=1 (dev/soak only): allow ANY same-user process to ptrace-attach.
    // Yama ptrace_scope=1 only lets an ANCESTOR attach, but a soak supervisor's
    // `gdb -p` is a SIBLING of the app — so a live-wedge stack dump (the whole point
    // of the hang-aware supervisor) is denied without this. Inert unless set.
    // Linux/Yama-specific; on Windows the W3 supervisor uses procdump (no opt-in needed).
#if defined(Q_OS_LINUX)
    if (qEnvironmentVariableIsSet("WT_PTRACE_ANY"))
        prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
#endif

    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("Watchtower"));
    QGuiApplication::setApplicationDisplayName(QStringLiteral("Watchtower"));
    QGuiApplication::setOrganizationName(QStringLiteral("Cilex Vision"));

    // --- per-open RSS retention control (the dominant memory growth during a review shift) ---
    // Playback churns large transient buffers every recording open — decoded frames (~5.5 MB at
    // 1440p), HLS segments, snapshot QImages. glibc's *dynamic* mmap threshold ratchets up as these
    // are freed, so later allocations of the same size land in the main arena instead of being
    // mmap'd; their freed space is then retained on the arena free-lists (not returned to the OS) and,
    // fragmented by the churn, the arena high-water-mark climbs unboundedly. This is RETENTION, not an
    // unfreed leak — `mallinfo2` in_use stays flat (~270 MB) while RSS climbs +66 MB/min. Pin a low,
    // fixed mmap threshold so large allocs are mmap'd and munmap'd straight back to the OS on free,
    // and a low trim threshold + a periodic malloc_trim() so the arena top is returned too.
    // (Localized 2026-06-29 via an LD_PRELOAD malloc-site tracer; see docs/perf deep-dive.)
    // glibc-specific: the Windows CRT heap (segment-based, decommits on free) does not exhibit
    // this arena-retention pathology, so there is nothing to tune there.
#if defined(Q_OS_LINUX)
    int mmapKb = qEnvironmentVariableIntValue("WT_MMAP_KB");   // tunable; default 128 KB
    if (mmapKb <= 0) mmapKb = 128;
    mallopt(M_MMAP_THRESHOLD, mmapKb * 1024);
    mallopt(M_TRIM_THRESHOLD, mmapKb * 1024);
    static QTimer s_trimTimer;
    QObject::connect(&s_trimTimer, &QTimer::timeout, [] { malloc_trim(0); });
    s_trimTimer.start(15000);
#endif

    // QtMultimedia (GStreamer backend, VA-API HW decode) renders video frames
    // through the scene graph; pin the OpenGL RHI backend before any window.
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    // Native (FreeType-hinted) text rendering — crisper for this dense UI than
    // the default distance-field rendering, which can look soft at small sizes.
    QQuickWindow::setTextRenderType(QQuickWindow::NativeTextRendering);

    // Unstyled "Basic" Controls style so our design tokens fully dictate the look.
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    loadBundledFonts();

    // Raise the file-descriptor soft limit to the hard limit so transient bursts
    // of GStreamer pipeline create/destroy (rapid layout switches → many sockets
    // + pipe pairs in flight) don't hit a 1024-fd default the launcher may have
    // imposed. RtspVideoSource also caps concurrent teardowns; this is belt-
    // and-suspenders against environment-imposed limits.
    // POSIX rlimit; Windows has no equivalent per-process fd soft-cap (its handle
    // limit is ~16M and not shell-imposed), so this is a no-op there.
#if defined(Q_OS_LINUX)
    {
        struct rlimit rl;
        if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
            rl.rlim_cur = rl.rlim_max;
            setrlimit(RLIMIT_NOFILE, &rl);
        }
    }
#endif

    // Initialize GStreamer for the opt-in low-latency RTSP path (RtspVideoSource).
    // Idempotent — QtMultimedia's backend also inits it for the default path.
    gst_init(nullptr, nullptr);

    // Silence ONE benign GStreamer churn assertion. Rapid live-pipeline teardown/rebuild (fullscreen,
    // layout change, wall camera-swap) makes a decodebin/VA-API element push a flush event whose seqnum is
    // still INVALID, tripping "gst_event_set_seqnum: assertion 'seqnum != GST_SEQNUM_INVALID' failed". It is a
    // g_return_if_fail (non-fatal — GStreamer proceeds) that we do not emit and cannot fix at the call site,
    // but it spams the log under stress (256× in a 12 h soak). Drop only that exact message; forward everything
    // else to GLib's default handler so real GStreamer criticals/warnings still surface.
    g_log_set_handler("GStreamer",
        (GLogLevelFlags)(G_LOG_LEVEL_CRITICAL | G_LOG_LEVEL_WARNING | G_LOG_FLAG_FATAL | G_LOG_FLAG_RECURSION),
        [](const gchar *domain, GLogLevelFlags level, const gchar *message, gpointer user) {
            if (message && std::strstr(message, "gst_event_set_seqnum"))
                return;                                    // benign churn assertion — swallow
            g_log_default_handler(domain, level, message, user);
        },
        nullptr);

    // Session owner + the one shared network manager every model uses. Created
    // before the engine loads so AuthController::instance() is valid when the
    // QML-instantiated models are constructed.
    auto *auth = new AuthController(&app);
    auth->restoreSession();
    // Opt-in dev convenience: WT_CV_AUTOLOGIN skips the login screen using the
    // WT_CV_USER/WT_CV_PASS service creds (previous always-on behaviour).
    if (qEnvironmentVariableIsSet("WT_CV_AUTOLOGIN") && !auth->authenticated()) {
        const auto env = QProcessEnvironment::systemEnvironment();
        // Fall back to the base URL restoreSession() already resolved (saved settings, or the built-in
        // default) when WT_CV_URL is unset — otherwise loginWithPassword() overwrites it with "" and
        // the auto-login silently fails (no token → /streams 401 → empty wall).
        auth->loginWithPassword(env.value("WT_CV_URL", auth->baseUrl()),
                                env.value("WT_CV_USER", "admin"),
                                env.value("WT_CV_PASS", "admin"));
    }

    QQmlApplicationEngine engine;
    // Authenticated backend images (event-moment snapshots): image://cvframe/<path>.
    engine.addImageProvider(QStringLiteral("cvframe"), new CvImageProvider(auth));
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed,
        &app, []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);

    // Exposed to QML as a context property (not a module type) so it does not
    // interfere with the qt_add_qml_module type registry.
    engine.rootContext()->setContextProperty("AuthController", auth);

    // UI language (EN/RU). Default follows the OS language; the operator's choice in
    // Preferences overrides + persists. Install the initial translator BEFORE load so
    // the first frame is already in the right language; switching later is live.
    auto *language = new LanguageController(&engine, &app);
    engine.rootContext()->setContextProperty("Language", language);
    language->applyInitial();

    // Field memory telemetry — periodic [MEMTEL] log of RSS + cumulative active-playback seconds + open
    // count, so a real shift self-reports whether the residual per-open RSS growth is shift-breaking.
    engine.rootContext()->setContextProperty("MemTel", new MemTelemetry(&app));

    // Frame-PTS probe/clock for frame stepping (docs/plans/2026-07-08-frame-step-plan.md).
    // Inert until a QML surface attaches its videoSink. WT_STEPSPIKE=<reps> runs the P0
    // measurement sequence in PlaybackScreen and quits.
    engine.rootContext()->setContextProperty("FrameClock", new FrameClock(&app));
    // Decoded-frame cache: instant hot backward steps (capture is step-gated inside
    // FrameStepper) + the frame-by-frame filmstrip's thumbnails (image://fcache/...).
    auto *frameCache = new FrameCache(&app);
    engine.rootContext()->setContextProperty("FrameCache", frameCache);
    engine.addImageProvider(QStringLiteral("fcache"), new FrameCacheImageProvider(frameCache));
    engine.rootContext()->setContextProperty("wtStepSpike", qEnvironmentVariableIntValue("WT_STEPSPIKE"));
    // Dev/test: auto-enter frame-by-frame mode once playback renders (screenshots/CI).
    engine.rootContext()->setContextProperty("wtFrameMode", qEnvironmentVariableIsSet("WT_FRAME_MODE"));
    // WT_STEPTEST=<N>: FrameStepper acceptance — N forward steps + backward smoke, then quit.
    engine.rootContext()->setContextProperty("wtStepTest", qEnvironmentVariableIntValue("WT_STEPTEST"));

    // Events section routing. The EventsArea redesign is now the DEFAULT (fed by
    // the live cilex-vision /events feed). WT_DEMO runs the same redesign on the
    // mock events-v2 showcase store; WT_EVENTS_LEGACY falls back to the old
    // table-style EventsScreen.
    engine.rootContext()->setContextProperty("wtDemo", qEnvironmentVariableIsSet("WT_DEMO"));
    engine.rootContext()->setContextProperty("wtEventsLegacy", qEnvironmentVariableIsSet("WT_EVENTS_LEGACY"));
    // Measurement knob (WT_THUMB_SCALE=<px>): cap the snapshot-tile Image sourceSize to <px> wide so
    // non-live tiles decode small JPEGs instead of full-res — measures the snapshot-side memory saving
    // of display-resolution rendering. 0 (unset) = decode at native size (current behaviour).
    engine.rootContext()->setContextProperty("wtThumbScale", qEnvironmentVariableIntValue("WT_THUMB_SCALE"));
    // WT_THUMB_REFRESH_MS: decode-capped live-tile snapshot poll interval (default 1000; the cached endpoint
    // makes a fast poll cheap). Lower = less apparent lag on capped tiles.
    engine.rootContext()->setContextProperty("wtThumbRefreshMs", qEnvironmentVariableIntValue("WT_THUMB_REFRESH_MS"));
    // Test drivers (env-gated, inert unless set): programmatic resize / playback-seek / events stress
    // harnesses that drive the UI deterministically and log timestamps for the external CPU/RSS sampler.
    engine.rootContext()->setContextProperty("wtResizeTest", qEnvironmentVariableIsSet("WT_RESIZE_TEST"));
    engine.rootContext()->setContextProperty("wtSeekTest", qEnvironmentVariableIsSet("WT_SEEK_TEST"));
    engine.rootContext()->setContextProperty("wtSeekIters", qEnvironmentVariableIntValue("WT_SEEK_ITERS"));
    engine.rootContext()->setContextProperty("wtSeekSpan", qEnvironmentVariableIntValue("WT_SEEK_SPAN"));
    engine.rootContext()->setContextProperty("wtEventsTest", qEnvironmentVariableIsSet("WT_EVENTS_TEST"));
    engine.rootContext()->setContextProperty("wtTrace", qEnvironmentVariableIsSet("WT_TRACE"));
    // RUNTIME Qt version (what the loader actually resolved, not the compile SDK).
    // It decides the QtMultimedia backend: <6.5 → GStreamer (souphttpsrc), which
    // SIGSEGVs in libsoup under playback seek/day-switch churn (P0, root-caused
    // 2026-07-01 — docs/perf/2026-07-01-calendar-soak-results.md); ≥6.5 → FFmpeg,
    // validated stable (8.8 h soak, 0 crashes). Surfaced to QML so the Playback
    // screen can warn persistently when someone launches the crash-prone build
    // directly instead of via ./run.sh.
    engine.rootContext()->setContextProperty("wtQtRuntime", QString::fromLatin1(qVersion()));
    if (QVersionNumber::fromString(QString::fromLatin1(qVersion())) < QVersionNumber(6, 5))
        qWarning("Watchtower: RUNTIME Qt %s -> GStreamer media backend: recorded playback "
                 "can crash (libsoup SIGSEGV) under seek churn. Launch via ./run.sh "
                 "(Qt 6.8.3 / FFmpeg).", qVersion());
    engine.rootContext()->setContextProperty("wtHeroAutoplay", qEnvironmentVariableIsSet("WT_HERO_AUTOPLAY"));
    engine.rootContext()->setContextProperty("wtHeroTest", qEnvironmentVariableIsSet("WT_HERO_TEST"));
    engine.rootContext()->setContextProperty("wtHeroOpenonly", qEnvironmentVariableIsSet("WT_HERO_OPENONLY"));
    // WT_HERO_SETTLE_MS: openonly per-open dwell (playback time before re-selecting). Default ~2.1s.
    // Raising it (e.g. 30000) holds fewer opens at equal playback time → discriminates open-driven vs
    // playback-time-driven RSS growth.
    engine.rootContext()->setContextProperty("wtHeroSettleMs", qEnvironmentVariableIntValue("WT_HERO_SETTLE_MS"));
    engine.rootContext()->setContextProperty("wtHeroNoplay", qEnvironmentVariableIsSet("WT_HERO_NOPLAY"));
    engine.rootContext()->setContextProperty("wtSeekDirect", qEnvironmentVariableIsSet("WT_SEEK_DIRECT"));
    // Optional camera to focus in the video test (by IP); empty -> first camera.
    engine.rootContext()->setContextProperty("wtTestIp", qEnvironmentVariable("WT_TEST_IP"));
    // Optional initial section (dev: WT_SECTION=groups|live|...).
    engine.rootContext()->setContextProperty("wtSection", qEnvironmentVariable("WT_SECTION"));
    // Optional initial Events sub-view (dev: WT_EVENTS_VIEW=triage|review|timeline|map).
    engine.rootContext()->setContextProperty("wtEventsView", qEnvironmentVariable("WT_EVENTS_VIEW"));
    // Optional initial Live status filter (dev: WT_STATUS_FILTER=recent|online|offline|...).
    engine.rootContext()->setContextProperty("wtStatusFilter", qEnvironmentVariable("WT_STATUS_FILTER"));
    // Optional initial Live camera group, by NAME (dev: WT_GROUP=Office).
    engine.rootContext()->setContextProperty("wtGroup", qEnvironmentVariable("WT_GROUP"));
    // Optional camera to open focused on boot, by IP (dev: WT_FOCUS_IP=192.168.1.108).
    engine.rootContext()->setContextProperty("wtFocusIp", qEnvironmentVariable("WT_FOCUS_IP"));
    // Max concurrent live VA-API decodes on the wall (WT_MAX_DECODES=N; 0/unset = default).
    // Each live decode holds hundreds of MB on the shared iGPU; tiles beyond the cap show a
    // periodic snapshot instead. Lower on a weak/loaded box, raise on a strong GPU.
    engine.rootContext()->setContextProperty("wtMaxDecodes", qEnvironmentVariableIntValue("WT_MAX_DECODES"));
    // WT_GUARD_SOAK: long-run guard-usage emulator (Live dwell + periodic click-throughs); WT_GUARD_LIVE_MS
    // tunes the Live dwell (default ~17 min). Drives navigation + logs [GUARD] for RSS/CPU attribution.
    engine.rootContext()->setContextProperty("wtGuardSoak", qEnvironmentVariableIsSet("WT_GUARD_SOAK"));
    engine.rootContext()->setContextProperty("wtGuardLiveMs", qEnvironmentVariableIntValue("WT_GUARD_LIVE_MS"));
    // Optional camera to open in Playback on boot, by IP (dev: WT_PLAYBACK_IP=192.168.1.106).
    engine.rootContext()->setContextProperty("wtPlaybackIp", qEnvironmentVariable("WT_PLAYBACK_IP"));
    // Optional: open WT_PLAYBACK_IP's playback on a specific day (dev:
    // WT_PLAYBACK_DAY=2026-05-28), or at a local instant when a "T" is present
    // (dev: WT_PLAYBACK_DAY=2026-06-07T00:44:10 → that day, seeked there −15s).
    engine.rootContext()->setContextProperty("wtPlaybackDay", qEnvironmentVariable("WT_PLAYBACK_DAY"));
    // Optional: open synchronized wall playback on boot over the live page's cameras
    // (dev: WT_WALL_DAY=2026-05-29, or WT_WALL_DAY=live for the last hour).
    engine.rootContext()->setContextProperty("wtWallDay", qEnvironmentVariable("WT_WALL_DAY"));
    // Calendar + historic-playback STRESS driver (dev/soak): rotates over the roster,
    // opening a day, scrubbing it, then clicking the next day — exercising the calendar
    // navigation, session load/seek ("awfully slow" under a degraded backend) and the
    // GUI-thread session teardown ("stops responding" on the .201 report). Logs [CAL]
    // lines. Starts on WT_PLAYBACK_IP if given.
    engine.rootContext()->setContextProperty("wtCalStress", qEnvironmentVariableIsSet("WT_CAL_STRESS"));
    // WT_NIGHT_SOAK: comprehensive overnight endurance/stress harness — historic-playback
    // timing (calendar-open → first frame, seek → frame-land, flag >1 s), full export matrix
    // (every camera / quality / size, HD-older-than-5-days policy, select+cancel, Esc focus),
    // and seek-bar-visibility invariant. Logs [NTIME]/[NSLOW]/[NSEEK]/[XSOAK]/[XRESULT]/
    // [ESCTEST]/[SEEKBAR]. Run on real Wayland (Qt 6.12 offscreen SIGBUSes). See qml/Main.qml.
    engine.rootContext()->setContextProperty("wtNightSoak", qEnvironmentVariableIsSet("WT_NIGHT_SOAK"));
    // WT_SOAK_NOEXPORT: run the night-soak with pure playback churn (skip the export +
    // export-drawer steps) — bisects whether the ~840s FFmpeg-backend crash is triggered
    // by the export path or by the open/seek churn itself.
    engine.rootContext()->setContextProperty("wtSoakNoExport", qEnvironmentVariableIsSet("WT_SOAK_NOEXPORT"));
    // WT_SOAK_FIX_CAM=<ip> / WT_SOAK_FIX_DAY=<yyyy-MM-dd>: pin the night-soak to one
    // camera/day — the targeted GUI-wedge repro (heavy-day + export + drawer-grab
    // coincidence, docs/perf/2026-07-03-night-soak-gui-wedge.prompt.md). Inert unless set.
    engine.rootContext()->setContextProperty("wtSoakFixCam", qEnvironmentVariable("WT_SOAK_FIX_CAM"));
    engine.rootContext()->setContextProperty("wtSoakFixDay", qEnvironmentVariable("WT_SOAK_FIX_DAY"));
    // WT_GRAB_STORM=<n>: fire n extra VideoOutput grabToImage readbacks (250 ms apart)
    // each night-soak drawer step — amplifies the rare grab/render race ~40× so a
    // 1-in-3h wedge becomes reproducible. Inert unless set.
    engine.rootContext()->setContextProperty("wtGrabStorm", qEnvironmentVariableIntValue("WT_GRAB_STORM"));
    // WT_PB_WINDOW_FRAGS: ready-fragment threshold above which a fresh day/span open
    // attaches the player to a bounded ~30 min window (scrubber stays full-day;
    // EndOfMedia rolls forward) instead of the full playlist. 0/unset → default 1200.
    // Test: 1 forces bounded for every open; a huge value disables it.
    engine.rootContext()->setContextProperty("wtPbWindowFrags", qEnvironmentVariableIntValue("WT_PB_WINDOW_FRAGS"));
    // WT_SEEK_SPAM=1: chaotic scrubber click-spam driver — bursts of rapid random
    // seekToWall calls with NO waiting (the operator gesture reported 2026-07-03:
    // "click fast and chaotically → lots of freezes"). Deterministic targets, logs
    // [SPAM] click/recovered lines. Pair with WT_PLAYBACK_IP/WT_PLAYBACK_DAY.
    engine.rootContext()->setContextProperty("wtSeekSpam", qEnvironmentVariableIntValue("WT_SEEK_SPAM"));
    // QA self-test: WT_SMOOTHTEST=<seconds> attaches a playback smoothness/sync
    // probe (frame-vs-playhead desync + freeze detection) and prints WTSMOOTH
    // lines, then quits. See qml/PlaybackScreen.qml SmoothnessProbe.
    engine.rootContext()->setContextProperty("wtSmoothTest", qEnvironmentVariable("WT_SMOOTHTEST"));
    // QA: WT_TTFF_DAYS="2026-06-30,2026-07-01,…" — open each day in turn in Playback
    // on a warm app, log [TTFF]/[PBTIME] (calendar-click → first rendered frame), then
    // quit. Pair with WT_PLAYBACK_IP. Measures the "historic playback is slow to
    // start" path end-to-end. See qml/PlaybackScreen.qml ttffRun.
    engine.rootContext()->setContextProperty("wtTtffDays", qEnvironmentVariable("WT_TTFF_DAYS"));
    // WT_TTFF_EOS=1: during the WT_TTFF_DAYS harness, seek near the loaded window's end
    // after each open so EndOfMedia → the bounded-window roll-over is exercised.
    engine.rootContext()->setContextProperty("wtTtffEos", qEnvironmentVariableIsSet("WT_TTFF_EOS"));
    // QA: WT_WALLPERF=1 (or =quick) attaches the synchronized-wall seek/re-composite
    // latency harness (drives the playhead over fixed offsets, measures time-to-replay
    // across all 16 cells). Logs "WALLPERF,..." CSV lines. Needs a real GPU (VA-API).
    engine.rootContext()->setContextProperty("wtWallPerf", qEnvironmentVariable("WT_WALLPERF"));
    // Live RTSP path: low-latency by default (custom GStreamer pipeline →
    // QVideoSink, rtspsrc latency≈150 ms). QMediaPlayer's default 2000 ms
    // jitter buffer is unusable for monitoring — proven so during the spike.
    // WT_LEGACY=1 falls back to the QMediaPlayer path for A/B comparison or
    // emergency fallback if rtspsrc tuning misbehaves. WT_LOWLATENCY is still
    // honored as a no-op for old muscle memory / scripts.
    const bool useLegacy = qEnvironmentVariableIsSet("WT_LEGACY");
    engine.rootContext()->setContextProperty("wtLowLatency", !useLegacy);
    // RTSP jitter-buffer override for the low-latency path. Default 500 ms (see
    // VideoSurface.qml). Lower = fresher live, more prone to green-frame resets
    // under packet loss; higher = steadier, more glass-to-glass lag.
    engine.rootContext()->setContextProperty("wtRtspLatencyMs",
        qEnvironmentVariableIntValue("WT_RTSP_LATENCY_MS"));
    // Build identifier (short git SHA), shown on the login screen so a relaunch
    // confirms which binary is running. Set via CMake compile definition.
#ifdef WT_GIT_SHA
    engine.rootContext()->setContextProperty("wtBuild", QStringLiteral(WT_GIT_SHA));
#else
    engine.rootContext()->setContextProperty("wtBuild", QStringLiteral("dev"));
#endif

    // WT_VIDEOTEST loads the single-stream video test instead of the app shell;
    // WT_TEST_HDCAP runs the headless live-wall HD-cap self-test (exits 0/1).
    QString entry = QStringLiteral("qrc:/qt/qml/Watchtower/qml/Main.qml");
    if (qEnvironmentVariableIsSet("WT_VIDEOTEST"))
        entry = QStringLiteral("qrc:/qt/qml/Watchtower/qml/VideoTest.qml");
    else if (qEnvironmentVariableIsSet("WT_TEST_HDCAP"))
        entry = QStringLiteral("qrc:/qt/qml/Watchtower/qml/HdCapTest.qml");
    // WT_TEST_QML=<file> loads an arbitrary QML file (dev-only; the Watchtower
    // module stays registered, so the file can `import Watchtower`). For
    // iterating on a screen/overlay offscreen without rebuilding the qrc.
    else if (qEnvironmentVariableIsSet("WT_TEST_QML"))
        entry = QUrl::fromLocalFile(qEnvironmentVariable("WT_TEST_QML")).toString();
    engine.load(QUrl(entry));

    maybeArmScreenshot(engine);

    // WT_TRACE: every 2 s log RSS + live VA-API pipeline count + total frames, so RSS growth can be
    // correlated with decode activity — a stable pipeline count with steadily rising RSS points to a
    // per-decode VA-API surface leak rather than pipeline accumulation.
    if (qEnvironmentVariableIsSet("WT_TRACE")) {
        static QTimer memTimer;
        QObject::connect(&memTimer, &QTimer::timeout, [] {
            qInfo().noquote() << QStringLiteral("[WT-MEM] rss=%1MB live_pipelines=%2 frames=%3")
                .arg(readRssMb())
                .arg(RtspVideoSource::livePipelineCount())
                .arg(RtspVideoSource::totalFramesDelivered());
        });
        memTimer.start(2000);
    }

    return app.exec();
}
