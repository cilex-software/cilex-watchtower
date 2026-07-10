import QtQuick
import QtMultimedia

// Hidden HARVESTER decoder for frame-by-frame mode: a second MediaPlayer on the
// SAME session playlist (same PTS domain) that races ahead of — and when needed
// behind — the operator's frame, capturing every frame it decodes into
// FrameCache. With it, single-frame steps and filmstrip slots are served from
// cache in BOTH directions, and holding an arrow key (ramp floor ~15 steps/s)
// cannot outrun the fill (it decodes at 2× ≈ 40 fps). The operator's own player
// never moves for prefetching — the old step-the-player warmup (the flicker
// source) is gone. Active only while frame mode is on; zero cost otherwise.
Item {
    id: hv
    visible: false

    property url source: ""            // MUST be the main player's playlist (same pts domain)
    property bool active: false
    property double userPts: -1        // operator's shown frame (FrameClock.lastPtsMs)
    property double anchorOffMs: 0     // pts → player-position mapping (from the stepper)
    property double frameDurMs: 50

    readonly property int aheadTarget: 48        // keep ~2.4 s cached ahead @ 20 fps
    readonly property int aheadLow: 30           // refill when the chained run drops below this
    readonly property int behindChunk: 48        // backward fill chunk (frames)
    readonly property int behindLow: 14          // refill behind when this close to the chain floor
    readonly property real chainGap: 2.6         // × frameDur — max gap that still counts as adjacent

    property string mode: "idle"                 // idle | ahead | behind (debug/telemetry)
    property int _lastRev: -1
    property double _lastRevAt: 0

    readonly property bool _trace: typeof wtTrace !== "undefined" && wtTrace
    function _tr(s) { if (_trace) console.log("[WT-HARVEST] " + s); }

    // CHURN-SAFE lifecycle (the 4a14650 rule, now on this second player too):
    // NEVER clear the source on deactivation — `source = ""` tears down the FFmpeg
    // backend's media objects, and a frame/state event its decode thread already
    // posted, delivered after that teardown, is a use-after-free (SIGSEGV in
    // libffmpegmediaplugin under rapid session churn; reproduced P0 2026-07-10:
    // fragment clicks flap `active` while re-opens swap sources). Deactivate =
    // stop + capture off, source stays; the next activation/source change does a
    // SINGLE setSource swap, which transitions the backend in one step.
    onActiveChanged: {
        if (active) {
            if (player.source !== source) player.source = source;   // single-swap
            FrameCache.harvestCapturing = true;
            _lastRev = -1;
            evalT.start();
            _tr("active src=" + source);
        } else {
            evalT.stop();
            FrameCache.harvestCapturing = false;
            player.pause();
            mode = "idle";
            _tr("inactive (source kept — churn-safe)");
        }
    }
    onSourceChanged: if (active && source != Qt.url("")) { player.stop(); player.source = source; mode = "idle"; }

    // Host bridge: does the position-domain jump [fromMs,toMs] cross a kept
    // discontinuity? Raw seeks ACROSS one stall the FFmpeg HLS demuxer (the very
    // reason seekToWall re-opens) — the harvester must never issue them. Playing
    // THROUGH a boundary is fine, so ahead-fill just keeps rolling; behind-fill
    // across a gap is skipped (the stepper's edge fallback owns cross-gap moves).
    property var crossesDisc: function(fromMs, toMs) { return false; }

    // Frames cached CONTIGUOUSLY ahead of the cursor (gaps ≤ chainGap×dur count as
    // adjacent — VFR streams legitimately mix 25/50/100 ms intervals).
    function chainedAhead() {
        var lim = chainGap * frameDurMs;
        var above = FrameCache.cachedAround(userPts, 0, aheadTarget);
        var prev = userPts, n = 0;
        for (var i = 0; i < above.length; i++) {
            if (above[i] - prev > lim) break;
            prev = above[i]; n++;
        }
        return { count: n, endPts: prev };
    }
    // Lowest pts chained backward from the cursor (the usable strip floor).
    function chainFloor() {
        var lim = chainGap * frameDurMs;
        var below = FrameCache.cachedAround(userPts, behindChunk + behindLow, 0);
        var p = userPts;
        for (var i = below.length - 1; i >= 0; i--) {
            if (below[i] > userPts) continue;
            if (p - below[i] > lim) break;
            p = below[i];
        }
        return p;
    }

    Timer {
        id: evalT
        interval: 300; repeat: true
        onTriggered: {
            if (!hv.active || hv.userPts <= 0 || player.source == Qt.url("")) return;
            // stall watch: playing but nothing new captured for 2.5 s → park (EOS/cold)
            if (player.playbackState === MediaPlayer.PlayingState) {
                if (FrameCache.rev !== hv._lastRev) { hv._lastRev = FrameCache.rev; hv._lastRevAt = Date.now(); }
                else if (Date.now() - hv._lastRevAt > 2500) { hv._park("stall"); return; }
            }
            var ahead = hv.chainedAhead();
            // At the live edge (today's footage opens there) there is nothing ahead to
            // fill — do NOT early-return into a park loop, or the behind branch below
            // never runs and the strip stays blank (the P0 "all black squares on
            // today's footage" symptom). Fall through and fill history instead.
            var aheadBase = (ahead.count > 0 ? ahead.endPts : hv.userPts) + hv.anchorOffMs;
            var atEnd = player.duration > 0 && aheadBase >= player.duration - 450;
            if (ahead.count < hv.aheadLow && !atEnd) { hv._fillAhead(ahead); return; }
            if (hv.mode === "ahead" && (ahead.count >= hv.aheadTarget || atEnd)) hv._park(atEnd ? "at end" : "ahead full");
            var floor = hv.chainFloor();
            var behindFrames = (hv.userPts - floor) / Math.max(1, hv.frameDurMs);
            if (behindFrames < hv.behindLow && floor > hv.frameDurMs) { hv._fillBehind(floor); return; }
            if (hv.mode === "behind" && behindFrames >= hv.behindChunk * 0.6) hv._park("behind full");
        }
    }

    function _fillAhead(ahead) {
        var wantPos = Math.max(0, Math.round((ahead.count > 0 ? ahead.endPts : userPts) + anchorOffMs - 150));
        if (player.duration > 0 && wantPos >= player.duration - 300) { _park("at end"); return; }
        // reposition only when idle/off-track — while cruising ahead just keep playing.
        // A repositioning that would cross a kept discontinuity is NOT issued (it
        // stalls the demuxer): keep playing from where we are — playback traverses
        // the boundary correctly on its own.
        if (mode !== "ahead" || player.playbackState !== MediaPlayer.PlayingState
                || Math.abs(player.position - wantPos) > 4000) {
            if (!crossesDisc(player.position, wantPos)) {
                player.position = wantPos;
                _tr("fill-ahead from pos=" + wantPos + " (chained=" + ahead.count + ")");
            } else {
                _tr("fill-ahead rolls through a boundary (no cross-disc seek) pos=" + player.position);
            }
        }
        mode = "ahead";
        player.playbackRate = 2.0;
        player.play();
        _lastRevAt = Date.now();
    }
    function _fillBehind(floor) {
        var startPos = Math.max(0, Math.round(floor + anchorOffMs - behindChunk * frameDurMs - 150));
        // Behind-fill never seeks across a kept discontinuity: cross-gap backward
        // moves belong to the stepper's edge fallback (wall re-open), not raw seeks.
        if (crossesDisc(startPos, Math.round(floor + anchorOffMs))) { _park("behind is across a gap"); return; }
        if (mode !== "behind") {
            player.position = startPos;
            _tr("fill-behind from pos=" + startPos + " (floor=" + floor.toFixed(0) + ")");
        }
        mode = "behind";
        player.playbackRate = 2.0;
        player.play();
        _lastRevAt = Date.now();
    }
    function _park(why) {
        if (player.playbackState === MediaPlayer.PlayingState) player.pause();
        if (mode !== "idle") _tr("park (" + why + ")");
        mode = "idle";
    }

    // Render-less output: frames go straight to FrameCache's owned capture sink
    // (toImage on the delivery thread) — never into the scene graph. No texture
    // import of churning-session frames, no GPU upload at 2× for unseen pixels.
    MediaPlayer {
        id: player
        videoOutput: FrameCache.harvestSink
        audioOutput: null
    }
}
