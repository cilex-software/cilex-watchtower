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
namespace FlightRecorder
{
// Install the tee. Call once, as early as possible after the application
// identity (org/app name) is set — the default dir derives from it.
void install(const char *buildSha);

// Where the recorder is writing ("" when disabled) — Warden's collector reads
// this dir; also logged at install so the location is discoverable post-mortem.
QString directory();
}
