#!/usr/bin/env bash
# Build committed Watchtower source without starting or installing it.
set -euo pipefail
[ "$(uname -s)" = Linux ] || { echo 'Run this build command on Linux.' >&2; exit 1; }
REPOSITORY=$(cd "$(dirname "$0")/../.." && pwd)
if [ -n "${WT_QT_PREFIX:-}" ]; then
    QT="$WT_QT_PREFIX"
elif [ -d "$HOME/Qt/6.12.0-patched-beta1/lib" ]; then
    QT="$HOME/Qt/6.12.0-patched-beta1"
else
    QT="$HOME/Qt/6.12.0/gcc_64"
fi
BUILD="${WT_BUILD_DIR:-$REPOSITORY/build}"
UPDATE=yes
REBUILD=ask
while [ "$#" -gt 0 ]; do
    case "$1" in
        --update) UPDATE="$2"; shift 2 ;;
        --rebuild) REBUILD="$2"; shift 2 ;;
        *) echo "Unknown build option: $1" >&2; exit 1 ;;
    esac
done
. "$REPOSITORY/packaging/build-state.sh"
SETTINGS=$(python3 -c 'import json,sys; print(json.dumps({"qt":sys.argv[1],"configuration":"Release","architecture":sys.argv[2]}))' "$QT" "$(uname -m)")
cilex_build_prepare linux-app "$REPOSITORY" --update "$UPDATE" --rebuild "$REBUILD" --settings "$SETTINGS" --candidate "$BUILD/watchtower"
if [ "$CILEX_BUILD_ENABLED" = true ]; then
    mkdir -p "$BUILD"
    BUILD=$(cd "$BUILD" && pwd)
    COMPILE_DIR="$BUILD/committed-build/$CILEX_BUILD_COMMIT"
    cmake -S "$CILEX_BUILD_SOURCE" -B "$COMPILE_DIR" -G Ninja -DCMAKE_PREFIX_PATH="$QT" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$COMPILE_DIR" -j"$(nproc)"
    cp "$COMPILE_DIR/watchtower" "$BUILD/.watchtower-built.$$"
    mv -f "$BUILD/.watchtower-built.$$" "$BUILD/watchtower"
    cilex_build_record --output binary "$BUILD/watchtower"
fi
if [ -n "${WT_BUILD_RESULT:-}" ]; then
    "$CILEX_BUILD_PYTHON" -I -B "$CILEX_BUILD_GUARD" value --plan "$CILEX_BUILD_PLAN" --field binary > "$WT_BUILD_RESULT"
fi
