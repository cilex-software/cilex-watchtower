#!/usr/bin/env bash
# Local macOS build → thin distribution zip, with optional publish to the
# rolling `macos-latest` prerelease. Mirrors packaging/windows/build-local.ps1
# in role: LOCAL BUILDS ARE THE ONLY CHANNEL (CI is off for budget — CLAUDE.md
# "Release channel"; macOS CI never existed at 10× billing).
#
# ── REWRITTEN 2026-08-20 ON THE MAC, replacing the 2026-08-16 Linux-written
# scaffold that had never executed here. What changed and why:
#   * Qt comes from HOMEBREW (M0 reality: brew qt 6.11.1), not ~/Qt/6.12 —
#     the binary links absolute /opt/homebrew paths for Qt AND GStreamer.
#   * The artifact is a THIN ZIP, not a bundled dmg. Operator decision
#     2026-08-20: prerequisites on the target are acceptable; size beats
#     self-containment. A full macdeployqt+GStreamer bundle (the W4 problem,
#     Darwin edition) stays an open M4 option nobody currently needs.
#   * Consequence, stated honestly: the zip runs ONLY on an Apple-Silicon Mac
#     with `brew install qt qtmultimedia gstreamer` (any recent version — the
#     dylib compatibility floor is checked at launch by run-macos.sh, which
#     prints the exact brew command when something is missing).
#
# Usage:
#   ./build-local.sh                # configure + build + zip into build-macos/
#   ./build-local.sh -Publish       # …then replace the macos-latest release
#     (-Publish needs `gh` authenticated with a token the OPERATOR provisions;
#      station rule: its own token, never someone else's.)
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD=build-macos
PUBLISH=0
[ "${1:-}" = "-Publish" ] && PUBLISH=1

[ "$(uname -m)" = "arm64" ] || { echo "FATAL: this script builds arm64 on Apple Silicon only"; exit 1; }

cmake -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu)"

APP="$BUILD/watchtower.app"
[ -d "$APP" ] || { echo "FATAL: $APP missing — MACOSX_BUNDLE did not apply"; exit 1; }

# ── ffmpeg: BUILT HERE, LGPL, AND BUNDLED ────────────────────────────────────
# Export post-processing (overlay burn-in, the compression ladder) shells out to
# ffmpeg. Windows ships a pinned LGPL build beside its exe; macOS shipped nothing,
# so the feature depended on whatever the user happened to have — and Homebrew's
# stock `ffmpeg` is a slim build that cannot do it.
#
# WE BUILD IT RATHER THAN DOWNLOAD IT, because no usable prebuilt exists (checked
# 2026-09-23): evermeet is GPL and Intel-only and its maintainer will not do Apple
# Silicon; ffmpeg.martin-riedl.de is --enable-gpl --enable-libx264 --enable-libx265;
# and the "LGPL macOS" repos on GitHub were either created within the fortnight with
# zero stars or abandoned in 2022. None of those belong in software that guards a
# camera fleet. ffmpeg.org source plus a pinned SHA-256 is auditable and answers to
# nobody else.
#
# NO --enable-gpl ANYWHERE. We distribute this app, so a GPL ffmpeg would impose GPL
# on the product. configure prints "License: LGPL version 2.1 or later" and the step
# below FAILS THE BUILD if it ever prints anything else — the check is the point, not
# the comment. No libx264 follows from that, so the encoder is Apple's
# h264_videotoolbox (see ClipTranscoder, which picks by capability).
#
# --disable-autodetect keeps the build from silently absorbing whatever happens to be
# installed on the packaging machine, which is both a licence and a reproducibility
# property. --enable-zlib is then REQUIRED and easy to miss: the PNG decoder needs it,
# and without it everything configures and builds cleanly and then fails at run time
# with "no decoder found for: png" — the overlay images are PNGs.
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
FFMPEG_CACHE="$HOME/Library/Caches/CilexWatchtower/ffmpeg-lgpl"
FFMPEG_BIN="$FFMPEG_CACHE/$FFMPEG_VERSION/ffmpeg"

if [ ! -x "$FFMPEG_BIN" ]; then
  echo "== building LGPL ffmpeg $FFMPEG_VERSION (once; cached in $FFMPEG_CACHE) =="
  mkdir -p "$FFMPEG_CACHE/src"
  TAR="$FFMPEG_CACHE/src/ffmpeg-$FFMPEG_VERSION.tar.xz"
  [ -f "$TAR" ] || curl -fsSL --max-time 600 -o "$TAR" \
      "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  GOT=$(shasum -a 256 "$TAR" | cut -d' ' -f1)
  [ "$GOT" = "$FFMPEG_SHA256" ] || {
    echo "FATAL: ffmpeg source SHA-256 mismatch"
    echo "  expected $FFMPEG_SHA256"
    echo "  got      $GOT"
    rm -f "$TAR"; exit 1; }
  echo "  source SHA-256 verified"
  SRC="$FFMPEG_CACHE/src/ffmpeg-$FFMPEG_VERSION"
  rm -rf "$SRC"; tar xf "$TAR" -C "$FFMPEG_CACHE/src"
  ( cd "$SRC" && ./configure \
      --disable-everything --disable-autodetect --disable-doc --disable-network --disable-debug \
      --disable-shared --enable-static --enable-small \
      --enable-zlib --enable-videotoolbox \
      --enable-encoder=h264_videotoolbox \
      --enable-decoder=h264 --enable-decoder=hevc --enable-decoder=png --enable-decoder=rawvideo \
      --enable-demuxer=mov --enable-demuxer=image2 --enable-demuxer=png_pipe \
      --enable-muxer=mp4 \
      --enable-parser=h264 --enable-parser=hevc --enable-parser=png \
      --enable-filter=scale,overlay,format,null,copy,setpts,fps \
      --enable-protocol=file \
      --enable-bsf=h264_mp4toannexb --enable-bsf=hevc_mp4toannexb \
      --enable-ffmpeg --disable-ffplay --disable-ffprobe > configure.log 2>&1 ) || {
        tail -20 "$SRC/configure.log"; echo "FATAL: ffmpeg configure failed"; exit 1; }
  LIC=$(grep -m1 '^License:' "$SRC/configure.log" || true)
  echo "  $LIC"
  case "$LIC" in
    *"LGPL version 2.1 or later"*) ;;
    *) echo "FATAL: refusing to bundle — ffmpeg reports '$LIC', expected LGPL"; exit 1 ;;
  esac
  ( cd "$SRC" && make -j"$(sysctl -n hw.ncpu)" > build.log 2>&1 ) || {
      tail -20 "$SRC/build.log"; echo "FATAL: ffmpeg build failed"; exit 1; }
  mkdir -p "$FFMPEG_CACHE/$FFMPEG_VERSION"
  cp "$SRC/ffmpeg" "$FFMPEG_BIN"
fi

# Nothing outside macOS's own libraries, or the zip is not self-contained.
LEAKS=$(otool -L "$FFMPEG_BIN" | tail -n +2 | grep -vE "/usr/lib/|/System/Library/" || true)
[ -z "$LEAKS" ] || { echo "FATAL: bundled ffmpeg links non-system libraries:"; echo "$LEAKS"; exit 1; }
cp "$FFMPEG_BIN" "$APP/Contents/MacOS/ffmpeg"
chmod +x "$APP/Contents/MacOS/ffmpeg"
echo "== bundled ffmpeg $FFMPEG_VERSION (LGPL, $(du -h "$FFMPEG_BIN" | cut -f1)) =="

VERSION=$(sed -n 's/^ *VERSION \([0-9.]*\) *$/\1/p' CMakeLists.txt | head -1)
SHA=$(git rev-parse --short=8 HEAD)
NAME="CilexWatchtower-$VERSION-macos-arm64"
STAGE="$BUILD/dist/$NAME"
rm -rf "$BUILD/dist"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"

# Ad-hoc signature: keeps the binary loadable on the SAME architecture without
# a Developer ID ($99/yr — operator decision still pending, M4). Downloaded
# copies still carry quarantine; run-macos.sh strips it on first run.
codesign --force --deep -s - "$STAGE/watchtower.app" 2>/dev/null

# The launcher a recipient actually runs. Self-contained: checks prereqs with
# exact remedies, heals quarantine, then execs the app with env passthrough.
cat > "$STAGE/run-macos.sh" <<'LAUNCH'
#!/bin/zsh
# Cilex Watchtower launcher (macOS, Apple Silicon).
# Usage: ./run-macos.sh   — WT_* environment variables pass straight through,
# e.g.:  WT_CV_URL=http://<server>:8000 ./run-macos.sh
cd "$(dirname "$0")"
BIN="watchtower.app/Contents/MacOS/watchtower"

# Banner before the prerequisite checks so it greets even a first run that
# stops for a missing brew package. Colour only on a TTY.
if [ -t 1 ]; then
  g=$'\033[38;5;214m'; w=$'\033[38;5;223m'; d=$'\033[38;5;242m'; r=$'\033[0m'
else
  g=; w=; d=; r=
fi
# The version of the app about to start, read from ITS OWN bundle -- the build writes it
# (CMakeLists.txt MACOSX_BUNDLE_SHORT_VERSION_STRING) -- never from the source tree, which
# can be ahead of the last build. Shown on the banner so a launch says at a glance what
# it runs (operator request, 2026-09-29). Unknown says "version unknown", never a guess.
PLIST="${BIN%/MacOS/watchtower}/Info.plist"
# PlistBuddy's answer counts only when it EXITS 0. A missing or unreadable plist makes it
# print "File Doesn't Exist, Will Create: ..." or "Error Reading File: ..." on STDOUT, exit 1
# (measured on macOS 26, 2026-09-29) -- which the banner then showed as the version.
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null) || VER=
[ -n "$VER" ] || VER=$(sed -n \
  -e 's/.*<key>CFBundleShortVersionString<\/key>[[:space:]]*<string>\([^<]*\)<\/string>.*/\1/p' \
  -e '/<key>CFBundleShortVersionString<\/key>[[:space:]]*$/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;}' \
  "$PLIST" 2>/dev/null | head -n 1)
# Digits and dots only. Anything else -- a message, an unfilled template placeholder -- is
# not a version, and the banner says "version unknown" rather than print it.
case "$VER" in ''|.*|*[!0-9.]*) VER= ;; esac
if [ "$(uname)" = Darwin ]; then
  BUILT=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$BIN" 2>/dev/null)
else
  BUILT=$(date -r "$BIN" '+%Y-%m-%d %H:%M' 2>/dev/null)
fi
if [ -n "$VER" ]; then VERSION_TEXT="v$VER${BUILT:+  ·  built $BUILT}"; else VERSION_TEXT="version unknown"; fi
printf '%s\n' \
"${g}    ▟▙▟▙" \
"${g}   ▐████▌  ${w}█   █ ▄▀▀▀▄ ▀▀█▀▀ ▄▀▀▀▀ █   █ ▀▀█▀▀ ▄▀▀▀▄ █   █ █▀▀▀▀ █▀▀▀▄" \
"${g}   ▐█  █▌  ${w}█ █ █ █▀▀▀█   █   █     █▀▀▀█   █   █   █ █ █ █ █▀▀   █▀▀▄" \
"${g}   ▐████▌  ${w}▀▄▀▄▀ ▀   ▀   ▀   ▀▀▀▀▀ ▀   ▀   ▀   ▀▀▀▀▀ ▀▄▀▄▀ ▀▀▀▀▀ ▀  ▀▄" \
"${g}   ▐█  █▌" \
"${g}  ▟██████▙ ${d} C I L E X   ·   V I S I O N   ${w}${VERSION_TEXT}${r}" \
"" \
"${d}   \"Night gathers, and now my watch begins.\"${r}" \
""

[ "$(uname -m)" = "arm64" ] || { echo "This build is Apple Silicon (arm64) only."; exit 1; }
[ -x "$BIN" ] || { echo "watchtower.app is missing next to this script."; exit 1; }

# Prerequisites: Watchtower links Homebrew Qt and GStreamer at their standard
# /opt/homebrew paths. Anything missing is a one-line install.
missing=()
[ -e /opt/homebrew/opt/qtbase/lib/QtCore.framework/QtCore ] || \
  [ -e /opt/homebrew/opt/qt/lib/QtCore.framework/QtCore ] || missing+=(qt)
[ -e /opt/homebrew/opt/qtmultimedia/lib/QtMultimedia.framework/QtMultimedia ] || \
  [ -e /opt/homebrew/opt/qt/lib/QtMultimedia.framework/QtMultimedia ] || missing+=(qtmultimedia)
[ -e /opt/homebrew/opt/gstreamer/lib/libgstreamer-1.0.0.dylib ] || missing+=(gstreamer)
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing prerequisites. Install Homebrew (https://brew.sh) if needed, then run:"
  echo
  echo "  brew install ${missing[*]}"
  echo
  exit 1
fi

# A downloaded zip carries the quarantine attribute and macOS refuses to start
# the unsigned app. Remove it once, from the app we ship, and only that.
if xattr -p com.apple.quarantine "$BIN" >/dev/null 2>&1; then
  echo "First run: removing the download quarantine from watchtower.app…"
  xattr -dr com.apple.quarantine watchtower.app
fi

exec "$BIN" "$@"
LAUNCH
chmod +x "$STAGE/run-macos.sh"

cat > "$STAGE/README.txt" <<EOF
Cilex Watchtower $VERSION — macOS (Apple Silicon), build $SHA

To run:
  1. Prerequisites (one time):  brew install qt qtmultimedia gstreamer
     (Homebrew itself: https://brew.sh)
  2. ./run-macos.sh

The server address persists after first login. To point a fresh install at a
server from the command line:  WT_CV_URL=http://<server>:8000 ./run-macos.sh

This build is unsigned (internal distribution). run-macos.sh removes the
download quarantine on first start; nothing else on the system is touched.
EOF

ZIP="$BUILD/$NAME.zip"
rm -f "$ZIP"
(cd "$BUILD/dist" && zip -qr9 "../$NAME.zip" "$NAME")
echo "==> $ZIP  ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
echo "    contents: watchtower.app + run-macos.sh + README.txt"
echo "    target needs: Apple Silicon + brew qt, qtmultimedia, gstreamer"

if [ "$PUBLISH" = 1 ]; then
    # Rolling prerelease, same semantics windows-latest has: delete + recreate.
    # No CI exists to race against; the only publisher is whoever runs this.
    gh release delete macos-latest --yes 2>/dev/null || true
    git push --delete origin macos-latest 2>/dev/null || true
    gh release create macos-latest "$ZIP" --prerelease \
        --title "macOS rolling build $VERSION" \
        --notes "Local build from $SHA. Unsigned, arm64-only; target needs \`brew install qt qtmultimedia gstreamer\` (see packaging/macos/README.md)."
    echo "==> published macos-latest ($VERSION)"
fi
