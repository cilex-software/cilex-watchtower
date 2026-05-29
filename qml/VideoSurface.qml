import QtQuick
import QtMultimedia
import Watchtower

// One live video surface. Two paths, same API (url/active/playing/errored):
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

    readonly property bool playing: root.lowLatency
        ? rtsp.playing
        : (player.playbackState === MediaPlayer.PlayingState && player.hasVideo)
    readonly property bool errored: root.lowLatency
        ? rtsp.errored
        : (player.error !== MediaPlayer.NoError)
    readonly property string errorText: root.lowLatency ? rtsp.errorText : player.errorString

    function maybePlay() {
        if (!root.lowLatency && root.active && root.url !== "")
            player.play();
    }

    VideoOutput {
        id: videoOut
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
    }

    // Default path.
    MediaPlayer {
        id: player
        source: root.lowLatency ? "" : root.url
        videoOutput: root.lowLatency ? null : videoOut
        onErrorOccurred: (err, str) => console.warn("VideoSurface:", root.url, "-", str)
    }

    // Opt-in low-latency path. Inert (no pipeline) unless lowLatency is on.
    RtspVideoSource {
        id: rtsp
        url: root.lowLatency ? root.url : ""
        active: root.lowLatency && root.active
        videoSink: root.lowLatency ? videoOut.videoSink : null
        latencyMs: 150
    }

    onActiveChanged: if (!root.lowLatency) (root.active ? maybePlay() : player.stop())
    onUrlChanged: maybePlay()
    Component.onCompleted: maybePlay()
    // Stop the default pipeline before teardown so it reaches NULL cleanly (avoids a
    // GStreamer-backend crash when many players are destroyed at once). The
    // RtspVideoSource tears its own pipeline down in its destructor.
    Component.onDestruction: if (!root.lowLatency) player.stop()
}
