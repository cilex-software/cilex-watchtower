#!/usr/bin/env bash
# Cilex Watchtower launcher.
#
# Runs the build against the UPGRADED Qt 6.8.3. Ubuntu 24.04's system Qt is 6.4.2, which has a
# QtMultimedia bug: VideoOutput retains every video frame it renders (~one frame-buffer per frame →
# RSS climbs ~260 MB/s on a 9-tile live wall → ~9 GB → earlyoom SIGTERMs the app in ~30 s). Verified
# leak-free on 6.8.3 (and it also fixes the Qt 6.4.2 GridLayout maximize/minimize SIGSEGV). The app
# source needs no changes — it builds and runs unmodified on 6.8.3. See docs/DEVELOPMENT.md.
#
# Override the Qt prefix or build dir with WT_QT_PREFIX / WT_BUILD_DIR if you relocate them.
set -euo pipefail
QT="${WT_QT_PREFIX:-/home/cilex-vision/Qt/6.8.3/gcc_64}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${WT_BUILD_DIR:-$DIR/build68}"

if [[ ! -d "$QT/lib" ]]; then
    echo "Qt 6.8.3 not found at $QT" >&2
    echo "Install it (user-space):" >&2
    echo "  python3 -m venv /tmp/aqtenv && /tmp/aqtenv/bin/pip install aqtinstall" >&2
    echo "  /tmp/aqtenv/bin/aqt install-qt linux desktop 6.8.3 linux_gcc_64 -m qtmultimedia qtshadertools -O \$HOME/Qt" >&2
    exit 1
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
