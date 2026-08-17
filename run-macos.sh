#!/usr/bin/env bash
# macOS launcher — the Linux run.sh checks for patched Qt at ~/Qt and refuses
# here (correctly; the operator hit exactly that on M1 day one). The mac build
# links brew Qt via rpath, so launching is just executing the bundle binary
# with the WT_* env passed through.
cd "$(dirname "$0")"
BIN="build-macos/watchtower.app/Contents/MacOS/watchtower"
[ -x "$BIN" ] || { echo "run-macos.sh: $BIN missing — build first:"; \
  echo "  cmake --build build-macos -j\"\$(sysctl -n hw.ncpu)\""; exit 1; }
exec "$BIN" "$@"
