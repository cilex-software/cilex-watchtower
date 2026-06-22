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
    readonly property bool lowLatency: (typeof wtLowLatency !== "undefined" && wtLowLatency)

    // `playing` = FRAMES ARE ACTUALLY FLOWING, not merely "the pipeline reports itself up".
    // A live RTSP pipeline can sit decoding nothing — a stalled substream, or the initial
    // all-zero NV12 buffer that renders bright green — while still claiming to play, which is
    // exactly how a green/frozen tile slips through (RtspVideoSource only flips playing=false
    // on EOS/error/teardown, never on a silent stall). So we key `playing` off real frames
    // reaching the sink (_hasRecentFrame), and the cover below hides the raw VideoOutput until
    // then. Standing rule: green must never appear anywhere.
    readonly property bool playing: _hasRecentFrame
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

    // Schedule the next reconnect attempt (idempotent: leaves a running countdown alone).
    function _armReconnect() {
        if (!root.active || root.url === "" || root.playing) { reconnectTimer.stop(); return; }
        if (reconnectTimer.running) return;
        // Be patient on a COLD connect (the first frame can legitimately take a beat —
        // don't tear down a pipeline that's still negotiating). Use the short backoff only
        // once we've seen frames and then lost them, i.e. a genuine stall.
        reconnectTimer.interval = root._everPlayed
            ? root._backoffMs[Math.min(root._reconnectAttempt, root._backoffMs.length - 1)]
            : 8000;
        reconnectTimer.start();
    }
    // Ask the global coordinator for a slot (it serializes initiations app-wide).
    function _requestReconnect() {
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
            reconnectTimer.stop(); root._reconnectAttempt = 0;
            root._armReconnect();
        }
        function onPlayingChanged() {
            if (root.playing) { root._reconnectAttempt = 0; reconnectTimer.stop(); }  // frames back → reset
            else root._armReconnect();                                                // stalled → schedule recovery
        }
    }

    // Picks exactly one backend at construction. Bindings inside reference
    // `root.url` / `root.active` / `videoOut` from the outer scope.
    Loader {
        id: backend
        sourceComponent: root.lowLatency ? lowLatencyComp : qtmmComp
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

            function maybePlay() {
                if (root.active && root.url !== "")
                    player.play();
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
