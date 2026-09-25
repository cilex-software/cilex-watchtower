#pragma once
// "cannot create texture, Metal texture cache was released?"
// (Qt's darwin media plugin: AVFVideoBuffer::textureHandle).
//
// REPRODUCED IN ISOLATION 2026-09-25 (QMediaPlayer -> a QVideoSink with NO rhi ->
// QVideoFrame::toImage(), Qt 6.11.1, macOS 26): the warning fires ONCE PER PLANE
// (NV12: exactly 2 per frame, 360 for 180 frames) because Qt first tries a zero-copy
// Metal texture and a render-less sink has no texture cache. Qt then uploads the planes
// and converts on the GPU, and the IMAGE IS CORRECT: +/-3 levels against SMPTE-bar
// ground truth. It is a false alarm there — 46,801 of them in this Mac's flight
// recorder, 60/s for 24 minutes on 22 Sep, burying everything else.
//
// NOT THE FIX: Qt's CPU converter (private qImageFromVideoFrame(f, forceCpu=true))
// silences it but gets BT.709 wrong — saturated colours off by up to 32 levels,
// cyan's green clipping at 255. Measured against the same bars; rejected.
//
// So this probe fixes the LOGGING and instruments everything else:
//  - inside an ExpectedScope (FrameCache's harvest path — the proven-benign producer)
//    the warning is counted, not printed, and each episode leaves one summary line;
//  - ANY other occurrence is unexplained, so the first of each episode logs the
//    emitting thread, a C++ backtrace (it names the caller: FrameCache::onFrame,
//    MotionScan, the scene graph, grabToImage...) and every registered sink's rhi()
//    state; the original line still reaches the flight recorder.
class QObject;
class QVideoSink;

namespace MetalCacheProbe {
void install();                                   // AFTER FlightRecorder::install — chains its handler
void startPeriodic(QObject *parent);              // closes idle episodes and logs their totals
void noteSink(const char *role, QVideoSink *sink); // who owns which sink: the snapshot's legend

// Marks warnings raised on THIS thread, while alive, as expected (counted, not printed).
// Only for producers proven benign — today: FrameCache's render-less harvest sink.
class ExpectedScope
{
public:
    explicit ExpectedScope(const char *who);
    ~ExpectedScope();
    ExpectedScope(const ExpectedScope &) = delete;
    ExpectedScope &operator=(const ExpectedScope &) = delete;

private:
    const char *m_prev;
};
} // namespace MetalCacheProbe
