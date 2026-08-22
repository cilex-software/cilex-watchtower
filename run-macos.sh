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
exec "$BIN" "$@"
