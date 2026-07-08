import QtQuick
import QtMultimedia

// Single-frame step engine for a QMediaPlayer + VideoOutput playback surface.
// docs/plans/2026-07-08-frame-step-plan.md (P1), primitive per the P0 spike
// (docs/perf/2026-07-08-frame-step-spike.md): on this backend QVideoFrame PTS is
// 100% valid, paused seeks RENDER exactly one frame, and the cameras emit true
// VFR — so all verification is PTS-exact via FrameClock.
//
//   forward  = play() → pause on the next rendered frame (measured 99.5% exact).
//   backward = direct paused seek to the EXACT previous frame's PTS (FrameClock
//              ring; estimate on a ring miss) — fast path, ~100 ms. VERIFIED
//              against the target: a backward seek into the segment the decoder
//              is currently parked in can snap to the decode head (measured:
//              a −50 ms request rendering +1149 ms), so any off-target landing
//              falls back to OVER-SEEK (land cleanly ~300 ms behind the target,
//              which re-opens the segment) + forward-flush one frame at a time
//              onto the target — built from the two primitives that are each
//              individually reliable.
//
// Steps are paused-only (the cross-VMS invariant): both entry points pause the
// host transport first via requestPause. Calls while busy are dropped (the
// busy-guard is what rate-limits held-down auto-repeat keys). Window-edge and
// discontinuity-boundary fallbacks are P2 — here a clamped landing fails
// honestly via stepFailed rather than silently no-oping.
Item {
    id: stepper
    visible: false

    // Host wiring. mediaPlayer/videoSink deliberately NOT named "player": in
    // `FrameStepper { player: player }` the RHS would resolve to the stepper's
    // own property, not the host's MediaPlayer id.
    property var mediaPlayer: null
    property var videoSink: null
    property var requestPause: function() { if (mediaPlayer) mediaPlayer.pause(); }

    readonly property bool ready: mediaPlayer !== null && videoSink !== null && mediaPlayer.duration > 0
    readonly property bool busy: _state !== _Idle

    signal stepped(int dir, real ptsDeltaMs, int latMs, int retries)
    signal stepFailed(int dir, string reason)

    // states
    readonly property int _Idle: 0
    readonly property int _FwdFlush: 1        // forward: awaiting the flushed frame
    readonly property int _BackDirect: 2      // backward: awaiting the direct-seek landing
    readonly property int _BackOverseek: 3    // backward: awaiting the over-seek landing
    readonly property int _BackWalk: 4        // backward: flushing forward onto the target
    property int _state: 0
    property int _dir: 0
    property int _retries: 0                  // total extra rounds this step (any mode)
    property int _walked: 0
    property double _overMs: 300
    property double _ptsBefore: -1
    property double _targetPts: -1
    property double _tCmd: 0
    property double _tPaint: -1
    // position↔PTS offset from the last VERIFIED-coherent landing. After a cursed
    // landing, `position` holds the requested value while the display shows the
    // zone head — any hop computed from that pair inherits the error. Anchoring
    // over-seeks to the last trusted pair keeps their depth exact.
    property double _anchorOff: 0
    readonly property bool _trace: typeof wtTrace !== "undefined" && wtTrace

    function _tr(s) { if (_trace) console.log("[WT-STEP] " + s); }
    function _frameDur() {
        var d = FrameClock.medianFrameDurMs;
        return d > 1 ? d : 50;                // fleet default 20fps until the ring warms up
    }
    function _tol() { return 0.75 * _frameDur(); }

    function stepForward() {
        if (!ready || busy) { _tr("drop fwd (ready=" + ready + " busy=" + busy + ")"); return false; }
        if (mediaPlayer.position >= mediaPlayer.duration - 500) {
            _tr("fwd blocked: end of footage");
            stepFailed(1, "end");
            return false;
        }
        FrameClock.attach(videoSink);
        requestPause();
        _dir = 1; _retries = 0; _tPaint = -1;
        _ptsBefore = FrameClock.lastPtsMs;
        _tCmd = Date.now();
        _state = _FwdFlush;
        watchdog.restart();
        mediaPlayer.play();                   // exactly one frame flushes; paused again on arrival
        return true;
    }

    function stepBackward() {
        if (!ready || busy) { _tr("drop back (ready=" + ready + " busy=" + busy + ")"); return false; }
        FrameClock.attach(videoSink);
        requestPause();
        _dir = -1; _retries = 0; _walked = 0; _overMs = 300; _tPaint = -1;
        _ptsBefore = FrameClock.lastPtsMs;
        _tCmd = Date.now();
        var dur = _frameDur();
        _targetPts = FrameClock.prevPtsMs(_ptsBefore);
        var mode = "ring";
        if (_targetPts < 0) {                 // ring miss (not recently played): mid-prev-interval estimate
            _targetPts = _ptsBefore - 1.5 * dur;
            mode = "est";
        }
        var newPos = Math.round(mediaPlayer.position + (_targetPts - FrameClock.lastPtsMs));
        if (newPos <= 0 && mediaPlayer.position <= 1) {
            _tr("back blocked: window start (P2 routes this via seekToWall)");
            stepFailed(-1, "window start");
            return false;
        }
        _state = _BackDirect;
        watchdog.restart();
        mediaPlayer.position = Math.max(0, newPos);   // paused seek paints the landed frame (P0 §2)
        _tr("back direct mode=" + mode + " targetPts=" + _targetPts.toFixed(1) + " newPos=" + Math.max(0, newPos));
        return true;
    }

    function _overseek() {
        _retries++;
        _state = _BackOverseek;
        watchdog.restart();
        var newPos = Math.max(0, Math.round(_targetPts - _overMs + _anchorOff));   // anchored, not pos-relative
        mediaPlayer.position = newPos;
        _tr("back overseek behind=" + _overMs + " newPos=" + newPos + " retries=" + _retries);
    }

    Connections {
        target: stepper.videoSink
        enabled: stepper._state !== stepper._Idle
        function onVideoFrameChanged() {
            if (stepper._tPaint < 0) stepper._tPaint = Date.now();
            if (stepper._state === stepper._FwdFlush || stepper._state === stepper._BackWalk)
                stepper.mediaPlayer.pause();
            settle.restart();                 // judge the FINAL displayed frame a beat later
        }
    }

    // A pause can let one more frame slip out; FrameClock tracks every paint, so
    // reading after a short settle judges what actually stayed on screen.
    Timer {
        id: settle; interval: 80
        onTriggered: {
            if (stepper._state === stepper._Idle) return;
            var landed = FrameClock.lastPtsMs;
            var d = landed - stepper._ptsBefore;
            var lat = Date.now() - stepper._tCmd;

            if (stepper._state === stepper._FwdFlush) {
                stepper._state = stepper._Idle; watchdog.stop();
                stepper._anchorOff = stepper.mediaPlayer.position - landed;
                stepper._tr("fwd landed dPts=" + d.toFixed(1) + " paintMs="
                            + (stepper._tPaint > 0 ? Math.round(stepper._tPaint - stepper._tCmd) : -1)
                            + " fullMs=" + lat);
                stepper.stepped(1, d, lat, 0);
                return;
            }

            if (stepper._state === stepper._BackDirect) {
                // Success = ON the target frame — never merely "moved back".
                if (Math.abs(landed - stepper._targetPts) <= stepper._tol()) {
                    stepper._state = stepper._Idle; watchdog.stop();
                    stepper._anchorOff = stepper.mediaPlayer.position - landed;
                    stepper._tr("back landed dPts=" + d.toFixed(1) + " fullMs=" + lat + " retries=" + stepper._retries);
                    stepper.stepped(-1, d, lat, stepper._retries);
                } else {
                    stepper._tr("back direct off-target (landed=" + landed.toFixed(1)
                                + " target=" + stepper._targetPts.toFixed(1) + ") → overseek");
                    stepper._overseek();
                }
                return;
            }

            if (stepper._state === stepper._BackOverseek) {
                if (landed < stepper._targetPts - stepper._tol()) {
                    // Cleanly behind the target (this landing is coherent — refresh the
                    // anchor) → walk forward onto it, one proven flush at a time. A seek
                    // (either direction) into the recently-stepped zone snaps to its head
                    // frame — sequential decode is the only reliable entry (measured).
                    stepper._anchorOff = stepper.mediaPlayer.position - landed;
                    stepper._state = stepper._BackWalk;
                    watchdog.restart();
                    stepper.mediaPlayer.play();
                } else if (stepper._retries < 4) {
                    stepper._overMs = Math.min(stepper._overMs * 2, 1600);   // still in the zone: further behind
                    stepper._overseek();
                } else {
                    stepper._state = stepper._Idle; watchdog.stop();
                    stepper._tr("back FAILED: overseek could not get behind target (landed=" + landed.toFixed(1) + ")");
                    stepper.stepFailed(-1, "seek stuck");
                }
                return;
            }

            if (stepper._state === stepper._BackWalk) {
                stepper._walked++;
                if (landed >= stepper._targetPts - stepper._tol()) {
                    stepper._state = stepper._Idle; watchdog.stop();
                    stepper._anchorOff = stepper.mediaPlayer.position - landed;
                    stepper._tr("back landed dPts=" + (landed - stepper._ptsBefore).toFixed(1)
                                + " via overseek+walk(" + stepper._walked + ") fullMs=" + lat
                                + " retries=" + stepper._retries);
                    stepper.stepped(-1, landed - stepper._ptsBefore, lat, stepper._retries);
                } else if (stepper._walked < 40) {                           // ≤ ~2s of frames
                    watchdog.restart();
                    stepper.mediaPlayer.play();
                } else {
                    stepper._state = stepper._Idle; watchdog.stop();
                    stepper._tr("back FAILED: walk exhausted before target");
                    stepper.stepFailed(-1, "walk exhausted");
                }
                return;
            }
        }
    }

    // In-buffer landings are ~15-30ms (P0); a step that produces no frame in this
    // window is stuck (cold rendition fetch / EOS) — fail it, never wedge `busy`.
    Timer {
        id: watchdog; interval: 1500
        onTriggered: {
            if (stepper._state === stepper._Idle) return;
            var dir = stepper._dir;
            stepper._state = stepper._Idle;
            if (stepper.mediaPlayer) stepper.mediaPlayer.pause();            // never leave it rolling
            stepper._tr("WATCHDOG dir=" + dir + " (no frame in " + interval + "ms)");
            stepper.stepFailed(dir, "timeout");
        }
    }
}
