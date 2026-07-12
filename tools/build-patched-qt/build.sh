#!/usr/bin/env bash
# Build the internally-patched Qt 6.12 overlay stack for Watchtower.
#
# Why: the SDK's SBOM revisions are Coin-internal (not publicly reachable), so
# per the patch-series policy we build ONE CONSISTENT public revision —
# v6.12.0-beta1 — for every module in the runtime overlay, apply
# third_party/qt-patches/6.12/ before qtmultimedia, and install to a private
# prefix. The app binary uses only public Qt ABI, so the SDK-built watchtower
# runs on this overlay via the existing launcher:
#
#   deploy   : WT_QT_PREFIX=$PREFIX ./run.sh
#   rollback : ./run.sh                       (SDK prefix, unchanged on disk)
#
# Outputs: $PREFIX (default ~/Qt/6.12.0-patched-beta1), plus REVISIONS,
# ARTIFACTS.sha256 and BUILDIDS.txt next to this script.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${QTPATCH_WORK:-$HOME/qtpatch-work}"
PREFIX="${QTPATCH_PREFIX:-$HOME/Qt/6.12.0-patched-beta1}"
SDK="${QTPATCH_SDK:-$HOME/Qt/6.12.0/gcc_64}"
TAG=v6.12.0-beta1
JOBS="${QTPATCH_JOBS:-$(nproc)}"
MODULES=(qtbase qtshadertools qtdeclarative qtwayland qtmultimedia)

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"

# Root-free dev sysroot (make-dev-sysroot.sh) — headers/.pc/symlinks for the
# system runtime libs; lets the stack build without sudo.
if [[ -f "$WORK/dev-sysroot/env.sh" ]]; then
    # shellcheck disable=SC1091
    source "$WORK/dev-sysroot/env.sh"
    echo "using dev sysroot: $QTPATCH_DEV_SYSROOT"
fi

echo "== sources @ $TAG =="
: > "$HERE/REVISIONS"
echo "toolchain: $(gcc --version | head -1)" >> "$HERE/REVISIONS"
echo "linker: $(ld --version | head -1)" >> "$HERE/REVISIONS"
for m in "${MODULES[@]}"; do
    if [[ ! -d "$m" ]]; then
        git clone --quiet --filter=blob:none "https://github.com/qt/$m.git" "$m"
    fi
    git -C "$m" fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" || true
    git -C "$m" checkout --quiet "$TAG"
    echo "$m: $(git -C "$m" rev-parse HEAD) ($TAG)" >> "$HERE/REVISIONS"
done

echo "== FFmpeg dep prefix (headers n7.1.1 + SDK-shipped runtime libs) =="
if [[ ! -d ffmpeg-src ]]; then
    git clone --quiet --depth 1 --branch n7.1.1 https://github.com/FFmpeg/FFmpeg.git ffmpeg-src
    (cd ffmpeg-src && ./configure --disable-everything --disable-x86asm --disable-doc >/dev/null)
fi
echo "ffmpeg-headers: n7.1.1 ($(git -C ffmpeg-src rev-parse HEAD)); runtime libs: SDK-shipped (libavcodec 61.19.101 line)" >> "$HERE/REVISIONS"
mkdir -p ffprefix/lib/pkgconfig
ln -sfn "$WORK/ffmpeg-src" ffprefix/include
for l in "$SDK"/lib/libav*.so* "$SDK"/lib/libsw*.so*; do ln -sfn "$l" ffprefix/lib/; done
declare -A FFV=([libavutil]=59 [libavcodec]=61 [libavformat]=61 [libswresample]=5 [libswscale]=8)
for p in "${!FFV[@]}"; do cat > "ffprefix/lib/pkgconfig/$p.pc" <<PC
prefix=$WORK/ffprefix
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $p
Description: $p (headers n7.1.1, SDK runtime)
Version: ${FFV[$p]}.0.0
Libs: -L\${libdir} -l${p#lib}
Cflags: -I\${includedir}
PC
done

echo "== libva dep prefix (2.20 headers + system runtime) =="
if [[ ! -d libva-src ]]; then
    git clone --quiet --depth 1 --branch 2.20.0 https://github.com/intel/libva.git libva-src
fi
echo "libva-headers: 2.20.0 ($(git -C libva-src rev-parse HEAD)); runtime: system libva2 2.20" >> "$HERE/REVISIONS"
mkdir -p vaprefix/include vaprefix/lib/pkgconfig
ln -sfn "$WORK/libva-src/va" vaprefix/include/va
for v in va va-drm va-wayland va-x11; do
    so="/usr/lib/x86_64-linux-gnu/lib$v.so.2"
    [[ -e "$so" ]] && ln -sfn "$so" "vaprefix/lib/lib$v.so"
    cat > "vaprefix/lib/pkgconfig/$v.pc" <<PC
prefix=$WORK/vaprefix
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $v
Description: $v (vendored headers 2.20.0, system runtime)
Version: 1.20.0
Libs: -L\${libdir} -l$v
Cflags: -I\${includedir}
PC
done
# va_version.h is configure-generated in libva; synthesize for 2.20
mkdir -p vaprefix/include/va
if [[ ! -e libva-src/va/va_version.h ]]; then cat > vaprefix/va_version_gen.h <<'H'
#ifndef VA_VERSION_H
#define VA_VERSION_H
#define VA_MAJOR_VERSION 1
#define VA_MINOR_VERSION 20
#define VA_MICRO_VERSION 0
#define VA_VERSION_S "1.20.0"
#define VA_CHECK_VERSION(major,minor,micro) \
    (VA_MAJOR_VERSION > (major) || \
     (VA_MAJOR_VERSION == (major) && VA_MINOR_VERSION > (minor)) || \
     (VA_MAJOR_VERSION == (major) && VA_MINOR_VERSION == (minor) && VA_MICRO_VERSION >= (micro)))
#endif
H
    cp vaprefix/va_version_gen.h libva-src/va/va_version.h
fi

export PKG_CONFIG_PATH="$WORK/ffprefix/lib/pkgconfig:$WORK/vaprefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

echo "== qtbase =="
rm -f b-qtbase/CMakeCache.txt          # clean retry after failed configures
cmake -S qtbase -B b-qtbase -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF > b-qtbase.configure.log 2>&1 \
    || { echo "CMake Error: qtbase configure failed"; tail -40 b-qtbase.configure.log; exit 1; }
grep -E "XCB \.+ yes|Wayland|ICU" b-qtbase.configure.log | head -5 || true
cmake --build b-qtbase --parallel "$JOBS" > b-qtbase.build.log 2>&1 \
    || { echo "ninja: build stopped (qtbase)"; tail -30 b-qtbase.build.log; exit 1; }
cmake --install b-qtbase > b-qtbase.install.log 2>&1

module() {
    local m="$1"; shift
    echo "== $m =="
    rm -f "b-$m/CMakeCache.txt"
    mkdir -p "b-$m" && ( cd "b-$m" && "$PREFIX/bin/qt-configure-module" "$WORK/$m" -- \
        -DCMAKE_BUILD_TYPE=Release -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF "$@" \
        > configure.log 2>&1 ) || { echo "CMake Error: $m configure failed"; tail -30 "b-$m/configure.log"; exit 1; }
    cmake --build "b-$m" --parallel "$JOBS" > "b-$m/build.log" 2>&1 \
        || { echo "ninja: build stopped ($m)"; tail -30 "b-$m/build.log"; exit 1; }
    cmake --install "b-$m" > "b-$m/install.log" 2>&1
}

module qtshadertools
module qtdeclarative
module qtwayland

echo "== apply patch series to qtmultimedia =="
git -C qtmultimedia checkout -- .
git -C qtmultimedia apply --verbose "$REPO/third_party/qt-patches/6.12/0001-qffmpegvideobuffer-commit-swframe-on-success.patch"
python3 "$HERE/apply-anchored.py" "$WORK/qtmultimedia"

module qtmultimedia -DFFMPEG_DIR="$WORK/ffprefix" -DINPUT_ffmpeg=ON

echo "== artifact manifest =="
( cd "$PREFIX" && find lib plugins -name "*.so*" -type f \
    | sort | xargs sha256sum ) > "$HERE/ARTIFACTS.sha256"
: > "$HERE/BUILDIDS.txt"
for f in "$PREFIX"/lib/libQt6Multimedia.so.6.12.0 "$PREFIX"/plugins/multimedia/libffmpegmediaplugin.so \
         "$PREFIX"/lib/libQt6Core.so.6.12.0 "$PREFIX"/lib/libQt6Qml.so.6.12.0; do
    [[ -e "$f" ]] && echo "$f $(readelf -n "$f" | awk '/Build ID/{print $3}')" >> "$HERE/BUILDIDS.txt"
done
echo "DONE prefix=$PREFIX"
