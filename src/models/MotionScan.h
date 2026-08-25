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
    Q_PROPERTY(double lastMotionPtsMs READ lastMotionPtsMs NOTIFY frameScanned)
    Q_PROPERTY(double latestPtsMs READ latestPtsMs NOTIFY frameScanned)
    Q_PROPERTY(double earliestPtsMs READ earliestPtsMs NOTIFY frameScanned)
    // Liveness: sampled frames THIS session. 0 at the clip's end = the scanner is blind
    // on this pipeline (map+readback both failed) — UI must not act on absent evidence.
    Q_PROPERTY(int framesScanned READ framesScanned NOTIFY frameScanned)
    // Sum of CONTIGUOUSLY-scanned time this session. The head-coverage proof: a scanner
    // that woke mid-clip claims earliest≈0 yet has scanned only a fraction of head→lock —
    // the QML side rejects a first-motion lock whose claimed stretch exceeds this span.
    Q_PROPERTY(double scannedSpanMs READ scannedSpanMs NOTIFY frameScanned)
public:
    explicit MotionScan(QObject *parent = nullptr);

    Q_INVOKABLE void attach(QObject *videoSink);   // QVideoSink*; re-attach replaces
    Q_INVOKABLE void reset();                      // new session window → fresh scan
    // No-PTS backends (macOS darwin/AVFoundation delivers frames without startTime): the
    // player feeds its position here on every scanned frame; it becomes the frame's time
    // source, with wall-clock gaps as the contiguity gate. WT_MSCAN_NOPTS=1 forces this
    // path on any platform so the fallback is verifiable against the PTS path on Linux.
    Q_INVOKABLE void notePosition(double posMs);   // stamps arrival wall time: a STALE note
                                                   // must never label a frame (Mac 08-25)

    double firstMotionPtsMs() const { return m_firstMotionPtsMs; }
    double lastMotionPtsMs() const { return m_lastMotionPtsMs; }
    double latestPtsMs() const { return m_latestPtsMs; }
    double earliestPtsMs() const { return m_earliestPtsMs; }
    int framesScanned() const { return m_framesScanned; }
    double scannedSpanMs() const { return m_scannedSpanMs; }

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
    static constexpr int kConsecNeed = 2;          // sustained = this many CHAINED crossings
    // Crossings chain if ≤ this far apart on the wall clock. At 15 fps mapped scanning two
    // adjacent frames sit 66 ms apart (old behaviour kept); at the 10 Hz toImage readback a
    // distant walker crosses the gate only sporadically — one sub-gate sample between two
    // crossings must not reset the count (measured 08-25: post-hole buckets max 0.055-0.066
    // yet zero sustained locks). A GOP I-frame pulse is a SINGLE crossing with quiet ~4 s
    // around it — it can never chain, so the pulse-killer property is preserved.
    static constexpr double kChainMs = 450.0;
    static constexpr double kMaxGapMs = 500.0;     // PTS gap above this = not contiguous

    QVideoSink *m_sink = nullptr;
    QVector<quint8> m_prev, m_cur;
    QVector<quint8> m_chPrev, m_chCur;             // changed-cell masks (this frame vs previous)
    double m_prevPtsMs = -1;
    double m_notedPosMs = -1;
    qint64 m_prevWallMs = -1;                      // arrival wall clock (contiguity when no PTS)
    bool m_forceNoPts = false;
    bool m_saidNoPts = false;
    bool m_saidPtsDiverge = false;
    bool m_ptsUntrusted = false;                   // latched on first divergence: a backend that
                                                   // lied once gets position-timing for the session
    int m_jumpNotes = 0;                           // rebaseline log throttle
    qint64 m_noteWallMs = -1;                      // when notePosition() last fired (staleness gate)
    double m_scannedSpanMs = 0;                    // Σ contiguous scanned time this session
    qint64 m_resetWallMs = -1;
    qint64 m_firstSampleWallMs = -1;               // when the first frame was actually sampled
    qint64 m_lastMoveWallMs = -1;                  // last gate-crossing frame (chain clock)
    qint64 m_rideWallMs = -1;                      // last crossing for the post-lock tail ride
    // Small-mover state (operator 08-26): at 640x360 a distant walker flips 1-3 cells —
    // under every area gate. Its surviving signature: a COMPACT active-cell cluster that
    // PERSISTS (per-cell hit streaks — a single-frame GOP pulse can't) and DRIFTS (net
    // centroid displacement — foliage wind oscillates in place). Post-lock, ride-only.
    quint8 m_hits[kGW * kGH] = {0};                // per-cell recent-change streak (0..5)
    struct CentSample { qint64 w = 0; double x = 0, y = 0; };
    CentSample m_cent[24];                         // ring of compact-cluster centroids
    int m_centN = 0, m_centI = 0;
    bool m_saidSmall = false;
    int m_bucketCellsMax = 0;                      // telemetry maxima per ~2s bucket
    double m_bucketDriftMax = 0;
    int m_blindMs = 0;                             // WT_MSCAN_BLINDMS (test): drop sampling in [2s, 2s+N] after the FIRST SAMPLE
    double m_earliestPtsMs = -1;
    double m_firstMotionPtsMs = -1;
    double m_lastMotionPtsMs = -1;                 // last sustained-motion frame seen this scan
    double m_latestPtsMs = -1;                     // scan coverage tail (for completeness checks)
    // Adaptive gate (2026-08-19): trailing median of recent scores = the scene's noise
    // floor (GOP spikes are single-frame, medians ignore them). A dark mover that never
    // clears the absolute floor still clears many multiples of ITS OWN floor.
    double m_recent[32] = {0};
    int m_recentN = 0, m_recentI = 0;
    double m_candPtsMs = -1;
    int m_consec = 0;
    int m_mapFails = 0;
    int m_framesScanned = 0;                       // per-session sampled-frame count (liveness)
    qint64 m_lastImgMs = 0;                        // toImage-readback throttle (~10 Hz)
    bool m_forceImg = false;                       // WT_MSCAN_FORCEIMG=1: exercise the readback path on Linux
    bool m_saidImgFail = false;
    double m_bucketT0 = 0, m_bucketMax = 0;
    bool m_trace = false;
};
