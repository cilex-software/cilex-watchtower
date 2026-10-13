#!/usr/bin/env bash
# Interactive UI-only preview. All incidents/actions stay in an isolated loopback fixture.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -x "${WT_BUILD_DIR:-$repo/build}/watchtower" ]]; then
    echo "Build Watchtower first; this preview does not start an automatic build." >&2
    exit 1
fi
preview_root="$(mktemp -d "${TMPDIR:-/tmp}/watchtower-obstruction-preview.XXXXXX")"
exec python3 "$repo/tools/tests/camera-obstruction/run-main-ui.py" \
    --interactive --binary "$repo/run-watchtower.sh" --output "$preview_root/session"
