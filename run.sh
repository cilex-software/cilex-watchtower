#!/usr/bin/env bash
# Convenience alias — the canonical launcher is run-watchtower.sh (Qt 6.12 primary,
# build/; Qt 6.8.3 LTS fallback via WT_QT_PREFIX/WT_BUILD_DIR). System Qt 6.4.2 is
# banned and can no longer configure (CMake floor 6.8) — it SIGSEGV'd in libsoup
# during playback seeks (P0). See run-watchtower.sh / docs/DEVELOPMENT.md.
exec "$(dirname "$0")/run-watchtower.sh" "$@"
