#!/usr/bin/env bash
# Cilex Watchtower launcher — ALWAYS start the app with this (or ./run.sh, an alias).
#
# PRIMARY toolchain: Qt 6.12.0 (mature FFmpeg media backend) -> build/.
# The old Ubuntu system Qt 6.4.2 is BANNED and can no longer even configure (CMake
# floor is 6.8): its GStreamer backend SIGSEGVs in libsoup during playback seeks (the
# P0, root-caused 2026-07-01, recurred 2026-07-02) and its VideoOutput leaks a
# frame-buffer per frame -> OOM. See docs/DEVELOPMENT.md.
#
# FALLBACK: Qt 6.8.3 LTS is the 8.8h-soak-validated runtime, kept as a safety net.
#   WT_QT_PREFIX="$HOME/Qt/6.8.3/gcc_64" WT_BUILD_DIR=build68 ./run-watchtower.sh
# (6.12 and 6.8.3 both use FFmpeg; 6.12 does NOT fix the residual per-open decode
# leak — it's ~+2 MB/min vs 6.8.3 — so the fallback loses nothing on that front.)
#
# The binary alone does NOT pin its Qt — without the LD_LIBRARY_PATH this script sets,
# it would load whatever libQt6*.so the system linker finds. Hence: always this script.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dev/pilot session continuity (2026-08-03): the backend token lives ~10 h, and a
# wall without credentials falls to the sign-in screen when it dies mid-shift
# (observed: token expired 11:07, wall dead-quiet until manually restarted).
# With WT_CV_AUTOLOGIN the app logs in at boot AND renews the session in the
# background (AuthController: proactive T-10min re-login + in-place 401
# recovery) — the wall never drops. Export WT_CV_AUTOLOGIN= (empty) to opt out;
# production stations will get these from the Warden unit env instead.
export WT_CV_AUTOLOGIN="${WT_CV_AUTOLOGIN-1}"
[ -z "$WT_CV_AUTOLOGIN" ] && unset WT_CV_AUTOLOGIN
# DEFAULT RUNTIME (2026-07-12, operator decision): the internally PATCHED Qt
# overlay — Qt 6.12 (v6.12.0-beta1 stack) with third_party/qt-patches/6.12/
# applied (poison-frame fix at the source + adjacent defects; validated 13/13,
# docs/qt-upstream/2026-07-12-delivery-report.md). Built by
# tools/build-patched-qt/build.sh. On machines without the patched prefix we
# fall back to the SDK with a loud notice (the in-app pre-map guard still
# intercepts the upstream defect there). WT_QT_PREFIX always overrides.
QT_PATCHED="$HOME/Qt/6.12.0-patched-beta1"
QT_SDK="$HOME/Qt/6.12.0/gcc_64"
if [[ -n "${WT_QT_PREFIX:-}" ]]; then
    QT="$WT_QT_PREFIX"
elif [[ -d "$QT_PATCHED/lib" ]]; then
    QT="$QT_PATCHED"
else
    QT="$QT_SDK"
    echo "watchtower: patched Qt not found at $QT_PATCHED — running on UNPATCHED SDK Qt" >&2
    echo "            (upstream poison-frame defect present; the in-app guard covers it)." >&2
    echo "            Build it: tools/build-patched-qt/make-dev-sysroot.sh && tools/build-patched-qt/build.sh" >&2
fi
BUILD="${WT_BUILD_DIR:-$DIR/build}"

if [[ ! -d "$QT/lib" ]]; then
    echo "Qt runtime not found at $QT (override with WT_QT_PREFIX=<gcc_64 dir>)." >&2
    echo "Install it (user-space):" >&2
    echo "  python3 -m venv /tmp/aqtenv && /tmp/aqtenv/bin/pip install aqtinstall" >&2
    echo "  /tmp/aqtenv/bin/aqt install-qt linux desktop 6.12.0 linux_gcc_64 -m qtmultimedia qtshadertools qttasktree -O \$HOME/Qt" >&2
    exit 1
fi

if [[ ! -x "$BUILD/watchtower" ]]; then
    echo "watchtower missing in $BUILD — configuring + building against $QT …" >&2
    cmake -S "$DIR" -B "$BUILD" -G Ninja -DCMAKE_PREFIX_PATH="$QT" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$BUILD" -j"$(nproc)"
fi

# Cap glibc malloc arenas. The app runs ~73 threads (≈8 GStreamer/Qt threads per live pipeline);
# glibc otherwise spins up an arena per thread (up to 8×cores), each retaining freed memory it never
# returns to the OS. Capping to 2 trims ~30–50 MB of that retention at negligible cost for a video app.
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

export LD_LIBRARY_PATH="$QT/lib:${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="$QT/plugins"
export QML_IMPORT_PATH="$QT/qml"
export QML2_IMPORT_PATH="$QT/qml"
exec "$BUILD/watchtower" "$@"
