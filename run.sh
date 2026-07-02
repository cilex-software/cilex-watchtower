#!/usr/bin/env bash
# Convenience alias — the canonical launcher is run-watchtower.sh (Qt 6.8.3 runtime).
# NEVER launch ./build/watchtower directly for real use: that's the system Qt 6.4.2
# GStreamer build, which SIGSEGVs in libsoup during playback seeks (P0, 2026-07-01).
exec "$(dirname "$0")/run-watchtower.sh" "$@"
