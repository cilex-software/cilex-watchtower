#!/usr/bin/env bash
# Build dependencies for the patched-Qt overlay stack (tools/build-patched-qt/build.sh).
# Run this in YOUR terminal (needs sudo). One line, verified against Ubuntu 24.04.
set -e
sudo apt-get install -y \
  libicu-dev libgl1-mesa-dev libegl1-mesa-dev \
  libxkbcommon-dev libxkbcommon-x11-dev \
  libwayland-dev wayland-protocols \
  libfontconfig-dev libfreetype-dev libssl-dev \
  libx11-dev libx11-xcb-dev libxcb1-dev libxcb-glx0-dev libxcb-keysyms1-dev \
  libxcb-image0-dev libxcb-shm0-dev libxcb-icccm4-dev libxcb-sync-dev \
  libxcb-xfixes0-dev libxcb-shape0-dev libxcb-randr0-dev libxcb-render-util0-dev \
  libxcb-util-dev libxcb-xinerama0-dev libxcb-xkb-dev libxcb-cursor-dev \
  libxrender-dev libxi-dev libxext-dev libvulkan-dev libva-dev
echo "deps installed — now rerun: tools/build-patched-qt/build.sh"
