# Isolated reproduction of the macOS "cannot create texture, Metal texture cache was
# released?" warning, and a test of src/models/MetalCacheProbe.cpp as the app builds it.
# See docs/perf/2026-09-25-mac-metal-cache-warning.md for what it measured and why.
#
#   FF=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg      # needs lavfi; the bundled LGPL ffmpeg has none
#   $FF -f lavfi -i testsrc2=size=1280x720:rate=30 -t 6 -c:v h264_videotoolbox -b:v 2M -pix_fmt yuv420p clip.mp4
#   $FF -f lavfi -i smptehdbars=size=1280x720 -frames:v 1 src.png
#   $FF -f lavfi -i smptehdbars=size=1280x720:rate=30 -t 3 -c:v h264_videotoolbox -b:v 8M -pix_fmt yuv420p \
#       -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv bars.mp4
#   cmake -S tools/tests/metal-cache-repro -B /tmp/mcr -G Ninja && cmake --build /tmp/mcr
#   MODE=toImage|map|forceCpu|compare /tmp/mcr/repro clip.mp4     (BARS=1 MODE=compare ... bars.mp4, run where src.png is)
#   [SCOPED=1] /tmp/mcr/probe_test clip.mp4
# macOS only; uses the cocoa platform (no window is shown). -platform offscreen delivers NO frames.
# Linux: see LINUX.md — UNTESTED there, with the controls needed to read any result.
cmake_minimum_required(VERSION 3.21)
project(metal_cache_repro LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(Qt6 REQUIRED COMPONENTS Gui Multimedia MultimediaPrivate)
add_executable(repro repro.cpp)
target_link_libraries(repro PRIVATE Qt6::Gui Qt6::Multimedia Qt6::MultimediaPrivate)
add_executable(probe_test probe_test.cpp ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/models/MetalCacheProbe.cpp)
target_include_directories(probe_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/models)
target_link_libraries(probe_test PRIVATE Qt6::Gui Qt6::Multimedia)
