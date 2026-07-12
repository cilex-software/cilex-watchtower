#!/usr/bin/env python3
"""Apply patch 0002 (reject invalid successful MapData) by anchor, not offsets.

The .patch file in third_party/qt-patches/6.12/ documents the change; hunk
offsets there are illustrative. This applier inserts the validation block
after the buffer-map call in QVideoFrame::map() and FAILS LOUDLY if the
anchor context has drifted (so a Qt bump can't silently skip the defense).
"""
import sys

path = sys.argv[1]
src = open(path).read()

ANCHOR = """    d->mapData = d->videoBuffer->map(mode);
    if (d->mapData.planeCount == 0)
        return false;
"""
GUARD = """    d->mapData = d->videoBuffer->map(mode);
    if (d->mapData.planeCount == 0)
        return false;

    // Internal patch 0002: reject a "successful" map whose required planes
    // are unusable — a null data pointer, negative stride, or negative size
    // on any reported plane means the underlying buffer failed without
    // saying so; treating it as success hands invalid planes to the pixel
    // converters (see qt-patches/6.12/README.md).
    for (int planeIdx = 0; planeIdx < d->mapData.planeCount; ++planeIdx) {
        if (d->mapData.data[planeIdx] == nullptr
            || d->mapData.bytesPerLine[planeIdx] < 0
            || d->mapData.dataSize[planeIdx] < 0) {
            qWarning("QVideoFrame::map: buffer reported %d planes but plane %d is invalid",
                     d->mapData.planeCount, planeIdx);
            d->mapData = {};
            return false;
        }
    }
"""

if GUARD in src:
    print("0002 already applied")
    sys.exit(0)
if ANCHOR not in src:
    sys.stderr.write("FATAL: 0002 anchor not found in %s — Qt source drifted; "
                     "re-verify the defense placement.\n" % path)
    sys.exit(1)
src = src.replace(ANCHOR, GUARD, 1)
open(path, "w").write(src)
print("0002 applied to", path)
