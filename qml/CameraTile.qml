import QtQuick
import Watchtower

// The core reusable tile (design §15). Video fills the tile; a gradient header
// carries the camera name/id and the dual status-badge stack; fault states get
// a 3px top edge, an inline issue strip, or a NO SIGNAL fallback; a hover action
// column exposes playback / snapshot / bookmark / favorite / open-in-new-tab.
Item {
    id: root

    property string camName: ""
    property string camId: ""
    property string groupId: ""
    property int live: CameraStatus.Live
    property int recording: CameraStatus.Recording
    property bool favorite: false
    property bool hasAudio: false
    property string timestamp: ""
    property string lastSeen: ""
    property int pattern: 0
    // In the Live Monitor grid the hairline separator comes from the grid
    // container, so the tile drops its own border (design §14).
    property bool gridMode: false

    // Live video. When videoActive and a stream URL is present, the tile plays
    // it; a Loader instantiates the player only then, so paged-out/offline tiles
    // stay cheap. The grid uses the substream (Hikvision channel 102) to keep
    // many simultaneous decodes light; focused views can use the main stream.
    property string rtspUrl: ""       // main stream (on-demand HD only)
    property string rtspSubUrl: ""    // substream — the default for monitoring
    property bool videoActive: false
    // Defaults to the global SD/HD preference; the per-tile toggle overrides it.
    property bool useMainStream: Settings.defaultStreamHd
    readonly property string streamUrl: (useMainStream && rtspUrl !== "")
        ? rtspUrl
        : (rtspSubUrl !== "" ? rtspSubUrl : rtspUrl)
    readonly property bool hasStream: streamUrl !== "" && videoActive && !isOffline
    readonly property bool streamPlaying: videoLoader.item ? videoLoader.item.playing : false
    readonly property bool streamErrored: videoLoader.item ? videoLoader.item.errored : false

    readonly property bool isOffline: live === CameraStatus.Offline
    readonly property bool isNotRec: recording === CameraStatus.NotRecording
    readonly property bool isDegraded: live === CameraStatus.Degraded
    readonly property bool isGap: recording === CameraStatus.RecordingGap
    readonly property bool isFault: isOffline || isNotRec || isDegraded || isGap

    readonly property string geom: groupId.indexOf("park") >= 0 ? "parking"
                                  : (groupId.indexOf("lob") >= 0 ? "lobby" : "corridor")

    signal opened()
    signal played()
    signal snapshotRequested()
    signal snapshotSaved(string path, string camName)
    signal bookmarkRequested()
    signal favoriteToggled()
    signal openedNewTab()
    signal issueRequested()

    // Capture the current frame (the live surface if playing, else the tile) to a
    // PNG and announce it. Phase 1 snapshot stub (full library = S07 later).
    function captureSnapshot() {
        var target = (streamPlaying && videoLoader.item) ? videoLoader.item : base;
        target.grabToImage(function(result) {
            var path = Artifacts.newSnapshotPath(root.camId);
            if (result.saveToFile(path))
                root.snapshotSaved(path, root.camName);
        });
    }

    Rectangle {
        id: base
        anchors.fill: parent
        color: Theme.tileBg
        clip: true
        border.width: root.gridMode ? 0 : 1
        border.color: root.gridMode ? "transparent"
                      : (hover.hovered ? Theme.accent
                      : (root.isOffline ? Theme.bad
                      : ((root.isNotRec || root.isDegraded) ? Theme.accent : Theme.line2)))

        // ---- video / fallback ----
        // Placeholder fallback: shown until a live frame arrives (or when the
        // tile is paged out / the stream fails).
        PlaceholderVid {
            anchors.fill: parent
            visible: !root.isOffline && !root.streamPlaying
            pattern: root.pattern
            ts: root.timestamp
            label: root.camId
            geom: root.geom
        }

        // Live stream — instantiated only while active (paged-out tiles hold no player).
        Loader {
            id: videoLoader
            anchors.fill: parent
            active: root.hasStream
            visible: root.streamPlaying
            sourceComponent: VideoSurface {
                url: root.streamUrl
                active: root.videoActive
            }
        }

        // Connecting indicator (while the stream negotiates / buffers).
        LoadingState {
            anchors.centerIn: parent
            visible: root.hasStream && !root.streamPlaying && !root.streamErrored
            label: "Connecting…"
            ringSize: 18
        }

        // Offline: NO SIGNAL.
        Rectangle {
            anchors.fill: parent
            visible: root.isOffline
            color: "#0a0d11"
            Column {
                anchors.centerIn: parent
                spacing: 4
                Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 28; color: Theme.bad }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "NO SIGNAL"; color: Theme.bad
                    font.family: Theme.fontMono; font.pixelSize: 13; font.letterSpacing: 1.3
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "last seen " + root.lastSeen; color: Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: 10
                }
            }
        }

        // Stream failed (reachable per the system, but this client can't get the
        // feed — e.g. auth/network). Distinct from offline (design §32).
        Rectangle {
            anchors.fill: parent
            visible: root.streamErrored && !root.isOffline
            color: "#0a0d11"
            Column {
                anchors.centerIn: parent
                spacing: 4
                Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "alert"; size: 26; color: Theme.warn }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "STREAM UNAVAILABLE"; color: Theme.warn
                    font.family: Theme.fontMono; font.pixelSize: 12; font.letterSpacing: 1.0
                }
            }
        }

        // ---- fault top edge ----
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 3
            z: 2
            visible: root.isFault
            color: root.isOffline ? Theme.bad : Theme.accent
        }

        // ---- header: name/id (left), badge stack (right) ----
        Item {
            id: hdr
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 48

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.7) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }

            Column {
                anchors { top: parent.top; left: parent.left; topMargin: 6; leftMargin: 8 }
                anchors.right: badges.left
                anchors.rightMargin: 8
                spacing: 1
                Text {
                    width: parent.width
                    text: root.camName; color: "#ffffff"; elide: Text.ElideRight
                    font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.DemiBold
                    style: Text.Raised; styleColor: Qt.rgba(0, 0, 0, 0.8)
                }
                Text {
                    text: root.camId; color: Qt.rgba(1, 1, 1, 0.6)
                    font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.4
                }
            }

            Row {
                id: badges
                anchors { top: parent.top; right: parent.right; topMargin: 6; rightMargin: 8 }
                spacing: 4
                LiveStatusBadge { state: root.live }
                RecordingStatusBadge { state: root.recording }
            }
        }

        // ---- inline issue strip (not-recording / degraded) ----
        Rectangle {
            visible: root.isNotRec || root.isDegraded
            anchors { left: parent.left; leftMargin: 8; bottom: parent.bottom; bottomMargin: 34 }
            implicitWidth: issueRow.implicitWidth + 20
            width: Math.min(implicitWidth, parent.width - 16)
            height: 22
            color: Qt.rgba(0, 0, 0, 0.9)

            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: 3
                color: root.isNotRec ? Theme.accent : Theme.warnDim
            }

            Row {
                id: issueRow
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 10
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.isNotRec ? "⚠" : "~"; color: Theme.warn; font.pixelSize: 11
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.isNotRec ? "LIVE, NO RECORDING" : "STREAM DEGRADED"
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 10
                    font.weight: Font.DemiBold; font.letterSpacing: 0.6
                }
                Text {
                    visible: root.isNotRec
                    anchors.verticalCenter: parent.verticalCenter
                    text: "VIEW ISSUE ›"; color: Theme.accent
                    font.family: Theme.fontMono; font.pixelSize: 10
                    font.weight: Font.DemiBold; font.letterSpacing: 0.6
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.issueRequested() }
                }
            }
        }

        // ---- hover action column ----
        Column {
            id: actions
            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
            spacing: 4
            visible: opacity > 0
            opacity: hover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }

            component TileAction: IconButton {
                bgColor: Qt.rgba(0, 0, 0, 0.85)
                borderColor: Theme.line2
                iconColor: Theme.ink
                hoverBg: Theme.accent
                hoverBorder: Theme.accent
                hoverIcon: Theme.bg
            }

            // Per-camera SD/HD stream toggle (defaults to the global setting; SD =
            // substream/responsive, HD = main stream). Switches the live feed.
            Rectangle {
                visible: root.rtspUrl !== ""
                width: 30
                height: 30
                color: hdMa.containsMouse ? Theme.accent : Qt.rgba(0, 0, 0, 0.85)
                border.width: 1
                border.color: hdMa.containsMouse ? Theme.accent : Theme.line2
                Text {
                    anchors.centerIn: parent
                    text: root.useMainStream ? "HD" : "SD"
                    color: hdMa.containsMouse ? Theme.bg : (root.useMainStream ? Theme.accent : Theme.ink)
                    font.family: Theme.fontMono
                    font.pixelSize: 10
                    font.weight: Font.Bold
                }
                MouseArea {
                    id: hdMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.useMainStream = !root.useMainStream
                }
            }

            TileAction { name: "clip"; tip: "Open playback"; onClicked: root.played() }
            TileAction { name: "shot"; tip: "Capture snapshot"; onClicked: root.captureSnapshot() }
            TileAction { name: "bookmark"; tip: "Add bookmark"; onClicked: root.bookmarkRequested() }
            TileAction {
                name: "star"
                tip: root.favorite ? "Remove from favorites" : "Add to favorites"
                iconColor: root.favorite ? Theme.accent : Theme.ink
                onClicked: root.favoriteToggled()
            }
            TileAction { name: "newtab"; tip: "Open in new tab"; onClicked: root.openedNewTab() }
        }

        HoverHandler { id: hover }
        TapHandler { onTapped: root.opened() }
    }
}
