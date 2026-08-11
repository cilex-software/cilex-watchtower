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
    // Events feed (EventModel) for the ARMED badge's motion-freshness readout.
    // Bound via motionRev (a cheap counter) — deliberately NOT via camera-row
    // updates, which would re-page tiles and restart their RTSP pipelines.
    property var eventsModel: null
    // CameraModel (for observed state-onset badge timers) — same rev-binding
    // pattern as eventsModel: no row re-paging.
    property var camModel: null
    readonly property double liveSinceMs:
        camModel ? (camModel.stateRev, camModel.liveSinceMs(camId)) : -1
    readonly property double recSinceMs:
        camModel ? (camModel.stateRev, camModel.recSinceMs(camId)) : -1
    readonly property double lastMotionAtMs:
        eventsModel ? (eventsModel.motionRev, eventsModel.lastMotionAtMs(camId)) : -1
    // LIVE "events are registering" indicator (distinct from ARMED, which only says
    // the MODE is on): hot while a motion episode is active (started with no ended)
    // or a motion event landed within the last ~45 s. Latency = the wall's motion
    // poll (~5 s); sub-second needs a push feed from the backend (CV ask).
    property int _motionTick: 0
    Timer {
        interval: 5000; repeat: true
        running: root.visible && root.eventsModel !== null && root.lastMotionAtMs > 0
        onTriggered: root._motionTick++
    }
    readonly property bool motionHot: {
        _motionTick;
        if (!eventsModel) return false;
        var rev = eventsModel.motionRev;
        if (eventsModel.motionActive(camId)) return true;
        var last = eventsModel.lastMotionAtMs(camId);
        return last > 0 && (Date.now() - last) < 45000;
    }
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
    property bool hasAudio: false          // audio supported (mic present, backend-reported)
    property bool audioRecording: false    // audio track recorded (ear vs muted ear)
    property string timestamp: ""
    property string lastSeen: ""
    property string lastSegmentAt: ""   // ISO of the last recorded segment (for the stalled strip)
    // Backend motion-readiness truth (P1 ask-4): known=false = field absent = unknown.
    property bool motionKnown: false
    property bool motionReady: false
    property string motionLastVmdAt: ""
    property int pattern: 0
    // In the Live Monitor grid the hairline separator comes from the grid
    // container, so the tile drops its own border (design §14).
    property bool gridMode: false
    // When false, a tap does NOT open the camera full-screen. The wall sets this false while
    // ARRANGING so a tap picks a camera for the cell (handled by the arrange overlay) instead —
    // the full-view TapHandler uses a passive grab that would otherwise ALSO fire under the
    // overlay, popping the camera open instead of the picker.
    property bool tapToOpen: true
    // One-touch autofocus (2026-08-03 letter). Model-string pre-gate (Z designator =
    // motorized lens, same heuristic as SingleCameraDetail.ptzCapable), then the free
    // backend probe confirms on first hover — only `lens`/`ptz` cameras get the AF chip,
    // so a mixed site never hands the guard a control that can only error (§3/§4).
    property string hwModel: ""
    readonly property bool afModelCapable:
        /PTZ/i.test(hwModel) || /\dZ[\s(]/.test(hwModel) || /\dZ$/.test(hwModel)
    property string ptzCaps: ""            // "" unknown · "pending" · "none" · "lens" · "ptz"
    property bool afFocusDead: false       // a focus command 501'd (cached) — chip hides
    Connections {
        target: Ptz
        enabled: root.afModelCapable
        function onCapsReady(id, supported, home, pendingBackend) {
            if (id === root.camId) root.ptzCaps = pendingBackend ? "pending" : supported;
        }
        function onFocusSupportChanged(id, supported) {
            if (id === root.camId) root.afFocusDead = !supported;
        }
    }
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
    // -1 = follow the global preference, 0 = forced SD, 1 = forced HD. A tri-state
    // rather than assigning over `useMainStream`: an imperative write destroys the
    // binding to Settings.defaultStreamHd for the life of the component, so after one
    // tap on this tile's SD/HD button the global preference silently stopped applying
    // to it until the app restarted. That is the "I changed SD to HD and it needed a
    // restart" report.
    property int hdOverride: -1
    readonly property bool useMainStream: gridMode ? false
        : (hdOverride < 0 ? Settings.defaultStreamHd : hdOverride === 1)
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
    // Merged-cell tile (cell spans): true when this tile occupies a merged region;
    // the hover row then offers Split (the wall handles the geometry).
    property bool spanned: false
    signal splitRequested()
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
        // Self-heal a STUCK tile (operator-reported: qsTr("STREAM UNAVAILABLE") while the
        // badges still read LIVE, cleared only by navigating away and back).
        //
        // VideoSurface's reconnect() re-assigns the same source on the SAME
        // MediaPlayer, which does not clear a latched player error — and the tile's
        // STREAM UNAVAILABLE is exactly `player.error != NoError`. The recovery that
        // always works is destroying and recreating the pipeline, which is all that
        // navigating away and back actually does. So do that here, automatically,
        // rather than making a guard leave the wall to fix a tile.
        //
        // Backs off 6s -> 15s -> 30s -> 60s: a camera that is genuinely down must not
        // cost a pipeline rebuild every few seconds, and at 130 cameras across 9 pages
        // that cost is multiplied by everything else the wall is doing.
        property bool _recycling: false
        property int _recycleTry: 0
        readonly property var _recycleBackoff: [6000, 15000, 30000, 60000]
        Timer {
            id: recycleHold                      // pipeline fully torn down before rebuild
            interval: 250
            onTriggered: base._recycling = false
        }
        Timer {
            id: errRecycle
            interval: base._recycleBackoff[Math.min(base._recycleTry, base._recycleBackoff.length - 1)]
            repeat: false
            running: root.streamErrored && !base._recycling && root.videoActive
                     && root.liveViewEnabled && root.liveDecodeAllowed
            onTriggered: {
                if (!root.streamErrored) return;
                // Logged unconditionally: a stuck tile healing itself must still be
                // COUNTABLE, or "the wall is flaky" stays an anecdote. There were zero
                // VideoSurface: warnings in the flight recorder across the whole
                // incident window, which is why this had no measurement at all.
                console.warn("[WT-TILE] recycling stuck pipeline ip=" + root.ip
                             + " try=" + (base._recycleTry + 1));
                base._recycleTry = Math.min(base._recycleTry + 1, base._recycleBackoff.length - 1);
                base._recycling = true;          // drops the Loader -> VideoSurface destroyed
                recycleHold.restart();           // ...and rebuilt fresh on release
            }
        }
        Connections {                          // frames back -> forget the backoff
            target: root
            function onStreamPlayingChanged() { if (root.streamPlaying) base._recycleTry = 0 }
        }

        Loader {
            id: videoLoader
            anchors.fill: parent
            active: !base._recycling && root.streamUrl !== "" && !root.isOffline && root.liveViewEnabled && root.liveDecodeAllowed
            visible: root.streamPlaying
            sourceComponent: VideoSurface {
                url: root.streamUrl
                active: root.videoActive
            }
        }

        // Decode-capped tile: a periodic go2rtc snapshot instead of a live VA-API pipeline,
        // so every camera stays visible while only `maxLiveDecodes` actually decode.
        // Live-decoded tiles keep this thumb ACTIVE too:
        // - as a WARMER (hidden): nobody else ever touches a live-decoded camera's
        //   cached-snapshot entry, so a section switch (Groups grid, pickers) hit ~16
        //   stone-cold entries serialized behind the client gate — measured 2026-08-02:
        //   groups content settle p90 2.3–3.9 s. Poll cadence 10.5 s is deliberately
        //   JUST ABOVE the server's 10 s freshness TTL: the server refills only on a
        //   miss, so polling faster merely reads the still-fresh entry and leaves a
        //   ~30% stale window; at TTL+0.5 every poll refills, stale window ~5%.
        //   (~1.5 cheap SUB fills/s fleet-wide — the same budget CV sized for their
        //   sweep; this becomes belt-and-braces when that ships.)
        // - as a CONNECTING BACKDROP (visible while the live pipeline (re)builds):
        //   returning to the Live section rebuilds up to 16 pipelines, which showed
        //   black + "Connecting…" for seconds; the ≤10 s-old snapshot is already in
        //   the pixmap cache, so show IT until real frames flow.
        LiveThumb {
            anchors.fill: parent
            visible: root.snapshotMode || (root.videoActive && !root.isOffline && !root.streamPlaying)
            active: root.videoActive
            refreshMs: root.snapshotMode
                       ? ((typeof wtThumbRefreshMs !== "undefined" && wtThumbRefreshMs > 0) ? wtThumbRefreshMs : 1000)
                       : 10500
            showOctet: false; showStatus: false      // the tile draws its own badges/octet
            cam: ({ snapshotUrl: root.snapshotUrl, ip: root.ip, live: root.live })
        }

        // Connecting indicator (while the stream negotiates / buffers). Live mode only —
        // a decode-capped tile is showing a snapshot, not connecting.
        LoadingState {
            anchors.centerIn: parent
            visible: root.hasStream && !root.streamPlaying && !root.streamErrored && root.liveDecodeAllowed
            label: qsTr("Connecting…")
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
                    text: qsTr("NO SIGNAL"); color: Theme.bad
                    font.family: Theme.fontMono; font.pixelSize: 13; font.letterSpacing: 1.3
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("last seen ") + root.lastSeen; color: Theme.ink3
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
                    text: qsTr("STREAM UNAVAILABLE"); color: Theme.warn
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
                    text: qsTr("LIVE VIEW OFF"); color: Theme.ink2
                    font.family: Theme.fontMono; font.pixelSize: 12; font.letterSpacing: 1.1
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("switched off by operator"); color: Theme.ink3
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
                // Decode-capped tile: a periodic still (~1 s refresh), NOT a live decode. Badge it so a
                // refreshing snapshot isn't mistaken for a real-time (or frozen) live feed.
                Rectangle {
                    visible: root.snapshotMode
                    anchors.verticalCenter: parent.verticalCenter
                    height: 14; radius: 2; width: snapLbl.implicitWidth + 9
                    color: Qt.rgba(0, 0, 0, 0.55); border.width: 1; border.color: Theme.line2
                    Text {
                        id: snapLbl; anchors.centerIn: parent; text: qsTr("◌ SNAPSHOT")
                        color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 0.6
                    }
                }
                StatusBadge {                     // live event-registration signal
                    visible: root.motionHot
                    label: qsTr("MOTION")
                    fg: Theme.accent; bgColor: Theme.accentDim
                    dotColor: Theme.accent; dotPulse: true; dotHollow: false
                }
                LiveStatusBadge { state: root.live; sinceMs: root.liveSinceMs }
                RecordingStatusBadge {
                    state: root.recOff ? CameraStatus.Disabled : root.recording
                    lastMotionAtMs: root.lastMotionAtMs
                    stateSinceMs: root.recSinceMs
                    lastSegmentAtMs: root.lastSegmentAt !== "" ? Date.parse(root.lastSegmentAt) : -1
                    motionKnown: root.motionKnown
                    motionReady: root.motionReady
                    lastVmdAtMs: root.motionLastVmdAt !== "" ? Date.parse(root.motionLastVmdAt) : -1
                }
                // Audio-recording state (backend `audio` fields; letter 2026-07-16).
                // No ear at all when the camera can't record audio / state unknown.
                Icon {
                    visible: root.hasAudio
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.audioRecording ? "ear" : "earMute"
                    size: 13
                    color: root.audioRecording ? Theme.good : Theme.ink3
                }
            }
        }

        // ---- inline issue strip (stalled / not-recording / degraded) ----
        Rectangle {
            visible: root.isDegraded || (!root.recOff && (root.isNotRec || root.isStalled))
            // Above the hover action row: their bands nearly touch in short tiles, and
            // the VIEW ISSUE link must never lose clicks to an overlapping panel.
            z: 5
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
                          ? (qsTr("RECORDING STALLED") + (root.lastSegmentAt !== "" ? "  ·  " + qsTr("since") + " " + Settings.clock(new Date(root.lastSegmentAt).getTime(), false) : ""))
                          : (root.isNotRec ? qsTr("LIVE, NO RECORDING") : qsTr("STREAM DEGRADED"))
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 10
                    font.weight: Font.DemiBold; font.letterSpacing: 0.6
                }
                Text {
                    visible: root.isNotRec || root.isStalled
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("VIEW ISSUE") + " ›"; color: Theme.accent
                    font.family: Theme.fontMono; font.pixelSize: 10
                    font.weight: Font.DemiBold; font.letterSpacing: 0.6
                    // A link must read as one: underline on hover (the cursor alone
                    // wasn't enough affordance), and a padded hit area so it wins
                    // clicks even at tile edges.
                    font.underline: issueMa.containsMouse
                    MouseArea {
                        id: issueMa
                        anchors.fill: parent; anchors.margins: -5
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.issueRequested()
                    }
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
                    text: parent.on ? qsTr("HD") : qsTr("SD")
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
                                             : (root.hdOverride = root.useMainStream ? 0 : 1)
                }
            }

            // One-touch autofocus chip — same chrome as the SD/HD chip. Visible only
            // when the model pre-gate holds AND the backend probe didn't say no.
            Rectangle {
                visible: root.afModelCapable && root.ptzCaps !== "none" && root.ptzCaps !== "pending"
                         && !root.afFocusDead
                width: afTileTxt.implicitWidth + 12; height: 20; radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: afTileMa.containsMouse ? Theme.accent : Qt.rgba(0, 0, 0, 0.55)
                border.width: 1; border.color: afTileMa.containsMouse ? Theme.accent : Theme.line2
                onVisibleChanged: if (visible && root.camId !== "") {
                    root.afFocusDead = Ptz.focusDead(root.camId);   // session cache, tile recycling
                    if (root.ptzCaps === "")
                        Ptz.probe(root.camId);   // free, cached, never touches the camera
                }
                Text {
                    id: afTileTxt; anchors.centerIn: parent; text: qsTr("AF")
                    color: afTileMa.containsMouse ? Theme.bg : Theme.ink
                    font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.Bold
                }
                MouseArea {
                    id: afTileMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Ptz.focusAutoRequest(root.camId)
                }
            }
            TileAction { name: "playback"; tip: qsTr("Open playback"); onClicked: root.played() }
            TileAction { name: "shot"; tip: qsTr("Capture snapshot"); onClicked: root.captureSnapshot() }
            TileToggle {
                name: "star"
                on: root.favorite
                tip: root.favorite ? qsTr("Remove from favorites") : qsTr("Add to favorites")
                onClicked: root.favoriteToggled()
            }
            TileAction { name: "newtab"; tip: qsTr("Open in new tab"); onClicked: root.openedNewTab() }
            TileAction { visible: root.spanned; name: "split"; tip: qsTr("Split into 1×1 cells")
                         onClicked: root.splitRequested() }
        }

        HoverHandler { id: hover }
        TapHandler {
            enabled: root.tapToOpen
            // The tap handler's passive grab fires EVEN WHEN a hover-row button's
            // MouseArea handled the click (same Qt semantics the arrange overlay
            // comment above documents) — so a snapshot/action click also opened
            // the camera full-screen (operator report 2026-07-11). A tap that
            // lands inside the actions row belongs to its buttons alone.
            onTapped: (eventPoint) => {
                var local = actions.mapFromGlobal(eventPoint.globalPosition.x, eventPoint.globalPosition.y);
                if (!(actions.visible && actions.contains(Qt.point(local.x, local.y))))
                    root.opened();
            }
        }
    }
}
