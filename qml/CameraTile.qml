import QtQuick
import Watchtower

// The core reusable tile (design §15). Video fills the tile; a gradient header
// carries the camera name/id and the dual status-badge stack; fault states get
// a 3px top edge, an inline issue strip, or a NO SIGNAL fallback; a hover action
// row (bottom-right) exposes SD/HD / playback / snapshot / bookmark / favorite /
// open-in-new-tab. A horizontal row fits short tiles in dense (4×4/5×5) grids
// where a vertical column would overflow and clip.
Item {
    id: root

    property string camName: ""
    property string camId: ""
    property string ip: ""
    property string groupId: ""

    // The backend name bakes the IP in ("HiWatch DS-… (192.168.1.104)"); strip it
    // so the IP can be shown (or hidden) independently via the overlay toggle.
    readonly property string displayName: {
        var n = camName;
        var suffix = ip !== "" ? (" (" + ip + ")") : "";
        if (suffix !== "" && n.endsWith(suffix))
            n = n.slice(0, n.length - suffix.length);
        return n;
    }
    // Composed overlay meta line (IP and/or camId), per the Settings toggles.
    readonly property string overlayMeta: {
        var parts = [];
        if (Settings.overlayShowIp && ip !== "") parts.push(ip);
        if (Settings.overlayShowId && camId !== "") parts.push(camId);
        return parts.join("  ·  ");
    }
    property string groupName: ""
    property int live: CameraStatus.Live
    property int recording: CameraStatus.Recording
    property bool favorite: false
    property bool hasAudio: false
    property string timestamp: ""
    property string lastSeen: ""
    property string lastSegmentAt: ""   // ISO of the last recorded segment (for the stalled strip)
    property int pattern: 0
    // In the Live Monitor grid the hairline separator comes from the grid
    // container, so the tile drops its own border (design §14).
    property bool gridMode: false
    // Live View business-function state (from the model). When false, an operator
    // stopped go2rtc → show a calm "switched off" tile, not a red fault.
    property bool liveViewEnabled: true
    // Recording business-function state. When false, an operator switched recording
    // off → the not-rec/stalled states are expected, so show a calm "OFF" badge
    // instead of a red STALLED fault.
    property bool recordingEnabled: true
    readonly property bool recOff: !recordingEnabled

    // Live video. When videoActive and a stream URL is present, the tile plays
    // it; a Loader instantiates the player only then, so paged-out/offline tiles
    // stay cheap. The grid uses the substream (Hikvision channel 102) to keep
    // many simultaneous decodes light; focused views can use the main stream.
    property string rtspUrl: ""       // main stream (on-demand HD only)
    property string rtspSubUrl: ""    // substream — the default for monitoring
    property bool videoActive: false
    // Concurrent-decode cap. Each live VA-API decode holds hundreds of MB on the shared iGPU,
    // so the grid runs only a bounded number at once (set by LiveMonitor, by tile position).
    // A tile beyond the cap shows a periodic SNAPSHOT (LiveThumb) instead of a live pipeline —
    // every camera stays visible, but only `maxLiveDecodes` actually decode.
    property bool liveDecodeAllowed: true
    property string snapshotUrl: ""     // go2rtc frame.jpeg, for the snapshot when decode-capped
    readonly property bool snapshotMode: !liveDecodeAllowed && !isOffline && liveViewEnabled && streamUrl !== ""
    // The live wall is ALWAYS SD (substream): many simultaneous decodes must stay
    // light and near real-time, so the wall never follows the global HD preference.
    // The per-tile HD button can still promote a single tile on demand. (gridMode
    // is the wall — the only place CameraTile is used today.)
    property bool useMainStream: gridMode ? false : Settings.defaultStreamHd
    readonly property string streamUrl: (useMainStream && rtspUrl !== "")
        ? rtspUrl
        : (rtspSubUrl !== "" ? rtspSubUrl : rtspUrl)
    readonly property bool hasStream: streamUrl !== "" && videoActive && !isOffline
    readonly property bool streamPlaying: videoLoader.item ? videoLoader.item.playing : false
    readonly property bool streamErrored: videoLoader.item ? videoLoader.item.errored : false

    readonly property bool isOffline: live === CameraStatus.Offline
    readonly property bool isNotRec: recording === CameraStatus.NotRecording
    readonly property bool isStalled: recording === CameraStatus.Stalled
    readonly property bool isArmed: recording === CameraStatus.Armed
    readonly property bool isDegraded: live === CameraStatus.Degraded
    readonly property bool isGap: recording === CameraStatus.RecordingGap
    // Recording states (not-rec / gap / stalled) are NOT faults when an operator
    // has deliberately switched recording off — only offline/degraded still are.
    readonly property bool isFault: isOffline || isDegraded
                                    || (!root.recOff && (isNotRec || isGap || isStalled))

    readonly property string geom: groupName.toLowerCase().indexOf("park") >= 0 ? "parking"
                                  : (groupName.toLowerCase().indexOf("lob") >= 0 ? "lobby" : "corridor")

    signal opened()
    signal played()
    signal snapshotRequested()
    signal snapshotSaved(string path, string camName)
    signal favoriteToggled()
    signal openedNewTab()
    signal issueRequested()
    // Asks the wall to promote/demote this tile's HD stream. In the grid the wall
    // gates promotion against a concurrency cap (go2rtc transcode budget) rather
    // than letting the tile flip itself; a focused (non-grid) tile flips freely.
    signal hdToggleRequested()

    // Capture a still and announce it. Prefer the main stream via go2rtc's
    // frame.jpeg endpoint (always full-res, regardless of which stream the
    // wall is rendering); fall back to grabbing the rendered tile if the HTTP
    // request fails. The HD path is async — completion arrives via the
    // Artifacts.snapshotCaptured/snapshotCaptureFailed signals below.
    function captureSnapshot() {
        if (root.rtspUrl !== "") {
            Artifacts.captureMainStreamSnapshot(root.camId, root.camName, root.rtspUrl);
        } else {
            captureFromTile();
        }
    }

    function captureFromTile() {
        var target = (streamPlaying && videoLoader.item) ? videoLoader.item : base;
        target.grabToImage(function(result) {
            var path = Artifacts.newSnapshotPath(root.camId);
            if (result.saveToFile(path))
                root.snapshotSaved(path, root.camName);
        });
    }

    Connections {
        target: Artifacts
        function onSnapshotCaptured(path, camId, camName) {
            if (camId === root.camId)
                root.snapshotSaved(path, camName);
        }
        function onSnapshotCaptureFailed(camId, camName, reason) {
            if (camId !== root.camId)
                return;
            console.warn("HD snapshot failed for", camId, "—", reason, "; falling back to tile grab");
            root.captureFromTile();
        }
    }

    Rectangle {
        id: base
        anchors.fill: parent
        color: Theme.tileBg
        clip: true
        border.width: root.gridMode ? 0 : 1
        border.color: root.gridMode ? "transparent"
                      : (hover.hovered ? Theme.accent
                      : ((root.isOffline || root.isStalled) ? Theme.bad
                      : ((root.isNotRec || root.isDegraded) ? Theme.accent : Theme.line2)))

        // ---- video / fallback ----
        // Placeholder fallback: shown until a live frame arrives (or when the
        // tile is paged out / the stream fails).
        PlaceholderVid {
            anchors.fill: parent
            visible: !root.isOffline && !root.streamPlaying && root.liveDecodeAllowed
            pattern: root.pattern
            ts: root.timestamp
            label: root.camId
            geom: root.geom
        }

        // Live stream — kept alive across short visibility changes.
        // Tearing down 16 RTSP pipelines at once on a section nav (e.g. opening
        // Preferences) freezes the GUI on GStreamer's TEARDOWN, so we hold the
        // VideoSurface alive as long as the camera has a stream URL. Players
        // keep running quietly in the background; the actual teardown happens
        // only when the tile itself is destroyed (paging, sign-out).
        // Exception: when Live View is switched off, go2rtc is stopped, so the
        // pipelines are dead either way — drop the Loader (tearing down already-
        // failed pipelines is cheap) so it is FRESHLY recreated, and reconnects,
        // when Live View is switched back on (otherwise the players stay stuck on
        // STREAM UNAVAILABLE and never retry).
        Loader {
            id: videoLoader
            anchors.fill: parent
            active: root.streamUrl !== "" && !root.isOffline && root.liveViewEnabled && root.liveDecodeAllowed
            visible: root.streamPlaying
            sourceComponent: VideoSurface {
                url: root.streamUrl
                active: root.videoActive
            }
        }

        // Decode-capped tile: a periodic go2rtc snapshot instead of a live VA-API pipeline,
        // so every camera stays visible while only `maxLiveDecodes` actually decode.
        LiveThumb {
            anchors.fill: parent
            visible: root.snapshotMode
            active: root.videoActive && root.snapshotMode
            showOctet: false; showStatus: false      // the tile draws its own badges/octet
            cam: root.snapshotMode ? ({ snapshotUrl: root.snapshotUrl, ip: root.ip, live: root.live }) : null
        }

        // Connecting indicator (while the stream negotiates / buffers). Live mode only —
        // a decode-capped tile is showing a snapshot, not connecting.
        LoadingState {
            anchors.centerIn: parent
            visible: root.hasStream && !root.streamPlaying && !root.streamErrored && root.liveDecodeAllowed
            label: "Connecting…"
            ringSize: 18
        }

        // Loading progress bar along the bottom edge while the stream is connecting or
        // reconnecting (no frames yet). Indeterminate — a stream connection has no real
        // percentage, so an honest sweeping segment signals "working on it" without
        // fabricating progress. Disappears the moment frames flow (streamPlaying).
        Rectangle {
            id: loadBar
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 3
            visible: root.hasStream && !root.streamPlaying && !root.streamErrored && root.liveDecodeAllowed
            color: "#141a22"          // dim track
            clip: true
            Rectangle {
                height: parent.height
                width: parent.width * 0.35
                color: Theme.accent
                SequentialAnimation on x {
                    running: loadBar.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: -loadBar.width * 0.35; to: loadBar.width; duration: 1100; easing.type: Easing.InOutSine }
                }
            }
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

        // Live View switched off by an operator (go2rtc stopped) — a deliberate
        // state, not a fault. Opaque, calm (muted, never red); covers the
        // offline/unavailable/connecting states beneath it.
        Rectangle {
            anchors.fill: parent
            visible: !root.liveViewEnabled
            color: "#0a0d11"
            z: 1
            Column {
                anchors.centerIn: parent
                spacing: 5
                Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 26; color: Theme.ink3 }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "LIVE VIEW OFF"; color: Theme.ink2
                    font.family: Theme.fontMono; font.pixelSize: 12; font.letterSpacing: 1.1
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "switched off by operator"; color: Theme.ink3
                    font.family: Theme.fontSans; font.pixelSize: 10
                }
            }
        }

        // ---- fault top edge ----
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 3
            z: 2
            // Suppressed when Live View is deliberately off (that's not a fault).
            visible: root.isFault && root.liveViewEnabled
            color: (root.isOffline || root.isStalled) ? Theme.bad : Theme.accent
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
                    visible: Settings.overlayShowName && text !== ""
                    text: root.displayName; color: "#ffffff"; elide: Text.ElideRight
                    font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.DemiBold
                    style: Text.Raised; styleColor: Qt.rgba(0, 0, 0, 0.8)
                }
                Text {
                    width: parent.width
                    visible: text !== ""
                    text: root.overlayMeta; color: Qt.rgba(1, 1, 1, 0.6); elide: Text.ElideRight
                    font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.4
                }
            }

            Row {
                id: badges
                anchors { top: parent.top; right: parent.right; topMargin: 6; rightMargin: 8 }
                spacing: 4
                LiveStatusBadge { state: root.live }
                RecordingStatusBadge { state: root.recOff ? CameraStatus.Disabled : root.recording }
            }
        }

        // ---- inline issue strip (stalled / not-recording / degraded) ----
        Rectangle {
            visible: root.isDegraded || (!root.recOff && (root.isNotRec || root.isStalled))
            anchors { left: parent.left; leftMargin: 8; bottom: parent.bottom; bottomMargin: 34 }
            implicitWidth: issueRow.implicitWidth + 20
            width: Math.min(implicitWidth, parent.width - 16)
            height: 22
            color: Qt.rgba(0, 0, 0, 0.9)

            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: 3
                color: root.isStalled ? Theme.bad : (root.isNotRec ? Theme.accent : Theme.warnDim)
            }

            Row {
                id: issueRow
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 10
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (root.isStalled || root.isNotRec) ? "⚠" : "~"
                    color: root.isStalled ? Theme.bad : Theme.warn; font.pixelSize: 11
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.isStalled
                          ? ("RECORDING STALLED" + (root.lastSegmentAt !== "" ? "  ·  since " + Settings.clock(new Date(root.lastSegmentAt).getTime(), false) : ""))
                          : (root.isNotRec ? "LIVE, NO RECORDING" : "STREAM DEGRADED")
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 10
                    font.weight: Font.DemiBold; font.letterSpacing: 0.6
                }
                Text {
                    visible: root.isNotRec || root.isStalled
                    anchors.verticalCenter: parent.verticalCenter
                    text: "VIEW ISSUE ›"; color: Theme.accent
                    font.family: Theme.fontMono; font.pixelSize: 10
                    font.weight: Font.DemiBold; font.letterSpacing: 0.6
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.issueRequested() }
                }
            }
        }

        // ---- hover action row (bottom-right) ----
        // A horizontal row so all actions fit even in dense grids where the tile is
        // short (a vertical column overflowed and clipped — see 4×4 / 5×5).
        Row {
            id: actions
            anchors { right: parent.right; rightMargin: 8; bottom: parent.bottom; bottomMargin: 8 }
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
            // A toggle action: when `on`, it stays filled (accent) so the operator
            // sees the active state — and clicking again clears it.
            component TileToggle: IconButton {
                property bool on: false
                bgColor: on ? Theme.accent : Qt.rgba(0, 0, 0, 0.85)
                borderColor: on ? Theme.accent : Theme.line2
                iconColor: on ? Theme.bg : Theme.ink
                hoverBg: Theme.accent
                hoverBorder: Theme.accent
                hoverIcon: Theme.bg
            }

            // Per-camera SD/HD stream toggle (defaults to the global setting; SD =
            // substream/responsive, HD = main stream). Switches the live feed; HD
            // stays filled-accent while active.
            Rectangle {
                visible: root.rtspUrl !== ""
                width: 30
                height: 30
                readonly property bool on: root.useMainStream
                color: (hdMa.containsMouse || on) ? Theme.accent : Qt.rgba(0, 0, 0, 0.85)
                border.width: 1
                border.color: (hdMa.containsMouse || on) ? Theme.accent : Theme.line2
                Text {
                    anchors.centerIn: parent
                    text: parent.on ? "HD" : "SD"
                    color: (hdMa.containsMouse || parent.on) ? Theme.bg : Theme.ink
                    font.family: Theme.fontMono
                    font.pixelSize: 10
                    font.weight: Font.Bold
                }
                MouseArea {
                    id: hdMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // In the wall the parent gates HD promotion against the
                    // concurrency cap; a focused tile flips its own stream.
                    onClicked: root.gridMode ? root.hdToggleRequested()
                                             : (root.useMainStream = !root.useMainStream)
                }
            }

            TileAction { name: "playback"; tip: "Open playback"; onClicked: root.played() }
            TileAction { name: "shot"; tip: "Capture snapshot"; onClicked: root.captureSnapshot() }
            TileToggle {
                name: "star"
                on: root.favorite
                tip: root.favorite ? "Remove from favorites" : "Add to favorites"
                onClicked: root.favoriteToggled()
            }
            TileAction { name: "newtab"; tip: "Open in new tab"; onClicked: root.openedNewTab() }
        }

        HoverHandler { id: hover }
        TapHandler { onTapped: root.opened() }
    }
}
