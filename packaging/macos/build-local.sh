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
#     with `brew install qt qt-multimedia gstreamer` (any recent version — the
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
printf '%s\n' \
"${g}    ▟▙▟▙" \
"${g}   ▐████▌  ${w}█   █ ▄▀▀▀▄ ▀▀█▀▀ ▄▀▀▀▀ █   █ ▀▀█▀▀ ▄▀▀▀▄ █   █ █▀▀▀▀ █▀▀▀▄" \
"${g}   ▐█  █▌  ${w}█ █ █ █▀▀▀█   █   █     █▀▀▀█   █   █   █ █ █ █ █▀▀   █▀▀▄" \
"${g}   ▐████▌  ${w}▀▄▀▄▀ ▀   ▀   ▀   ▀▀▀▀▀ ▀   ▀   ▀   ▀▀▀▀▀ ▀▄▀▄▀ ▀▀▀▀▀ ▀  ▀▄" \
"${g}   ▐█  █▌" \
"${g}  ▟██████▙ ${d} C I L E X   ·   V I S I O N${r}" \
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
  [ -e /opt/homebrew/opt/qt/lib/QtMultimedia.framework/QtMultimedia ] || missing+=(qt-multimedia)
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
  1. Prerequisites (one time):  brew install qt qt-multimedia gstreamer
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
echo "    target needs: Apple Silicon + brew qt, qt-multimedia, gstreamer"

if [ "$PUBLISH" = 1 ]; then
    # Rolling prerelease, same semantics windows-latest has: delete + recreate.
    # No CI exists to race against; the only publisher is whoever runs this.
    gh release delete macos-latest --yes 2>/dev/null || true
    git push --delete origin macos-latest 2>/dev/null || true
    gh release create macos-latest "$ZIP" --prerelease \
        --title "macOS rolling build $VERSION" \
        --notes "Local build from $SHA. Unsigned, arm64-only; target needs \`brew install qt qt-multimedia gstreamer\` (see packaging/macos/README.md)."
    echo "==> published macos-latest ($VERSION)"
fi
