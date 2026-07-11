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
    // Pre-arm: load the source (paused, no decode) ahead of frame mode so
    // activation skips the manifest+probe cold start. Churn-safe: same
    // single-swap rule as activation, source is never cleared.
    property bool prearm: false
    onPrearmChanged: if (prearm && !active && source != Qt.url("") && player.source !== source)
                         player.source = source;
    property double userPts: -1        // operator's shown frame (FrameClock.lastPtsMs)
    property double anchorOffMs: 0     // pts → player-position mapping (from the stepper)
    property double mainPosMs: -1      // MAIN player's position — ground truth for the cursor
                                       // (this file's `player` is the HARVESTER's own; its
                                       // position is 0 on a fresh session — round-6 regression)
    property double frameDurMs: 50

    readonly property int aheadTarget: 48        // keep ~2.4 s cached ahead @ 20 fps
    readonly property int aheadLow: 30           // refill when the chained run drops below this
    readonly property int behindChunk: 48        // backward fill chunk (frames)
    readonly property int behindLow: 14          // refill behind when this close to the chain floor
    readonly property real chainGap: 2.6         // × frameDur — max gap that still counts as adjacent

    property string mode: "idle"                 // idle | ahead | behind (debug/telemetry)
    property int _lastRev: -1
    property double _lastRevAt: 0
    property int _nudges: 0                      // consecutive stall-nudges (cap 3, then park)

    readonly property bool _trace: typeof wtTrace !== "undefined" && wtTrace
    function _tr(s) { if (_trace) console.log("[WT-HARVEST] t=" + Date.now() + " " + s); }

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
    onSourceChanged: if ((active || prearm) && source != Qt.url("")) { player.stop(); player.source = source; mode = "idle"; }

    // Host bridge: does the position-domain jump [fromMs,toMs] cross a kept
    // discontinuity? Raw seeks ACROSS one stall the FFmpeg HLS demuxer (the very
    // reason seekToWall re-opens) — the harvester must never issue them. Playing
    // THROUGH a boundary is fine, so ahead-fill just keeps rolling; behind-fill
    // across a gap is skipped (the stepper's edge fallback owns cross-gap moves).
    property var crossesDisc: function(fromMs, toMs) { return false; }

    // Frames cached CONTIGUOUSLY ahead of the cursor (gaps ≤ chainGap×dur count as
    // adjacent — VFR streams legitimately mix 25/50/100 ms intervals).
    function chainedAhead() {
        var lim = Math.max(chainGap * frameDurMs, 130);   // VFR floor (see FrameStrip)
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
        var lim = Math.max(chainGap * frameDurMs, 130);   // VFR floor
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
            // userPts < 0 = no cursor yet; EXACTLY 0 is a legitimate pts (heavy-day
            // bounded bootstrap lands at 00:00:00 — first frame pts 0.0; fsoak
            // window-2: the <=0 guard idled the harvester there for the full 6 s).
            if (!hv.active || hv.userPts < 0 || player.source == Qt.url("")) return;
            // stall watch: playing but nothing new captured for 2.5 s. A park +
            // same-spot refill re-enters the wedge (truncated-TS joint from an
            // interrupted fetch, corrupt-packet recovery, cold segment) — measured
            // as a uniform ~5.7 s strip (2 stall cycles + fill). NUDGE forward past
            // the wedge instead; park only after 3 fruitless nudges.
            if (player.playbackState === MediaPlayer.PlayingState) {
                if (FrameCache.rev !== hv._lastRev) {
                    hv._lastRev = FrameCache.rev; hv._lastRevAt = Date.now(); hv._nudges = 0;
                } else if (Date.now() - hv._lastRevAt > 2500) {
                    if (hv._nudges < 3) {
                        hv._nudges++;
                        var npos = Math.min(Math.max(0, player.position + 500),
                                            Math.max(0, player.duration - 300));
                        if (!crossesDisc(player.position, npos)) {
                            player.position = npos;
                            hv._lastRevAt = Date.now();
                            player.play();
                            hv._tr("stall-nudge #" + hv._nudges + " -> pos=" + npos);
                            return;
                        }
                    }
                    hv._park("stall"); hv._nudges = 0; return;
                }
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
        // Empty chain → base on the MAIN player's position, not userPts+anchorOffMs:
        // right after a re-open the stepper's anchor still maps the PREVIOUS session
        // (fsoak: fills landed +1.7 s past the cursor → center-only strip until the
        // 6 s timeout). Paused on the shown frame, main position IS the cursor.
        var wantPos = ahead.count > 0
            ? Math.max(0, Math.round(ahead.endPts + anchorOffMs - 150))
            : Math.max(0, Math.round((mainPosMs >= 0 ? mainPosMs : userPts + anchorOffMs) - 150));
        if (player.duration > 0 && wantPos >= player.duration - 300) { _park("at end"); return; }
        // reposition only when idle/off-track — while cruising ahead just keep playing.
        // A repositioning that would cross a kept discontinuity is NOT issued (it
        // stalls the demuxer): keep playing from where we are — playback traverses
        // the boundary correctly on its own.
        var repositioned = false;
        if (mode !== "ahead" || player.playbackState !== MediaPlayer.PlayingState
                || Math.abs(player.position - wantPos) > 4000) {
            if (!crossesDisc(player.position, wantPos)) {
                player.position = wantPos;
                repositioned = true;
                _tr("fill-ahead from pos=" + wantPos + " (chained=" + ahead.count + ")");
            } else {
                _tr("fill-ahead rolls through a boundary (no cross-disc seek) pos=" + player.position);
            }
        }
        mode = "ahead";
        player.playbackRate = 2.0;
        player.play();
        // Only NEW work resets the stall clock — resetting on every keep-playing
        // eval pass (300 ms) starved the stall detector: the nudge/park could
        // never fire (fsoak: nudges=0 through a 5.7 s wedge).
        if (repositioned) _lastRevAt = Date.now();
    }
    function _fillBehind(floor) {
        // Same anchor rule as _fillAhead: no chain behind → MAIN position is truth.
        var target = (floor === userPts && mainPosMs >= 0) ? Math.round(mainPosMs)
                                                           : Math.round(floor + anchorOffMs);
        var chunkMs = behindChunk * frameDurMs + 150;
        // Behind-fill never seeks across a kept discontinuity — but a boundary
        // close behind the cursor must CLAMP the window, not starve the fill
        // (fsoak finding, 2026-07-10: at the live edge the cursor sits ~2 s into
        // the day's final motion clip; the full 2.5 s window crossed the clip's
        // leading boundary -> silent park loop -> empty filmstrip until stepping
        // forced main-tap captures). Halve the window until it fits the run;
        // only park when even a few frames back would cross (cursor at run head
        // -- cross-gap moves belong to the stepper's edge fallback).
        while (chunkMs > 4 * frameDurMs && crossesDisc(Math.max(0, target - chunkMs), target))
            chunkMs = chunkMs / 2;
        var startPos = Math.max(0, target - chunkMs);
        if (crossesDisc(startPos, target)) { _park("behind is across a gap"); return; }
        if (mode !== "behind") {
            player.position = startPos;
            _tr("fill-behind from pos=" + startPos + " (floor=" + floor.toFixed(0) + " chunkMs=" + chunkMs.toFixed(0) + ")");
            _lastRevAt = Date.now();               // new work only (see _fillAhead)
        }
        mode = "behind";
        player.playbackRate = 2.0;
        player.play();
    }
    property string _lastPark: ""
    function _park(why) {
        if (player.playbackState === MediaPlayer.PlayingState) player.pause();
        // Trace on reason CHANGE, not only on mode change -- a repeating idle park
        // (the live-edge starvation above) was invisible in the log.
        if (mode !== "idle" || _lastPark !== why) _tr("park (" + why + ")");
        _lastPark = why;
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
