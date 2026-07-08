import QtQuick
import QtMultimedia

// Single-frame step engine for a QMediaPlayer + VideoOutput playback surface.
// docs/plans/2026-07-08-frame-step-plan.md (P1+P2), calibrated by measurement:
// P0 spike (docs/perf/2026-07-08-frame-step-spike.md) — PTS 100% valid, paused
// seeks render, true-VFR streams; P1 — a seek in EITHER direction into the zone
// the decoder recently stepped through renders the zone's HEAD frame, so hot
// backward seeks cannot work and only sequential decode enters the zone.
//
// Step paths, in order of preference:
//   forward : cache repaint (when stepped-back through cached frames)
//             → play() + pause-on-first-frame flush (measured 99.5% exact);
//   backward: cache repaint (FrameCache holds recently DISPLAYED frames —
//             instant, no demuxer) → direct paused seek to the exact previous
//             frame's PTS → anchored overseek + frame-walk (the walk CAPTURES
//             every frame it decodes, so one walk fills the cache and the
//             following back-steps are instant).
//
// Cache repaints DIVERGE the shown frame from the player's parked position;
// `diverged` tracks that, forward repaints re-converge at the parked frame,
// and the host must call resumeForPlay()/invalidate() on real transport ops.
// Window-edge / discontinuity-boundary steps route to the host's wall-seek
// machinery via edgeFallback. Steps are paused-only (the cross-VMS invariant);
// busy-guard drops auto-repeat overflow; a watchdog guarantees `busy` can
// never wedge; [WT-STEP] traces every path.
Item {
    id: stepper
    visible: false

    // Host wiring. mediaPlayer/videoSink deliberately NOT named "player": in
    // `FrameStepper { player: player }` the RHS would resolve to the stepper's
    // own property, not the host's MediaPlayer id.
    property var mediaPlayer: null
    property var videoSink: null
    property var requestPause: function() { if (mediaPlayer) mediaPlayer.pause(); }
    // Host: does the position-domain jump [fromMs,toMs] cross a kept discontinuity?
    property var crossesDisc: function(fromMs, toMs) { return false; }
    // Host: route an un-steppable edge (window start / disc boundary) to the wall-seek path.
    property var edgeFallback: null

    readonly property bool ready: mediaPlayer !== null && videoSink !== null && mediaPlayer.duration > 0
    readonly property bool busy: _state !== _Idle
    // Shown frame came from the cache; the player is parked elsewhere (at _cohPts).
    property bool diverged: false
    // The recovery machinery (overseek + walk) is churning frames the operator must
    // not see — the host shows a freeze-frame of the pre-step image while this is up.
    property bool veiled: false
    // Host hook: grab the currently shown frame (async) so the veil has an image to
    // hold. Called at the start of every seek-path back-step, before any seek moves.
    property var veilGrab: null
    // Position-domain estimate of the SHOWN frame (for host playhead sync while diverged).
    readonly property double cursorPosEstMs: FrameClock.lastPtsMs + _anchorOff
    // PTS→position offset for mapping arbitrary cached PTS to wall time (filmstrip labels).
    readonly property double anchorOffMs: _anchorOff
    property string lastPath: ""              // flush | cache | direct | walk | edge

    signal stepped(int dir, real ptsDeltaMs, int latMs, int retries)
    signal stepFailed(int dir, string reason)

    // states
    readonly property int _Idle: 0
    readonly property int _FwdFlush: 1        // forward: awaiting the flushed frame
    readonly property int _BackDirect: 2      // backward: awaiting the direct-seek landing
    readonly property int _BackOverseek: 3    // backward: awaiting the over-seek landing
    readonly property int _BackWalk: 4        // backward: walking forward onto the target
    property int _state: 0
    property int _dir: 0
    property int _retries: 0
    property int _walked: 0
    property double _overMs: 300
    property double _ptsBefore: -1
    property double _targetPts: -1
    property double _tCmd: 0
    property double _tPaint: -1
    // position↔PTS offset from the last VERIFIED-coherent landing: after a cursed
    // landing `position` holds the requested value while the display shows the zone
    // head, so hops computed from that pair inherit the error. All seek targets are
    // computed from this anchor in absolute terms instead.
    property double _anchorOff: 0
    property double _cohPts: -1               // PTS where the player is actually parked
    readonly property bool _trace: typeof wtTrace !== "undefined" && wtTrace

    function _tr(s) { if (_trace) console.log("[WT-STEP] " + s); }
    function _frameDur() {
        var d = FrameClock.medianFrameDurMs;
        return d > 1 ? d : 50;                // fleet default 20fps until the ring warms up
    }
    function _tol() { return 0.75 * _frameDur(); }
    function _attach() { FrameClock.attach(videoSink); FrameCache.attach(videoSink); }
    function _finishReal(landedPts) {         // a REAL frame landed: player and display coherent
        _anchorOff = mediaPlayer.position - landedPts;
        _cohPts = landedPts;
        diverged = false;
        veiled = false;
        FrameCache.capturing = false;
        _state = _Idle;
        watchdog.stop();
    }

    // Host must call on any real transport op (scrubber/far seek, session load,
    // speed change): drops the cache, divergence and any in-flight step.
    function invalidate() {
        FrameCache.clear();
        FrameCache.capturing = false;
        diverged = false;
        veiled = false;
        if (_state !== _Idle) { _state = _Idle; watchdog.stop(); settle.stop(); _tr("invalidated mid-step"); }
    }
    // Host calls before resuming playback while diverged: park the player just
    // behind the shown frame so play continues from what the operator sees
    // (a seek INTO the hot zone is unreliable — land shortly behind instead).
    function resumeForPlay() {
        if (!diverged) return;
        var pos = Math.max(0, Math.round(FrameClock.lastPtsMs - 300 + _anchorOff));
        mediaPlayer.position = pos;
        _tr("resumeForPlay → pos=" + pos + " (300ms behind shown frame)");
        diverged = false;
        FrameCache.clear();
    }

    // Jump straight to a cached frame (filmstrip thumbnail click). Instant repaint;
    // divergence bookkeeping matches the cache step paths.
    function jumpToCachedPts(pts) {
        if (!ready || busy) { _tr("drop jump (busy)"); return false; }
        _attach();
        requestPause();
        var cursor = FrameClock.lastPtsMs;
        var landed = FrameCache.repaint(pts, _tol());
        if (landed < 0) { _tr("jump miss pts=" + pts.toFixed(1)); return false; }
        diverged = !(_cohPts >= 0 && Math.abs(landed - _cohPts) <= _tol());
        lastPath = "cache";
        _tr("jump cache pts=" + landed.toFixed(1));
        stepped(landed >= cursor ? 1 : -1, landed - cursor, 0, 0);
        return true;
    }

    function stepForward() {
        if (!ready || busy) { _tr("drop fwd (ready=" + ready + " busy=" + busy + ")"); return false; }
        _attach();
        requestPause();
        var cursor = FrameClock.lastPtsMs;
        // Re-tracing cached ground: repaint forward instantly until we reach the
        // frame the player is actually parked at, then hand back to real decode.
        if (diverged) {
            var np = FrameCache.nextPts(cursor + 0.5);
            if (np >= 0) {
                var landed = FrameCache.repaint(np, _tol());
                if (landed >= 0) {
                    if (_cohPts >= 0 && Math.abs(landed - _cohPts) <= _tol()) diverged = false;  // re-converged
                    lastPath = "cache";
                    _tr("fwd cache hit pts=" + landed.toFixed(1) + (diverged ? "" : " (re-converged)"));
                    stepped(1, landed - cursor, 0, 0);
                    return true;
                }
            }
            // Cache exhausted below the parked frame (tolerance edge) — treat as converged.
            diverged = false;
        }
        if (mediaPlayer.position >= mediaPlayer.duration - 500) {
            _tr("fwd blocked: end of footage");
            stepFailed(1, "end");
            return false;
        }
        _dir = 1; _retries = 0; _tPaint = -1;
        _ptsBefore = cursor;
        _tCmd = Date.now();
        _state = _FwdFlush;
        FrameCache.capturing = true;          // stepped-through frames feed the back-step cache
        watchdog.restart();
        mediaPlayer.play();                   // exactly one frame flushes; paused again on arrival
        return true;
    }

    function stepBackward() {
        if (!ready || busy) { _tr("drop back (ready=" + ready + " busy=" + busy + ")"); return false; }
        _attach();
        requestPause();
        var cursor = FrameClock.lastPtsMs;
        // 1) Instant path: the frame is in the cache (recently displayed).
        var cp = FrameCache.prevPts(cursor - 0.5);
        if (cp >= 0) {
            var landed = FrameCache.repaint(cp, _tol());
            if (landed >= 0) {
                diverged = true;
                lastPath = "cache";
                _tr("back cache hit pts=" + landed.toFixed(1) + " (cache " + FrameCache.frames + "f)");
                stepped(-1, landed - cursor, 0, 0);
                return true;
            }
        }
        // 2) Seek path. Target = exact previous frame PTS (ring) or a mid-interval estimate.
        var dur = _frameDur();
        _targetPts = FrameClock.prevPtsMs(cursor);
        var mode = "ring";
        if (_targetPts < 0) { _targetPts = cursor - 1.5 * dur; mode = "est"; }
        var newPos = Math.round(_targetPts + _anchorOff);      // absolute, anchor-based
        // Edge/boundary: window start or a kept discontinuity → wall-seek machinery.
        if (newPos <= 1 || crossesDisc(Math.max(0, cursorPosEstMs), newPos)) {
            lastPath = "edge";
            _tr("back edge (newPos=" + newPos + ") → host wall-seek fallback");
            if (edgeFallback) edgeFallback(-1);
            stepFailed(-1, "window edge");
            return false;
        }
        if (veilGrab) veilGrab();             // freeze-frame source, ready if recovery kicks in
        _dir = -1; _retries = 0; _walked = 0; _overMs = 300; _tPaint = -1;
        _ptsBefore = cursor;
        _tCmd = Date.now();
        _state = _BackDirect;
        FrameCache.capturing = true;          // landings + walk frames feed the cache
        watchdog.restart();
        mediaPlayer.position = newPos;        // paused seek paints the landed frame (P0 §2)
        _tr("back direct mode=" + mode + " targetPts=" + _targetPts.toFixed(1) + " newPos=" + newPos);
        return true;
    }

    function _overseek() {
        _retries++;
        _state = _BackOverseek;
        veiled = true;                        // recovery churn starts — hold the pre-step frame
        watchdog.restart();
        var newPos = Math.max(0, Math.round(_targetPts - _overMs + _anchorOff));
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
                stepper._finishReal(landed);
                stepper.lastPath = "flush";
                stepper._tr("fwd landed dPts=" + d.toFixed(1) + " paintMs="
                            + (stepper._tPaint > 0 ? Math.round(stepper._tPaint - stepper._tCmd) : -1)
                            + " fullMs=" + lat);
                stepper.stepped(1, d, lat, 0);
                return;
            }

            if (stepper._state === stepper._BackDirect) {
                // Success = ON the target frame — never merely "moved back".
                if (Math.abs(landed - stepper._targetPts) <= stepper._tol()) {
                    stepper._finishReal(landed);
                    stepper.lastPath = "direct";
                    stepper._tr("back landed dPts=" + d.toFixed(1) + " fullMs=" + lat);
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
                    // Cleanly behind (coherent → refresh the anchor); walk forward onto the
                    // target — sequential decode is the only reliable entry into the hot
                    // zone, and every walked frame is captured into the cache.
                    stepper._anchorOff = stepper.mediaPlayer.position - landed;
                    stepper._state = stepper._BackWalk;
                    watchdog.restart();
                    stepper.mediaPlayer.play();
                } else if (stepper._retries < 4) {
                    stepper._overMs = Math.min(stepper._overMs * 2, 1600);   // still in the zone: further behind
                    stepper._overseek();
                } else {
                    stepper._state = stepper._Idle; watchdog.stop(); FrameCache.capturing = false; stepper.veiled = false;
                    stepper._tr("back FAILED: overseek could not get behind target (landed=" + landed.toFixed(1) + ")");
                    stepper.stepFailed(-1, "seek stuck");
                }
                return;
            }

            if (stepper._state === stepper._BackWalk) {
                stepper._walked++;
                if (landed >= stepper._targetPts - stepper._tol()) {
                    stepper._finishReal(landed);
                    stepper.lastPath = "walk";
                    stepper._tr("back landed dPts=" + (landed - stepper._ptsBefore).toFixed(1)
                                + " via overseek+walk(" + stepper._walked + ") fullMs=" + lat
                                + " cached=" + FrameCache.frames);
                    stepper.stepped(-1, landed - stepper._ptsBefore, lat, stepper._retries);
                } else if (stepper._walked < 40) {                           // ≤ ~2s of frames
                    watchdog.restart();
                    stepper.mediaPlayer.play();
                } else {
                    stepper._state = stepper._Idle; watchdog.stop(); FrameCache.capturing = false; stepper.veiled = false;
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
            FrameCache.capturing = false;
            stepper.veiled = false;
            if (stepper.mediaPlayer) stepper.mediaPlayer.pause();            // never leave it rolling
            stepper._tr("WATCHDOG dir=" + dir + " (no frame in " + interval + "ms)");
            stepper.stepFailed(dir, "timeout");
        }
    }
}
