#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
qt_bin="${QT_BIN:-/home/cilex-vision/Qt/6.12.0/gcc_64/bin}"
fixture_import="$(mktemp -d /tmp/watchtower-obstruction-qml.XXXXXX)"
trap 'rm -rf -- "$fixture_import"' EXIT
mkdir "$fixture_import/Watchtower"
cp "$repo/qml/Theme.qml" "$repo/qml/Icon.qml" "$repo/qml/CameraObstructionButton.qml" \
    "$repo/qml/CameraObstructionAlert.qml" "$repo/qml/CameraObstructionReview.qml" "$fixture_import/Watchtower/"
cat > "$fixture_import/Watchtower/qmldir" <<'MODULE'
module Watchtower
singleton Theme 1.0 Theme.qml
Icon 1.0 Icon.qml
CameraObstructionButton 1.0 CameraObstructionButton.qml
CameraObstructionAlert 1.0 CameraObstructionAlert.qml
CameraObstructionReview 1.0 CameraObstructionReview.qml
MODULE
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Fusion \
    "$qt_bin/qmltestrunner" -input "$repo/tools/tests/camera-obstruction/tst_ui.qml" -import "$fixture_import"
