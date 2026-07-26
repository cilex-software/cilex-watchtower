#pragma once

#include <QString>

// Flight recorder (Warden CW-01): tees every Qt log message — qDebug/qInfo/
// qWarning/qCritical, QML console.*, category logs — into a rotating file set in
// the app data dir, so the recent past is ALWAYS on disk when the process dies.
// On Windows this is the only journal there is; on Linux it doubles journald so
// Warden's bundle format is identical on both platforms.
//
// Design rules (see docs/plans/warden-build-plan.md):
//  - The console/journald behaviour is UNCHANGED: the previous handler is chained
//    verbatim, so soak harnesses that grep stdout/stderr keep working.
//  - Crash-durable, not power-durable: every line is flushed to the kernel
//    (survives SIGSEGV/SIGKILL of the process); no fsync per line (process death
//    is the threat model, not power loss — and Warden uploads soon after anyway).
//  - Never recursive, never throws, never logs through itself.
//
// Env knobs: WT_FLIGHTREC_OFF=1 disables; WT_FLIGHTREC_DIR overrides the dir;
// WT_FLIGHTREC_BYTES per-file rotation size (default 10 MB); WT_FLIGHTREC_KEEP
// rotated-file count (default 5).
class QObject;

namespace FlightRecorder
{
// Install the tee AND arm the crash marker (CW-03). Call once, as early as
// possible after the application identity (org/app name) is set — the default
// dirs derive from it. Marker arming is unconditional; WT_FLIGHTREC_OFF only
// disables the log tee + module snapshots, never crash forensics.
void install(const char *buildSha);

// Start the periodic module/BuildID snapshot (CW-02) — needs a running event
// loop, so it's a separate call made right after the QGuiApplication exists.
// Writes <flightrec>/modules.txt (+ maps.txt on Linux) whenever the loaded
// module set changes; that is what lets a bare [WT-FATAL] backtrace be
// symbolized offline against the exact binaries the guard box was running
// (the 2026-07-25 P0 was symbolized by hand for want of exactly this file).
void startPeriodic(QObject *parent);

// Where the recorder is writing ("" when disabled) — Warden's collector reads
// this dir; also logged at install so the location is discoverable post-mortem.
QString directory();

// ---- crash-time API (called from the fatal handler in main.cpp) ----
#if defined(Q_OS_WIN)
// Windows: write the marker JSON + a minidump (MiniDumpWriteDump) next to it.
// Runs inside the unhandled-exception filter — normal CRT is permitted there.
void writeCrashArtifacts(unsigned long exceptionCode, long rssMb, void *exceptionPointers);
#else
// Linux: async-signal-safe. Opens <AppData>/crash/marker-<report_id>.json and
// writes the one-line JSON header (signal, epoch, uptime, rss, build, qt, pid);
// returns the fd so the caller can append backtrace_symbols_fd() lines, or -1
// when unarmed. First line JSON, rest raw backtrace — Warden parses leniently.
int openCrashMarker(int sig, long rssMb);
#endif
}
