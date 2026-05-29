import QtQuick
import QtMultimedia
import Watchtower

// One live video surface. Two mutually-exclusive backends — only the active one
// is instantiated (via Loader) so the inert one never logs nullptr-disconnect
// warnings from internal QtMultimedia / signal cleanup:
//  • Default: QtMultimedia MediaPlayer (GStreamer + VA-API). rtspsrc's jitter
//    buffer (latency, default 2000 ms) dominates live lag and QMediaPlayer 6.4
//    exposes no knob for it.
//  • WT_LOWLATENCY: RtspVideoSource — a small custom GStreamer pipeline
//    (rtspsrc latency≈150 ms) pushing frames into this VideoOutput's sink, for
//    near-real-time. Opt-in so we can A/B it against the default.
Item {
    id: root

    property string url: ""
    property bool active: true   // play when true (e.g. tile visible / on current page)
    readonly property bool lowLatency: (typeof wtLowLatency !== "undefined" && wtLowLatency)

    readonly property bool playing: backend.item ? backend.item.playing : false
    readonly property bool errored: backend.item ? backend.item.errored : false
    readonly property string errorText: backend.item ? backend.item.errorText : ""

    VideoOutput {
        id: videoOut
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
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
                latencyMs: 150
            }
        }
    }
}
