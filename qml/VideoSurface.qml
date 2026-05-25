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
