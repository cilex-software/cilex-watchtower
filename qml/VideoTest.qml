import QtQuick
import QtQuick.Window
import Watchtower

// Single-stream video test (loaded when WT_VIDEOTEST is set). Plays the first
// imported camera so we can verify QtMultimedia RTSP + HW decode in isolation
// before wiring video into the grid. Run with WT_CAMERAS pointing at a
// provisioning export.
Window {
    id: win
    width: 1440
    height: 900
    visible: true
    color: Theme.bg
    title: qsTr("Watchtower — video test")

    CameraModel { id: cams }

    function pickCamera() {
        if (typeof wtTestIp !== "undefined" && wtTestIp !== "") {
            for (var i = 0; i < cams.total; i++) {
                var c = cams.get(i);
                if (c.ip === wtTestIp)
                    return c;
            }
        }
        return cams.total > 0 ? cams.get(0) : null;
    }
    readonly property var cam0: pickCamera()

    Rectangle {
        anchors.centerIn: parent
        width: 960
        height: 540
        color: Theme.tileBg
        border.width: 1
        border.color: Theme.line2

        VideoSurface {
            id: surf
            anchors.fill: parent
            anchors.margins: 1
            url: win.cam0 ? win.cam0.rtspUrl : ""
        }

        Text {
            anchors.centerIn: parent
            visible: !surf.playing
            horizontalAlignment: Text.AlignHCenter
            text: surf.errored
                  ? ("STREAM ERROR\n" + surf.errorText)
                  : ("Connecting…\n" + (win.cam0 ? win.cam0.name + "\n" + win.cam0.rtspUrl : "no camera imported"))
            color: surf.errored ? Theme.bad : Theme.ink2
            font.family: Theme.fontMono
            font.pixelSize: 12
        }

        Text {
            anchors { left: parent.left; bottom: parent.bottom; leftMargin: 10; bottomMargin: 8 }
            text: (win.cam0 ? win.cam0.name : "—")
                  + "  ·  playback=" + surf.playbackState
                  + "  status=" + surf.mediaStatus
                  + (surf.playing ? "  ·  PLAYING" : "")
            color: Qt.rgba(1, 1, 1, 0.8)
            font.family: Theme.fontMono
            font.pixelSize: 11
        }
    }
}
