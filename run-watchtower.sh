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

# Session continuity is credential-less since 2026-08-03: the app renews its
# 24 h session via POST /auth/refresh at T-10min (AuthController), so NO
# service credentials live in the environment (CV's explicit ask — the
# WT_CV_AUTOLOGIN=1 default that briefly existed here is deliberately gone).
# A box that stays off past its token's exp signs in interactively once;
# refresh renews, it does not resurrect. WT_CV_AUTOLOGIN remains available
# for explicit dev use only.
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
    echo "watchtower missing in $BUILD — checking committed source and existing builds …" >&2
    BUILD_RESULT=$(mktemp -t cilex-linux-binary.XXXXXX)
    trap 'rm -f "$BUILD_RESULT"' EXIT
    WT_BUILD_RESULT="$BUILD_RESULT" WT_BUILD_DIR="$BUILD" WT_QT_PREFIX="$QT" "$DIR/packaging/linux/build-local.sh"
    BINARY=$(cat "$BUILD_RESULT")
    rm -f "$BUILD_RESULT"
    trap - EXIT
else
    BINARY="$BUILD/watchtower"
fi

# Cap glibc malloc arenas. The app runs ~73 threads (≈8 GStreamer/Qt threads per live pipeline);
# glibc otherwise spins up an arena per thread (up to 8×cores), each retaining freed memory it never
# returns to the OS. Capping to 2 trims ~30–50 MB of that retention at negligible cost for a video app.
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

export LD_LIBRARY_PATH="$QT/lib:${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="$QT/plugins"
export QML_IMPORT_PATH="$QT/qml"
export QML2_IMPORT_PATH="$QT/qml"
exec "$BINARY" "$@"
