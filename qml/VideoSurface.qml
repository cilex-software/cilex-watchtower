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

    readonly property bool playing: backend.item ? backend.item.playing : false
    readonly property bool errored: backend.item ? backend.item.errored : false
    readonly property string errorText: backend.item ? backend.item.errorText : ""

    // Auto-retry: if the stream errors while it should be playing (go2rtc restarted,
    // a transient drop, etc.), periodically re-establish it so the tile self-heals
    // without an operator touching anything. Jittered interval so many tiles never
    // reconnect in lockstep (a synchronized herd against a recovering go2rtc).
    readonly property int _retryMs: 4000 + Math.round(Math.random() * 2000)
    function reconnect() { if (backend.item && backend.item.reconnect) backend.item.reconnect(); }
    Timer {
        interval: root._retryMs
        repeat: true
        running: root.active && root.url !== "" && root.errored
        onTriggered: root.reconnect()
    }

    VideoOutput {
        id: videoOut
        anchors.fill: parent
        // Fit (letterbox), never crop — the operator must always see the WHOLE
        // frame. Tiles are auto-sized ~16:9 (see LiveMonitor) so bars stay minimal.
        fillMode: VideoOutput.PreserveAspectFit
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
            function reconnect() {
                // Fallback backend: drop + re-issue play to reconnect an errored
                // pipeline. stop() can block briefly, but the retry is per-tile and
                // jittered, so it is never many at once.
                player.stop();
                if (root.active)
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
            function reconnect() { rtsp.reconnect(); }

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
