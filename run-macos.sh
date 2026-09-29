#!/usr/bin/env bash
# macOS launcher — the Linux run.sh checks for patched Qt at ~/Qt and refuses
# here (correctly; the operator hit exactly that on M1 day one). The mac build
# links brew Qt via rpath, so launching is just executing the bundle binary
# with the WT_* env passed through.
cd "$(dirname "$0")"
BIN="build-macos/watchtower.app/Contents/MacOS/watchtower"
[ -x "$BIN" ] || { echo "run-macos.sh: $BIN missing — build first:"; \
  echo "  cmake --build build-macos -j\"\$(sysctl -n hw.ncpu)\""; exit 1; }
# Direct-binary exec below means LaunchServices never sees the bundle, so
# cilex:// links die with kLSApplicationNotFoundErr (measured, M1 2026-08-22).
# Registering here is belt-and-braces with the app's own LSRegisterURL claim —
# this one also covers builds too old to carry it. Idempotent, ~100 ms.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$PWD/build-macos/watchtower.app" 2>/dev/null
# ----------------------------------------------------------------- banner
# Printed BEFORE the exec below, so it reaches the terminal only and never
# enters run-last.log — that file gets pasted into bug reports verbatim and
# should stay all signal. Colour only on a TTY, so piping stays clean.
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
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)
[ -n "$VER" ] || VER=$(sed -n \
  -e 's/.*<key>CFBundleShortVersionString<\/key>[[:space:]]*<string>\([^<]*\)<\/string>.*/\1/p' \
  -e '/<key>CFBundleShortVersionString<\/key>[[:space:]]*$/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;}' \
  "$PLIST" 2>/dev/null | head -n 1)
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
# Every run tees to a rolling log so a bug report needs zero setup — just paste:
#   grep -E "MSCAN|MKT|HERO" "$HOME/Library/Logs/CilexWatchtower/run-last.log"
LOGDIR="$HOME/Library/Logs/CilexWatchtower"
mkdir -p "$LOGDIR"
[ -f "$LOGDIR/run-last.log" ] && mv -f "$LOGDIR/run-last.log" "$LOGDIR/run-prev.log"
exec "$BIN" "$@" > >(tee "$LOGDIR/run-last.log") 2>&1
