#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
if [[ -n "${QT_BIN:-}" ]]; then
    runner="$QT_BIN/qmltestrunner"
else
    runner="$(command -v qmltestrunner)"
fi
fixture_import="$(mktemp -d /tmp/watchtower-arrangement-qml.XXXXXX)"
trap 'rm -rf -- "$fixture_import"' EXIT
mkdir "$fixture_import/Watchtower"
for component in LiveMonitor Theme LayoutSpec GroupSwitcher FilterPill NetIcon Icon IconButton EmptyState LoadingState PaginationControl; do
    cp "$repo/qml/$component.qml" "$fixture_import/Watchtower/"
done
cp "$repo/tools/tests/live-arrangement/fixtures/"* "$fixture_import/Watchtower/"
shots=(31-cameras-35-cells outside-group-added picker-all-sorted one-camera-after-clear filtered-occupied-cells)
if [[ "$#" -eq 0 ]]; then
    for shot in "${shots[@]}"; do
        rm -f -- "/tmp/watchtower-live-arrangement-$shot.png"
    done
fi
# This module deliberately cannot load production Settings or CameraTile. In
# particular, HOME/CFFIXED_USER_HOME do not isolate QSettings on macOS.
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic \
    "$runner" -input "$repo/tools/tests/live-arrangement/tst_ui.qml" -import "$fixture_import" "$@"
if [[ "$#" -eq 0 ]]; then
    for shot in "${shots[@]}"; do
        test -s "/tmp/watchtower-live-arrangement-$shot.png"
    done
fi
