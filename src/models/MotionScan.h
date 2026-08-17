#pragma once

#include <QObject>
#include <QVector>

class QVideoSink;
class QVideoFrame;

// Measured-motion scanner on the hero player's QVideoSink (operator goal 2026-08-17: the
// yellow movement span must start where movement is VISIBLE in the footage; camera motion
// stamps measured skewing −20 s / +2 s / +7 s per camera in one evening —
// docs/letters/2026-08-17-null-clock-fields-block-marker-sync.md). Every rendered frame is
// downsampled to a 32×18 luma grid IN the frame handler (raw QVideoFrames never cross
// threads — the 4aa4ed7 law), diffed against the previous CONTIGUOUS frame (a PTS-delta
// gate rebaselines across seeks/re-opens so a scene jump can't score), and the first
// SUSTAINED motion (two consecutive frames over the cell-fraction threshold) is reported
// by PTS. The fraction threshold is what separates a person crossing the frame (tens of
// cells) from a distant background car (1–2 cells) — the .110 lesson.
class MotionScan : public QObject
{
    Q_OBJECT
    Q_PROPERTY(double firstMotionPtsMs READ firstMotionPtsMs NOTIFY firstMotionChanged)
    Q_PROPERTY(double earliestPtsMs READ earliestPtsMs NOTIFY frameScanned)
public:
    explicit MotionScan(QObject *parent = nullptr);

    Q_INVOKABLE void attach(QObject *videoSink);   // QVideoSink*; re-attach replaces
    Q_INVOKABLE void reset();                      // new session window → fresh scan

    double firstMotionPtsMs() const { return m_firstMotionPtsMs; }
    double earliestPtsMs() const { return m_earliestPtsMs; }

signals:
    void firstMotionChanged();
    void frameScanned();

private slots:
    void onFrame(const QVideoFrame &frame);

private:
    static constexpr int kGW = 32, kGH = 18;       // luma grid
    static constexpr int kDiffThresh = 14;         // per-cell |Δluma| that counts as change
    // Movement = changed cells that PERSIST in place across consecutive frames (set
    // intersection). A walker keeps disturbing the same region; an HEVC I-frame refresh
    // flips ~10% of cells for exactly ONE frame in a scattered pattern (measured on the
    // .189 fixture: 0.09-0.12 spikes every GOP ~4s, noise floor 0.005-0.009), so the
    // intersection gate kills GOP pulses while a low floor still catches small movers.
    // Tuned on the 2026-08-17 fixtures: an HEVC I-frame refresh spikes ~9-12% of cells for
    // exactly ONE frame (GOP ~4s) — the consec gate is what kills it, so it can afford to be
    // long. Raw floor sits between a distant background car (~<1% of cells, .110 pre-roll)
    // and a mid-distance walker (~1.5-3%); a close walker is 3%+. Intersection scoring was
    // tried and reverted: it catches small coherent movers (the background car) — measured.
    static constexpr double kCellFrac = 0.025;     // fraction of changed cells = movement
    static constexpr int kConsecNeed = 2;          // sustained = this many contiguous frames
    static constexpr double kMaxGapMs = 500.0;     // PTS gap above this = not contiguous

    QVideoSink *m_sink = nullptr;
    QVector<quint8> m_prev, m_cur;
    QVector<quint8> m_chPrev, m_chCur;             // changed-cell masks (this frame vs previous)
    double m_prevPtsMs = -1;
    double m_earliestPtsMs = -1;
    double m_firstMotionPtsMs = -1;
    double m_candPtsMs = -1;
    int m_consec = 0;
    int m_mapFails = 0;
    double m_bucketT0 = 0, m_bucketMax = 0;
    bool m_trace = false;
};
