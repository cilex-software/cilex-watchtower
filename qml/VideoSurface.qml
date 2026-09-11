import QtQuick
import QtMultimedia
import Watchtower

// One live video surface. Two mutually-exclusive backends — only the active one
// is instantiated (via Loader) so the inert one never logs nullptr-disconnect
// warnings from internal QtMultimedia / signal cleanup:
//  • Default (lowLatency): RtspVideoSource — a small custom GStreamer pipeline
//    (rtspsrc latency≈150 ms) pushing frames into this VideoOutput's sink, for
//    near-real-time monitoring. The fix to QMediaPlayer 6.4's untuneable 2000 ms
//    jitter buffer.
//  • WT_LEGACY=1: QtMultimedia MediaPlayer (GStreamer + VA-API). Fallback path
//    if the custom pipeline misbehaves; not usable for actual operator work
//    because of the 2s default lag.
Item {
    id: root

    property string url: ""
    property bool active: true   // play when true (e.g. tile visible / on current page)
    property bool warmOnly: false // hold the RTSP session open with no decoder (see RtspVideoSource.h)
    readonly property bool lowLatency: (typeof wtLowLatency !== "undefined" && wtLowLatency)

    // ---- source ladder (adaptive quality + transport) --------------------------------
    // Ordered candidates, best first, each {url, tier, net, badge}. When non-empty this
    // surface OWNS `url` (drives it from the current rung) and steps DOWN a rung on a
    // measured failure: a cold connect that will not complete, or frames that arrive too
    // slowly to be video. Empty = legacy single-`url` mode (VideoTest, direct callers) —
    // nothing below changes their behaviour. Rungs mix quality (HD→SD) and transport
    // (rtsp→http fMP4, the remote path for when go2rtc's RTSP port is unreachable).
    // The list must be built from STABLE inputs (camera identity + override), never from
    // status polls, or a poll would reset the rung and undo a step-down.
    property var tiers: []
    property int _tierIndex: 0
    // Step down only after this many cold-connect failures on the current rung (~2×8 s),
    // so a rung that is merely slow to negotiate is not abandoned prematurely.
    property int _coldFailLimit: 2
    property int _coldFailsThisTier: 0
    readonly property var currentTier: (tiers.length > 0)
        ? tiers[Math.max(0, Math.min(_tierIndex, tiers.length - 1))] : null
    readonly property bool _hasLowerTier: tiers.length > 0 && _tierIndex < tiers.length - 1
    // A step is allowed unless it would abandon RTSP for HTTP while RTSP is
    // demonstrably reachable (some surface got rtsp frames in the last 60 s).
    // Quality steps within one transport are always allowed.
    function _isHttp(u) { return typeof u === "string" && u.indexOf("http") === 0; }
    readonly property bool canStepDownTier: {
        if (!_hasLowerTier) return false;
        var cur = tiers[_tierIndex], nxt = tiers[_tierIndex + 1];
        if (!cur || !nxt) return false;
        if (!_isHttp(cur.url) && _isHttp(nxt.url) && ReconnectCoordinator.rtspReachable()) return false;
        return true;
    }
    // What the SD/HD chip shows, and whether the ladder chose it (AUTO) vs the top rung.
    readonly property string tierBadge: currentTier ? (currentTier.badge || "") : ""
    readonly property bool autoStepped: _tierIndex > 0
    // Public: whether a lighter rung exists, and a request to move to it. The wall
    // tile's stuck-pipeline recycler uses these to ADVANCE the ladder instead of
    // destroying-and-rebuilding the surface (which would reset it to the top rung
    // and loop forever on an unreachable transport).
    readonly property bool hasLowerTier: _hasLowerTier
    // A rung that failed to deliver after a rung that DID is not retried for 15 s
    // (e.g. CV's -opt budget answering 503): the surface returns to the last rung
    // that played. Recovery, not an upgrade probe — auto step-UP stays off.
    property var _rungBlockedUntil: ({})
    property bool _prevRungPlayed: false
    function _rungBlocked(i) { var t = _rungBlockedUntil[i]; return t !== undefined && Date.now() < t; }
    function stepDownAllowed() { return canStepDownTier && !_rungBlocked(_tierIndex + 1); }
    readonly property bool canReturnToPreviousRung: _tierIndex > 0 && _prevRungPlayed
    function returnToPreviousRung(reason) {
        if (!canReturnToPreviousRung) return false;
        var b = {}; for (var k in _rungBlockedUntil) b[k] = _rungBlockedUntil[k];
        // 15 s = the Retry-After CV sends with 503 opt_tier_budget_exhausted; a
        // flat 60 s waited four times longer than asked (CV letter 2026-09-11).
        b[_tierIndex] = Date.now() + 15000; _rungBlockedUntil = b;
        console.info("[TIER] rung", (currentTier ? currentTier.badge : "?"), "failed (" + reason + ") → back to",
                     tiers[_tierIndex - 1].badge, "(blocked 15 s)");
        _prevRungPlayed = false;
        _tierIndex = _tierIndex - 1;
        return true;
    }
    function stepDownTier(reason) { if (stepDownAllowed()) _stepDownTier(reason && reason.length ? reason : "external") }
    signal tierStepped(string reason, string badge)

    function _applyTier() {
        if (tiers.length === 0)
            return;
        var i = Math.max(0, Math.min(_tierIndex, tiers.length - 1));
        var u = tiers[i] ? (tiers[i].url || "") : "";
        if (url !== u)
            url = u;                     // → onUrlChanged resets frame/backoff state
    }
    function _stepDownTier(reason) {
        if (!stepDownAllowed())
            return;
        var from = tiers[_tierIndex], to = tiers[_tierIndex + 1];
        _prevRungPlayed = _everPlayed;
        if (from && to && !_isHttp(from.url) && _isHttp(to.url))
            ReconnectCoordinator.noteTransportFallback();   // → remote wall budget
        _tierIndex = _tierIndex + 1;     // → on_TierIndexChanged → _applyTier
        console.info("[TIER] step down →", (currentTier ? currentTier.badge : "?"), "(" + reason + ")");
        tierStepped(reason, currentTier ? currentTier.badge : "");
    }
    onTiersChanged: { _tierIndex = 0; _coldFailsThisTier = 0; _prevRungPlayed = false; _rungBlockedUntil = ({}); _applyTier(); }
    on_TierIndexChanged: _applyTier()

    // `playing` = FRAMES ARE ACTUALLY FLOWING, not merely "the pipeline reports itself up".
    // A live RTSP pipeline can sit decoding nothing — a stalled substream, or the initial
    // all-zero NV12 buffer that renders bright green — while still claiming to play, which is
    // exactly how a green/frozen tile slips through (RtspVideoSource only flips playing=false
    // on EOS/error/teardown, never on a silent stall). So we key `playing` off real frames
    // reaching the sink (_hasRecentFrame), and the cover below hides the raw VideoOutput until
    // then. Standing rule: green must never appear anywhere.
    readonly property bool playing: _hasRecentFrame

    // ---- degraded: frames ARE arriving, but too slowly to be video ---------------------
    // `playing` above is a GAP detector: any frame inside stallTimer's 2500 ms window makes
    // it true. It was written to catch a stream that STOPS and cannot see one that DEGRADES,
    // so a pipe limping at 0.7 fps — one frame every ~1.4 s — reads as fully live and the
    // tile keeps a green LIVE badge over a picture that visibly never changes. That is the
    // 2026-08-15 P1: six cells at the guard booth frozen, badged live, saying nothing.
    //
    // `degraded` is deliberately a SEPARATE signal and NOT a change to `playing`. Flipping
    // `playing` false on a slow pipe would fire _armReconnect() below, putting every slow
    // tile on a wall into simultaneous reconnect — a behavioural change that must not ride
    // along with an honesty fix. This property changes what the operator SEES, nothing else.
    // 5 fps = a third of the fleet's 15. Below that a guard is watching a slideshow,
    // and the booth was right that 2.0 set the bar so low a plainly-broken tile still
    // read as healthy. The rate is set ON THE CAMERAS (CLAUDE.md) — this only judges
    // what arrived, it never requests or caps anything.
    // 10 fps. Operator spec 2026-08-15: the fleet runs a near-constant 15 with small
    // deviations, and anything under 10 is to be reported as a fault — so the badge and
    // the Health report use ONE threshold. (Rate is set on the cameras; this only judges
    // what arrived — CLAUDE.md.)
    property real degradedBelowFps: 10.0
    // Debounce: 3 consecutive sub-threshold windows (~6 s) before the badge turns. At a
    // 10 fps bar against a 15 fps source, ordinary jitter WILL dip a single 2 s window,
    // and a badge that flickers amber on a healthy wall teaches the guard to ignore amber.
    property int degradedWindows: 3
    property int _lowRuns: 0
    // NOTE the `!playing` term, which the first version of this fix did not have.
    // It read `playing && fps < floor`, and `playing` is itself a 2500 ms gap detector —
    // so a tile so broken that its gaps EXCEEDED 2.5 s fell out of `degraded` entirely
    // and the badge reverted to the model's green LIVE. The worse the stream, the less
    // likely it was flagged; measured at the booth on 2026-08-15 as tiles updating once
    // per ~9 s (~0.1 fps) still wearing a green badge. Once a surface has ever played,
    // anything short of a real rate is degraded — including nothing at all.
    readonly property bool degraded:
        _everPlayed && (!playing || (_fpsValid && _lowRuns >= degradedWindows))
    // Rolling frame rate over the last window. -1 until the first full window has closed,
    // so a tile that has just started is never reported as degraded.
    property real fps: -1
    // Rolling 60 s mean, -1 until at least 30 s of windows exist. This is the number
    // that goes to CV Health / Cilex Pro Mobile — reported when it falls under 10.
    property real fpsMean60: -1
    property var _win: []
    property bool _fpsValid: false
    property int _frameTicks: 0
    Timer {
        id: fpsTimer
        interval: 2000
        repeat: true
        running: root.active && root.url !== "" && root._everPlayed
        onTriggered: {
            root.fps = root._frameTicks / (interval / 1000);
            root._frameTicks = 0;
            root._fpsValid = true;
            root._lowRuns = (root.fps < root.degradedBelowFps) ? root._lowRuns + 1 : 0;
            // 60 s mean for the Health report — a single window is too twitchy to send
            // to a fleet-health surface, and the operator asked for an AVERAGE.
            root._win.push(root.fps);
            while (root._win.length > 30) root._win.shift();
            var t = 0; for (var i = 0; i < root._win.length; i++) t += root._win[i];
            root.fpsMean60 = root._win.length >= 15 ? t / root._win.length : -1;
        }
        onRunningChanged: if (!running) { root.fps = -1; root._fpsValid = false; root._frameTicks = 0; }
    }
    // Where the fitted (letterboxed) video actually sits inside this item —
    // consumers place chrome in the bars instead of over the pixels.
    readonly property rect contentRect: videoOut.contentRect
    readonly property bool errored: backend.item ? backend.item.errored : false
    readonly property string errorText: backend.item ? backend.item.errorText : ""

    // Flipped true as frames arrive, false by the stall timer when they stop — so a silent
    // freeze degrades to an honest "connecting" state (and self-heals if frames resume).
    property bool _hasRecentFrame: false

    // ---- auto-reconnect on stall ------------------------------------------------------
    // A silently-stalled pipeline (no EOS/error, just no frames) won't recover on its own,
    // so we actively rebuild it — carefully. Per-tile EXPONENTIAL BACKOFF means we never
    // hammer a dead stream, and every attempt is routed through the global
    // ReconnectCoordinator so a fleet-wide stall can't trigger a burst of simultaneous
    // VA-API pipeline rebuilds (the decode-context churn suspected behind the Live-relayout
    // freeze). Only a tile the operator is actually watching (active, real url) reconnects.
    property bool _everPlayed: false        // have we ever had frames on the current url?
    property int  _reconnectAttempt: 0      // index into _backoffMs, grows per attempt
    property bool _reconnectPending: false  // a coordinator slot has been requested, not yet run
    readonly property var _backoffMs: [2000, 5000, 10000, 20000, 30000]

    Timer {
        id: reconnectTimer
        repeat: false
        onTriggered: root._requestReconnect()
    }

    // A rung that connected but delivers video too slowly (VideoSurface.degraded:
    // sustained sub-10 fps, or a stall) never flips `playing` false on the low-fps
    // path, so the reconnect ladder above cannot see it. This does: 8 s of continuous
    // degraded on a rung that has a lighter option → step down. Re-armed by the
    // running binding, so a recovery (degraded→false) cancels the pending step.
    Timer {
        id: tierDegradeTimer
        interval: 8000
        repeat: false
        running: root.canStepDownTier && root._everPlayed && root.degraded
        onTriggered: root._stepDownTier("degraded")
    }

    // Schedule the next reconnect attempt (idempotent: leaves a running countdown alone).
    function _armReconnect() {
        if (!root.active || root.url === "" || root.playing) { reconnectTimer.stop(); return; }
        if (reconnectTimer.running) return;
        // Be patient on a COLD connect (the first frame can legitimately take a beat —
        // don't tear down a pipeline that's still negotiating). Use the short backoff only
        // once we've seen frames and then lost them, i.e. a genuine stall.
        // HTTP (HLS) needs longer to a first frame than rtsp: master → media playlist →
        // first segments, plus a transcode spin-up on the -opt tier. FIRST attempt on a
        // rung is cold (CV measured 5.7 s spin-up, ~10 s at our player) → 15 s. Once a
        // consumer has attached, CV's linger (live 2026-09-11) keeps the producer warm
        // 60 s, so a SECOND attempt joins warm — measured 1.7–2.2 s on five of six
        // cameras, one outlier at 5.0 s → 8 s covers it with margin.
        reconnectTimer.interval = root._everPlayed
            ? root._backoffMs[Math.min(root._reconnectAttempt, root._backoffMs.length - 1)]
            : (root._isHttp(root.url) ? (root._reconnectAttempt === 0 ? 15000 : 8000) : 8000);
        reconnectTimer.start();
    }
    // Ask the global coordinator for a slot (it serializes initiations app-wide).
    function _requestReconnect() {
        if (typeof wtReconOff !== "undefined" && wtReconOff) return;   // isolation runs: backstop owns recovery
        if (root._reconnectPending) return;
        if (!root.active || root.url === "" || root.playing) return;
        root._reconnectPending = true;
        // `root` is nulled by the engine if this surface is destroyed (paged out) before
        // the slot is granted — guard so a queued reconnect never calls into a dead tile.
        ReconnectCoordinator.request(function() { if (root) root._doReconnect(); });
    }
    // Runs when the coordinator grants a slot. Self-guards (the tile may have recovered or
    // gone inactive while queued), then forces a fresh pipeline and re-arms in case this
    // attempt also fails (next one waits a longer backoff).
    function _doReconnect() {
        root._reconnectPending = false;
        if (!root.active || root.url === "" || root.playing) return;
        // Ladder: a rung that has never delivered a frame and keeps failing to
        // connect gets abandoned for a lighter one, rather than hammered forever.
        if (!root._everPlayed) {
            if (root.stepDownAllowed()) {
                root._coldFailsThisTier++;
                if (root._coldFailsThisTier >= root._coldFailLimit) { root._stepDownTier("cold-connect"); return; }
            } else if (root.canReturnToPreviousRung) {
                root._coldFailsThisTier++;
                if (root._coldFailsThisTier >= root._coldFailLimit && root.returnToPreviousRung("cold-connect")) return;
            }
        }
        if (backend.item && backend.item.reconnect) backend.item.reconnect();
        root._reconnectAttempt = Math.min(root._reconnectAttempt + 1, root._backoffMs.length - 1);
        root._armReconnect();
    }

    Component.onCompleted: _armReconnect()   // also covers a cold connect that never delivers a frame

    VideoOutput {
        id: videoOut
        anchors.fill: parent
        // Fit (letterbox), never crop — the operator must always see the WHOLE
        // frame. Tiles are auto-sized ~16:9 (see LiveMonitor) so bars stay minimal.
        fillMode: VideoOutput.PreserveAspectFit
    }

    // Opaque cover over the raw VA-API surface. That surface is bright green before its
    // first decoded frame, and stays green/frozen on a silent stall; this keeps it hidden
    // until frames are genuinely flowing, so no green ever reaches the operator. Consumers
    // (tile, single-cam) layer their own "Connecting…/Unavailable" states on top.
    Rectangle {
        anchors.fill: parent
        z: 1
        color: "#0a0d11"
        visible: !root.playing
    }

    // Frame-flow watchdog. Both backends push frames into videoOut.videoSink, so this one
    // hook covers the low-latency (RtspVideoSource) and QtMultimedia paths alike.
    Timer {
        id: stallTimer
        interval: 2500     // ~35+ missed frames at 15 fps — a real stall, not jitter
        repeat: false
        onTriggered: root._hasRecentFrame = false
    }
    Connections {
        target: videoOut.videoSink
        function onVideoFrameChanged() {
            root._hasRecentFrame = true;
            root._everPlayed = true;
            root._frameTicks++;
            if (!root._isHttp(root.url)) ReconnectCoordinator.noteRtspFrame();
            stallTimer.restart();
        }
    }
    // A new URL or going inactive makes the current frame stale — drop to the covered
    // state at once instead of showing the last (possibly green) frame.
    Connections {
        target: root
        function onActiveChanged() {
            if (!root.active) {            // hidden/off — stop everything; lowLatency tears down anyway
                root._hasRecentFrame = false; stallTimer.stop();
                reconnectTimer.stop(); root._reconnectAttempt = 0;
            } else {
                root._armReconnect();      // became visible again — recover if it isn't flowing
            }
        }
        function onUrlChanged() {          // new stream: forget all prior frame/backoff state
            root._hasRecentFrame = false; root._everPlayed = false; stallTimer.stop();
            root.fps = -1; root._fpsValid = false; root._frameTicks = 0;
            reconnectTimer.stop(); root._reconnectAttempt = 0;
            root._coldFailsThisTier = 0;
            root._armReconnect();
        }
        function onPlayingChanged() {
            if (root.playing) { root._reconnectAttempt = 0; reconnectTimer.stop(); }  // frames back → reset
            else root._armReconnect();                                                // stalled → schedule recovery
        }
    }

    // Picks a backend by URL SCHEME, not just the global flag: the low-latency
    // custom pipeline is rtsp-only, so an http fMP4 rung (the remote transport)
    // MUST go through QtMultimedia, which speaks http/HLS/fMP4. Reselects when the
    // ladder crosses rtsp↔http; staying within rtsp rungs (HD↔SD) keeps the same
    // backend and only swaps its url.
    Loader {
        id: backend
        sourceComponent: (root.lowLatency && root.url.indexOf("rtsp") === 0)
                         ? lowLatencyComp : qtmmComp
    }

    // Default (QtMultimedia) backend.
    Component {
        id: qtmmComp
        Item {
            readonly property bool playing: player.playbackState === MediaPlayer.PlayingState && player.hasVideo
            readonly property bool errored: player.error !== MediaPlayer.NoError
            readonly property string errorText: player.errorString

            MediaPlayer {
                id: player
                source: root.url
                videoOutput: videoOut
                onErrorOccurred: (err, str) => console.warn("VideoSurface:", root.url, "-", str)
            }

            // INITIAL connects are serialised through the same global coordinator as
            // reconnects. Reconnects were already rate-limited; first connects were
            // not — so every page change on a large wall fired all 16 live-decode
            // slots at once, 16 simultaneous RTSP negotiations plus 16 VA-API decode
            // contexts. Measured on the 130-camera wall (9 pages): substantially the
            // whole budget came up "Connecting…" then STREAM UNAVAILABLE together.
            // Staggering costs a progressive fill — each tile already shows its
            // snapshot until frames flow, so the wall is never blank — and buys tiles
            // that actually connect.
            property bool _playPending: false
            function maybePlay() {
                if (!(root.active && root.url !== "") || _playPending)
                    return;
                _playPending = true;
                ReconnectCoordinator.request(function () {
                    _playPending = false;
                    // Self-guard: the slot may arrive after the tile went inactive,
                    // changed camera, or already started playing.
                    if (root.active && root.url !== "" && !root.playing)
                        player.play();
                });
            }
            // Force a fresh pipeline to recover a stall: release the source (async, never
            // the GUI-blocking stop()) and re-arm. Best-effort — this is the non-default
            // WT_LEGACY path; the low-latency RtspVideoSource.reconnect() is the real one.
            function reconnect() {
                if (!root.active || root.url === "") return;
                player.source = "";
                player.source = root.url;
                player.play();
            }

            // Start (or resume) on becoming active; do NOT stop on going inactive — a
            // synchronous MediaPlayer.stop() on live RTSP can block the GUI thread, and
            // 16 of them at once (section nav) freezes the app. The pipeline keeps
            // running quietly until the component is actually destroyed.
            Connections {
                target: root
                function onActiveChanged() { if (root.active) maybePlay() }
                function onUrlChanged() { maybePlay() }
            }
            Component.onCompleted: maybePlay()
            // Teardown: clear the source rather than calling stop(). MediaPlayer.stop()
            // on a live RTSP pipeline blocks the GUI thread on GStreamer's TEARDOWN, and
            // a layout shrink (16→4 tiles) destroys 12 surfaces at once — 12 blocking
            // stops freezes the app. Assigning source = "" releases the pipeline
            // asynchronously; the QObject then destructs without waiting.
            Component.onDestruction: player.source = ""
        }
    }

    // Opt-in low-latency backend (custom GStreamer pipeline → QVideoSink).
    Component {
        id: lowLatencyComp
        Item {
            readonly property bool playing: rtsp.playing
            readonly property bool errored: rtsp.errored
            readonly property string errorText: rtsp.errorText

            RtspVideoSource {
                warmOnly: root.warmOnly
                id: rtsp
                url: root.url
                active: root.active
                videoSink: videoOut.videoSink
                latencyMs: (typeof wtRtspLatencyMs !== "undefined" && wtRtspLatencyMs > 0)
                           ? wtRtspLatencyMs : 150
            }
        }
    }
}
