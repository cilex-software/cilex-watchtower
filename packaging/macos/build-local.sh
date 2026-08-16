#!/usr/bin/env bash
# Local macOS build → .app → .dmg, with optional publish to the rolling
# `macos-latest` prerelease. Mirrors packaging/windows/build-local.ps1 in role:
# LOCAL BUILDS ARE THE ONLY CHANNEL (CI is off for budget — CLAUDE.md
# "Release channel"), and macOS CI never existed (10× billing).
#
# ── STATUS: WRITTEN 2026-08-16 ON THE LINUX BOX. NEVER EXECUTED ON A MAC. ──
# M0/M4 of docs/plans/mac-port/2026-08-16-mac-port-plan.md are its first runs;
# treat every step as unverified until the Mac agent has run it and said so.
#
# Usage:
#   ./build-local.sh                # configure + build + .app + .dmg
#   ./build-local.sh -Publish       # …then replace the macos-latest release
#
# Prereqs (M0): Xcode CLT, CMake+Ninja, Qt 6.12 (online installer),
#   `brew install gstreamer` (verify: gst-inspect-1.0 vtdec_hw && rtspsrc),
#   and for -Publish: `gh` authenticated with a repo token the OPERATOR
#   provisions (station rule: its own token, never someone else's).
set -euo pipefail
cd "$(dirname "$0")/../.."

QT="${WT_QT_PREFIX:-$HOME/Qt/6.12.0/macos}"
BUILD=build-macos
PUBLISH=0
[ "${1:-}" = "-Publish" ] && PUBLISH=1

cmake -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="$QT" >/dev/null
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu)"

APP="$BUILD/watchtower.app"
[ -d "$APP" ] || { echo "FATAL: $APP missing — MACOSX_BUNDLE did not apply"; exit 1; }

# Bundle Qt. GStreamer is the open question of M4 (the W4 problem, Darwin
# edition): macdeployqt does NOT collect GStreamer's plugin tree. Until M4
# solves bundling, the .dmg REQUIRES a brew gstreamer install on the target —
# the dmg is "internal station" grade, not "drag to any Mac" grade. Honest
# limitation, printed loudly below.
"$QT/bin/macdeployqt" "$APP" -qmldir=qml

VERSION=$(sed -n 's/^    VERSION \([0-9.]*\)$/\1/p' CMakeLists.txt | head -1)
DMG="$BUILD/CilexWatchtower-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Cilex Watchtower $VERSION" -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "==> $DMG"
echo "NOTE: unsigned (operator decision pending at M4) — first launch needs"
echo "      right-click → Open, or: xattr -d com.apple.quarantine <app>"
echo "NOTE: target Mac needs 'brew install gstreamer' until M4 solves bundling"

if [ "$PUBLISH" = 1 ]; then
    # Rolling prerelease, same semantics windows-latest had: delete + recreate.
    # No CI exists to race against; the only publisher is whoever runs this.
    gh release delete macos-latest --yes 2>/dev/null || true
    git push --delete origin macos-latest 2>/dev/null || true
    gh release create macos-latest "$DMG" --prerelease \
        --title "macOS rolling build $VERSION" \
        --notes "Local build from $(git rev-parse --short=8 HEAD). Unsigned; requires brew gstreamer on the target (see packaging/macos/README.md)."
    echo "==> published macos-latest ($VERSION)"
fi
