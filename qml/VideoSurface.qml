import QtQuick
import QtMultimedia
import Watchtower

// One live video surface, played via QtMultimedia (GStreamer backend + VA-API HW
// decode on Linux). Audio is omitted (grid is muted by default, design §19); a
// focused view can add an AudioOutput later. Exposes playback state so the tile
// can drive its live badge and show loading/error affordances.
Item {
    id: root

    property string url: ""
    property bool active: true   // play when true (e.g. tile visible / on current page)

    readonly property int playbackState: player.playbackState
    readonly property int mediaStatus: player.mediaStatus
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState && player.hasVideo
    readonly property bool errored: player.error !== MediaPlayer.NoError
    readonly property string errorText: player.errorString

    function maybePlay() {
        if (root.active && root.url !== "")
            player.play();
    }

    VideoOutput {
        id: videoOut
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
    }

    // LATENCY NOTE (Phase D investigation): live glass-to-glass is dominated by
    // GStreamer rtspsrc's jitter buffer (`latency`, default 2000 ms). QtMultimedia
    // 6.4.2's QMediaPlayer exposes NO knob for it (the property lives on the
    // internal rtspsrc element Qt abstracts away), so it can't be tuned from here.
    // Getting to ≤300 ms drop-late needs a minimal custom GStreamer pipeline
    // (note: qml6glsink is broken on this Ubuntu 24 build — re-check before
    // reopening) or a Qt ≥6.5 upgrade. Tracked as a follow-up; see the backend
    // letter. (go2rtc RTSP restream / Track A does not change this client limit.)
    MediaPlayer {
        id: player
        source: root.url
        videoOutput: videoOut
        onErrorOccurred: (err, str) => console.warn("VideoSurface:", root.url, "-", str)
    }

    onActiveChanged: root.active ? maybePlay() : player.stop()
    onUrlChanged: maybePlay()
    Component.onCompleted: maybePlay()
    // Stop the pipeline before teardown so it reaches NULL cleanly (avoids a
    // GStreamer-backend crash when many players are destroyed at once).
    Component.onDestruction: player.stop()
}
