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

    onActiveChanged: {
        if (active) {
            player.source = source;
            FrameCache.harvestCapturing = true;
            _lastRev = -1;
            evalT.start();
            _tr("active src=" + source);
        } else {
            evalT.stop();
            FrameCache.harvestCapturing = false;
            player.stop();
            player.source = "";
            mode = "idle";
            _tr("inactive");
        }
    }
    onSourceChanged: if (active) { player.stop(); player.source = source; mode = "idle"; }

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
            if (ahead.count < hv.aheadLow) { hv._fillAhead(ahead); return; }
            if (hv.mode === "ahead" && ahead.count >= hv.aheadTarget) { hv._park("ahead full"); }
            var floor = hv.chainFloor();
            var behindFrames = (hv.userPts - floor) / Math.max(1, hv.frameDurMs);
            if (behindFrames < hv.behindLow && floor > hv.frameDurMs) { hv._fillBehind(floor); return; }
            if (hv.mode === "behind" && behindFrames >= hv.behindChunk * 0.6) hv._park("behind full");
        }
    }

    function _fillAhead(ahead) {
        var wantPos = Math.max(0, Math.round((ahead.count > 0 ? ahead.endPts : userPts) + anchorOffMs - 150));
        if (player.duration > 0 && wantPos >= player.duration - 300) { _park("at end"); return; }
        // reposition only when idle/off-track — while cruising ahead just keep playing
        if (mode !== "ahead" || player.playbackState !== MediaPlayer.PlayingState
                || Math.abs(player.position - wantPos) > 4000) {
            player.position = wantPos;
            _tr("fill-ahead from pos=" + wantPos + " (chained=" + ahead.count + ")");
        }
        mode = "ahead";
        player.playbackRate = 2.0;
        player.play();
        _lastRevAt = Date.now();
    }
    function _fillBehind(floor) {
        var startPos = Math.max(0, Math.round(floor + anchorOffMs - behindChunk * frameDurMs - 150));
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

    VideoOutput { id: sink; visible: false; width: 16; height: 9 }
    MediaPlayer {
        id: player
        videoOutput: sink
        audioOutput: null
    }
    Component.onCompleted: FrameCache.attachHarvest(sink.videoSink)
}
