#!/usr/bin/env bash
# Root-free build-dependency sysroot: `apt-get download` the -dev packages and
# dpkg-extract them into $SYSROOT. Dev packages carry only headers, .pc files
# and unversioned .so symlinks; the matching RUNTIME libraries are already
# installed on any desktop system — we re-point the extracted symlinks at the
# real /usr/lib/x86_64-linux-gnu/*.so.N. No sudo needed anywhere.
set -euo pipefail
SYSROOT="${QTPATCH_SYSROOT:-$HOME/qtpatch-work/dev-sysroot}"
mkdir -p "$SYSROOT/dl"
cd "$SYSROOT/dl"

PKGS=(
  libicu-dev icu-devtools
  libgl-dev libegl-dev libgles-dev libglx-dev libopengl-dev libglvnd-dev
  libxkbcommon-dev libxkbcommon-x11-dev
  libwayland-dev wayland-protocols
  libfontconfig-dev libfreetype-dev libexpat1-dev
  libssl-dev
  libx11-dev libx11-xcb-dev xorg-sgml-doctools x11proto-dev libxau-dev libxdmcp-dev
  libxcb1-dev libxcb-glx0-dev libxcb-keysyms1-dev libxcb-image0-dev libxcb-shm0-dev
  libxcb-icccm4-dev libxcb-sync-dev libxcb-xfixes0-dev libxcb-shape0-dev
  libxcb-randr0-dev libxcb-render0-dev libxcb-render-util0-dev libxcb-util-dev
  libxcb-util0-dev libxcb-xinerama0-dev libxcb-xkb-dev libxcb-cursor-dev
  libxrender-dev libxi-dev libxext-dev libxfixes-dev libxrandr-dev libxtst-dev libxcb-shm0-dev
  libvulkan-dev libva-dev libdrm-dev
  libbrotli-dev libpng-dev zlib1g-dev libzstd-dev
  libasound2-dev libpulse-dev
  libpipewire-0.3-dev libspa-0.2-dev
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
)
for p in "${PKGS[@]}"; do
  apt-get download "$p" >/dev/null 2>&1 || echo "  (skip: $p not downloadable)"
done
echo "downloaded $(ls -1 *.deb 2>/dev/null | wc -l) debs"
for d in *.deb; do dpkg -x "$d" "$SYSROOT"; done

# Re-point extracted dev symlinks at the installed runtime libraries.
LIBDIR="$SYSROOT/usr/lib/x86_64-linux-gnu"
if [[ -d "$LIBDIR" ]]; then
  find "$LIBDIR" -maxdepth 1 -name "*.so" -type l | while read -r l; do
    tgt=$(readlink "$l")
    base=$(basename "$tgt")
    if [[ ! -e "$LIBDIR/$base" && -e "/usr/lib/x86_64-linux-gnu/$base" ]]; then
      ln -sfn "/usr/lib/x86_64-linux-gnu/$base" "$l"
    fi
  done
fi
# CMake package configs pin VERSIONED imported locations (e.g. libzstd.so.1.5.x)
# relative to their prefix — mirror the installed versioned runtime libs for
# every library family present in the sysroot.
if [[ -d "$LIBDIR" ]]; then
  find "$LIBDIR" -maxdepth 1 -name "lib*.so" | while read -r l; do
    fam=$(basename "$l" .so)
    for real in /usr/lib/x86_64-linux-gnu/"$fam".so.*; do
      [[ -e "$real" ]] && ln -sfn "$real" "$LIBDIR/$(basename "$real")"
    done
  done
fi

# Same for .pc prefix paths: point them at the sysroot.
find "$SYSROOT/usr" -name "*.pc" -exec sed -i "s|^prefix=/usr|prefix=$SYSROOT/usr|" {} +

cat > "$SYSROOT/env.sh" <<ENV
export QTPATCH_DEV_SYSROOT="$SYSROOT"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig:\${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="$SYSROOT/usr:\${CMAKE_PREFIX_PATH:-}"
export CFLAGS="-I$SYSROOT/usr/include -I$SYSROOT/usr/include/x86_64-linux-gnu \${CFLAGS:-}"
export CXXFLAGS="-I$SYSROOT/usr/include -I$SYSROOT/usr/include/x86_64-linux-gnu \${CXXFLAGS:-}"
export LDFLAGS="-L$SYSROOT/usr/lib/x86_64-linux-gnu \${LDFLAGS:-}"
ENV
echo "sysroot ready: $SYSROOT (source env.sh before build.sh)"
