#!/usr/bin/env python3
"""Anchor-based applier for patches 0002-0005 (offsets in the .patch files are
illustrative; each change is applied by exact source anchor and FAILS LOUDLY
on drift so a Qt bump cannot silently skip a defense).

Usage: apply-anchored.py <qtmultimedia-src-root>
"""
import sys, os

root = sys.argv[1]
applied = []

def patch(relpath, anchor, replacement, name):
    p = os.path.join(root, relpath)
    s = open(p).read()
    if replacement in s:
        applied.append(name + " (already)")
        return
    if anchor not in s:
        sys.stderr.write("FATAL: %s anchor not found in %s — source drifted\n" % (name, relpath))
        sys.exit(1)
    open(p, "w").write(s.replace(anchor, replacement, 1))
    applied.append(name)

# ---- 0002: QVideoFrame::map rejects invalid successful MapData ----
patch("src/multimedia/video/qvideoframe.cpp",
"""    d->mapData = d->videoBuffer->map(mode);
    if (d->mapData.planeCount == 0)
        return false;
""",
"""    d->mapData = d->videoBuffer->map(mode);
    if (d->mapData.planeCount == 0)
        return false;

    // Internal patch 0002: reject a "successful" map whose required planes
    // are unusable (see third_party/qt-patches/6.12/README.md).
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
""", "0002")

# ---- 0003: balance beginOffscreenFrame on fallback paths ----
patch("src/multimedia/video/qvideoframeconverter.cpp",
"""    auto videoFrameTextures = QVideoTextureHelper::createTextures(frameTmp, *rhi, *rub, texturesTmp);
    if (!videoFrameTextures) {
        qCDebug(qLcVideoFrameConverter) << "Failed obtain textures. Using CPU conversion.";
        return convertCPU(frame, transformation);
    }
""",
"""    auto videoFrameTextures = QVideoTextureHelper::createTextures(frameTmp, *rhi, *rub, texturesTmp);
    if (!videoFrameTextures) {
        qCDebug(qLcVideoFrameConverter) << "Failed obtain textures. Using CPU conversion.";
        // Internal patch 0003: never leave the offscreen frame recording.
        cb->resourceUpdate(rub);
        rhi->endOffscreenFrame();
        return convertCPU(frame, transformation);
    }
""", "0003a")

patch("src/multimedia/video/qvideoframeconverter.cpp",
"""    if (!updateTextures(rhi, uniformBuffer, textureSampler, shaderResourceBindings,
                        graphicsPipeline, renderPass, frameTmp, videoFrameTextures)) {
        qCDebug(qLcVideoFrameConverter) << "Failed to update textures. Using CPU conversion.";
        return convertCPU(frame, transformation);
    }
""",
"""    if (!updateTextures(rhi, uniformBuffer, textureSampler, shaderResourceBindings,
                        graphicsPipeline, renderPass, frameTmp, videoFrameTextures)) {
        qCDebug(qLcVideoFrameConverter) << "Failed to update textures. Using CPU conversion.";
        // Internal patch 0003: never leave the offscreen frame recording.
        cb->resourceUpdate(rub);
        rhi->endOffscreenFrame();
        return convertCPU(frame, transformation);
    }
""", "0003b")

# ---- 0004: check vaSyncSurface before import ----
patch("src/plugins/multimedia/ffmpeg/qffmpeghwaccel_vaapi.cpp",
"""    // ### Check that prime.fourcc is what we expect
    vaSyncSurface(vaDisplay, vaSurface);
""",
"""    // ### Check that prime.fourcc is what we expect
    // Internal patch 0004: importing an unsynchronized surface hands the
    // render pipeline undefined pixels; fds are closed by closeObjectsGuard.
    if (VAStatus syncStatus = vaSyncSurface(vaDisplay, vaSurface); syncStatus != VA_STATUS_SUCCESS) {
        qWarning() << "vaSyncSurface failed:" << syncStatus << "- not importing the surface";
        return nullptr;
    }
""", "0004")

# ---- 0005: corrupt-frame flags: log + opt-in drop ----
patch("src/plugins/multimedia/ffmpeg/playbackengine/qffmpegstreamdecoder.cpp",
"""        if (receiveFrameResult < 0) {
            emit error(QMediaPlayer::FormatError, err2str(receiveFrameResult));
            break;
        }
""",
"""        if (receiveFrameResult < 0) {
            emit error(QMediaPlayer::FormatError, err2str(receiveFrameResult));
            break;
        }

        // Internal patch 0005: surface damaged decoder output instead of
        // silently delivering it; drop only when explicitly requested.
        if ((avFrame->flags & AV_FRAME_FLAG_CORRUPT) || avFrame->decode_error_flags) {
            static const bool dropCorrupt =
                    qEnvironmentVariableIsSet("QT_FFMPEG_DROP_CORRUPT_FRAMES");
            qWarning() << "StreamDecoder: damaged decoder output, flags" << avFrame->flags
                       << "decode_error_flags" << avFrame->decode_error_flags
                       << (dropCorrupt ? "- dropping" : "- delivering");
            if (dropCorrupt)
                continue;
        }
""", "0005")

print("applied:", ", ".join(applied))
