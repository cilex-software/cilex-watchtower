# Deterministic reproducer — retained blank m_swFrame (Qt 6.12 FFmpeg backend)

## Build

    QT=~/Qt/6.12.0/gcc_64          # or the patched prefix from tools/build-patched-qt/
    cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH=$QT
    cmake --build build
    gcc -shared -fPIC -O2 -o xfer-interpose.so ../tools/xfer-interpose.c

## Test clip (hardware-decodable H.264)

    ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=25:duration=30 \
           -c:v libx264 -pix_fmt yuv420p -g 50 clip.mp4
    # (any VA-API/D3D11-decodable local file works; HEVC from a real camera is ideal)

## Run — UNPATCHED Qt (expect SIGSEGV at the forced frame)

    LD_LIBRARY_PATH=$QT/lib QT_PLUGIN_PATH=$QT/plugins \
    LD_PRELOAD=./xfer-interpose.so XFER_FAIL_AFTER=100 XFER_FAIL_COUNT=1 \
    ./build/qvf-repro clip.mp4

    → "[XFER] call#100 ... FORCED_FAIL" → "Error transferring ..." →
      "Cannot map a video frame in ReadOnly mode!" → SIGSEGV in
      qImageFromVideoFrame (bt frame offsets match the field crashes).

## Run — PATCHED Qt (same command, patched prefix)

    → the poisoned frame's toImage() returns null gracefully,
      "[REPRO] frame N: second map -> ..." shows the transfer being
      RE-ATTEMPTED (seam logs "first REAL transfer after forced window"),
      process exits 0 with "-> CLEAN".

Covers the required regression scenarios end-to-end: failed transfer then
another map of the same buffer; single toImage texture-path + CPU fallback;
failure followed by successful retry; repeated failure (raise
XFER_FAIL_COUNT) without invalid successful MapData; valid conversion
immediately after a poisoned frame (subsequent frames in the same run).
