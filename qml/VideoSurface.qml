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
            stallTimer.restart();
        }
    }
    // A new URL or going inactive makes the current frame stale — drop to the covered
    // state at once instead of showing the last (possibly green) frame.
    Connections {
        target: root
        function onActiveChanged() { if (!root.active) { root._hasRecentFrame = false; stallTimer.stop(); } }
        function onUrlChanged() { root._hasRecentFrame = false; stallTimer.stop(); }
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
