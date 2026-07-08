#pragma once

#include <QObject>
#include <QVector>

class QVideoSink;

// Frame-PTS probe / clock on a QVideoSink (P0 spike of docs/plans/2026-07-08-frame-step-plan.md,
// then the PTS source for frame stepping). Reads QVideoFrame::startTime()/endTime() off every
// rendered frame: exposes the last frame's PTS, a median frame duration over a small ring, and
// PTS-validity counters (the research flags startTime can be -1 on some backends — the spike
// measures ours). Keeps a short PTS history so a back-step can target the EXACT previous frame's
// timestamp instead of an estimate (crucial: our cameras emit true VFR — 25/50/100 ms deltas).
// Inert (no sink connected) unless attach() is called.
class FrameClock : public QObject
{
    Q_OBJECT
    Q_PROPERTY(double lastPtsMs READ lastPtsMs NOTIFY frameSeen)
    Q_PROPERTY(int frameCount READ frameCount NOTIFY frameSeen)
    Q_PROPERTY(int validPts READ validPts NOTIFY frameSeen)
    Q_PROPERTY(int invalidPts READ invalidPts NOTIFY frameSeen)
    Q_PROPERTY(double medianFrameDurMs READ medianFrameDurMs NOTIFY frameSeen)
public:
    explicit FrameClock(QObject *parent = nullptr) : QObject(parent) {}

    Q_INVOKABLE void attach(QObject *videoSink);   // QVideoSink*; re-attach replaces
    Q_INVOKABLE void reset();

    double lastPtsMs() const { return m_lastPtsMs; }
    int frameCount() const { return m_frames; }
    int validPts() const { return m_valid; }
    int invalidPts() const { return m_invalid; }
    double medianFrameDurMs() const;

    // Exact PTS of the newest ring entry strictly BEFORE `beforeMs − 0.5` (the previous
    // frame's timestamp when we've recently played through it). −1 when unknown.
    Q_INVOKABLE double prevPtsMs(double beforeMs) const;

signals:
    void frameSeen();

private:
    void onFrame(const class QVideoFrame &frame);

    QVideoSink *m_sink = nullptr;
    double m_lastPtsMs = -1;
    int m_frames = 0, m_valid = 0, m_invalid = 0;
    QVector<double> m_ring;          // recent valid PTS (ms), bounded
    static constexpr int kRingMax = 256;
};
