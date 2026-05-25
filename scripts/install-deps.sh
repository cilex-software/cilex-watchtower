#!/usr/bin/env bash
# Watchtower — install the Qt 6 + GStreamer build toolchain (Ubuntu 24.04).
#
# Usage:   sudo bash scripts/install-deps.sh
#
# The package list lives here (not on the command line) so a long paste can't
# get split at terminal line-wraps. Safe to re-run; apt skips what's installed.
set -euo pipefail

PKGS=(
  # build
  cmake ninja-build pkg-config
  # Qt 6 dev
  qt6-base-dev qt6-declarative-dev qt6-multimedia-dev
  # QtQuick runtime modules
  qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts
  qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qtqml-workerscript
  qml6-module-qtquick-shapes qml6-module-qt5compat-graphicaleffects qml6-module-qtquick-dialogs
  qml6-module-qtmultimedia
  # GStreamer (video pipeline phase)
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-qt6
  gstreamer1.0-vaapi gstreamer1.0-gl
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav
  # font
  fonts-jetbrains-mono
)

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo:  sudo bash scripts/install-deps.sh" >&2
  exit 1
fi

echo "==> apt-get install (${#PKGS[@]} packages)…"
apt-get install -y "${PKGS[@]}"
echo
echo "==> Toolchain install finished. Tell Claude 'done'."
